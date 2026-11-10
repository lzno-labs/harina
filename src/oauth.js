// OAuth 2.1 authorization server for the MCP endpoint (docs/adr/0004-oauth-and-mcp.md).
// Public clients only (PKCE S256), identified by a Client ID Metadata Document (CIMD) or by
// dynamic registration. Opaque tokens, stored as SHA-256 hashes, bound to the /mcp resource.
import { randomToken, sha256 } from "./crypto.js";

export const SCOPES = ["harina.read", "harina.write"];
export const ACCESS_TTL_MS = 60 * 60 * 1000;
export const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export const CODE_TTL_MS = 5 * 60 * 1000;
export const REQUEST_TTL_MS = 10 * 60 * 1000;
export const CIMD_TTL_MS = 24 * 60 * 60 * 1000;
export const MAX_DCR_CLIENTS = 200;
const MAX_CIMD_BYTES = 64 * 1024;

export class OAuthError extends Error {
  /** @param {string} code RFC 6749 error code */
  constructor(code, description, status = 400) {
    super(code);
    this.code = code;
    this.description = description;
    this.status = status;
  }
}

export const resourceOf = (cfg) => `${cfg.origin}/mcp`;

export function protectedResourceMetadata(cfg) {
  return {
    resource: resourceOf(cfg),
    authorization_servers: [cfg.origin],
    scopes_supported: SCOPES,
    bearer_methods_supported: ["header"],
    resource_name: "Harina",
  };
}

export function authorizationServerMetadata(cfg) {
  return {
    issuer: cfg.origin,
    authorization_endpoint: `${cfg.origin}/oauth/authorize`,
    token_endpoint: `${cfg.origin}/oauth/token`,
    registration_endpoint: `${cfg.origin}/oauth/register`,
    revocation_endpoint: `${cfg.origin}/oauth/revoke`,
    response_types_supported: ["code"],
    response_modes_supported: ["query"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    revocation_endpoint_auth_methods_supported: ["none"],
    scopes_supported: SCOPES,
    client_id_metadata_document_supported: cfg.cimd,
    authorization_response_iss_parameter_supported: true,
  };
}

// ---------- clients ----------

/** Redirect URIs a public client may use: https, or http on a loopback host (native and CLI clients). */
function validRedirect(uri) {
  let u;
  try {
    u = new URL(uri);
  } catch {
    return false;
  }
  if (u.hash || u.username || u.password) return false;
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname);
}

/** Exact match, except loopback redirects, which match on any port (RFC 8252). */
export function redirectAllowed(registered, requested) {
  if (registered.includes(requested)) return true;
  let r;
  try {
    r = new URL(requested);
  } catch {
    return false;
  }
  if (r.protocol !== "http:" || !["localhost", "127.0.0.1", "[::1]"].includes(r.hostname)) return false;
  return registered.some((x) => {
    try {
      const u = new URL(x);
      return u.protocol === "http:" && u.hostname === r.hostname && u.pathname === r.pathname && u.search === r.search;
    } catch {
      return false;
    }
  });
}

/** A CIMD client id is an https URL with a path, on a public host name (not an IP or a local name). */
export function isCimdClientId(id) {
  let u;
  try {
    u = new URL(id);
  } catch {
    return false;
  }
  if (u.protocol !== "https:" || u.pathname === "/" || u.hash || u.username || u.password || u.port) return false;
  const h = u.hostname.toLowerCase();
  if (/^[\d.]+$/.test(h) || h.includes(":") || h.startsWith("[")) return false;
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal") || !h.includes(".")) return false;
  return true;
}

async function fetchCimd(cfg, clientId) {
  let res;
  try {
    res = await cfg.fetch(clientId, { redirect: "manual", headers: { Accept: "application/json" }, signal: AbortSignal.timeout(5000) });
  } catch {
    throw new OAuthError("invalid_client", "client metadata document could not be fetched");
  }
  if (res.status !== 200) throw new OAuthError("invalid_client", "client metadata document not found");
  const text = await res.text();
  if (text.length > MAX_CIMD_BYTES) throw new OAuthError("invalid_client", "client metadata document too large");
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    throw new OAuthError("invalid_client", "client metadata document is not JSON");
  }
  if (doc.client_id !== clientId) throw new OAuthError("invalid_client", "client_id does not match the document URL");
  if (!Array.isArray(doc.redirect_uris) || !doc.redirect_uris.length || !doc.redirect_uris.every(validRedirect)) {
    throw new OAuthError("invalid_client", "invalid redirect_uris");
  }
  if (doc.token_endpoint_auth_method && doc.token_endpoint_auth_method !== "none") {
    throw new OAuthError("invalid_client", "only public clients are supported");
  }
  return { name: typeof doc.client_name === "string" ? doc.client_name.slice(0, 100) : null, redirect_uris: doc.redirect_uris };
}

