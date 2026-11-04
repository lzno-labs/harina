// Maintenance commands for self-hosters.
//   node src/cli.js reset-passkeys   Removes every passkey and session, reopening first-run setup.
import { configFromEnv } from "./config.js";
import { migrate } from "./storage/migrate.js";
import { openSqlite } from "./storage/sqlite.js";

const cmd = process.argv[2];
const db = openSqlite(configFromEnv().dbPath);
await migrate(db);
if (cmd === "reset-passkeys") {
  await db.batch([
    { sql: "DELETE FROM credentials", params: [] },
    { sql: "DELETE FROM sessions", params: [] },
  ]);
  console.log("harina: passkeys removed. Open the app to run setup again with HARINA_SETUP_TOKEN.");
} else {
  console.error("usage: node src/cli.js reset-passkeys");
  process.exitCode = 1;
}
db.close();
