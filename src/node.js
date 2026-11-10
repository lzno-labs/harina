// Run harina on any machine: `npm start`. SQLite file storage, static files from public/.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { createApp } from "./app.js";
import { createDecider } from "./decider.js";
import { configFromEnv, ensureSetupToken } from "./config.js";
import { setupNeeded } from "./auth.js";
import { migrate } from "./storage/migrate.js";
import { openSqlite } from "./storage/sqlite.js";

const PUBLIC = fileURLToPath(new URL("../public/", import.meta.url));
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
};

export async function serveStatic(req) {
  const url = new URL(req.url);
  let rel = normalize(decodeURIComponent(url.pathname)).replace(/^([/\\])+/, "");
  if (rel.includes("..")) return new Response("", { status: 400 });
  if (!rel || !extname(rel)) rel = "index.html"; // single page app
  try {
    const body = await readFile(join(PUBLIC, rel));
    return new Response(body, { headers: { "Content-Type": TYPES[extname(rel)] ?? "application/octet-stream" } });
  } catch {
    return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain" } });
  }
}

async function toRequest(req, origin) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, Array.isArray(v) ? v.join(", ") : v);
  return new Request(new URL(req.url, origin), {
    method: req.method,
    headers,
    body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
  });
}

async function main() {
  let cfg = configFromEnv();
  const db = openSqlite(cfg.dbPath);
  const applied = await migrate(db);
  if (applied.length) console.log(`harina: applied migrations ${applied.join(", ")}`);
  if (await setupNeeded(db)) cfg = ensureSetupToken(cfg);
  const app = createApp({ db, config: cfg, assets: serveStatic, decider: createDecider(process.env) });
  createServer(async (req, res) => {
    const r = await app(await toRequest(req, cfg.origin));
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(Buffer.from(await r.arrayBuffer()));
  }).listen(cfg.port, cfg.host, () => console.log(`harina: listening on ${cfg.origin} (${cfg.host}:${cfg.port})`));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
