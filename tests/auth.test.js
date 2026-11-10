import assert from "node:assert/strict";
import { test } from "node:test";
import { createAuthenticator } from "./fake-authenticator.js";
import { ORIGIN, setup } from "./helpers.js";

const cookieOf = (res) => res.headers.get("Set-Cookie").split(";")[0];

test("first-run setup needs the setup token, then closes", async () => {
  const { call } = await setup();
  const h = { Origin: ORIGIN };
  assert.equal((await (await call("/api/session")).json()).setupNeeded, true);

  const bad = await call("/api/auth/register/options", { method: "POST", body: { setupToken: "nope" }, headers: h });
  assert.equal(bad.status, 403);
  assert.equal((await bad.json()).error, "setup_required");

  const authn = await createAuthenticator();
  const { challengeId, options } = await (await call("/api/auth/register/options", { method: "POST", body: { setupToken: "secret-setup" }, headers: h })).json();
  assert.equal(options.rp.id, "harina.test");
  const response = await authn.register(options, ORIGIN);
  const ok = await call("/api/auth/register/verify", { method: "POST", body: { setupToken: "secret-setup", challengeId, response }, headers: h });
  assert.equal(ok.status, 200, await ok.clone().text());
  const cookie = cookieOf(ok);
  assert.match(ok.headers.get("Set-Cookie"), /HttpOnly; SameSite=Strict.*Secure/);

  const s = await (await call("/api/session", { headers: { Cookie: cookie } })).json();
  assert.deepEqual([s.authenticated, s.setupNeeded], [true, false]);

  // Sign-up is closed by default: the setup token only creates the first person.
  const again = await call("/api/auth/register/options", { method: "POST", body: { setupToken: "secret-setup" }, headers: h });
  assert.equal((await again.json()).error, "signup_closed");

  // Log in with the same passkey; the challenge is single use.
  const lo = await (await call("/api/auth/login/options", { method: "POST", body: {}, headers: h })).json();
  const assertion = await authn.login(lo.options, ORIGIN);
  const li = await call("/api/auth/login/verify", { method: "POST", body: { challengeId: lo.challengeId, response: assertion }, headers: h });
  assert.equal(li.status, 200, await li.clone().text());
  const replay = await call("/api/auth/login/verify", { method: "POST", body: { challengeId: lo.challengeId, response: assertion }, headers: h });
  assert.equal(replay.status, 400);

  // Logout ends the session.
  await call("/api/auth/logout", { method: "POST", body: {}, headers: { ...h, Cookie: cookieOf(li) } });
  assert.equal((await call("/api/sync", { headers: { Cookie: cookieOf(li) } })).status, 401);
});

test("an assertion for another origin is rejected", async () => {
  const { call } = await setup();
  const h = { Origin: ORIGIN };
  const authn = await createAuthenticator();
  const reg = await (await call("/api/auth/register/options", { method: "POST", body: { setupToken: "secret-setup" }, headers: h })).json();
  await call("/api/auth/register/verify", { method: "POST", body: { setupToken: "secret-setup", challengeId: reg.challengeId, response: await authn.register(reg.options, ORIGIN) }, headers: h });
  const lo = await (await call("/api/auth/login/options", { method: "POST", body: {}, headers: h })).json();
  const phished = await authn.login(lo.options, "https://evil.test", { rpId: "evil.test" });
  const r = await call("/api/auth/login/verify", { method: "POST", body: { challengeId: lo.challengeId, response: phished }, headers: h });
  assert.equal((await r.json()).error, "passkey_failed");
});

test("setup is disabled when no setup token is configured", async () => {
  const { call } = await setup({ setupToken: "" });
  const r = await call("/api/auth/register/options", { method: "POST", body: { setupToken: "" }, headers: { Origin: ORIGIN } });
  assert.equal((await r.json()).error, "setup_required");
});

test("cookie-authenticated writes need our Origin", async () => {
  const { call, login } = await setup();
  const { Cookie } = await login();
  const r = await call("/api/devices/link-code", { method: "POST", body: {}, headers: { Cookie } });
  assert.equal(r.status, 403);
  const r2 = await call("/api/devices/link-code", { method: "POST", body: {}, headers: { Cookie, Origin: "https://evil.test" } });
  assert.equal(r2.status, 403);
});

test("iPhone linking: one-time code, bearer token, revocation", async () => {
  const { call, login } = await setup();
  const h = await login();
  assert.equal((await call("/api/devices/link-code", { method: "POST", body: {} })).status, 403);
  const { code } = await (await call("/api/devices/link-code", { method: "POST", body: {}, headers: h })).json();
  assert.match(code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);

  const linked = await (await call("/api/devices/link", { method: "POST", body: { code: code.toLowerCase().replace("-", " "), name: "iPhone de Gabriel" } })).json();
  assert.ok(linked.token);
  const reuse = await call("/api/devices/link", { method: "POST", body: { code } });
  assert.equal((await reuse.json()).error, "invalid_link_code");

  const bearer = { Authorization: `Bearer ${linked.token}` };
  assert.equal((await call("/api/sync?since=0", { headers: bearer })).status, 200);
  // A device token cannot manage devices or open link codes.
  assert.equal((await call("/api/devices", { headers: bearer })).status, 401);
  assert.equal((await call("/api/devices/link-code", { method: "POST", body: {}, headers: bearer })).status, 401);

  const { devices } = await (await call("/api/devices", { headers: h })).json();
  assert.equal(devices[0].name, "iPhone de Gabriel");
  await call(`/api/devices/${devices[0].id}`, { method: "DELETE", headers: h });
  assert.equal((await call("/api/sync?since=0", { headers: bearer })).status, 401);
});

test("too many wrong link codes void the open code", async () => {
  const { call, login } = await setup();
  const h = await login();
  const { code } = await (await call("/api/devices/link-code", { method: "POST", body: {}, headers: h })).json();
  for (let i = 0; i < 5; i++) await call("/api/devices/link", { method: "POST", body: { code: `WRNG-000${i}` } });
  const r = await call("/api/devices/link", { method: "POST", body: { code } });
  assert.equal((await r.json()).error, "invalid_link_code");
});
