// Remote MCP endpoint (docs/design/mcp.md): JSON-RPC over Streamable HTTP with JSON responses,
// no sessions. Serves clients on protocol 2026-07-28 (server/discover, version in _meta) and older
// clients that still open with initialize.
import { decide as decideCategory, detectRecurring, merchantKey, projectMonth, calibrate, trainCategoryModel } from "../public/insights.js";
import { parseAmount } from "../public/money.js";
import { formatMinor } from "./export.js";
import { lookup } from "./locales.js";
import { verifyAccessToken } from "./oauth.js";
import { push, ValidationError } from "./sync.js";

export const MODERN_VERSIONS = ["2026-07-28"];
export const LEGACY_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];
const VERSION_KEY = "io.modelcontextprotocol/protocolVersion";
const SERVER_INFO = { name: "harina", version: "1.2.0" };
const LANG = "es";
const t = (key) => lookup(LANG, key);

class RpcError extends Error {
  constructor(code, message, data, status = 200) {
    super(message);
    this.code = code;
    this.data = data;
    this.status = status;
  }
}

// ---------- data helpers ----------

async function loadData(db) {
  const [transactions, categories, accounts] = await Promise.all([
    db.all("SELECT * FROM transactions WHERE deleted = 0"),
    db.all("SELECT * FROM categories WHERE deleted = 0"),
    db.all("SELECT * FROM accounts WHERE deleted = 0"),
  ]);
  return { transactions, categories, accounts };
}

const signed = (minor, currency) => `${minor < 0 ? "-" : ""}${formatMinor(Math.abs(minor), currency)}`;

const categoryName = (c) => (c ? c.name || lookup(LANG, `categories.default.${c.key}`) || c.key : null);

function dayIn(tz, iso) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
}

function txOut(tx, cats, accounts) {
  const c = cats.get(tx.category_id);
  return {
    id: tx.id,
    date: tx.occurred_at,
    kind: tx.kind,
    amount: formatMinor(tx.amount_minor, tx.currency),
    currency: tx.currency,
    merchant: tx.merchant,
    category: categoryName(c),
    category_id: tx.category_id,
    category_set_automatically: tx.category_auto === 1,
    account: accounts.get(tx.account_id)?.name ?? null,
    note: tx.note,
    source: tx.source,
    needs_review: Boolean(tx.needs_review) || (tx.kind === "expense" && !tx.category_id),
  };
}

function findCategory(categories, value) {
  if (typeof value !== "string" || !value.trim()) return null;
  const byId = categories.find((c) => c.id === value);
  if (byId) return byId;
  const k = merchantKey(value);
  return categories.find((c) => merchantKey(categoryName(c)) === k) ?? null;
}

const toolError = (message) => ({ content: [{ type: "text", text: message }], isError: true });

function result(data) {
  return { content: [{ type: "text", text: JSON.stringify(data) }], structuredContent: data };
}

// ---------- tools ----------

const str = (key, extra = {}) => ({ type: "string", description: t(`mcp.params.${key}`), ...extra });

