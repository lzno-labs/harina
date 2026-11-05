import assert from "node:assert/strict";
import { test } from "node:test";
import { setup } from "./helpers.js";

test("CSV and JSON export everything, in Spanish, safe for spreadsheets", async () => {
  const { call, login } = await setup();
  const h = await login();
  await call("/api/sync", {
    method: "POST",
    headers: h,
    body: {
      changes: {
        accounts: [{ id: "a1", name: "Tarjeta BAC", card: "BAC Visa", updated_at: 1 }],
        transactions: [
          { id: "t1", kind: "expense", amount_minor: 450050, currency: "CRC", category_id: "default-food", account_id: "a1", merchant: 'Soda "La Esquina", Escazú', source: "manual", occurred_at: "2026-11-02T12:00:00Z", updated_at: 1 },
          { id: "t2", kind: "income", amount_minor: 1250, currency: "USD", merchant: "=HYPERLINK(1)", source: "manual", occurred_at: "2026-11-03T12:00:00Z", updated_at: 1 },
          { id: "t3", kind: "expense", amount_minor: 1, currency: "USD", source: "manual", occurred_at: "2026-11-03T12:00:00Z", updated_at: 1, deleted: true },
        ],
      },
    },
  });
  const csv = await (await call("/api/export.csv", { headers: h })).text();
  const lines = csv.replace(/^\uFEFF/, "").trim().split("\r\n");
  assert.equal(lines[0], "fecha,tipo,monto,moneda,categoria,cuenta,comercio,nota,tarjeta,origen,por_revisar,categoria_automatica,id");
  assert.equal(lines.length, 3);
  assert.equal(lines[1], '2026-11-02T12:00:00Z,Gasto,4500.50,CRC,Comida,Tarjeta BAC,"Soda ""La Esquina"", Escazú",,,Manual,0,0,t1');
  assert.match(lines[2], /,'=HYPERLINK\(1\),/);

  const json = await (await call("/api/export.json", { headers: h })).json();
  assert.equal(json.format, "harina-export");
  assert.equal(json.transactions.length, 2);
  assert.equal(json.transactions[1].amount, "12.50");
  assert.equal(json.categories.length, 7);
});

test("delete all data leaves tombstones for the iPhones", async () => {
  const { call, login } = await setup();
  const h = await login();
  await call("/api/sync", { method: "POST", headers: h, body: { changes: { transactions: [{ id: "t1", kind: "expense", amount_minor: 1, currency: "CRC", merchant: "x", source: "manual", occurred_at: "2026-11-02T12:00:00Z", updated_at: 1 }] } } });
  assert.equal((await call("/api/data/delete", { method: "POST", headers: h, body: {} })).status, 400);
  assert.equal((await call("/api/data/delete", { method: "POST", headers: h, body: { confirm: true } })).status, 200);
  const json = await (await call("/api/export.json", { headers: h })).json();
  assert.deepEqual([json.transactions.length, json.categories.length], [0, 0]);
  const pulled = await (await call("/api/sync?since=8", { headers: h })).json();
  assert.equal(pulled.records.transactions[0].deleted, 1);
  assert.equal(pulled.records.transactions[0].merchant, null);
});
