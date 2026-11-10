import { createApp } from "../src/app.js";
import { createSession } from "../src/auth.js";
import { migrate } from "../src/storage/migrate.js";
import { openSqlite } from "../src/storage/sqlite.js";

export const ORIGIN = "https://harina.test";

export async function setup(extra = {}, { decider = null } = {}) {
  const db = openSqlite(":memory:");
  await migrate(db);
  const app = createApp({ db, config: { origin: ORIGIN, setupToken: "secret-setup", coreSha: "abc123", ...extra }, decider });
  const call = (path, { method = "GET", body, headers = {} } = {}) =>
    app(
      new Request(ORIGIN + path, {
        method,
        headers: { ...(body !== undefined ? { "Content-Type": "application/json" } : {}), ...headers },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
  const login = async () => {
    const { token } = await createSession(db);
    return { Cookie: `__Host-harina=${token}`, Origin: ORIGIN };
  };
  return { db, app, call, login };
}
