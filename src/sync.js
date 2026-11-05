// Offline-first sync (docs/adr/0002-sync.md): every synced row has a client id, a client
// `updated_at` for last-writer-wins, a `deleted` tombstone, and a server `seq`.

export const MAX_PUSH = 500;
export const PULL_LIMIT = 1000;
const MAX_FUTURE_MS = 24 * 60 * 60 * 1000;

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const CURRENCY = /^[A-Z]{3}$/;
const COLOR = /^#[0-9a-f]{6}$/;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/;

/** Field rules per entity: [column, type, options]. Order is the column order. */
export const ENTITIES = {
  accounts: [
    ["name", "string", { required: true, max: 100 }],
    ["card", "string", { max: 100 }],
  ],
  categories: [
    ["key", "string", { max: 40 }],
    ["name", "string", { max: 100 }],
    ["icon", "string", { max: 16 }],
    ["color", "color", {}],
  ],
  transactions: [
    ["kind", "enum", { required: true, values: ["expense", "income"] }],
    ["amount_minor", "int", { required: true, min: 0, max: 1e15 }],
    ["currency", "currency", { required: true }],
    ["category_id", "id", {}],
    ["account_id", "id", {}],
    ["merchant", "string", { max: 200 }],
    ["note", "string", { max: 1000 }],
    ["card", "string", { max: 100 }],
    ["source", "enum", { required: true, values: ["manual", "apple_pay"] }],
    ["raw_amount", "string", { max: 100 }],
    ["needs_review", "bool", {}],
    ["category_auto", "int", { min: 0, max: 2 }],
    ["occurred_at", "date", { required: true }],
  ],
};

export class ValidationError extends Error {
  constructor(code, detail) {
    super(code);
    this.code = code;
    this.detail = detail;
  }
}

function checkField(entity, [col, type, opt], value) {
  const where = `${entity}.${col}`;
  if (value === undefined || value === null || value === "") {
    if (opt.required) throw new ValidationError("invalid_record", `${where} is required`);
    return type === "bool" ? 0 : null;
  }
  switch (type) {
    case "string":
      if (typeof value !== "string" || value.length > opt.max) throw new ValidationError("invalid_record", where);
      return value.trim();
    case "enum":
      if (!opt.values.includes(value)) throw new ValidationError("invalid_record", where);
      return value;
    case "int":
      if (!Number.isSafeInteger(value) || value < opt.min || value > opt.max) throw new ValidationError("invalid_record", where);
      return value;
    case "currency":
      if (typeof value !== "string" || !CURRENCY.test(value)) throw new ValidationError("invalid_record", where);
      return value;
    case "color":
      if (typeof value !== "string" || !COLOR.test(value)) throw new ValidationError("invalid_record", where);
      return value;
    case "id":
      if (typeof value !== "string" || !ID.test(value)) throw new ValidationError("invalid_record", where);
      return value;
    case "bool":
      if (typeof value !== "boolean" && value !== 0 && value !== 1) throw new ValidationError("invalid_record", where);
      return value ? 1 : 0;
    case "date":
      if (typeof value !== "string" || !ISO_DATE.test(value) || Number.isNaN(Date.parse(value))) {
        throw new ValidationError("invalid_record", where);
      }
      return value;
  }
  throw new Error(`unknown type ${type}`);
}

/** Validates one pushed record and returns the row to store (without seq). */
export function validateRecord(entity, rec, now = Date.now()) {
  const fields = ENTITIES[entity];
  if (!fields) throw new ValidationError("invalid_entity", entity);
  if (!rec || typeof rec !== "object") throw new ValidationError("invalid_record", entity);
  if (typeof rec.id !== "string" || !ID.test(rec.id)) throw new ValidationError("invalid_record", `${entity}.id`);
  if (!Number.isSafeInteger(rec.updated_at) || rec.updated_at < 0 || rec.updated_at > now + MAX_FUTURE_MS) {
    throw new ValidationError("invalid_record", `${entity}.updated_at`);
  }
  const deleted = rec.deleted ? 1 : 0;
  const row = { id: rec.id, updated_at: rec.updated_at, deleted };
  for (const f of fields) {
    // A tombstone keeps only what the table needs to stay valid.
    row[f[0]] = deleted && !f[2].required ? null : checkField(entity, f, rec[f[0]]);
  }
  if (row.needs_review === null) row.needs_review = 0;
  if (row.category_auto === null) row.category_auto = 0;
  return row;
}

function upsertStatement(entity, row) {
  const cols = ["id", ...ENTITIES[entity].map((f) => f[0]), "updated_at", "deleted"];
  const sets = [...cols.slice(1), "seq"].map((c) => `${c} = excluded.${c}`).join(", ");
  return {
    sql:
      `INSERT INTO ${entity} (${cols.join(", ")}, seq) ` +
      `VALUES (${cols.map(() => "?").join(", ")}, (SELECT value FROM meta WHERE key = 'seq')) ` +
      `ON CONFLICT (id) DO UPDATE SET ${sets} WHERE excluded.updated_at > ${entity}.updated_at`,
    params: cols.map((c) => row[c]),
  };
}

const BUMP = { sql: "UPDATE meta SET value = value + 1 WHERE key = 'seq'", params: [] };

/**
 * Applies pushed changes with last-writer-wins and returns the server's current version of
 * every pushed row, so a device whose change lost adopts the winner.
 * @param {import("./storage/db.js").Db} db
 * @param {Record<string, unknown[]>} changes
 */
export async function push(db, changes, now = Date.now()) {
  if (!changes || typeof changes !== "object") throw new ValidationError("invalid_changes");
  const rows = [];
  for (const [entity, list] of Object.entries(changes)) {
    if (!ENTITIES[entity]) throw new ValidationError("invalid_entity", entity);
    if (!Array.isArray(list)) throw new ValidationError("invalid_changes", entity);
    for (const rec of list) rows.push([entity, validateRecord(entity, rec, now)]);
  }
  if (rows.length > MAX_PUSH) throw new ValidationError("too_many_records");
  if (rows.length) await db.batch(rows.flatMap(([e, r]) => [BUMP, upsertStatement(e, r)]));
  const out = {};
  for (const entity of Object.keys(ENTITIES)) {
    const ids = rows.filter(([e]) => e === entity).map(([, r]) => r.id);
    out[entity] = [];
    for (let i = 0; i < ids.length; i += 100) {
      const chunk = ids.slice(i, i + 100);
      out[entity].push(...(await db.all(`SELECT * FROM ${entity} WHERE id IN (${chunk.map(() => "?").join(",")})`, chunk)));
    }
  }
  return { seq: await currentSeq(db), records: out };
}

export async function currentSeq(db) {
  return (await db.first("SELECT value FROM meta WHERE key = 'seq'")).value;
}

/** Everything changed after `since`. `more` means call again with `seq` as the new `since`. */
export async function pull(db, since = 0, limit = PULL_LIMIT) {
  const records = {
    accounts: await db.all("SELECT * FROM accounts WHERE seq > ? ORDER BY seq", [since]),
    categories: await db.all("SELECT * FROM categories WHERE seq > ? ORDER BY seq", [since]),
    transactions: await db.all("SELECT * FROM transactions WHERE seq > ? ORDER BY seq LIMIT ?", [since, limit + 1]),
  };
  let seq = await currentSeq(db);
  let more = false;
  if (records.transactions.length > limit) {
    records.transactions.length = limit;
    seq = records.transactions[limit - 1].seq;
    more = true;
  }
  return { seq, more, records };
}

/** Normalized merchant name used to remember a merchant's category. */
export function merchantKey(name) {
  return (name ?? "")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}
