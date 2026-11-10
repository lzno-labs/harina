// SPDX-License-Identifier: AGPL-3.0-only
// Envelopes, reminders and savings pots sync like every other row (docs/design/budgets-reminders-savings.md).
import assert from "node:assert/strict";
import { test } from "node:test";
import { budgetStatus, potBalance, reminderStatus } from "../public/insights.js";
import { setup } from "./helpers.js";

const now = Date.now();
const tx = (over) => ({ kind: "expense", amount_minor: 100000, currency: "CRC", source: "manual", occurred_at: "2026-11-10T12:00:00Z", updated_at: now, ...over });

test("reminders, envelopes and pots sync, validate and stay in their space", async () => {
  const { call, person } = await setup();
  const ana = await person("Ana");
  const beto = await person("Beto");
  const push = (h, changes) => call("/api/sync", { method: "POST", headers: h, body: { changes } });
  const ok = await push(ana.headers, {
    reminders: [{ id: "r1", name: "Tarjeta BAC", day_of_month: 15, currency: "CRC", updated_at: now }],
    budgets: [{ id: "b1", name: "Mesada", amount_minor: 2000000, currency: "CRC", category_ids: ["default-food", "default-food"], updated_at: now }],
    pots: [{ id: "p1", name: "Emergencias", currency: "CRC", goal_minor: 50000000, goal_date: "2026-12-31", updated_at: now }],
    transactions: [tx({ id: "s1", kind: "saving", pot_id: "p1", amount_minor: 1000000 }), tx({ id: "e1", pot_id: "p1", category_id: "default-food" })],
  });
  assert.equal(ok.status, 200, await ok.clone().text());
  const body = await ok.json();
  assert.equal(body.records.budgets[0].category_ids, '["default-food"]', "duplicates removed, stored as JSON");
  for (const bad of [
    { reminders: [{ id: "r2", name: "x", day_of_month: 32, updated_at: now }] },
    { reminders: [{ id: "r2", name: "x", day_of_month: 5, paid_month: "2026-13", updated_at: now }] },
    { budgets: [{ id: "b2", name: "x", amount_minor: 1, currency: "CRC", category_ids: [], updated_at: now }] },
    { budgets: [{ id: "b2", name: "x", amount_minor: 1, currency: "CRC", category_ids: ["../x"], updated_at: now }] },
    { pots: [{ id: "p2", name: "x", currency: "CRC", goal_date: "mañana", updated_at: now }] },
    { transactions: [tx({ id: "t", kind: "transfer" })] },
  ]) {
    assert.equal((await push(ana.headers, bad)).status, 400, JSON.stringify(bad));
  }
  const pulled = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.deepEqual([pulled.records.reminders.length, pulled.records.budgets.length, pulled.records.pots.length], [0, 0, 0]);
  const exported = await (await call("/api/export.json", { headers: ana.headers })).json();
  assert.deepEqual(exported.budgets[0].category_ids, ["default-food"]);
  assert.equal(exported.pots[0].name, "Emergencias");
});

test("pot balance: savings minus withdrawals minus expenses paid from it", () => {
  const txs = [
    tx({ id: "1", kind: "saving", pot_id: "p", amount_minor: 1000 }),
    tx({ id: "2", kind: "saving", pot_id: "p", amount_minor: 500 }),
    tx({ id: "3", kind: "withdrawal", pot_id: "p", amount_minor: 200 }),
    tx({ id: "4", kind: "expense", pot_id: "p", amount_minor: 300 }),
    tx({ id: "5", kind: "saving", pot_id: "other", amount_minor: 9999 }),
    tx({ id: "6", kind: "saving", pot_id: "p", amount_minor: 7777, deleted: 1 }),
  ];
  assert.deepEqual(potBalance({ id: "p", goal_minor: 2000 }, txs), { balance: 1000, saved: 1500, goal: 2000, progress: 0.5 });
});

test("envelope: spending of the month in its categories and currency", () => {
  const txs = [
    tx({ id: "1", category_id: "a", amount_minor: 8000, occurred_at: "2026-11-02T12:00:00Z" }),
    tx({ id: "2", category_id: "b", amount_minor: 9000, occurred_at: "2026-11-20T12:00:00Z" }),
    tx({ id: "3", category_id: "a", amount_minor: 5000, occurred_at: "2026-10-30T12:00:00Z" }),
    tx({ id: "4", category_id: "a", amount_minor: 5000, currency: "USD", occurred_at: "2026-11-05T12:00:00Z" }),
    tx({ id: "5", category_id: "c", amount_minor: 5000, occurred_at: "2026-11-05T12:00:00Z" }),
    tx({ id: "6", kind: "income", category_id: "a", amount_minor: 5000, occurred_at: "2026-11-05T12:00:00Z" }),
  ];
  const b = { amount_minor: 20000, currency: "CRC", category_ids: '["a","b"]' };
  assert.deepEqual(budgetStatus(b, txs, "2026-11"), { spent: 17000, left: 3000, ratio: 0.85, level: "warn" });
  assert.equal(budgetStatus({ ...b, amount_minor: 10000 }, txs, "2026-11").level, "over");
});

test("reminder: next due date, short months, paid this month", () => {
  const r = { day_of_month: 31, paid_month: null };
  assert.deepEqual(reminderStatus(r, new Date("2026-11-10T12:00:00")), { due: "2026-11-30", days: 20, status: "upcoming" });
  assert.equal(reminderStatus({ day_of_month: 15 }, new Date("2026-11-14T12:00:00")).status, "soon");
  assert.equal(reminderStatus({ day_of_month: 15 }, new Date("2026-11-15T09:00:00")).status, "today");
  assert.equal(reminderStatus({ day_of_month: 5 }, new Date("2026-11-10T12:00:00")).status, "late");
  const paid = reminderStatus({ day_of_month: 5, paid_month: "2026-11" }, new Date("2026-11-10T12:00:00"));
  assert.deepEqual(paid, { due: "2026-12-05", days: 25, status: "paid" });
});