/** Looks up a client, fetching (and caching for a day) a CIMD document when the id is a URL. */
export async function getClient(db, cfg, clientId) {
  if (typeof clientId !== "string" || !clientId || clientId.length > 512) throw new OAuthError("invalid_client", "missing client_id");
  const row = await db.first("SELECT * FROM oauth_clients WHERE id = ?", [clientId]);
  if (row && (row.kind === "dcr" || row.fetched_at > Date.now() - CIMD_TTL_MS)) {
    return { id: row.id, kind: row.kind, name: row.name, redirect_uris: JSON.parse(row.redirect_uris) };
  }
  if (!cfg.cimd || !isCimdClientId(clientId)) throw new OAuthError("invalid_client", "unknown client");
  const doc = await fetchCimd(cfg, clientId);
  await db.run(
    "INSERT INTO oauth_clients (id, kind, name, redirect_uris, fetched_at, created_at) VALUES (?, 'cimd', ?, ?, ?, ?) " +
      "ON CONFLICT (id) DO UPDATE SET name = excluded.name, redirect_uris = excluded.redirect_uris, fetched_at = excluded.fetched_at",
    [clientId, doc.name, JSON.stringify(doc.redirect_uris), Date.now(), Date.now()],
  );
  return { id: clientId, kind: "cimd", name: doc.name, redirect_uris: doc.redirect_uris };
}

/** RFC 7591 dynamic registration for public clients. Capped, since anyone can call it. */
export async function registerClient(db, body) {
  const uris = body?.redirect_uris;
  if (!Array.isArray(uris) || !uris.length || uris.length > 10 || !uris.every((u) => typeof u === "string" && validRedirect(u))) {
    throw new OAuthError("invalid_redirect_uri", "redirect_uris must be https or loopback http URLs");
  }
  if (body.token_endpoint_auth_method && body.token_endpoint_auth_method !== "none") {
    throw new OAuthError("invalid_client_metadata", "only public clients (token_endpoint_auth_method none) are supported");
  }
  const count = (await db.first("SELECT COUNT(*) AS n FROM oauth_clients WHERE kind = 'dcr'")).n;
  if (count >= MAX_DCR_CLIENTS) {
    // Make room by forgetting registrations that never got a grant.
    await db.run("DELETE FROM oauth_clients WHERE kind = 'dcr' AND id NOT IN (SELECT client_id FROM oauth_grants) AND created_at < ?", [
      Date.now() - 24 * 60 * 60 * 1000,
    ]);
    if ((await db.first("SELECT COUNT(*) AS n FROM oauth_clients WHERE kind = 'dcr'")).n >= MAX_DCR_CLIENTS) {
      throw new OAuthError("temporarily_unavailable", "too many registered clients", 503);
    }
  }
  const id = `dcr_${randomToken(16)}`;
  const name = typeof body.client_name === "string" ? body.client_name.slice(0, 100) : null;
  await db.run("INSERT INTO oauth_clients (id, kind, name, redirect_uris, fetched_at, created_at) VALUES (?, 'dcr', ?, ?, ?, ?)", [
    id,
    name,
    JSON.stringify(uris),
    Date.now(),
    Date.now(),
  ]);
  return {
    client_id: id,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    client_name: name ?? undefined,
    redirect_uris: uris,
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  };
}

// ---------- authorization ----------

export function parseScopes(text) {
  const asked = String(text ?? "").split(/\s+/).filter(Boolean);
  if (asked.some((s) => !SCOPES.includes(s))) throw new OAuthError("invalid_scope", "unknown scope");
  // Reading is always part of a connection; writing only when asked for and then approved.
  return SCOPES.filter((s) => s === "harina.read" || asked.includes(s));
}

/**
 * Validates GET /oauth/authorize. Errors about the client or redirect URI are shown to the person
 * (never redirected); other errors are sent back to the client's redirect URI.
 * @returns {{ redirect: string }} where the browser goes next
 */
