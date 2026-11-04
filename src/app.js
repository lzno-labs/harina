// The HTTP app, written against the Fetch API so it runs unchanged on Node and on Workers.
import * as auth from "./auth.js";
import { deleteAllData, exportCsv, exportJson } from "./export.js";
import { LOCALES } from "./locales.js";
import { pull, push, ValidationError } from "./sync.js";

const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
  "Cross-Origin-Opener-Policy": "same-origin",
};

const MAX_BODY = 1024 * 1024;

/** Wraps a response with the security headers every response carries. */
export function withSecurityHeaders(res, https) {
  const r = new Response(res.body, res);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) r.headers.set(k, v);
  if (https) r.headers.set("Strict-Transport-Security", "max-age=31536000");
  return r;
}

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

const error = (code, status) => json({ error: code }, status);

/**
 * @param {object} cfg
 * @param {string} cfg.origin   public origin, for example https://harina.example.org
 * @param {string} [cfg.setupToken]  HARINA_SETUP_TOKEN, needed only for first-run setup
 * @param {string} [cfg.coreSha]     LZNO_CORE_SHA or any build identifier, shown by /health
 */
export function normalizeConfig(cfg) {
  const url = new URL(cfg.origin);
  return {
    origin: url.origin,
    rpID: url.hostname,
    https: url.protocol === "https:",
    setupToken: cfg.setupToken || "",
    coreSha: cfg.coreSha || "dev",
  };
}

function cookieName(cfg) {
  return cfg.https ? "__Host-harina" : "harina_session";
}

function readCookie(req, name) {
  for (const part of (req.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return "";
}

function sessionCookie(cfg, token, maxAgeMs) {
  const attrs = [`${cookieName(cfg)}=${token}`, "Path=/", "HttpOnly", "SameSite=Strict", `Max-Age=${Math.floor(maxAgeMs / 1000)}`];
  if (cfg.https) attrs.push("Secure");
  return attrs.join("; ");
}

async function readJson(req) {
  const len = Number(req.headers.get("Content-Length") ?? 0);
  if (len > MAX_BODY) throw new ValidationError("too_large");
  if (!(req.headers.get("Content-Type") ?? "").startsWith("application/json")) throw new ValidationError("json_required");
  const text = await req.text();
  if (text.length > MAX_BODY) throw new ValidationError("too_large");
  try {
    return JSON.parse(text || "{}");
  } catch {
    throw new ValidationError("invalid_json");
  }
}

/**
 * @param {{ db: import("./storage/db.js").Db, config: object, assets?: (req: Request) => Promise<Response> }} deps
 */
export function createApp({ db, config, assets }) {
  const cfg = normalizeConfig(config);

  async function principal(req) {
    const bearer = (req.headers.get("Authorization") ?? "").match(/^Bearer (.+)$/)?.[1];
    if (bearer) {
      const device = await auth.deviceFromToken(db, bearer);
      return device ? { kind: "device", device } : null;
    }
    const token = readCookie(req, cookieName(cfg));
    return (await auth.sessionValid(db, token)) ? { kind: "session", token } : null;
  }

  // Cookie-authenticated writes must come from our own pages (CSRF defense on top of SameSite).
  function sameOrigin(req) {
    return req.headers.get("Origin") === cfg.origin;
  }

  async function route(req) {
    const url = new URL(req.url);
    const { pathname: path } = url;
    const method = req.method;

    if (path === "/health" && method === "GET") return json({ ok: true, core: cfg.coreSha });

    const lang = path.match(/^\/locales\/([a-z]{2})\.json$/)?.[1];
    if (lang && method === "GET") {
      return LOCALES[lang]
        ? new Response(JSON.stringify(LOCALES[lang]), { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-cache" } })
        : error("not_found", 404);
    }

    if (!path.startsWith("/api/")) {
      return assets ? assets(req) : error("not_found", 404);
    }

    const who = await principal(req);
    if (!who && req.headers.has("Authorization")) return error("unauthorized", 401);
    if (method !== "GET" && who?.kind === "session" && !sameOrigin(req)) return error("bad_origin", 403);
    if (method !== "GET" && !who && !sameOrigin(req) && path !== "/api/devices/link") return error("bad_origin", 403);
    const needSession = () => {
      if (who?.kind !== "session") throw new auth.AuthError("unauthorized", 401);
    };
    const needAny = () => {
      if (!who) throw new auth.AuthError("unauthorized", 401);
    };

    switch (`${method} ${path}`) {
      case "GET /api/session":
        return json({
          authenticated: who?.kind === "session",
          setupNeeded: !(await auth.hasCredentials(db)),
          origin: cfg.origin,
        });

      case "POST /api/auth/register/options": {
        const body = await readJson(req);
        return json(await auth.registrationOptions(db, cfg, { authenticated: who?.kind === "session", setupToken: body.setupToken }));
      }
      case "POST /api/auth/register/verify": {
        const body = await readJson(req);
        const authenticated = who?.kind === "session";
        const s = await auth.registrationVerify(db, cfg, { ...body, authenticated });
        if (authenticated) return json({ ok: true });
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, s.token, auth.SESSION_TTL_MS) });
      }
      case "POST /api/auth/login/options":
        return json(await auth.authenticationOptions(db, cfg));
      case "POST /api/auth/login/verify": {
        const s = await auth.authenticationVerify(db, cfg, await readJson(req));
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, s.token, auth.SESSION_TTL_MS) });
      }
      case "POST /api/auth/logout":
        if (who?.kind === "session") await auth.endSession(db, who.token);
        return json({ ok: true }, 200, { "Set-Cookie": sessionCookie(cfg, "", 0) });

      case "POST /api/devices/link-code":
        needSession();
        return json(await auth.createLinkCode(db));
      case "POST /api/devices/link": {
        const body = await readJson(req);
        return json(await auth.linkDevice(db, body));
      }
      case "GET /api/devices":
        needSession();
        return json({ devices: await auth.listDevices(db) });

      case "GET /api/sync": {
        needAny();
        const since = Number(url.searchParams.get("since") ?? 0);
        if (!Number.isSafeInteger(since) || since < 0) return error("invalid_since", 400);
        return json(await pull(db, since));
      }
      case "POST /api/sync": {
        needAny();
        const body = await readJson(req);
        return json(await push(db, body.changes));
      }

      case "GET /api/export.json":
        needAny();
        return json(await exportJson(db), 200, { "Content-Disposition": 'attachment; filename="harina.json"' });
      case "GET /api/export.csv":
        needAny();
        return new Response(await exportCsv(db), {
          headers: {
            "Content-Type": "text/csv; charset=utf-8",
            "Content-Disposition": 'attachment; filename="harina.csv"',
            "Cache-Control": "no-store",
          },
        });
      case "POST /api/data/delete": {
        needSession();
        const body = await readJson(req);
        if (body.confirm !== true) return error("confirmation_required", 400);
        await deleteAllData(db);
        return json({ ok: true });
      }
    }

    const dev = path.match(/^\/api\/devices\/([A-Za-z0-9_-]{1,64})$/);
    if (dev && method === "DELETE") {
      needSession();
      await auth.revokeDevice(db, dev[1]);
      return json({ ok: true });
    }
    return error("not_found", 404);
  }

  return async function fetch(req) {
    let res;
    try {
      res = await route(req);
    } catch (e) {
      if (e instanceof auth.AuthError) res = error(e.code, e.status);
      else if (e instanceof ValidationError) res = json({ error: e.code, detail: e.detail }, 400);
      else {
        console.error(e);
        res = error("internal", 500);
      }
    }
    return withSecurityHeaders(res, cfg.https);
  };
}
