import assert from "node:assert/strict";
import { test } from "node:test";
import { serveStatic } from "../src/node.js";
import { configFromEnv, ensureSetupToken } from "../src/config.js";

test("serves the app and refuses path traversal", async () => {
  assert.match(await (await serveStatic(new Request("http://x/"))).text(), /<main id="main"/);
  assert.match(await (await serveStatic(new Request("http://x/ajustes"))).text(), /<main id="main"/);
  assert.equal((await serveStatic(new Request("http://x/app.js"))).headers.get("Content-Type"), "text/javascript; charset=utf-8");
  const r = await serveStatic(new Request("http://x/%2e%2e/package.json"));
  assert.notEqual(r.status, 200);
});

test("configuration comes from the environment", () => {
  const cfg = configFromEnv({ PORT: "9000" });
  assert.equal(cfg.origin, "http://localhost:9000");
  let printed = "";
  const withToken = ensureSetupToken(cfg, (s) => (printed = s));
  assert.ok(withToken.setupToken.length > 8);
  assert.ok(printed.includes(withToken.setupToken));
});
