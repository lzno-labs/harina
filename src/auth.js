// Authentication (docs/adr/0003-authentication.md): one owner per instance, passkeys on the
// web, and a device token for the iOS app obtained with a one-time link code.
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import { isoBase64URL } from "@simplewebauthn/server/helpers";
import { linkCode, normalizeLinkCode, randomToken, safeEqual, sha256 } from "./crypto.js";

export const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export const CHALLENGE_TTL_MS = 5 * 60 * 1000;
export const LINK_CODE_TTL_MS = 10 * 60 * 1000;
export const MAX_LINK_FAILURES = 5;

export class AuthError extends Error {
  constructor(code, status = 401) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

export async function hasCredentials(db) {
  return Boolean(await db.first("SELECT id FROM credentials LIMIT 1"));
}

async function saveChallenge(db, challenge, purpose) {
  const id = randomToken(16);
  await db.run("DELETE FROM challenges WHERE expires_at < ?", [Date.now()]);
  await db.run("INSERT INTO challenges (id, challenge, purpose, expires_at) VALUES (?, ?, ?, ?)", [
    id,
    challenge,
    purpose,
    Date.now() + CHALLENGE_TTL_MS,
  ]);
  return id;
}

async function takeChallenge(db, id, purpose) {
  const row = await db.first("SELECT * FROM challenges WHERE id = ?", [String(id ?? "")]);
  if (!row) throw new AuthError("challenge_expired", 400);
  await db.run("DELETE FROM challenges WHERE id = ?", [row.id]);
  if (row.purpose !== purpose || row.expires_at < Date.now()) throw new AuthError("challenge_expired", 400);
  return row.challenge;
}

/**
 * Registration is open only (a) to the logged-in owner adding a passkey, or (b) during
 * first-run setup, when no passkey exists yet and the caller knows HARINA_SETUP_TOKEN.
 */
export async function registrationOptions(db, cfg, { authenticated, setupToken }) {
  if (!authenticated) {
    if (await hasCredentials(db)) throw new AuthError("already_set_up", 403);
    if (!cfg.setupToken) throw new AuthError("setup_token_not_configured", 403);
    if (!(await safeEqual(String(setupToken ?? ""), cfg.setupToken))) throw new AuthError("invalid_setup_token", 403);
  }
  const existing = await db.all("SELECT id, transports FROM credentials");
  const options = await generateRegistrationOptions({
    rpName: "harina",
    rpID: cfg.rpID,
    userName: "harina",
    userID: new TextEncoder().encode("owner"),
    attestationType: "none",
    excludeCredentials: existing.map((c) => ({ id: c.id, transports: c.transports ? JSON.parse(c.transports) : undefined })),
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
  });
  const challengeId = await saveChallenge(db, options.challenge, authenticated ? "register" : "setup");
  return { challengeId, options };
}

export async function registrationVerify(db, cfg, { authenticated, setupToken, challengeId, response }) {
  if (!authenticated) {
    // Re-check: setup closes as soon as the first passkey exists.
    if (await hasCredentials(db)) throw new AuthError("already_set_up", 403);
    if (!cfg.setupToken || !(await safeEqual(String(setupToken ?? ""), cfg.setupToken))) {
      throw new AuthError("invalid_setup_token", 403);
    }
  }
  const expectedChallenge = await takeChallenge(db, challengeId, authenticated ? "register" : "setup");
  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge,
      expectedOrigin: cfg.origin,
      expectedRPID: cfg.rpID,
      requireUserVerification: true,
    });
  } catch {
    throw new AuthError("passkey_failed", 400);
  }
  if (!verification.verified || !verification.registrationInfo) throw new AuthError("passkey_failed", 400);
  const { credential } = verification.registrationInfo;
  await db.run("INSERT INTO credentials (id, public_key, counter, transports, created_at) VALUES (?, ?, ?, ?, ?)", [
    credential.id,
    isoBase64URL.fromBuffer(credential.publicKey),
    credential.counter,
    JSON.stringify(credential.transports ?? []),
    Date.now(),
  ]);
  return createSession(db);
}

export async function authenticationOptions(db, cfg) {
  const options = await generateAuthenticationOptions({ rpID: cfg.rpID, userVerification: "required" });
  return { challengeId: await saveChallenge(db, options.challenge, "login"), options };
}

