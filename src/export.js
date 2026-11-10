// Data export in open formats (JSON and CSV). Everything harina stores about its owner's
// finances is here; auth secrets (passkeys, tokens) are not data the person needs back.
import { lookup } from "./locales.js";

export const MINOR_UNITS = { JPY: 0, KRW: 0, CLP: 0, PYG: 0 };
export const minorUnits = (currency) => MINOR_UNITS[currency] ?? 2;

export function formatMinor(amountMinor, currency) {
  const d = minorUnits(currency);
  if (d === 0) return String(amountMinor);
  const s = String(amountMinor).padStart(d + 1, "0");
  return `${s.slice(0, -d)}.${s.slice(-d)}`;
}

/** Everything in the given spaces (the person's own, docs/adr/0006-people-and-spaces.md). */
export async function exportJson(db, spaces) {
  if (!spaces?.length) throw new Error("no spaces");
  const w = `space_id IN (${spaces.map(() => "?").join(",")})`;
  const live = (t) => db.all(`SELECT * FROM ${t} WHERE deleted = 0 AND ${w} ORDER BY ${t === "transactions" ? "occurred_at" : "id"}`, spaces);
  const [accounts, categories, transactions] = await Promise.all([live("accounts"), live("categories"), live("transactions")]);
  const strip = ({ seq: _s, deleted: _d, ...r }) => r;
  return {
    format: "harina-export",
    version: 2,
    spaces: await db.all(`SELECT id, kind, name FROM spaces WHERE id IN (${spaces.map(() => "?").join(",")})`, spaces),
    exported_at: new Date().toISOString(),
    accounts: accounts.map(strip),
    categories: categories.map(strip),
    transactions: transactions.map((t) => ({ ...strip(t), amount: formatMinor(t.amount_minor, t.currency) })),
  };
}

function csvCell(v) {
  let s = v === null || v === undefined ? "" : String(v);
  // Keep spreadsheets from evaluating cells as formulas.
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export async function exportCsv(db, spaces, lang = "es") {
  const data = await exportJson(db, spaces);
  const cat = new Map(data.categories.map((c) => [c.id, c.name ?? lookup(lang, `categories.default.${c.key}`) ?? c.key]));
  const acc = new Map(data.accounts.map((a) => [a.id, a.name]));
  const cols = ["date", "kind", "amount", "currency", "category", "account", "merchant", "note", "card", "source", "needs_review", "category_auto", "id"];
  const lines = [cols.map((c) => csvCell(lookup(lang, `export.columns.${c}`))).join(",")];
  for (const t of data.transactions) {
    lines.push(
      [
        t.occurred_at,
        lookup(lang, `form.${t.kind}`),
        t.amount,
        t.currency,
        cat.get(t.category_id) ?? "",
        acc.get(t.account_id) ?? "",
        t.merchant,
        t.note,
        t.card,
        lookup(lang, `source.${t.source}`),
        t.needs_review ? 1 : 0,
        t.category_auto ?? 0,
        t.id,
      ]
        .map(csvCell)
        .join(","),
    );
  }
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

/** Deletes every movement, category and account of a space (as tombstones, so iPhones sync the deletion). */
export async function deleteAllData(db, space) {
  const stmts = [];
  for (const t of ["transactions", "categories", "accounts"]) {
    const ids = (await db.all(`SELECT id FROM ${t} WHERE deleted = 0 AND space_id = ?`, [space])).map((r) => r.id);
    for (const id of ids) {
      stmts.push({ sql: "UPDATE meta SET value = value + 1 WHERE key = 'seq'", params: [] });
      const blank =
        t === "transactions"
          ? ", amount_minor = 0, category_id = NULL, account_id = NULL, merchant = NULL, note = NULL, card = NULL, raw_amount = NULL"
          : t === "accounts"
            ? ", name = '', card = NULL"
            : ", key = NULL, name = NULL";
      stmts.push({
        sql: `UPDATE ${t} SET deleted = 1, updated_at = ?, seq = (SELECT value FROM meta WHERE key = 'seq')${blank} WHERE space_id = ? AND id = ?`,
        params: [Date.now(), space, id],
      });
    }
  }
  for (let i = 0; i < stmts.length; i += 200) await db.batch(stmts.slice(i, i + 200));
}
