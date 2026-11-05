// Default storage: SQLite through Node's built-in node:sqlite (no native dependency).
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * @param {string} path file path, or ":memory:"
 * @returns {import("./db.js").Db & { close(): void, exec(sql: string): void }}
 */
export function openSqlite(path) {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
  const norm = (params = []) => params.map((p) => (p === undefined ? null : typeof p === "boolean" ? Number(p) : p));
  const plain = (row) => (row ? { ...row } : null);
  return {
    async all(sql, params) {
      return db.prepare(sql).all(...norm(params)).map(plain);
    },
    async first(sql, params) {
      return plain(db.prepare(sql).get(...norm(params)));
    },
    async run(sql, params) {
      db.prepare(sql).run(...norm(params));
    },
    async batch(statements) {
      db.exec("BEGIN IMMEDIATE");
      try {
        const out = statements.map(({ sql, params }) => {
          const st = db.prepare(sql);
          return st.columns().length ? st.all(...norm(params)).map(plain) : (st.run(...norm(params)), []);
        });
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
    exec(sql) {
      db.exec(sql);
    },
    close() {
      db.close();
    },
  };
}