export async function authenticationVerify(db, cfg, { challengeId, response }) {
  const expectedChallenge = await takeChallenge(db, challengeId, "login");
  const cred = await db.first("SELECT * FROM credentials WHERE id = ?", [String(response?.id ?? "")]);
  if (!cred) throw new AuthError("passkey_failed", 400);
  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge,
      expectedOrigin: cfg.origin,
      expectedRPID: cfg.rpID,
      requireUserVerification: true,
      credential: {
        id: cred.id,
        publicKey: isoBase64URL.toBuffer(cred.public_key),
        counter: cred.counter,
        transports: cred.transports ? JSON.parse(cred.transports) : undefined,
      },
    });
  } catch {
    throw new AuthError("passkey_failed", 400);
  }
  if (!verification.verified) throw new AuthError("passkey_failed", 400);
  await db.run("UPDATE credentials SET counter = ? WHERE id = ?", [verification.authenticationInfo.newCounter, cred.id]);
  return createSession(db);
}

export async function createSession(db) {
  const token = randomToken();
  const now = Date.now();
  await db.run("DELETE FROM sessions WHERE expires_at < ?", [now]);
  await db.run("INSERT INTO sessions (token_hash, created_at, expires_at) VALUES (?, ?, ?)", [
    await sha256(token),
    now,
    now + SESSION_TTL_MS,
  ]);
  return { token, expiresAt: now + SESSION_TTL_MS };
}

export async function sessionValid(db, token) {
  if (!token) return false;
  const row = await db.first("SELECT expires_at FROM sessions WHERE token_hash = ?", [await sha256(token)]);
  return Boolean(row && row.expires_at > Date.now());
}

export async function endSession(db, token) {
  if (token) await db.run("DELETE FROM sessions WHERE token_hash = ?", [await sha256(token)]);
}

// ----- iOS device linking -----

export async function createLinkCode(db) {
  const code = linkCode();
  await db.run("DELETE FROM link_codes WHERE expires_at < ?", [Date.now()]);
  await db.run("INSERT INTO link_codes (code_hash, expires_at) VALUES (?, ?)", [
    await sha256(normalizeLinkCode(code)),
    Date.now() + LINK_CODE_TTL_MS,
  ]);
  await db.run("UPDATE meta SET value = 0 WHERE key = 'link_failures'");
  return { code, expiresAt: Date.now() + LINK_CODE_TTL_MS };
}

/** Trades a one-time link code for a device token. Too many wrong codes void every open code. */
export async function linkDevice(db, { code, name }) {
  const hash = await sha256(normalizeLinkCode(code));
  const row = await db.first("SELECT * FROM link_codes WHERE code_hash = ?", [hash]);
  if (!row || row.expires_at < Date.now()) {
    await db.run("UPDATE meta SET value = value + 1 WHERE key = 'link_failures'");
    const f = await db.first("SELECT value FROM meta WHERE key = 'link_failures'");
    if (f.value >= MAX_LINK_FAILURES) await db.run("DELETE FROM link_codes");
    throw new AuthError("invalid_link_code", 400);
  }
  await db.run("DELETE FROM link_codes WHERE code_hash = ?", [hash]);
  const token = randomToken();
  const id = randomToken(12);
  const deviceName = typeof name === "string" && name.trim() ? name.trim().slice(0, 100) : "iPhone";
  await db.run("INSERT INTO devices (id, name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)", [
    id,
    deviceName,
    await sha256(token),
    Date.now(),
    Date.now(),
  ]);
  return { deviceId: id, token };
}

export async function deviceFromToken(db, token) {
  if (!token) return null;
  const row = await db.first("SELECT id FROM devices WHERE token_hash = ?", [await sha256(token)]);
  if (row) await db.run("UPDATE devices SET last_seen_at = ? WHERE id = ?", [Date.now(), row.id]);
  return row?.id ?? null;
}

export async function listDevices(db) {
  return db.all("SELECT id, name, created_at, last_seen_at FROM devices ORDER BY created_at");
}

export async function revokeDevice(db, id) {
  await db.run("DELETE FROM devices WHERE id = ?", [id]);
}
