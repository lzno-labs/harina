// SPDX-License-Identifier: AGPL-3.0-only
// Several people per instance (docs/adr/0006-people-and-spaces.md): sign-up, codes and isolation.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createAuthenticator } from "./fake-authenticator.js";
import { ORIGIN, setup } from "./helpers.js";

const cookieOf = (res) => res.headers.get("Set-Cookie").split(";")[0];
const tx = (over = {}) => ({
  id: "tx-1", kind: "expense", amount_minor: 100000, currency: "CRC", merchant: "Musmanni",
  source: "apple_pay", occurred_at: "2026-11-10T12:00:00Z", updated_at: Date.now(), ...over,
});

test("with open sign-up anyone creates an account on the web, with a personal space and categories", async () => {
  const { call } = await setup({ signup: "open" });
  const h = { Origin: ORIGIN };
  for (const name of ["Ana", "Beto"]) {
    const authn = await createAuthenticator();
    const { challengeId, options } = await (await call("/api/auth/register/options", { method: "POST", body: {}, headers: h })).json();
    const ok = await call("/api/auth/register/verify", { method: "POST", body: { challengeId, response: await authn.register(options, ORIGIN) }, headers: h });
    assert.equal(ok.status, 200, await ok.clone().text());
    const c = { Cookie: cookieOf(ok) };
    const s = await (await call("/api/session", { headers: c })).json();
    assert.equal(s.authenticated, true);
    assert.equal(s.user.hasPasskey, true);
    const { records } = await (await call("/api/sync?since=0", { headers: c })).json();
    assert.equal(records.categories.length, 7, name);
  }
});

test("sign-up from the iPhone gives a device token; closed sign-up refuses it", async () => {
  const closed = await setup();
  const r = await closed.call("/api/auth/signup/device", { method: "POST", body: { deviceName: "iPhone" } });
  assert.equal(r.status, 403);
  assert.equal((await r.json()).error, "setup_required");

  const { call } = await setup({ signup: "open" });
  const s = await (await call("/api/auth/signup/device", { method: "POST", body: { name: "Ana", deviceName: "iPhone de Ana" } })).json();
  assert.ok(s.token && s.userId);
  const bearer = { Authorization: `Bearer ${s.token}` };
  const pushed = await call("/api/sync", { method: "POST", headers: bearer, body: { changes: { transactions: [tx()] } } });
  assert.equal(pushed.status, 200);
  assert.equal((await pushed.json()).records.transactions[0].created_by, s.userId);
});

test("sign-up is limited per IP and by the maximum of people", async () => {
  const { call } = await setup({ signup: "open", maxUsers: 3 });
  const from = (ip) => ({ "CF-Connecting-IP": ip });
  const statuses = [];
  for (let i = 0; i < 6; i++) statuses.push((await call("/api/auth/signup/device", { method: "POST", body: {}, headers: from("1.1.1.1") })).status);
  assert.deepEqual(statuses.slice(0, 3), [200, 200, 200]);
  assert.equal((await (await call("/api/auth/signup/device", { method: "POST", body: {}, headers: from("2.2.2.2") })).json()).error, "signup_full");

  const limited = await setup({ signup: "open" });
  const codes = [];
  for (let i = 0; i < 6; i++) codes.push((await limited.call("/api/auth/signup/device", { method: "POST", body: {}, headers: from("3.3.3.3") })).status);
  assert.deepEqual(codes, [200, 200, 200, 200, 200, 429]);
});

test("the iPhone opens the same account on the web with a one-time code", async () => {
  const { call } = await setup({ signup: "open" });
  const s = await (await call("/api/auth/signup/device", { method: "POST", body: {} })).json();
  const bearer = { Authorization: `Bearer ${s.token}` };
  assert.equal((await call("/api/auth/web-code", { method: "POST", body: {} })).status, 403);
  const { code } = await (await call("/api/auth/web-code", { method: "POST", body: {}, headers: bearer })).json();
  const r = await call("/api/auth/web-code/redeem", { method: "POST", body: { code }, headers: { Origin: ORIGIN } });
  assert.equal(r.status, 200);
  const c = { Cookie: cookieOf(r), Origin: ORIGIN };
  const session = await (await call("/api/session", { headers: c })).json();
  assert.equal(session.user.id, s.userId);
  assert.equal(session.user.hasPasskey, false);
  // Single use.
  assert.equal((await call("/api/auth/web-code/redeem", { method: "POST", body: { code }, headers: { Origin: ORIGIN } })).status, 400);
  // Signed in that way, the person adds a passkey to their own account.
  const authn = await createAuthenticator();
  const reg = await (await call("/api/auth/register/options", { method: "POST", body: {}, headers: c })).json();
  const ok = await call("/api/auth/register/verify", { method: "POST", body: { challengeId: reg.challengeId, response: await authn.register(reg.options, ORIGIN) }, headers: c });
  assert.equal(ok.status, 200);
  assert.equal((await (await call("/api/session", { headers: c })).json()).user.hasPasskey, true);
});

test("one person never reaches another person's data", async () => {
  const { call, person } = await setup();
  const ana = await person("Ana");
  const beto = await person("Beto");
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ id: "a1", note: "solo Ana" })] } } });

  // Pull and export of Beto show none of Ana's rows.
  const pulled = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.equal(pulled.records.transactions.length, 0);
  assert.ok(pulled.records.categories.every((c) => c.space_id === beto.personal));
  const exported = await (await call("/api/export.json", { headers: beto.headers })).json();
  assert.equal(exported.transactions.length, 0);

  // Beto cannot write into Ana's space, even knowing its id and the row id.
  const intrude = await call("/api/sync", { method: "POST", headers: beto.headers, body: { changes: { transactions: [tx({ id: "a1", space_id: ana.personal, note: "hack" })] } } });
  assert.equal(intrude.status, 400);
  assert.equal((await intrude.json()).error, "invalid_space");
  // The same id in his own space is a different row.
  await call("/api/sync", { method: "POST", headers: beto.headers, body: { changes: { transactions: [tx({ id: "a1", note: "de Beto" })] } } });
  const anas = await (await call("/api/export.json", { headers: ana.headers })).json();
  assert.equal(anas.transactions[0].note, "solo Ana");

  // Deleting all data only touches the caller's space.
  await call("/api/data/delete", { method: "POST", headers: beto.headers, body: { confirm: true } });
  assert.equal((await (await call("/api/export.json", { headers: ana.headers })).json()).transactions.length, 1);
  // Devices, link codes and connections are per person too.
  const { code } = await (await call("/api/devices/link-code", { method: "POST", body: {}, headers: ana.headers })).json();
  await call("/api/devices/link", { method: "POST", body: { code, name: "iPhone de Ana" } });
  assert.equal((await (await call("/api/devices", { headers: beto.headers })).json()).devices.length, 0);
});

test("deleting an account removes the person and their personal space", async () => {
  const { call, person, db } = await setup();
  const ana = await person("Ana");
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx()] } } });
  assert.equal((await call("/api/account/delete", { method: "POST", headers: ana.headers, body: {} })).status, 400);
  assert.equal((await call("/api/account/delete", { method: "POST", headers: ana.headers, body: { confirm: true } })).status, 200);
  assert.equal((await call("/api/sync?since=0", { headers: ana.headers })).status, 401);
  for (const t of ["users", "spaces", "members", "transactions", "categories", "sessions"]) {
    assert.equal((await db.first(`SELECT COUNT(*) AS n FROM ${t}`)).n, 0, t);
  }
});