export const TOOLS = [
  {
    name: "get_month_summary",
    scope: "harina.read",
    inputSchema: { type: "object", properties: { month: str("month", { pattern: "^\\d{4}-\\d{2}$" }) }, additionalProperties: false },
    async run({ db, cfg }, args) {
      const { transactions, categories } = await loadData(db);
      const month = args.month ?? dayIn(cfg.timeZone, new Date().toISOString()).slice(0, 7);
      const cats = new Map(categories.map((c) => [c.id, c]));
      const inMonth = transactions.filter((tx) => dayIn(cfg.timeZone, tx.occurred_at).startsWith(month));
      const recurring = detectRecurring(transactions, new Date());
      const byCurrency = {};
      for (const tx of inMonth) {
        const cur = (byCurrency[tx.currency] ??= { spent: 0, income: 0, byCategory: {} });
        if (tx.kind === "income") cur.income += tx.amount_minor;
        else {
          cur.spent += tx.amount_minor;
          const name = categoryName(cats.get(tx.category_id)) ?? t("categories.uncategorized");
          cur.byCategory[name] = (cur.byCategory[name] ?? 0) + tx.amount_minor;
        }
      }
      const isCurrent = month === dayIn(cfg.timeZone, new Date().toISOString()).slice(0, 7);
      const currencies = Object.entries(byCurrency).map(([currency, v]) => {
        const projection = isCurrent ? projectMonth(transactions, recurring, currency, new Date()) : null;
        return {
          currency,
          spent: formatMinor(v.spent, currency),
          income: formatMinor(v.income, currency),
          balance: signed(v.income - v.spent, currency),
          by_category: Object.entries(v.byCategory)
            .sort((a, b) => b[1] - a[1])
            .map(([category, amount]) => ({ category, amount: formatMinor(amount, currency) })),
          projected_month_end_spending: projection ? formatMinor(projection.projected, currency) : null,
        };
      });
      const pending = transactions.filter((tx) => tx.needs_review || (tx.kind === "expense" && !tx.category_id)).length;
      return result({ month, currencies, movements: inMonth.length, to_review: pending });
    },
  },
  {
    name: "search_transactions",
    scope: "harina.read",
    inputSchema: {
      type: "object",
      properties: {
        query: str("query"),
        from: str("from", { pattern: "^\\d{4}-\\d{2}-\\d{2}$" }),
        to: str("to", { pattern: "^\\d{4}-\\d{2}-\\d{2}$" }),
        category: str("category"),
        kind: str("kind", { enum: ["expense", "income"] }),
        limit: { type: "integer", minimum: 1, maximum: 100, description: t("mcp.params.limit") },
      },
      additionalProperties: false,
    },
    async run({ db, cfg }, args) {
      const { transactions, categories, accounts } = await loadData(db);
      const cats = new Map(categories.map((c) => [c.id, c]));
      const accs = new Map(accounts.map((a) => [a.id, a]));
      const q = merchantKey(args.query);
      const cat = args.category ? findCategory(categories, args.category) : null;
      if (args.category && !cat) return toolError(`${t("mcp.errors.category")} ${categories.map(categoryName).join(", ")}`);
      const limit = Math.min(Math.max(Number(args.limit) || 30, 1), 100);
      const list = transactions
        .filter((tx) => {
          const day = dayIn(cfg.timeZone, tx.occurred_at);
          if (args.from && day < args.from) return false;
          if (args.to && day > args.to) return false;
          if (args.kind && tx.kind !== args.kind) return false;
          if (cat && tx.category_id !== cat.id) return false;
          if (q && !merchantKey(`${tx.merchant ?? ""} ${tx.note ?? ""} ${categoryName(cats.get(tx.category_id)) ?? ""}`).includes(q)) return false;
          return true;
        })
        .sort((a, b) => (a.occurred_at < b.occurred_at ? 1 : -1));
      return result({ total: list.length, transactions: list.slice(0, limit).map((tx) => txOut(tx, cats, accs)) });
    },
  },
  {
    name: "list_recurring",
    scope: "harina.read",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    async run({ db }) {
      const { transactions, categories } = await loadData(db);
      const cats = new Map(categories.map((c) => [c.id, c]));
      const rec = detectRecurring(transactions, new Date()).map((r) => ({
        merchant: r.merchant,
        amount: formatMinor(r.amount, r.currency),
        currency: r.currency,
        cadence: r.cadence,
        next_charge: r.next,
        status: r.status,
        sure: r.confidence === "sure",
        monthly_equivalent: formatMinor(r.monthly, r.currency),
        price_change: r.priceChange ? { from: formatMinor(r.priceChange.from, r.currency), to: formatMinor(r.priceChange.to, r.currency) } : null,
        category: categoryName(cats.get(r.categoryId)),
      }));
      return result({ recurring: rec });
    },
  },
  {
    name: "list_to_review",
    scope: "harina.read",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    async run({ db }) {
      const { transactions, categories, accounts } = await loadData(db);
      const cats = new Map(categories.map((c) => [c.id, c]));
      const accs = new Map(accounts.map((a) => [a.id, a]));
      const active = new Set(categories.map((c) => c.id));
      const model = trainCategoryModel(transactions, active);
      const cal = calibrate(transactions, active);
      const pending = transactions
        .filter((tx) => tx.needs_review || (tx.kind === "expense" && !tx.category_id))
        .sort((a, b) => (a.occurred_at < b.occurred_at ? 1 : -1))
        .map((tx) => {
          const d = decideCategory(model, cal, tx);
          return { ...txOut(tx, cats, accs), suggested_category: d.band === "ask" ? null : categoryName(cats.get(d.categoryId)) };
        });
      return result({ to_review: pending });
    },
  },
  {
    name: "list_categories",
    scope: "harina.read",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    async run({ db }) {
      const { categories } = await loadData(db);
      return result({ categories: categories.map((c) => ({ id: c.id, name: categoryName(c), emoji: c.icon ?? null })) });
    },
  },
  {
    name: "add_transaction",
    scope: "harina.write",
    inputSchema: {
      type: "object",
      properties: {
        amount: str("amount"),
        currency: str("currency", { enum: ["CRC", "USD"] }),
        kind: str("kind", { enum: ["expense", "income"] }),
        merchant: str("merchant"),
        category: str("category"),
        date: str("date"),
        note: str("note"),
      },
      required: ["amount"],
      additionalProperties: false,
    },
    async run({ db, cfg }, args) {
      const { categories } = await loadData(db);
      const currency = args.currency ?? cfg.defaultCurrency;
      const minor = parseAmount(String(args.amount ?? ""), currency);
      if (minor === null || minor <= 0) return toolError(t("mcp.errors.amount"));
      let category = null;
      if (args.category) {
        category = findCategory(categories, args.category);
        if (!category) return toolError(`${t("mcp.errors.category")} ${categories.map(categoryName).join(", ")}`);
      }
      let when = new Date();
      if (args.date) {
        const d = /^\d{4}-\d{2}-\d{2}$/.test(args.date) ? new Date(`${args.date}T12:00:00Z`) : new Date(args.date);
        if (Number.isNaN(d.getTime())) return toolError(t("mcp.errors.date"));
        when = d;
      }
      const tx = {
        id: crypto.randomUUID(),
        kind: args.kind ?? "expense",
        amount_minor: minor,
        currency,
        category_id: category?.id ?? null,
        merchant: args.merchant ?? null,
        note: args.note ?? null,
        source: "manual",
        occurred_at: when.toISOString(),
        updated_at: Date.now(),
      };
      try {
        await push(db, { transactions: [tx] });
      } catch (e) {
        if (e instanceof ValidationError) return toolError(`${t("mcp.errors.invalid")} ${e.detail ?? ""}`.trim());
        throw e;
      }
      return result({ added: { id: tx.id, amount: formatMinor(minor, currency), currency, kind: tx.kind, category: categoryName(category), date: tx.occurred_at } });
    },
  },
  {
    name: "categorize_transaction",
    scope: "harina.write",
    inputSchema: {
      type: "object",
      properties: { transaction_id: str("transaction_id"), category: str("category") },
      required: ["transaction_id", "category"],
      additionalProperties: false,
    },
    async run({ db }, args) {
      const { categories } = await loadData(db);
      const category = findCategory(categories, args.category);
      if (!category) return toolError(`${t("mcp.errors.category")} ${categories.map(categoryName).join(", ")}`);
      const tx = await db.first("SELECT * FROM transactions WHERE id = ? AND deleted = 0", [String(args.transaction_id ?? "")]);
      if (!tx) return toolError(t("mcp.errors.notFound"));
      // A person (through their assistant) changing an automatic category is a correction.
      const auto = tx.category_auto === 1 ? (tx.category_id === category.id ? 1 : 2) : tx.category_auto;
      const { seq: _seq, ...row } = tx;
      await push(db, { transactions: [{ ...row, category_id: category.id, category_auto: auto, needs_review: Boolean(row.needs_review), deleted: false, updated_at: Math.max(Date.now(), tx.updated_at + 1) }] });
      return result({ categorized: { id: tx.id, category: categoryName(category) } });
    },
  },
];

