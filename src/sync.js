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
    ["kind", "enum", { required: true, values: ["expense", "income", "saving", "withdrawal"] }],
    ["amount_minor", "int", { required: true, min: 0, max: 1e15 }],
    ["currency", "currency", { required: true }],
    ["category_id", "id", {}],
    ["account_id", "id", {}],
    ["pot_id", "id", {}],
    ["merchant", "string", { max: 200 }],
    ["note", "string", { max: 1000 }],
    ["card", "string", { max: 100 }],
    ["source", "enum", { required: true, values: ["manual", "apple_pay"] }],
    ["raw_amount", "string", { max: 100 }],
    ["needs_review", "bool", {}],
    ["category_auto", "int", { min: 0, max: 2 }],
    ["occurred_at", "date", { required: true }],
  ],
  // docs/design/budgets-reminders-savings.md
  reminders: [
    ["name", "string", { required: true, max: 100 }],
    ["amount_minor", "int", { min: 0, max: 1e15 }],
    ["currency", "currency", {}],
    ["day_of_month", "int", { required: true, min: 1, max: 31 }],
    ["category_id", "id", {}],
    ["account_id", "id", {}],
    ["paid_month", "month", {}],
    ["note", "string", { max: 500 }],
  ],
  budgets: [
    ["name", "string", { required: true, max: 100 }],
    ["amount_minor", "int", { required: true, min: 1, max: 1e15 }],
    ["currency", "currency", { required: true }],
    ["category_ids", "idlist", { required: true, max: 20 }],
  ],
  pots: [
    ["name", "string", { required: true, max: 100 }],
    ["currency", "currency", { required: true }],
    ["goal_minor", "int", { min: 1, max: 1e15 }],
    ["goal_date", "day", {}],
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
    case "month":
      if (typeof value !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(value)) throw new ValidationError("invalid_record", where);
      return value;
    case "day":
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(value))) throw new ValidationError("invalid_record", where);
      return value;
    case "idlist": {
      // A JSON list of ids, stored as text; sent as a list or as its JSON.
      let list = value;
      if (typeof list === "string") {
        try {
          list = JSON.parse(list);
        } catch {
          throw new ValidationError("invalid_record", where);
        }
      }
      if (!Array.isArray(list) || !list.length || list.length > opt.max || !list.every((x) => typeof x === "string" && ID.test(x))) {
        throw new ValidationError("invalid_record", where);
      }
      return JSON.stringify([...new Set(list)]);
    }
    case "date":
      if (typeof value !== "string" || !ISO_DATE.test(value) || Number.isNaN(Date.parse(value))) {
        throw new ValidationError("invalid_record", where);
      }
      return value;
  }
  throw new Error(`unknown type ${type}`);
}

/** Validates one pushed record and returns the row to store (without seq or space). */
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
  const data = [...ENTITIES[entity].map((f) => f[0]), "updated_at", "deleted"];
  const cols = ["space_id", "id", ...data, ...(entity === "transactions" ? ["created_by"] : [])];
  // created_by is set by the first write only; the rest follow last-writer-wins.
  const sets = [...data, "seq"].map((c) => `${c} = excluded.${c}`).join(", ");
  return {
    sql:
      `INSERT INTO ${entity} (${cols.join(", ")}, seq) ` +
      `VALUES (${cols.map(() => "?").join(", ")}, (SELECT value FROM meta WHERE key = 'seq')) ` +
      `ON CONFLICT (space_id, id) DO UPDATE SET ${sets} WHERE excluded.updated_at > ${entity}.updated_at`,
    params: cols.map((c) => row[c]),
  };
}

async function isMember(db, space, userId) {
  return Boolean(await db.first("SELECT 1 FROM members WHERE space_id = ? AND user_id = ?", [space, userId]));
}

/** The spaces a request may touch (docs/adr/0006-people-and-spaces.md). */
function inSpaces(spaces) {
  if (!spaces?.length) throw new ValidationError("no_space");
  return { sql: `space_id IN (${spaces.map(() => "?").join(",")})`, params: spaces };
}

const BUMP = { sql: "UPDATE meta SET value = value + 1 WHERE key = 'seq'", params: [] };

/**
 * Applies pushed changes with last-writer-wins and returns the server's current version of
 * every pushed row, so a device whose change lost adopts the winner. A row goes to the space it
 * names, or to the person's personal space; a space the person is not in is refused.
 * @param {import("./storage/db.js").Db} db
 * @param {Record<string, unknown[]>} changes
 * @param {{ spaces: string[], personal: string, userId: string }} who
 */
export async function push(db, changes, who, now = Date.now()) {
  if (!changes || typeof changes !== "object") throw new ValidationError("invalid_changes");
  const rows = [];
  for (const [entity, list] of Object.entries(changes)) {
    if (!ENTITIES[entity]) throw new ValidationError("invalid_entity", entity);
    if (!Array.isArray(list)) throw new ValidationError("invalid_changes", entity);
    for (const rec of list) {
      const space = rec?.space_id ?? who.personal;
      if (typeof space !== "string" || !who.spaces.includes(space)) throw new ValidationError("invalid_space", `${entity}.space_id`);
      // Moving a movement to another space keeps who added it, if that person is in the space too.
      const by = typeof rec.created_by === "string" && rec.created_by !== who.userId && (await isMember(db, space, rec.created_by)) ? rec.created_by : who.userId;
      rows.push([entity, { ...validateRecord(entity, rec, now), space_id: space, created_by: by }]);
    }
  }
  if (rows.length > MAX_PUSH) throw new ValidationError("too_many_records");
  if (rows.length) await db.batch(rows.flatMap(([e, r]) => [BUMP, upsertStatement(e, r)]));
  const out = {};
  for (const entity of Object.keys(ENTITIES)) {
    out[entity] = [];
    for (const [e, r] of rows) {
      if (e !== entity) continue;
      out[entity].push(await db.first(`SELECT * FROM ${entity} WHERE space_id = ? AND id = ?`, [r.space_id, r.id]));
    }
  }
  return { seq: await currentSeq(db), records: out };
}

export async function currentSeq(db) {
  return (await db.first("SELECT value FROM meta WHERE key = 'seq'")).value;
}

/**
 * Everything changed after `since` in the given spaces. `more` means call again with `seq` as
 * the new `since`.
 */
export async function pull(db, since, spaces, limit = PULL_LIMIT) {
  const w = inSpaces(spaces);
  const records = {
    accounts: await db.all(`SELECT * FROM accounts WHERE seq > ? AND ${w.sql} ORDER BY seq`, [since, ...w.params]),
    categories: await db.all(`SELECT * FROM categories WHERE seq > ? AND ${w.sql} ORDER BY seq`, [since, ...w.params]),
    reminders: await db.all(`SELECT * FROM reminders WHERE seq > ? AND ${w.sql} ORDER BY seq`, [since, ...w.params]),
    budgets: await db.all(`SELECT * FROM budgets WHERE seq > ? AND ${w.sql} ORDER BY seq`, [since, ...w.params]),
    pots: await db.all(`SELECT * FROM pots WHERE seq > ? AND ${w.sql} ORDER BY seq`, [since, ...w.params]),
    transactions: await db.all(`SELECT * FROM transactions WHERE seq > ? AND ${w.sql} ORDER BY seq LIMIT ?`, [since, ...w.params, limit + 1]),
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
