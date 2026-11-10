// The HTTP app, written against the Fetch API so it runs unchanged on Node and on Workers.
import * as auth from "./auth.js";
import { categorize, DEFAULT_CAP_TOKENS, DeciderError, setConsent, status as deciderStatus } from "./categorize.js";
import { deleteAllData, exportCsv, exportJson } from "./export.js";
import { DEFAULT_MAX_USERS, PeopleError, deleteUser, getUser, spacesOf } from "./people.js";
import * as spaces from "./spaces.js";
import { LOCALES } from "./locales.js";
import { pull, push, ValidationError } from "./sync.js";
import * as oauth from "./oauth.js";
import { handleMcp } from "./mcp.js";

const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
  "Cross-Origin-Opener-Policy": "same-origin",
};

const MAX_BODY = 1024 * 1024;

/** Wraps a response with the security headers every response carries. */
export function withSecurityHeaders(res, https) {
  const r = new Response(res.body, res);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) r.headers.set(k, v);
  if (https) r.headers.set("Strict-Transport-Security", "max-age=31536000");
  return r;
}

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

const error = (code, status) => json({ error: code }, status);

/**
 * @param {object} cfg
 * @param {string} cfg.origin   public origin, for example https://harina.example.org
 * @param {string} [cfg.setupToken]  HARINA_SETUP_TOKEN, needed only for first-run setup
 * @param {string} [cfg.coreSha]     LZNO_CORE_SHA or any build identifier, shown by /health
 * @param {string|boolean} [cfg.cimd]  HARINA_OAUTH_CIMD: "off" disables Client ID Metadata Documents
 * @param {string} [cfg.mcpOrigins]  HARINA_MCP_ORIGINS: extra browser origins allowed on /mcp, comma separated
 * @param {string} [cfg.timeZone]    HARINA_TZ for month boundaries in assistant answers (default America/Costa_Rica)
 * @param {string} [cfg.signup]      HARINA_SIGNUP: "open" lets anyone sign up; anything else keeps it closed (first person only)
 * @param {string|number} [cfg.maxUsers]  HARINA_MAX_USERS: cap on people when sign-up is open (default 1000)
 * @param {string} [cfg.privacyUrl]  HARINA_PRIVACY_URL: privacy notice shown when creating an account
 * @param {string} [cfg.termsUrl]    HARINA_TERMS_URL: terms of use shown when creating an account
 * @param {Function} [cfg.fetch]     fetch used for CIMD documents (tests inject one)
 */
export function normalizeConfig(cfg) {
  const url = new URL(cfg.origin);
  return {
    origin: url.origin,
    rpID: url.hostname,
    https: url.protocol === "https:",
    setupToken: cfg.setupToken || "",
    coreSha: cfg.coreSha || "dev",
    cimd: cfg.cimd !== false && cfg.cimd !== "off",
    mcpOrigins: String(cfg.mcpOrigins ?? "").split(",").map((s) => s.trim()).filter(Boolean),
    timeZone: cfg.timeZone || "America/Costa_Rica",
    defaultCurrency: cfg.defaultCurrency || "CRC",
    signup: cfg.signup === "open" ? "open" : "closed",
    privacyUrl: /^https:\/\//.test(cfg.privacyUrl ?? "") ? cfg.privacyUrl : null,
    termsUrl: /^https:\/\//.test(cfg.termsUrl ?? "") ? cfg.termsUrl : null,
    maxUsers: Number.isSafeInteger(Number(cfg.maxUsers)) && Number(cfg.maxUsers) > 0 ? Number(cfg.maxUsers) : DEFAULT_MAX_USERS,
    fetch: cfg.fetch ?? ((...a) => fetch(...a)),
  };
}

// Discovery, registration and token endpoints are called by other sites' clients.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name",
  "Access-Control-Max-Age": "86400",
};

function oauthError(e) {
  return json({ error: e.code, error_description: e.description }, e.status, CORS);
}

async function readForm(req) {
  const type = req.headers.get("Content-Type") ?? "";
  const text = await req.text();
  if (text.length > 16384) throw new oauth.OAuthError("invalid_request", "request too large");
  if (type.startsWith("application/json")) {
    try {
      return new URLSearchParams(Object.entries(JSON.parse(text)).map(([k, v]) => [k, String(v)]));
    } catch {
      throw new oauth.OAuthError("invalid_request", "invalid JSON");
    }
  }
  return new URLSearchParams(text);
}

function cookieName(cfg) {
  return cfg.https ? "__Host-harina" : "harina_session";
}

