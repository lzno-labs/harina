// Passkeys from inside the iPhone app (docs/adr/0007-passkeys-in-the-app.md).
import assert from "node:assert/strict";
import { test } from "node:test";
import { createAuthenticator } from "./fake-authenticator.js";
import { ORIGIN, setup } from "./helpers.js";

test("an iPhone that signed up adds a passkey and learns it has one", async () => {
  const { call } = await setup({ signup: "open" });
  const s = await (await call("/api/auth/signup/device", { method: "POST", body: { name: "Ana" } })).json();
  const bearer = { Authorization: `Bearer ${s.token}` };

  const before = await (await call("/api/me", { headers: bearer })).json();
  assert.deepEqual([before.id, before.name, before.hasPasskey], [s.userId, "Ana", false]);

  const authn = await createAuthenticator();
  const reg = await (await call("/api/auth/register/options", { method: "POST", body: {}, headers: bearer })).json();
  const ok = await call("/api/auth/register/verify", {
    method: "POST",
    body: { challengeId: reg.challengeId, response: await authn.register(reg.options, ORIGIN) },
    headers: bearer,
  });
  assert.equal(ok.status, 200, await ok.clone().text());
  assert.equal(ok.headers.get("Set-Cookie"), null);
  assert.equal((await (await call("/api/me", { headers: bearer })).json()).hasPasskey, true);
});

test("after reinstalling, a passkey gives the iPhone a new device token of the same person", async () => {
  const { call } = await setup({ signup: "open" });
  const s = await (await call("/api/auth/signup/device", { method: "POST", body: { name: "Ana" } })).json();
  const bearer = { Authorization: `Bearer ${s.token}` };
  const authn = await createAuthenticator();
  const reg = await (await call("/api/auth/register/options", { method: "POST", body: {}, headers: bearer })).json();
  await call("/api/auth/register/verify", { method: "POST", body: { challengeId: reg.challengeId, response: await authn.register(reg.options, ORIGIN) }, headers: bearer });

  // No Origin header and no token: the app after a reinstall.
  const lo = await (await call("/api/auth/device/login/options", { method: "POST", body: {} })).json();
  const r = await call("/api/auth/device/login/verify", {
    method: "POST",
    body: { challengeId: lo.challengeId, response: await authn.login(lo.options, ORIGIN), deviceName: "iPhone de Ana" },
  });
  assert.equal(r.status, 200, await r.clone().text());
  const d = await r.json();
  assert.equal(d.userId, s.userId);
  assert.notEqual(d.token, s.token);
  const me = await (await call("/api/me", { headers: { Authorization: `Bearer ${d.token}` } })).json();
  assert.equal(me.name, "Ana");
});

test("device passkey sign-in rejects another origin and needs a challenge", async () => {
  const { call, login } = await setup({ signup: "open" });
  const h = await login();
  const authn = await createAuthenticator();
  const reg = await (await call("/api/auth/register/options", { method: "POST", body: {}, headers: h })).json();
  await call("/api/auth/register/verify", { method: "POST", body: { challengeId: reg.challengeId, response: await authn.register(reg.options, ORIGIN) }, headers: h });

  const lo = await (await call("/api/auth/device/login/options", { method: "POST", body: {} })).json();
  const phished = await authn.login(lo.options, "https://evil.test", { rpId: "evil.test" });
  const bad = await call("/api/auth/device/login/verify", { method: "POST", body: { challengeId: lo.challengeId, response: phished } });
  assert.equal((await bad.json()).error, "passkey_failed");

  const none = await call("/api/auth/device/login/verify", { method: "POST", body: { challengeId: "x", response: {} } });
  assert.equal((await none.json()).error, "challenge_expired");
  assert.equal((await call("/api/me")).status, 401);
});

test("apple-app-site-association lists only configured app ids", async () => {
  const off = await setup();
  assert.equal((await off.call("/.well-known/apple-app-site-association")).status, 404);
  const { call } = await setup({ appleAppIds: "ABCDE12345.app.example.harina, nope" });
  const r = await call("/.well-known/apple-app-site-association");
  assert.equal(r.status, 200);
  assert.match(r.headers.get("Content-Type"), /application\/json/);
  assert.deepEqual(await r.json(), { webcredentials: { apps: ["ABCDE12345.app.example.harina"] } });
});