export async function startAuthorization(db, cfg, params) {
  const client = await getClient(db, cfg, params.get("client_id"));
  const redirectUri = params.get("redirect_uri") ?? (client.redirect_uris.length === 1 ? client.redirect_uris[0] : null);
  if (!redirectUri || !redirectAllowed(client.redirect_uris, redirectUri)) throw new OAuthError("invalid_request", "redirect_uri is not registered for this client");
  const back = (error, description) => ({ redirect: withParams(redirectUri, { error, error_description: description, state: params.get("state"), iss: cfg.origin }) });
  if (params.get("response_type") !== "code") return back("unsupported_response_type", "response_type must be code");
  const challenge = params.get("code_challenge");
  if (params.get("code_challenge_method") !== "S256" || !challenge || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
    return back("invalid_request", "PKCE with S256 is required");
  }
  const resource = params.get("resource") ?? resourceOf(cfg);
  if (resource !== resourceOf(cfg)) return back("invalid_target", "unknown resource");
  let scopes;
  try {
    scopes = parseScopes(params.get("scope"));
  } catch (e) {
    return back(e.code, e.description);
  }
  const id = randomToken(18);
  await db.run("DELETE FROM oauth_requests WHERE expires_at < ?", [Date.now()]);
  await db.run(
    "INSERT INTO oauth_requests (id, client_id, redirect_uri, state, scopes, code_challenge, resource, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [id, client.id, redirectUri, params.get("state"), scopes.join(" "), challenge, resource, Date.now() + REQUEST_TTL_MS],
  );
  return { redirect: `${cfg.origin}/#/autorizar/${id}` };
}

function withParams(uri, params) {
  const u = new URL(uri);
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined) u.searchParams.set(k, v);
  return u.toString();
}

async function pendingRequest(db, id) {
  const req = await db.first("SELECT * FROM oauth_requests WHERE id = ?", [String(id ?? "")]);
  if (!req || req.expires_at < Date.now()) throw new OAuthError("request_expired", "authorization request expired", 404);
  return req;
}

/** What the consent page shows: who is asking, from where, and for what. */
export async function describeRequest(db, cfg, id) {
  const req = await pendingRequest(db, id);
  const client = await getClient(db, cfg, req.client_id);
  return {
    client: { name: client.name, host: new URL(client.kind === "cimd" ? client.id : req.redirect_uri).host, kind: client.kind },
    redirectHost: new URL(req.redirect_uri).host,
    scopes: req.scopes.split(" "),
  };
}

/** The person's decision on the consent page (passkey session required by the caller). */
export async function decide(db, cfg, { id, approve, write }) {
  const req = await pendingRequest(db, id);
  await db.run("DELETE FROM oauth_requests WHERE id = ?", [req.id]);
  if (!approve) return { redirect: withParams(req.redirect_uri, { error: "access_denied", state: req.state, iss: cfg.origin }) };
  const scopes = req.scopes.split(" ").filter((s) => s === "harina.read" || (s === "harina.write" && write === true));
  const client = await getClient(db, cfg, req.client_id);
  const grantId = randomToken(12);
  await db.run(
    "INSERT INTO oauth_grants (id, client_id, client_name, scopes, resource, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
    [grantId, client.id, client.name, scopes.join(" "), req.resource, Date.now()],
  );
  const code = randomToken(32);
  await db.run(
    "INSERT INTO oauth_codes (code_hash, grant_id, client_id, redirect_uri, code_challenge, resource, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [await sha256(code), grantId, client.id, req.redirect_uri, req.code_challenge, req.resource, Date.now() + CODE_TTL_MS],
  );
  return { redirect: withParams(req.redirect_uri, { code, state: req.state, iss: cfg.origin }) };
}

// ---------- tokens ----------

async function s256(verifier) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(d))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function issueTokens(db, grant) {
  const access = randomToken(32);
  const refresh = randomToken(32);
  const now = Date.now();
  await db.batch([
    { sql: "INSERT INTO oauth_tokens (token_hash, grant_id, kind, scopes, expires_at) VALUES (?, ?, 'access', ?, ?)", params: [await sha256(access), grant.id, grant.scopes, now + ACCESS_TTL_MS] },
    { sql: "INSERT INTO oauth_tokens (token_hash, grant_id, kind, scopes, expires_at) VALUES (?, ?, 'refresh', ?, ?)", params: [await sha256(refresh), grant.id, grant.scopes, now + REFRESH_TTL_MS] },
    { sql: "DELETE FROM oauth_tokens WHERE expires_at < ?", params: [now - REFRESH_TTL_MS] },
  ]);
  return { access_token: access, token_type: "Bearer", expires_in: ACCESS_TTL_MS / 1000, refresh_token: refresh, scope: grant.scopes };
}

async function revokeGrantTokens(db, grantId) {
  await db.batch([
    { sql: "UPDATE oauth_grants SET revoked = 1 WHERE id = ?", params: [grantId] },
    { sql: "DELETE FROM oauth_tokens WHERE grant_id = ?", params: [grantId] },
    { sql: "DELETE FROM oauth_codes WHERE grant_id = ?", params: [grantId] },
  ]);
}

