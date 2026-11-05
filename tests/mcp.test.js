import assert from "node:assert/strict";
import { test } from "node:test";
import { ORIGIN } from "./helpers.js";
import { cimdSetup, connect } from "./oauth-helpers.js";

async function ready({ write = true } = {}) {
  const ctx = await cimdSetup();
  const { tokens, session } = await connect(ctx, { write });
  const h = await ctx.login();
  await ctx.call("/api/sync", {
    method: "POST",
    headers: h,
    body: {
      changes: {
        transactions: [
          { id: "t1", kind: "expense", amount_minor: 450000, currency: "CRC", category_id: "default-food", merchant: "Soda Tapia", source: "apple_pay", occurred_at: new Date().toISOString(), updated_at: 1 },
          { id: "t2", kind: "expense", amount_minor: 1899, currency: "USD", merchant: "Netflix", source: "manual", occurred_at: new Date().toISOString(), updated_at: 1 },
          { id: "t3", kind: "income", amount_minor: 100000000, currency: "CRC", merchant: "Salario", source: "manual", occurred_at: new Date().toISOString(), updated_at: 1 },
        ],
      },
    },
  });
  const rpc = (method, params = {}, headers = {}) =>
    ctx.call("/mcp", { method: "POST", body: { jsonrpc: "2.0", id: 7, method, params }, headers: { Authorization: `Bearer ${tokens.access_token}`, ...headers } });
  return { ...ctx, tokens, session, rpc };
}

test("no token: 401 with the resource metadata challenge; GET is not allowed", async () => {
  const ctx = await cimdSetup();
  const r = await ctx.call("/mcp", { method: "POST", body: { jsonrpc: "2.0", id: 1, method: "tools/list" } });
  assert.equal(r.status, 401);
  assert.equal(r.headers.get("WWW-Authenticate"), `Bearer resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource/mcp", scope="harina.read harina.write"`);
  assert.equal((await ctx.call("/mcp")).status, 405);
});

test("legacy clients: initialize, notifications, tools", async () => {
  const { rpc, call, tokens } = await ready();
  const init = await (await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "x", version: "1" } })).json();
  assert.equal(init.result.protocolVersion, "2025-06-18");
  assert.equal(init.result.serverInfo.name, "harina");
  const note = await call("/mcp", { method: "POST", body: { jsonrpc: "2.0", method: "notifications/initialized" }, headers: { Authorization: `Bearer ${tokens.access_token}` } });
  assert.equal(note.status, 202);
  const list = await (await rpc("tools/list", {}, { "MCP-Protocol-Version": "2025-06-18" })).json();
  assert.equal(list.result.resultType, undefined, "legacy results keep the legacy shape");
  assert.deepEqual(list.result.tools.map((t) => t.name), [
    "get_month_summary", "search_transactions", "list_recurring", "list_to_review", "list_categories", "add_transaction", "categorize_transaction",
  ]);
  assert.equal(list.result.tools[0].title, "Resumen del mes");
});

