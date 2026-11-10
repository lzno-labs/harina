// Maintenance commands for self-hosters.
//   node src/cli.js login-code [user id]   Prints a one-time code to open the web as that person
//                                          (the first person by default), to add a new passkey
//                                          after losing them all. Valid 10 minutes.
import { createCode } from "./auth.js";
import { configFromEnv } from "./config.js";
import { migrate } from "./storage/migrate.js";
import { openSqlite } from "./storage/sqlite.js";

const cmd = process.argv[2];
const db = openSqlite(configFromEnv().dbPath);
await migrate(db);
if (cmd === "login-code") {
  const user = process.argv[3]
    ? await db.first("SELECT id FROM users WHERE id = ?", [process.argv[3]])
    : await db.first("SELECT id FROM users ORDER BY created_at LIMIT 1");
  if (!user) {
    console.error("harina: no such person. Open the app to sign up first.");
    process.exitCode = 1;
  } else {
    const { code } = await createCode(db, user.id, "web");
    console.log(`harina: on the sign-in page choose «Entrar con un código» and type ${code} (valid 10 minutes), then add a passkey.`);
  }
} else {
  console.error("usage: node src/cli.js login-code [user id]");
  process.exitCode = 1;
}
db.close();
