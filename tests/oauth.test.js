import assert from "node:assert/strict";
import { test } from "node:test";
import { ORIGIN, setup } from "./helpers.js";

import { CLAUDE_CIMD, CLAUDE_REDIRECT, cimdSetup, connect, form, pkce } from "./oauth-helpers.js";

test("discovery metadata follows the MCP authorization profile", async () => {
  const { call } = await setup();
  const prm = await (await call("/.well-known/oauth-protected-resource/mcp")).json();
  assert.deepEqual([prm.resource, prm.authorization_servers], [`${ORIGIN}/mcp`, [ORIGIN]]);
  const as = await (await call("/.well-known/oauth-authorization-server")).json();
  assert.equal(as.issuer, ORIGIN);
  assert.deepEqual(as.code_challenge_methods_supported, ["S256"]);
  assert.deepEqual(as.token_endpoint_auth_methods_supported, ["none"]);
  assert.equal(as.client_id_metadata_document_supported, true);
  assert.equal(as.authorization_response_iss_parameter_supported, true);
  const r = await call("/.well-known/oauth-authorization-server");
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
});

test("CIMD client: consent, code, tokens, refresh rotation and reuse detection", async () => {
  const ctx = await cimdSetup();
  const { described, tokens, status } = await connect(ctx);
  assert.equal(status, 200, JSON.stringify(tokens));
  assert.deepEqual(described.client, { name: "Claude", host: "claude.ai", kind: "cimd" });
  assert.deepEqual(described.scopes, ["harina.read", "harina.write"]);
  assert.equal(tokens.token_type, "Bearer");
  assert.equal(tokens.scope, "harina.read harina.write");

  const refresh = (rt, extra = {}) =>
    ctx.app(new Request(`${ORIGIN}/oauth/token`, { method: "POST", ...form({ grant_type: "refresh_token", refresh_token: rt, client_id: CLAUDE_CIMD, ...extra }) }));
  const r1 = await refresh(tokens.refresh_token);
  assert.equal(r1.status, 200);
  const t1 = await r1.json();
  assert.notEqual(t1.refresh_token, tokens.refresh_token);
  // Reusing the old refresh token revokes the whole connection, including the new tokens.
  const reuse = await refresh(tokens.refresh_token);
  assert.equal((await reuse.json()).error, "invalid_grant");
  assert.equal((await refresh(t1.refresh_token)).status, 400);
  const { connections } = await (await ctx.call("/api/connections", { headers: await ctx.login() })).json();
  assert.equal(connections.length, 0);
});

test("dynamic registration works for public clients only", async () => {
  const ctx = await setup();
  const bad = await ctx.call("/oauth/register", { method: "POST", body: { redirect_uris: ["http://evil.example/cb"] } });
  assert.equal((await bad.json()).error, "invalid_redirect_uri");
  const secret = await ctx.call("/oauth/register", { method: "POST", body: { redirect_uris: ["https://chatgpt.com/connector_platform_oauth_redirect"], token_endpoint_auth_method: "client_secret_basic" } });
  assert.equal(secret.status, 400);
  const reg = await (await ctx.call("/oauth/register", { method: "POST", body: { client_name: "ChatGPT", redirect_uris: ["https://chatgpt.com/connector_platform_oauth_redirect"] } })).json();
  assert.match(reg.client_id, /^dcr_/);
  const { tokens, status, described } = await connect(ctx, { clientId: reg.client_id, redirect: "https://chatgpt.com/connector_platform_oauth_redirect", scope: "harina.read", write: false });
  assert.equal(status, 200);
  assert.equal(tokens.scope, "harina.read");
  assert.equal(described.client.host, "chatgpt.com");
});

test("loopback redirects match on any port (Claude Code, Gemini CLI)", async () => {
  const ctx = await setup();
  const reg = await (await ctx.call("/oauth/register", { method: "POST", body: { redirect_uris: ["http://localhost/callback"] } })).json();
  const { status } = await connect(ctx, { clientId: reg.client_id, redirect: "http://localhost:3118/callback" });
  assert.equal(status, 200);
});

