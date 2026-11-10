// SPDX-License-Identifier: AGPL-3.0-only
// Shared spaces (docs/design/people-and-spaces.md, phase 2).
import assert from "node:assert/strict";
import { test } from "node:test";
import { setup } from "./helpers.js";

const tx = (over = {}) => ({
  id: "tx-1", kind: "expense", amount_minor: 100000, currency: "CRC", merchant: "Automercado",
  source: "apple_pay", occurred_at: "2026-11-10T12:00:00Z", updated_at: Date.now(), ...over,
});

async function household() {
  const ctx = await setup();
  const ana = await ctx.person("Ana");
  const beto = await ctx.person("Beto");
  const { call } = ctx;
  const created = await (await call("/api/spaces", { method: "POST", headers: ana.headers, body: { name: "Casa" } })).json();
  const { code } = await (await call(`/api/spaces/${created.id}/invites`, { method: "POST", headers: ana.headers, body: {} })).json();
  const joined = await call("/api/invites/accept", { method: "POST", headers: beto.headers, body: { code } });
  assert.equal(joined.status, 200);
  return { ...ctx, ana, beto, casa: created.id, code };
}

test("a shared space starts with its own categories and both members see what either adds", async () => {
  const { call, ana, beto, casa } = await household();
  await call("/api/sync", { method: "POST", headers: beto.headers, body: { changes: { transactions: [tx({ space_id: casa })] } } });
  const pulled = await (await call("/api/sync?since=0", { headers: ana.headers })).json();
  const shared = pulled.records.transactions.filter((t) => t.space_id === casa);
  assert.equal(shared.length, 1);
  assert.equal(shared[0].created_by, beto.userId);
  assert.equal(pulled.records.categories.filter((c) => c.space_id === casa).length, 7);
  const casaInfo = pulled.spaces.find((s) => s.id === casa);
  assert.deepEqual(casaInfo.members.map((m) => [m.name, m.role]), [["Ana", "owner"], ["Beto", "member"]]);
});

test("personal spaces stay private inside a household", async () => {
  const { call, ana, beto } = await household();
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ id: "privado" })] } } });
  const pulled = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.equal(pulled.records.transactions.length, 0);
  const r = await call("/api/sync", { method: "POST", headers: beto.headers, body: { changes: { transactions: [tx({ id: "privado", space_id: ana.personal })] } } });
  assert.equal((await r.json()).error, "invalid_space");
});

test("moving a movement to the shared space keeps who added it", async () => {
  const { call, ana, beto, casa } = await household();
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ id: "super" })] } } });
  // Move: tombstone in the old space and the same row in the new one.
  const later = Date.now() + 1;
  await call("/api/sync", {
    method: "POST", headers: ana.headers,
    body: { changes: { transactions: [tx({ id: "super", deleted: true, updated_at: later }), tx({ id: "super", space_id: casa, updated_at: later, created_by: ana.userId })] } },
  });
  const seen = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  const row = seen.records.transactions.find((t) => t.id === "super");
  assert.equal(row.space_id, casa);
  assert.equal(row.created_by, ana.userId);
  assert.equal(seen.records.transactions.filter((t) => t.id === "super").length, 1, "the old copy stays private");
});

test("a pushed author outside the space is ignored", async () => {
  const { call, beto, casa, person } = await household();
  const carla = await person("Carla");
  await call("/api/sync", { method: "POST", headers: beto.headers, body: { changes: { transactions: [tx({ id: "x", space_id: casa, created_by: carla.userId })] } } });
  const r = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.equal(r.records.transactions.find((t) => t.id === "x").created_by, beto.userId);
});

test("invites are single use; leaving keeps the data for the others; the owner role passes on", async () => {
  const { call, ana, beto, casa, code, person } = await household();
  const carla = await person("Carla");
  assert.equal((await call("/api/invites/accept", { method: "POST", headers: carla.headers, body: { code } })).status, 400);
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ id: "de-ana", space_id: casa })] } } });
  await call(`/api/spaces/${casa}/leave`, { method: "POST", headers: ana.headers, body: {} });
  const betoView = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.equal(betoView.records.transactions.filter((t) => t.space_id === casa).length, 1);
  assert.equal(betoView.spaces.find((s) => s.id === casa).role, "owner");
  const anaView = await (await call("/api/sync?since=0", { headers: ana.headers })).json();
  assert.equal(anaView.records.transactions.filter((t) => t.space_id === casa).length, 0);
  assert.equal(anaView.spaces.some((s) => s.id === casa), false);
});

test("only the owner renames, removes members or deletes; the personal space cannot be shared", async () => {
  const { call, ana, beto, casa } = await household();
  assert.equal((await call(`/api/spaces/${casa}`, { method: "PATCH", headers: beto.headers, body: { name: "Mía" } })).status, 403);
  assert.equal((await call(`/api/spaces/${casa}`, { method: "DELETE", headers: beto.headers })).status, 403);
  assert.equal((await call(`/api/spaces/${ana.personal}/invites`, { method: "POST", headers: ana.headers, body: {} })).status, 400);
  assert.equal((await call(`/api/spaces/${casa}/invites`, { method: "POST", headers: { Cookie: "x", Origin: "https://harina.test" }, body: {} })).status, 401);
  await call(`/api/spaces/${casa}`, { method: "PATCH", headers: ana.headers, body: { name: "Hogar" } });
  await call(`/api/spaces/${casa}/members/${beto.userId}`, { method: "DELETE", headers: ana.headers });
  assert.equal((await (await call("/api/spaces", { headers: beto.headers })).json()).spaces.length, 1);
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ space_id: casa })] } } });
  await call(`/api/spaces/${casa}`, { method: "DELETE", headers: ana.headers });
  const left = await (await call("/api/sync?since=0", { headers: ana.headers })).json();
  assert.equal(left.records.transactions.length, 0);
  assert.equal(left.spaces.length, 1);
});

test("deleting an account leaves its shared spaces in the hands of the others", async () => {
  const { call, ana, beto, casa } = await household();
  await call("/api/sync", { method: "POST", headers: ana.headers, body: { changes: { transactions: [tx({ space_id: casa })] } } });
  await call("/api/account/delete", { method: "POST", headers: ana.headers, body: { confirm: true } });
  const view = await (await call("/api/sync?since=0", { headers: beto.headers })).json();
  assert.equal(view.records.transactions.filter((t) => t.space_id === casa).length, 1);
  assert.deepEqual(view.spaces.find((s) => s.id === casa).members.map((m) => m.role), ["owner"]);
});
