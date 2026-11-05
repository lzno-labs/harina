// Cloudflare Workers entry. Bindings: DB (D1), ASSETS (static files from public/).
// Vars: HARINA_ORIGIN, LZNO_CORE_SHA. Secret: HARINA_SETUP_TOKEN.
import { createApp } from "./app.js";
import { d1Db } from "./storage/d1.js";

let cached;

export default {
  async fetch(request, env) {
    if (!cached) {
      cached = createApp({
        db: d1Db(env.DB),
        config: {
          origin: env.HARINA_ORIGIN || new URL(request.url).origin,
          setupToken: env.HARINA_SETUP_TOKEN,
          coreSha: env.LZNO_CORE_SHA,
          cimd: env.HARINA_OAUTH_CIMD,
          mcpOrigins: env.HARINA_MCP_ORIGINS,
          timeZone: env.HARINA_TZ,
        },
        assets: (req) => env.ASSETS.fetch(req),
      });
    }
    return cached(request);
  },
};