test("2026-07-28 clients: server/discover, version in _meta and headers", async () => {
  const { rpc } = await ready();
  const meta = { "io.modelcontextprotocol/protocolVersion": "2026-07-28" };
  const d = await (await rpc("server/discover", { _meta: meta }, { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover" })).json();
  assert.equal(d.result.resultType, "complete");
  assert.ok(d.result.supportedVersions.includes("2026-07-28"));
  const mismatch = await rpc("tools/list", { _meta: meta }, { "MCP-Protocol-Version": "2025-06-18" });
  assert.equal(mismatch.status, 400);
  assert.equal((await mismatch.json()).error.code, -32020);
  const method = await rpc("tools/list", { _meta: meta }, { "Mcp-Method": "tools/call" });
  assert.equal((await method.json()).error.code, -32020);
  const old = await rpc("tools/list", { _meta: { "io.modelcontextprotocol/protocolVersion": "1900-01-01" } });
  const body = await old.json();
  assert.equal(body.error.code, -32022);
  assert.ok(body.error.data.supported.includes("2026-07-28"));
  const list = await (await rpc("tools/list", { _meta: meta })).json();
  assert.equal(list.result.resultType, "complete");
});

test("read tools answer from the person's data", async () => {
  const { rpc } = await ready();
  const call = async (name, args = {}) => (await (await rpc("tools/call", { name, arguments: args })).json()).result;
  const summary = (await call("get_month_summary")).structuredContent;
  const crc = summary.currencies.find((c) => c.currency === "CRC");
  assert.equal(crc.spent, "4500.00");
  assert.equal(crc.income, "1000000.00");
  assert.equal(crc.balance, "995500.00");
  assert.deepEqual(crc.by_category, [{ category: "Comida", amount: "4500.00" }]);
  assert.equal(summary.to_review, 1, "Netflix has no category");
  const found = (await call("search_transactions", { query: "soda" })).structuredContent;
  assert.equal(found.transactions[0].merchant, "Soda Tapia");
  assert.equal((await call("list_to_review")).structuredContent.to_review[0].id, "t2");
  assert.ok((await call("list_categories")).structuredContent.categories.some((c) => c.name === "Súper"));
  const bad = await call("search_transactions", { category: "Yates" });
  assert.equal(bad.isError, true);
});

test("write tools add and categorize, and sync to devices", async () => {
  const { rpc, call: http, login } = await ready();
  const tool = async (name, args) => (await (await rpc("tools/call", { name, arguments: args })).json()).result;
  const added = await tool("add_transaction", { amount: "12.500,50", currency: "CRC", merchant: "Feria", category: "súper" });
  assert.equal(added.structuredContent.added.amount, "12500.50");
  assert.equal(added.structuredContent.added.category, "Súper");
  assert.equal((await tool("add_transaction", { amount: "abc" })).isError, true);
  const cat = await tool("categorize_transaction", { transaction_id: "t2", category: "Entretenimiento" });
  assert.equal(cat.structuredContent.categorized.category, "Entretenimiento");
  const pulled = await (await http("/api/sync?since=0", { headers: await login() })).json();
  const t2 = pulled.records.transactions.find((t) => t.id === "t2");
  assert.equal(t2.category_id, "default-entertainment");
  assert.ok(pulled.records.transactions.some((t) => t.merchant === "Feria" && t.amount_minor === 1250050));
});

test("a read-only connection lists only read tools and gets 403 insufficient_scope on writes", async () => {
  const { rpc } = await ready({ write: false });
  const list = await (await rpc("tools/list")).json();
  assert.ok(list.result.tools.every((t) => t.annotations.readOnlyHint));
  const r = await rpc("tools/call", { name: "add_transaction", arguments: { amount: "1" } });
  assert.equal(r.status, 403);
  assert.match(r.headers.get("WWW-Authenticate"), /error="insufficient_scope"/);
});

test("browser requests from other origins are refused", async () => {
  const { rpc } = await ready();
  assert.equal((await rpc("tools/list", {}, { Origin: "https://evil.example" })).status, 403);
});

test("a client that follows the 401 challenge gets the optional write switch on the consent page", async () => {
  // Regression: with scope="harina.read" in the challenge, Claude asked only for reading and the
  // consent page could not offer writing.
  const ctx = await cimdSetup();
  const r = await ctx.call("/mcp", { method: "POST", body: { jsonrpc: "2.0", id: 1, method: "tools/list" } });
  const scope = r.headers.get("WWW-Authenticate").match(/scope="([^"]+)"/)[1];
  const { described, tokens } = await connect(ctx, { scope, write: false });
  assert.deepEqual(described.scopes, ["harina.read", "harina.write"], "the page shows the switch");
  assert.equal(tokens.scope, "harina.read", "and writing stays off unless the person turns it on");
});
