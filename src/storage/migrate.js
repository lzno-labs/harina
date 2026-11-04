// Applies migrations/*.sql in order on SQLite. Cloudflare uses `wrangler d1 migrations apply`
// with the same files, so both paths share one schema.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const MIGRATIONS_DIR = fileURLToPath(new URL("../../migrations/", import.meta.url));

/** @param {{ exec(sql: string): void, all: Function, run: Function }} db */
export async function migrate(db, dir = MIGRATIONS_DIR) {
  db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)");
  const done = new Set((await db.all("SELECT name FROM schema_migrations")).map((r) => r.name));
  const files = readdirSync(dir).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
  const applied = [];
  for (const f of files) {
    if (done.has(f)) continue;
    db.exec("BEGIN");
    try {
      db.exec(readFileSync(join(dir, f), "utf8"));
      await db.run("INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)", [f, Date.now()]);
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw new Error(`migration ${f} failed: ${e.message}`);
    }
    applied.push(f);
  }
  return applied;
}
