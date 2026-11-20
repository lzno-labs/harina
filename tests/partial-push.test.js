// A push from the iPhone's queue saves what is valid and reports the rest (docs/adr/0008-partial-push.md).
import assert from "node:assert/strict";
import { test } from "node:test";
import { setup } from "./helpers.js";

const tx = (over = {}) => ({
  id: "tx-1",
  kind: "expense",
  amount_minor: 450000,
  currency: "CRC",
  merchant: "Automercado",
  source: "apple_pay",
  occurred_at: "2026-11-04T18:30:00.000Z",
  updated_at: 1000,
  ...over,
});

const pushed = async (call, h, changes, partial = true) =>
  call("/api/sync", { method: "POST", body: partial ? { changes, partial: true } : { changes }, headers: h });

test("a partial push saves the valid records and reports the refused ones", async () => {
  const { call, login } = await setup();
  const h = await login();
  const r = await pushed(call, h, {
    transactions: [tx({ id: "good" }), tx({ id: "long", note: "x".repeat(1001) }), tx({ id: "money", currency: "colones" })],
    categories: [{ id: "c1", name: "Mascotas", updated_at: 1 }],
  });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.deepEqual(body.records.transactions.map((t) => t.id), ["good"]);
  assert.deepEqual(body.records.categories.map((c) => c.id), ["c1"]);
  assert.deepEqual(body.rejected, [
    { entity: "transactions", id: "long", space_id: null, error: "invalid_record", field: "note" },
    { entity: "transactions", id: "money", space_id: null, error: "invalid_record", field: "currency" },
  ]);
  const pulled = await (await call("/api/sync?since=0", { headers: h })).json();
  assert.deepEqual(pulled.records.transactions.map((t) => t.id), ["good"]);
});

test("everything refused is still a 200 in partial mode, and a 400 without it", async () => {
  const { call, login } = await setup();
  const h = await login();
  const partial = await pushed(call, h, { transactions: [tx({ kind: "transfer" })] });
  assert.equal(partial.status, 200);
  assert.deepEqual((await partial.json()).rejected, [{ entity: "transactions", id: "tx-1", space_id: null, error: "invalid_record", field: "kind" }]);
  const whole = await pushed(call, h, { transactions: [tx({ kind: "transfer" })] }, false);
  assert.equal(whole.status, 400);
});

test("a move is saved or refused whole", async () => {
  const { call, person } = await setup();
  const ana = await person("Ana");
  const h = ana.headers;
  await pushed(call, h, { transactions: [tx({ id: "m1" })] });
  // The copy goes to a space Ana is not in: the tombstone must not be saved alone.
  const r = await pushed(call, h, { transactions: [tx({ id: "m1", deleted: true, updated_at: 2000 }), tx({ id: "m1", space_id: "not-mine", updated_at: 2000 })] });
  const body = await r.json();
  assert.deepEqual(body.records.transactions, []);
  // The offending record is reported: the copy aimed at the other space.
  assert.deepEqual(body.rejected, [{ entity: "transactions", id: "m1", space_id: "not-mine", error: "invalid_space", field: null }]);
  const pulled = await (await call("/api/sync?since=0", { headers: h })).json();
  const m1 = pulled.records.transactions.find((t) => t.id === "m1");
  assert.equal(m1.deleted, 0);
});

test("an entity the server does not know is refused alone in partial mode", async () => {
  const { call, login } = await setup();
  const h = await login();
  const r = await pushed(call, h, { goals: [{ id: "g1", updated_at: 1 }], transactions: [tx()] });
  const body = await r.json();
  assert.equal(r.status, 200);
  assert.equal(body.records.transactions.length, 1);
  assert.deepEqual(body.rejected, [{ entity: "goals", id: "g1", space_id: null, error: "invalid_entity", field: null }]);
  assert.equal((await pushed(call, h, { goals: [] }, false)).status, 400);
  assert.equal((await pushed(call, h, { transactions: Array.from({ length: 501 }, (_, i) => tx({ id: `t${i}` })) })).status, 400);
});

test("a clock more than a day ahead counts as now instead of being refused", async () => {
  const { call, login } = await setup();
  const h = await login();
  const before = Date.now();
  const future = await (await pushed(call, h, { transactions: [tx({ id: "f", updated_at: before + 3 * 86400000 })] }, false)).json();
  const saved = future.records.transactions[0].updated_at;
  assert.ok(saved >= before && saved <= Date.now(), String(saved));
  const near = await (await pushed(call, h, { transactions: [tx({ id: "n", updated_at: before + 3600000 })] }, false)).json();
  assert.equal(near.records.transactions[0].updated_at, before + 3600000);
});