function toolList(scopes) {
  return TOOLS.filter((tool) => scopes.includes(tool.scope)).map((tool) => ({
    name: tool.name,
    title: t(`mcp.tools.${tool.name}.title`),
    description: t(`mcp.tools.${tool.name}.description`),
    inputSchema: tool.inputSchema,
    annotations: { readOnlyHint: tool.scope === "harina.read", destructiveHint: false, idempotentHint: tool.scope === "harina.read", openWorldHint: false },
  }));
}

// ---------- HTTP ----------

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers } });
}

// Clients must request exactly the scopes in this challenge (MCP authorization spec), so both are
// offered here; the consent page keeps writing optional and unchecked.
function challenge(cfg, extra = "") {
  const metadata = `${cfg.origin}/.well-known/oauth-protected-resource/mcp`;
  return `Bearer resource_metadata="${metadata}", scope="harina.read harina.write"${extra}`;
}

/** Handles /mcp. Returns a Response. */
export async function handleMcp(req, { db, cfg }) {
  if (req.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  const origin = req.headers.get("Origin");
  if (origin && origin !== cfg.origin && !cfg.mcpOrigins.includes(origin)) return json({ error: "bad_origin" }, 403);

  const bearer = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i)?.[1];
  const grant = await verifyAccessToken(db, cfg, bearer);
  if (!grant) {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32001, message: "Unauthorized" } }, 401, { "WWW-Authenticate": challenge(cfg) });
  }

  let msg;
  try {
    msg = JSON.parse(await req.text());
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }
  if (Array.isArray(msg) || !msg || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    return json({ jsonrpc: "2.0", id: msg?.id ?? null, error: { code: -32600, message: "Invalid Request" } }, 400);
  }
  // Notifications (no id) are accepted and need no answer.
  if (msg.id === undefined || msg.id === null) return new Response(null, { status: 202 });

  const id = msg.id;
  const reply = (r) => json({ jsonrpc: "2.0", id, result: r });
  const fail = (e) => json({ jsonrpc: "2.0", id, error: { code: e.code, message: e.message, ...(e.data ? { data: e.data } : {}) } }, e.status);

  try {
    const params = msg.params ?? {};
    const metaVersion = params._meta?.[VERSION_KEY];
    const headerVersion = req.headers.get("MCP-Protocol-Version");

    if (msg.method === "initialize") {
      // Legacy handshake (2025 revisions): answer with the requested version when we know it.
      const asked = params.protocolVersion;
      const version = LEGACY_VERSIONS.includes(asked) ? asked : LEGACY_VERSIONS[0];
      return reply({ protocolVersion: version, capabilities: { tools: { listChanged: false } }, serverInfo: SERVER_INFO, instructions: t("mcp.instructions") });
    }

    const modern = Boolean(metaVersion) || MODERN_VERSIONS.includes(headerVersion);
    if (modern) {
      if (headerVersion && metaVersion && headerVersion !== metaVersion) throw new RpcError(-32020, "Header mismatch: MCP-Protocol-Version does not match _meta", null, 400);
      const version = metaVersion ?? headerVersion;
      if (!MODERN_VERSIONS.includes(version)) {
        throw new RpcError(-32022, "Unsupported protocol version", { supported: [...MODERN_VERSIONS, ...LEGACY_VERSIONS], requested: version }, 400);
      }
      const hMethod = req.headers.get("Mcp-Method");
      if (hMethod && hMethod !== msg.method) throw new RpcError(-32020, `Header mismatch: Mcp-Method header value '${hMethod}' does not match body value '${msg.method}'`, null, 400);
      const hName = req.headers.get("Mcp-Name");
      if (hName && msg.method === "tools/call" && hName !== params.name) {
        throw new RpcError(-32020, `Header mismatch: Mcp-Name header value '${hName}' does not match body value '${params.name}'`, null, 400);
      }
    } else if (headerVersion && !LEGACY_VERSIONS.includes(headerVersion)) {
      throw new RpcError(-32022, "Unsupported protocol version", { supported: [...MODERN_VERSIONS, ...LEGACY_VERSIONS], requested: headerVersion }, 400);
    }
    const complete = modern ? { resultType: "complete" } : {};

    switch (msg.method) {
      case "server/discover":
        return reply({
          ...complete,
          resultType: "complete",
          supportedVersions: [...MODERN_VERSIONS, ...LEGACY_VERSIONS],
          capabilities: { tools: {} },
          instructions: t("mcp.instructions"),
          _meta: { "io.modelcontextprotocol/serverInfo": SERVER_INFO },
        });
      case "ping":
        return reply({ ...complete });
      case "tools/list":
        return reply({ ...complete, tools: toolList(grant.scopes) });
      case "tools/call": {
        const tool = TOOLS.find((x) => x.name === params.name);
        if (!tool) throw new RpcError(-32602, `Unknown tool: ${params.name}`);
        if (!grant.scopes.includes(tool.scope)) {
          return json({ jsonrpc: "2.0", id, error: { code: -32001, message: "Insufficient scope" } }, 403, {
            "WWW-Authenticate": `Bearer error="insufficient_scope", scope="harina.read harina.write", resource_metadata="${cfg.origin}/.well-known/oauth-protected-resource/mcp", error_description="write permission required"`,
          });
        }
        const args = params.arguments && typeof params.arguments === "object" ? params.arguments : {};
        return reply({ ...complete, ...(await tool.run({ db, cfg }, args)) });
      }
      default:
        throw new RpcError(-32601, `Method not found: ${msg.method}`);
    }
  } catch (e) {
    if (e instanceof RpcError) return fail(e);
    console.error(e);
    return fail(new RpcError(-32603, "Internal error"));
  }
}
