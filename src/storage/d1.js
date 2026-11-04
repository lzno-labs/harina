// Cloudflare D1 adapter. Generic: no account or database IDs here (those live in the
// deployment's wrangler.toml).

/**
 * @param {any} d1 a D1Database binding
 * @returns {import("./db.js").Db}
 */
export function d1Db(d1) {
  const bind = (sql, params = []) => d1.prepare(sql).bind(...params.map((p) => (p === undefined ? null : p)));
  return {
    async all(sql, params) {
      return (await bind(sql, params).all()).results ?? [];
    },
    async first(sql, params) {
      return (await bind(sql, params).first()) ?? null;
    },
    async run(sql, params) {
      await bind(sql, params).run();
    },
    async batch(statements) {
      const res = await d1.batch(statements.map(({ sql, params }) => bind(sql, params)));
      return res.map((r) => r.results ?? []);
    },
  };
}
