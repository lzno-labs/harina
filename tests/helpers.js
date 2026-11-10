import { createApp } from "../src/app.js";
import { createSession } from "../src/auth.js";
import { createUser } from "../src/people.js";
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
  /** A new person with a web session: `{ userId, personal, headers }`. */
  const person = async (name) => {
    const user = await createUser(db, { name });
    const { token } = await createSession(db, user.id);
    return { userId: user.id, personal: user.personalSpace, headers: { Cookie: `__Host-harina=${token}`, Origin: ORIGIN } };
  };
  let first;
  /** Session headers of the first person (created on first use). */
  const login = async () => {
    first ??= await person("Primera");
    return first.headers;
  };
  return { db, app, call, login, person };
}
