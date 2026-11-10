// Configuration from environment variables (see .env.example).
import { randomToken } from "./crypto.js";

export function configFromEnv(env = process.env) {
  const port = Number(env.PORT || 8787);
  return {
    port,
    host: env.HOST || "127.0.0.1",
    origin: env.HARINA_ORIGIN || `http://localhost:${port}`,
    dbPath: env.HARINA_DB || "./data/harina.sqlite",
    setupToken: env.HARINA_SETUP_TOKEN || "",
    coreSha: env.LZNO_CORE_SHA || "dev",
    cimd: env.HARINA_OAUTH_CIMD || "on",
    mcpOrigins: env.HARINA_MCP_ORIGINS || "",
    timeZone: env.HARINA_TZ || "America/Costa_Rica",
    aiCapTokens: env.HARINA_AI_CAP_TOKENS,
  };
}

/** Self-hosting without HARINA_SETUP_TOKEN: a one-time token printed to the console. */
export function ensureSetupToken(cfg, log = console.log) {
  if (cfg.setupToken) return cfg;
  const setupToken = randomToken(9);
  log(`harina: first-run setup code (only needed until you create your passkey): ${setupToken}`);
  return { ...cfg, setupToken };
}
