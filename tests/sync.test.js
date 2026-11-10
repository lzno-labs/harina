import assert from "node:assert/strict";
import { test } from "node:test";
import { merchantKey } from "../src/sync.js";
import { setup } from "./helpers.js";

const tx = (over = {}) => ({
  id: "tx-1",
  kind: "expense",
  amount_minor: 450000,
  currency: "CRC",
  merchant: "Automercado Escazú",
  source: "apple_pay",
  card: "BAC Visa",
  occurred_at: "2026-11-04T18:30:00.000Z",
  updated_at: 1000,
  ...over,
});

test("health reports the core commit", async () => {
  const { call } = await setup();
  const r = await call("/health");
  assert.deepEqual(await r.json(), { ok: true, core: "abc123" });
  assert.match(r.headers.get("Content-Security-Policy"), /default-src 'self'/);
  assert.equal(r.headers.get("X-Content-Type-Options"), "nosniff");
});

test("sync needs a session or a device token", async () => {
  const { call } = await setup();
  assert.equal((await call("/api/sync?since=0")).status, 401);
  assert.equal((await call("/api/sync", { method: "POST", body: { changes: {} }, headers: { Authorization: "Bearer nope" } })).status, 401);
});

test("first pull brings the default categories", async () => {
  const { call, login } = await setup();
  const r = await (await call("/api/sync?since=0", { headers: await login() })).json();
  assert.deepEqual(
    r.records.categories.map((c) => c.key),
    ["food", "groceries", "transport", "home", "health", "entertainment", "other"],
  );
  assert.equal(r.seq, 7);
});

test("push, pull since, and last-writer-wins", async () => {
  const { call, login } = await setup();
  const h = await login();
  const push = async (rec) => (await call("/api/sync", { method: "POST", body: { changes: { transactions: [rec] } }, headers: h })).json();

  const first = await push(tx());
  assert.equal(first.records.transactions[0].amount_minor, 450000);
  const since = first.seq;

  const newer = await push(tx({ amount_minor: 500000, updated_at: 2000 }));
  assert.equal(newer.records.transactions[0].amount_minor, 500000);

  // An older edit (an iPhone that was offline) loses, and gets the winner back.
  const stale = await push(tx({ amount_minor: 1, updated_at: 1500 }));
  assert.equal(stale.records.transactions[0].amount_minor, 500000);

  const pulled = await (await call(`/api/sync?since=${since}`, { headers: h })).json();
  assert.equal(pulled.records.transactions.length, 1);
  assert.equal(pulled.records.transactions[0].amount_minor, 500000);
  assert.equal(pulled.records.categories.length, 0);

  // Tombstones sync too.
  await push(tx({ deleted: true, updated_at: 3000 }));
  const after = await (await call(`/api/sync?since=${pulled.seq}`, { headers: h })).json();
  assert.equal(after.records.transactions[0].deleted, 1);
  assert.equal(after.records.transactions[0].merchant, null);
});

test("pull pages large histories", async () => {
  const { db, person } = await setup();
  const { push, pull } = await import("../src/sync.js");
  const p = await person();
  const who = { spaces: [p.personal], personal: p.personal, userId: p.userId };
  await push(db, { transactions: Array.from({ length: 30 }, (_, i) => tx({ id: `t${i}` })) }, who);
  const p1 = await pull(db, 0, who.spaces, 20);
  assert.equal(p1.more, true);
  assert.equal(p1.records.transactions.length, 20);
  const p2 = await pull(db, p1.seq, who.spaces, 20);
  assert.equal(p2.more, false);
  assert.equal(p2.records.transactions.length, 10);
});

test("invalid records are rejected whole", async () => {
  const { call, login } = await setup();
  const h = await login();
  for (const bad of [
    tx({ currency: "colones" }),
    tx({ amount_minor: -5 }),
    tx({ amount_minor: 1.5 }),
    tx({ kind: "transfer" }),
    tx({ occurred_at: "ayer" }),
    tx({ id: "../etc" }),
    tx({ merchant: "x".repeat(201) }),
    tx({ updated_at: Date.now() + 3 * 86400000 }),
  ]) {
    const r = await call("/api/sync", { method: "POST", body: { changes: { transactions: [tx({ id: "ok" }), bad] } }, headers: h });
    assert.equal(r.status, 400, JSON.stringify(bad));
  }
  const r = await call("/api/sync", { method: "POST", body: { changes: { users: [] } }, headers: h });
  assert.equal(r.status, 400);
  const pulled = await (await call("/api/sync?since=7", { headers: h })).json();
  assert.equal(pulled.records.transactions.length, 0);
});

test("merchant keys ignore case, accents and punctuation", () => {
  assert.equal(merchantKey("AUTOMERCADO  Escazú!"), merchantKey("automercado escazu"));
});

test("categories carry an optional emoji and color; suggestions converge by id", async () => {
  const { call, login } = await setup();
  const h = await login();
  const push = async (rec) => call("/api/sync", { method: "POST", headers: h, body: { changes: { categories: [rec] } } });
  // An iPhone that started offline turns off a default and adds a suggestion with the shared id.
  assert.equal((await push({ id: "default-food", key: "food", updated_at: 5, deleted: true })).status, 200);
  assert.equal((await push({ id: "default-coffee", key: "coffee", icon: "☕", color: "#a16207", updated_at: 5 })).status, 200);
  assert.equal((await push({ id: "c1", name: "Gym", icon: "🏋️", color: "#16a34a", updated_at: 5 })).status, 200);
  for (const bad of [{ color: "red" }, { color: "#FFF" }, { icon: "x".repeat(17) }]) {
    assert.equal((await push({ id: "c2", name: "x", updated_at: 5, ...bad })).status, 400, JSON.stringify(bad));
  }
  const { records } = await (await call("/api/sync?since=0", { headers: h })).json();
  const byId = Object.fromEntries(records.categories.map((c) => [c.id, c]));
  assert.equal(byId["default-food"].deleted, 1);
  assert.equal(byId["default-coffee"].icon, "☕");
  assert.equal(byId.c1.color, "#16a34a");
  assert.equal(records.categories.filter((c) => c.id === "default-food").length, 1);
});

test("category_auto syncs as 0, 1 or 2", async () => {
  const { call, login } = await setup();
  const h = await login();
  const push = (extra) => call("/api/sync", { method: "POST", headers: h, body: { changes: { transactions: [tx({ updated_at: Date.now(), ...extra })] } } });
  assert.equal((await push({ category_auto: 3 })).status, 400);
  const r = await (await push({ category_auto: 1, category_id: "default-food" })).json();
  assert.equal(r.records.transactions[0].category_auto, 1);
  const r2 = await (await push({ id: "tx-2" })).json();
  assert.equal(r2.records.transactions[0].category_auto, 0);
});