test("authorization requests are validated before anything is shown", async () => {
  const ctx = await cimdSetup();
  const { challenge } = await pkce();
  const base = { response_type: "code", client_id: CLAUDE_CIMD, redirect_uri: CLAUDE_REDIRECT, code_challenge: challenge, code_challenge_method: "S256", scope: "harina.read", state: "s" };
  const go = async (over) => (await ctx.call(`/oauth/authorize?${new URLSearchParams({ ...base, ...over })}`)).headers.get("Location");
  assert.match(await go({ redirect_uri: "https://evil.example/cb" }), /#\/autorizar\/error\/invalid_request$/, "never redirect to an unregistered URI");
  assert.match(await go({ client_id: "https://unknown.example/client.json" }), /#\/autorizar\/error\/invalid_client$/);
  assert.match(await go({ client_id: "https://127.0.0.1/client.json" }), /#\/autorizar\/error\/invalid_client$/, "no IP-literal CIMD hosts");
  assert.match(await go({ code_challenge_method: "plain" }), /^https:\/\/claude\.ai\/api\/mcp\/auth_callback\?error=invalid_request/);
  assert.match(await go({ resource: "https://other.example/mcp" }), /error=invalid_target/);
  assert.match(await go({ scope: "harina.read harina.delete" }), /error=invalid_scope/);
});

test("codes are single use and PKCE, client and redirect must match", async () => {
  const ctx = await cimdSetup();
  const { code, verifier } = await connect(ctx);
  const again = await ctx.app(
    new Request(`${ORIGIN}/oauth/token`, { method: "POST", ...form({ grant_type: "authorization_code", code, redirect_uri: CLAUDE_REDIRECT, client_id: CLAUDE_CIMD, code_verifier: verifier }) }),
  );
  assert.equal((await again.json()).error, "invalid_grant");

  for (const over of [{ code_verifier: "x".repeat(43) }, { redirect_uri: "https://claude.ai/other" }, { client_id: "dcr_someone_else" }]) {
    // A fresh code each time, exchanged with one wrong field.
    const ctx2 = await cimdSetup();
    const flow = await connectNoExchange(ctx2);
    const res = await ctx2.app(
      new Request(`${ORIGIN}/oauth/token`, {
        method: "POST",
        ...form({ grant_type: "authorization_code", code: flow.code, redirect_uri: CLAUDE_REDIRECT, client_id: CLAUDE_CIMD, code_verifier: flow.verifier, ...over }),
      }),
    );
    assert.equal(res.status, 400, JSON.stringify(over));
  }
});

async function connectNoExchange(ctx) {
  const { verifier, challenge } = await pkce();
  const q = new URLSearchParams({ response_type: "code", client_id: CLAUDE_CIMD, redirect_uri: CLAUDE_REDIRECT, code_challenge: challenge, code_challenge_method: "S256", scope: "harina.read" });
  const reqId = (await ctx.call(`/oauth/authorize?${q}`)).headers.get("Location").match(/#\/autorizar\/(.+)$/)[1];
  const session = await ctx.login();
  const { redirect } = await (await ctx.call("/api/oauth/decision", { method: "POST", body: { id: reqId, approve: true }, headers: session })).json();
  return { code: new URL(redirect).searchParams.get("code"), verifier };
}

test("the consent decision needs the passkey session and our Origin; denying returns access_denied", async () => {
  const ctx = await cimdSetup();
  const { challenge } = await pkce();
  const q = new URLSearchParams({ response_type: "code", client_id: CLAUDE_CIMD, redirect_uri: CLAUDE_REDIRECT, code_challenge: challenge, code_challenge_method: "S256", state: "s" });
  const reqId = (await ctx.call(`/oauth/authorize?${q}`)).headers.get("Location").match(/#\/autorizar\/(.+)$/)[1];
  assert.equal((await ctx.call("/api/oauth/decision", { method: "POST", body: { id: reqId, approve: true }, headers: { Origin: ORIGIN } })).status, 401);
  const { Cookie } = await ctx.login();
  assert.equal((await ctx.call("/api/oauth/decision", { method: "POST", body: { id: reqId, approve: true }, headers: { Cookie } })).status, 403);
  const denied = await (await ctx.call("/api/oauth/decision", { method: "POST", body: { id: reqId, approve: false }, headers: { Cookie, Origin: ORIGIN } })).json();
  assert.match(denied.redirect, /error=access_denied/);
  assert.equal((await ctx.call(`/api/oauth/requests/${reqId}`, { headers: { Cookie, Origin: ORIGIN } })).status, 404, "a request is decided once");
});

test("connections are listed and revocable; revoked tokens stop working", async () => {
  const ctx = await cimdSetup();
  const { tokens, session } = await connect(ctx);
  const { connections } = await (await ctx.call("/api/connections", { headers: session })).json();
  assert.equal(connections.length, 1);
  assert.equal(connections[0].client_name, "Claude");
  assert.equal(connections[0].host, "claude.ai");
  await ctx.call(`/api/connections/${connections[0].id}`, { method: "DELETE", headers: session });
  const r = await ctx.call("/mcp", { method: "POST", body: { jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: { Authorization: `Bearer ${tokens.access_token}` } });
  assert.equal(r.status, 401);
});