function readCookie(req, name) {
  for (const part of (req.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return "";
}

function sessionCookie(cfg, token, maxAgeMs) {
  const attrs = [`${cookieName(cfg)}=${token}`, "Path=/", "HttpOnly", "SameSite=Strict", `Max-Age=${Math.floor(maxAgeMs / 1000)}`];
  if (cfg.https) attrs.push("Secure");
  return attrs.join("; ");
}

async function readJson(req) {
  const len = Number(req.headers.get("Content-Length") ?? 0);
  if (len > MAX_BODY) throw new ValidationError("too_large");
  if (!(req.headers.get("Content-Type") ?? "").startsWith("application/json")) throw new ValidationError("json_required");
  const text = await req.text();
  if (text.length > MAX_BODY) throw new ValidationError("too_large");
  try {
    return JSON.parse(text || "{}");
  } catch {
    throw new ValidationError("invalid_json");
  }
}

/**
 * @param {{ db: import("./storage/db.js").Db, config: object, assets?: (req: Request) => Promise<Response>, decider?: object | null }} deps
 */
export function createApp({ db, config, assets, decider = null }) {
  const cfg = normalizeConfig(config);
  const capRaw = config?.aiCapTokens === "" || config?.aiCapTokens === undefined || config?.aiCapTokens === null ? NaN : Number(config.aiCapTokens);
  const capTokens = Number.isSafeInteger(capRaw) && capRaw >= 0 ? capRaw : DEFAULT_CAP_TOKENS;

  async function principal(req) {
    const bearer = (req.headers.get("Authorization") ?? "").match(/^Bearer (.+)$/)?.[1];
    if (bearer) {
      const device = await auth.deviceFromToken(db, bearer);
      return device ? { kind: "device", device: device.id, userId: device.userId } : null;
    }
    const token = readCookie(req, cookieName(cfg));
    const userId = await auth.sessionUser(db, token);
    return userId ? { kind: "session", token, userId } : null;
  }

  /** The spaces a signed-in person can reach (docs/adr/0006-people-and-spaces.md). */
  async function scope(userId) {
    const s = await spacesOf(db, userId);
    return { spaces: s.ids, personal: s.personal, userId };
  }

  const clientIp = (req) => req.headers.get("CF-Connecting-IP") ?? req.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ?? "local";

  // Cookie-authenticated writes must come from our own pages (CSRF defense on top of SameSite).
  function sameOrigin(req) {
    return req.headers.get("Origin") === cfg.origin;
  }

  async function route(req) {
    const url = new URL(req.url);
    const { pathname: path } = url;
    const method = req.method;

    if (path === "/health" && method === "GET") return json({ ok: true, core: cfg.coreSha });

    const lang = path.match(/^\/locales\/([a-z]{2})\.json$/)?.[1];
    if (lang && method === "GET") {
      return LOCALES[lang]
        ? new Response(JSON.stringify(LOCALES[lang]), { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-cache" } })
        : error("not_found", 404);
    }

    // ----- OAuth and MCP (docs/adr/0004-oauth-and-mcp.md) -----
    const corsPath = path.startsWith("/.well-known/oauth-") || path === "/oauth/token" || path === "/oauth/register" || path === "/oauth/revoke";
    if (corsPath && method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (path === "/.well-known/oauth-protected-resource" || path === "/.well-known/oauth-protected-resource/mcp") {
      return json(oauth.protectedResourceMetadata(cfg), 200, CORS);
    }
    if (path === "/.well-known/oauth-authorization-server") return json(oauth.authorizationServerMetadata(cfg), 200, CORS);
    if (path === "/oauth/register" && method === "POST") {
      try {
        return json(await oauth.registerClient(db, JSON.parse((await req.text()) || "{}")), 201, CORS);
      } catch (e) {
        if (e instanceof oauth.OAuthError) return oauthError(e);
        if (e instanceof SyntaxError) return oauthError(new oauth.OAuthError("invalid_client_metadata", "invalid JSON"));
        throw e;
      }
    }
    if (path === "/oauth/authorize" && method === "GET") {
      try {
        const { redirect } = await oauth.startAuthorization(db, cfg, url.searchParams);
        return new Response(null, { status: 302, headers: { Location: redirect, "Cache-Control": "no-store" } });
      } catch (e) {
        if (!(e instanceof oauth.OAuthError)) throw e;
        // Never redirect to an unverified URI: show the error on harina's own page.
        return new Response(null, { status: 302, headers: { Location: `${cfg.origin}/#/autorizar/error/${e.code}` } });
      }
    }
    if (path === "/oauth/token" && method === "POST") {
      try {
        return json(await oauth.token(db, cfg, await readForm(req)), 200, { ...CORS, Pragma: "no-cache" });
      } catch (e) {
        if (e instanceof oauth.OAuthError) return oauthError(e);
        throw e;
      }
    }
    if (path === "/oauth/revoke" && method === "POST") {
      await oauth.revoke(db, await readForm(req));
      return json({}, 200, CORS);
    }
    if (path === "/mcp") return handleMcp(req, { db, cfg });

    if (!path.startsWith("/api/")) {
      return assets ? assets(req) : error("not_found", 404);
    }

    const who = await principal(req);
    if (!who && req.headers.has("Authorization")) return error("unauthorized", 401);
    if (method !== "GET" && who?.kind === "session" && !sameOrigin(req)) return error("bad_origin", 403);
    // The iPhone app has no Origin: linking and signing up from it are the only anonymous writes it makes.
    const fromApp = path === "/api/devices/link" || path === "/api/auth/signup/device";
    if (method !== "GET" && !who && !sameOrigin(req) && !fromApp) return error("bad_origin", 403);
    const needSession = () => {
      if (who?.kind !== "session") throw new auth.AuthError("unauthorized", 401);
    };
    const needAny = () => {
      if (!who) throw new auth.AuthError("unauthorized", 401);
    };

    switch (`${method} ${path}`) {
      case "GET /api/session": {
        const user = who?.kind === "session" ? await getUser(db, who.userId) : null;
        return json({
          authenticated: Boolean(user),
          user: user ? { id: user.id, name: user.name, hasPasskey: await auth.hasPasskey(db, user.id) } : null,
          setupNeeded: await auth.setupNeeded(db),
          signup: cfg.signup,
          legal: { privacy: cfg.privacyUrl, terms: cfg.termsUrl },
          origin: cfg.origin,
        });
      }

      case "POST /api/auth/register/options": {
        const body = await readJson(req);
        const userId = who?.kind === "session" ? who.userId : null;
        return json(await auth.registrationOptions(db, cfg, { userId, setupToken: body.setupToken, ip: clientIp(req) }));
      }
      case "POST /api/auth/register/verify": {
        const body = await readJson(req);
        const userId = who?.kind === "session" ? who.userId : null;
        const r = await auth.registrationVerify(db, cfg, { ...body, userId });
        if (!r.session) return json({ ok: true });
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, r.session.token, auth.SESSION_TTL_MS) });
      }
      case "POST /api/auth/login/options":
        return json(await auth.authenticationOptions(db, cfg));
      case "POST /api/auth/login/verify": {
        const s = await auth.authenticationVerify(db, cfg, await readJson(req));
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, s.token, auth.SESSION_TTL_MS) });
      }
      case "POST /api/auth/logout":
        if (who?.kind === "session") await auth.endSession(db, who.token);
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, "", 0) });

      // Sign up from the iPhone: a new person and this device's token in one step.
      case "POST /api/auth/signup/device": {
        const body = await readJson(req);
        return json(await auth.signupDevice(db, cfg, { name: body.name, deviceName: body.deviceName, ip: clientIp(req) }));
      }
      // The iPhone shows a one-time code to open the same account on the web.
      case "POST /api/auth/web-code":
        if (who?.kind !== "device") throw new auth.AuthError("unauthorized", 401);
        return json(await auth.createCode(db, who.userId, "web"));
      case "POST /api/auth/web-code/redeem": {
        const body = await readJson(req);
        const r = await auth.redeemWebCode(db, body);
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, r.session.token, auth.SESSION_TTL_MS) });
      }

      case "POST /api/devices/link-code":
        needSession();
        return json(await auth.createCode(db, who.userId, "link"));
      case "POST /api/devices/link": {
        const body = await readJson(req);
        return json(await auth.linkDevice(db, body));
      }
      case "GET /api/devices":
        needSession();
        return json({ devices: await auth.listDevices(db, who.userId) });

      case "GET /api/sync": {
        needAny();
        const since = Number(url.searchParams.get("since") ?? 0);
        if (!Number.isSafeInteger(since) || since < 0) return error("invalid_since", 400);
        // The spaces travel with every pull so devices notice a joined or removed space.
        return json({ ...(await pull(db, since, (await scope(who.userId)).spaces)), spaces: await spaces.listSpaces(db, who.userId) });
      }
      case "POST /api/sync": {
        needAny();
        const body = await readJson(req);
        return json(await push(db, body.changes, await scope(who.userId)));
      }

      // ----- Shared spaces (docs/design/people-and-spaces.md, phase 2) -----
      case "GET /api/spaces":
        needAny();
        return json({ spaces: await spaces.listSpaces(db, who.userId) });
      case "POST /api/spaces": {
        needAny();
        const id = await spaces.createSpace(db, who.userId, await readJson(req));
        return json({ id, spaces: await spaces.listSpaces(db, who.userId) });
      }
      case "POST /api/invites/accept": {
        needAny();
        const space = await spaces.acceptInvite(db, who.userId, await readJson(req));
        return json({ space, spaces: await spaces.listSpaces(db, who.userId) });
      }
      case "PATCH /api/me":
        needAny();
        await spaces.renameMe(db, who.userId, await readJson(req));
        return json({ ok: true });

      // ----- Hosted category decider (docs/design/hosted-decision-model.md) -----
      case "GET /api/decider":
        needAny();
        return json(await deciderStatus(db, decider, capTokens, who.userId));
      case "POST /api/decider/consent": {
        needAny();
        const body = await readJson(req);
        if (typeof body.on !== "boolean") return error("invalid_consent", 400);
        await setConsent(db, who.userId, body.on);
        return json(await deciderStatus(db, decider, capTokens, who.userId));
      }
      case "POST /api/categorize": {
        needAny();
        const body = await readJson(req);
        try {
          return json(await categorize(db, decider, capTokens, await scope(who.userId), body));
        } catch (e) {
          if (e instanceof DeciderError) return error(e.code, e.status);
          throw e;
        }
      }

      case "GET /api/export.json":
        needAny();
        return json(await exportJson(db, (await scope(who.userId)).spaces), 200, { "Content-Disposition": 'attachment; filename="harina.json"' });
      case "GET /api/export.csv":
        needAny();
        return new Response(await exportCsv(db, (await scope(who.userId)).spaces), {
          headers: {
            "Content-Type": "text/csv; charset=utf-8",
            "Content-Disposition": 'attachment; filename="harina.csv"',
            "Cache-Control": "no-store",
          },
        });
      case "POST /api/data/delete": {
        needSession();
        const body = await readJson(req);
        if (body.confirm !== true) return error("confirmation_required", 400);
        await deleteAllData(db, (await scope(who.userId)).personal);
        return json({ ok: true });
      }
      // Deletes the person: personal space, passkeys, devices and connections (ADR-0006).
      case "POST /api/account/delete": {
        needSession();
        const body = await readJson(req);
        if (body.confirm !== true) return error("confirmation_required", 400);
        await deleteUser(db, who.userId);
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, "", 0) });
      }
    }

    const oreq = path.match(/^\/api\/oauth\/requests\/([A-Za-z0-9_-]{1,64})$/);
    if (oreq && method === "GET") {
      needSession();
      try {
        return json(await oauth.describeRequest(db, cfg, oreq[1]));
      } catch (e) {
        if (e instanceof oauth.OAuthError) return error(e.code, e.status === 404 ? 404 : 400);
        throw e;
      }
    }
    if (path === "/api/oauth/decision" && method === "POST") {
      needSession();
      const body = await readJson(req);
      try {
        return json(await oauth.decide(db, cfg, { id: body.id, approve: body.approve === true, write: body.write === true, userId: who.userId }));
      } catch (e) {
        if (e instanceof oauth.OAuthError) return error(e.code, e.status === 404 ? 404 : 400);
        throw e;
      }
    }
    if (path === "/api/connections" && method === "GET") {
      needSession();
      return json({ connections: await oauth.listGrants(db, who.userId) });
    }
    const conn = path.match(/^\/api\/connections\/([A-Za-z0-9_-]{1,64})$/);
    if (conn && method === "DELETE") {
      needSession();
      await oauth.revokeGrant(db, who.userId, conn[1]);
      return json({ ok: true });
    }

    const sp = path.match(/^\/api\/spaces\/([A-Za-z0-9_-]{1,64})(\/invites|\/leave|\/members\/([A-Za-z0-9_-]{1,64}))?$/);
    if (sp) {
      needAny();
      const [, id, sub, member] = sp;
      if (!sub && method === "PATCH") await spaces.renameSpace(db, who.userId, id, await readJson(req));
      else if (!sub && method === "DELETE") await spaces.deleteSpace(db, who.userId, id);
      else if (sub === "/invites" && method === "POST") return json(await spaces.createInvite(db, who.userId, id));
      else if (sub === "/leave" && method === "POST") await spaces.leaveSpace(db, who.userId, id);
      else if (member && method === "DELETE") await spaces.removeMember(db, who.userId, id, member);
      else return error("not_found", 404);
      return json({ spaces: await spaces.listSpaces(db, who.userId) });
    }

    const dev = path.match(/^\/api\/devices\/([A-Za-z0-9_-]{1,64})$/);
    if (dev && method === "DELETE") {
      needSession();
      await auth.revokeDevice(db, who.userId, dev[1]);
      return json({ ok: true });
    }
    return error("not_found", 404);
  }

  return async function fetch(req) {
    let res;
    try {
      res = await route(req);
    } catch (e) {
      if (e instanceof auth.AuthError || e instanceof PeopleError) res = error(e.code, e.status);
      else if (e instanceof ValidationError) res = json({ error: e.code, detail: e.detail }, 400);
      else {
        console.error(e);
        res = error("internal", 500);
      }
    }
    return withSecurityHeaders(res, cfg.https);
  };
}
