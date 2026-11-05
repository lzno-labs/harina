/**
 * The storage boundary. The core talks to SQL through this small interface so the
 * same code runs on SQLite (default, any machine) and on Cloudflare D1.
 *
 * @typedef {{ sql: string, params?: unknown[] }} Statement
 * @typedef {object} Db
 * @property {(sql: string, params?: unknown[]) => Promise<Record<string, unknown>[]>} all
 * @property {(sql: string, params?: unknown[]) => Promise<Record<string, unknown> | null>} first
 * @property {(sql: string, params?: unknown[]) => Promise<void>} run
 * @property {(statements: Statement[]) => Promise<Record<string, unknown>[][]>} batch
 *   Runs the statements in one transaction and returns the rows of each one.
 */

export const DB_INTERFACE = ["all", "first", "run", "batch"];

/** @param {unknown} db */
export function assertDb(db) {
  for (const m of DB_INTERFACE) {
    if (typeof db?.[m] !== "function") throw new Error(`storage is missing ${m}()`);
  }
  return /** @type {Db} */ (db);
}
