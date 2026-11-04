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
  const { db } = await setup();
  const { push, pull } = await import("../src/sync.js");
  await push(db, { transactions: Array.from({ length: 30 }, (_, i) => tx({ id: `t${i}` })) });
  const p1 = await pull(db, 0, 20);
  assert.equal(p1.more, true);
  assert.equal(p1.records.transactions.length, 20);
  const p2 = await pull(db, p1.seq, 20);
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