/** POST /oauth/token with form fields. */
export async function token(db, cfg, form) {
  const grantType = form.get("grant_type");
  const clientId = form.get("client_id");
  if (grantType === "authorization_code") {
    const hash = await sha256(String(form.get("code") ?? ""));
    const code = await db.first("SELECT * FROM oauth_codes WHERE code_hash = ?", [hash]);
    if (!code) throw new OAuthError("invalid_grant", "invalid or used code");
    await db.run("DELETE FROM oauth_codes WHERE code_hash = ?", [hash]); // single use
    if (code.expires_at < Date.now()) throw new OAuthError("invalid_grant", "code expired");
    if (code.client_id !== clientId) throw new OAuthError("invalid_grant", "code was issued to another client");
    if (code.redirect_uri !== form.get("redirect_uri")) throw new OAuthError("invalid_grant", "redirect_uri does not match");
    const resource = form.get("resource") ?? code.resource;
    if (resource !== code.resource) throw new OAuthError("invalid_target", "resource does not match");
    const verifier = String(form.get("code_verifier") ?? "");
    if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) || (await s256(verifier)) !== code.code_challenge) {
      await revokeGrantTokens(db, code.grant_id);
      throw new OAuthError("invalid_grant", "PKCE verification failed");
    }
    const grant = await db.first("SELECT * FROM oauth_grants WHERE id = ? AND revoked = 0", [code.grant_id]);
    if (!grant) throw new OAuthError("invalid_grant", "grant revoked");
    return issueTokens(db, grant);
  }
  if (grantType === "refresh_token") {
    const hash = await sha256(String(form.get("refresh_token") ?? ""));
    const row = await db.first("SELECT * FROM oauth_tokens WHERE token_hash = ? AND kind = 'refresh'", [hash]);
    if (!row) throw new OAuthError("invalid_grant", "invalid refresh token");
    const grant = await db.first("SELECT * FROM oauth_grants WHERE id = ?", [row.grant_id]);
    if (!grant || grant.revoked) throw new OAuthError("invalid_grant", "grant revoked");
    if (row.used) {
      // A rotated refresh token came back: someone else may hold it. Revoke the whole connection.
      await revokeGrantTokens(db, grant.id);
      throw new OAuthError("invalid_grant", "refresh token reuse detected; connection revoked");
    }
    if (row.expires_at < Date.now()) throw new OAuthError("invalid_grant", "refresh token expired");
    if (grant.client_id !== clientId) throw new OAuthError("invalid_grant", "token was issued to another client");
    const resource = form.get("resource") ?? grant.resource;
    if (resource !== grant.resource) throw new OAuthError("invalid_target", "resource does not match");
    let scopes = grant.scopes;
    if (form.get("scope")) {
      const asked = String(form.get("scope")).split(/\s+/).filter(Boolean);
      if (asked.some((s) => !grant.scopes.split(" ").includes(s))) throw new OAuthError("invalid_scope", "scope exceeds the grant");
      scopes = asked.join(" ");
    }
    await db.run("UPDATE oauth_tokens SET used = 1 WHERE token_hash = ?", [hash]);
    return issueTokens(db, { ...grant, scopes });
  }
  throw new OAuthError("unsupported_grant_type", "use authorization_code or refresh_token");
}

/** RFC 7009: always succeeds; revoking a refresh token ends the whole connection. */
export async function revoke(db, form) {
  const hash = await sha256(String(form.get("token") ?? ""));
  const row = await db.first("SELECT * FROM oauth_tokens WHERE token_hash = ?", [hash]);
  if (!row) return;
  if (row.kind === "refresh") await revokeGrantTokens(db, row.grant_id);
  else await db.run("DELETE FROM oauth_tokens WHERE token_hash = ?", [hash]);
}

/** The connection behind a bearer token for this resource, or null. */
export async function verifyAccessToken(db, cfg, bearer) {
  if (!bearer) return null;
  const row = await db.first(
    "SELECT t.scopes, t.expires_at, g.id AS grant_id, g.resource, g.revoked, g.client_name FROM oauth_tokens t JOIN oauth_grants g ON g.id = t.grant_id " +
      "WHERE t.token_hash = ? AND t.kind = 'access'",
    [await sha256(bearer)],
  );
  if (!row || row.revoked || row.expires_at < Date.now() || row.resource !== resourceOf(cfg)) return null;
  await db.run("UPDATE oauth_grants SET last_used_at = ? WHERE id = ?", [Date.now(), row.grant_id]);
  return { grantId: row.grant_id, scopes: row.scopes.split(" "), clientName: row.client_name };
}

export async function listGrants(db) {
  return (await db.all("SELECT id, client_id, client_name, scopes, created_at, last_used_at FROM oauth_grants WHERE revoked = 0 ORDER BY created_at DESC")).map(
    (g) => ({ ...g, scopes: g.scopes.split(" "), host: hostOf(g.client_id) }),
  );
}

function hostOf(clientId) {
  try {
    return new URL(clientId).host;
  } catch {
    return null;
  }
}

export async function revokeGrant(db, id) {
  await revokeGrantTokens(db, id);
}
