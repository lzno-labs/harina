import assert from "node:assert/strict";
import { ORIGIN, setup } from "./helpers.js";

export const CLAUDE_CIMD = "https://claude.ai/oauth/claude-client.json";
export const CLAUDE_REDIRECT = "https://claude.ai/api/mcp/auth_callback";

/** A fake CIMD host for the client metadata documents. */
export function fakeFetch(docs) {
  return async (url) => {
    const doc = docs[url];
    if (!doc) return new Response("not found", { status: 404 });
    return new Response(JSON.stringify(doc), { status: 200, headers: { "Content-Type": "application/json" } });
  };
}

export async function pkce() {
  const verifier = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
  const challenge = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))).toString("base64url");
  return { verifier, challenge };
}

export const form = (o) => ({ body: new URLSearchParams(o).toString(), headers: { "Content-Type": "application/x-www-form-urlencoded" } });

/** Runs the whole flow up to tokens. */
export async function connect(ctx, { clientId = CLAUDE_CIMD, redirect = CLAUDE_REDIRECT, scope = "harina.read harina.write", write = true } = {}) {
  const { app, call, login } = ctx;
  const { verifier, challenge } = await pkce();
  const q = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirect,
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope,
    state: "xyz",
    resource: `${ORIGIN}/mcp`,
  });
  const start = await call(`/oauth/authorize?${q}`);
  assert.equal(start.status, 302);
  const consent = start.headers.get("Location");
  const reqId = consent.match(/#\/autorizar\/(.+)$/)?.[1];
  assert.ok(reqId, consent);
  const session = await login();
  const described = await (await call(`/api/oauth/requests/${reqId}`, { headers: session })).json();
  const decision = await (await call("/api/oauth/decision", { method: "POST", body: { id: reqId, approve: true, write }, headers: session })).json();
  const back = new URL(decision.redirect);
  assert.equal(back.searchParams.get("state"), "xyz");
  assert.equal(back.searchParams.get("iss"), ORIGIN);
  const code = back.searchParams.get("code");
  const tokenRes = await app(
    new Request(`${ORIGIN}/oauth/token`, {
      method: "POST",
      ...form({ grant_type: "authorization_code", code, redirect_uri: redirect, client_id: clientId, code_verifier: verifier, resource: `${ORIGIN}/mcp` }),
    }),
  );
  return { described, tokens: await tokenRes.json(), status: tokenRes.status, code, verifier, session };
}

export const cimdSetup = () =>
  setup({
    fetch: fakeFetch({
      [CLAUDE_CIMD]: { client_id: CLAUDE_CIMD, client_name: "Claude", redirect_uris: [CLAUDE_REDIRECT], token_endpoint_auth_method: "none" },
    }),
  });

