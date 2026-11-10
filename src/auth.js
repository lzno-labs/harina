// Authentication (docs/adr/0006-people-and-spaces.md, which supersedes ADR-0003): passkeys on the
// web and device tokens on the iPhone, per person. A person signs up from the web (passkey) or from
// the iPhone (device token), and moves between them with one-time codes.
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import { isoBase64URL } from "@simplewebauthn/server/helpers";
import { linkCode, normalizeLinkCode, randomToken, safeEqual, sha256 } from "./crypto.js";
import { checkSignup, createUser, userCount } from "./people.js";

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

/** True while nobody has signed up yet (the first person needs the setup token unless sign-up is open). */
export async function setupNeeded(db) {
  return (await userCount(db)) === 0;
}

async function saveChallenge(db, challenge, purpose, userId = null) {
  const id = randomToken(16);
  await db.run("DELETE FROM challenges WHERE expires_at < ?", [Date.now()]);
  await db.run("INSERT INTO challenges (id, challenge, purpose, user_id, expires_at) VALUES (?, ?, ?, ?, ?)", [
    id,
    challenge,
    purpose,
    userId,
    Date.now() + CHALLENGE_TTL_MS,
  ]);
  return id;
}

async function takeChallenge(db, id, purpose) {
  const row = await db.first("SELECT * FROM challenges WHERE id = ?", [String(id ?? "")]);
  if (!row) throw new AuthError("challenge_expired", 400);
  await db.run("DELETE FROM challenges WHERE id = ?", [row.id]);
  if (row.purpose !== purpose || row.expires_at < Date.now()) throw new AuthError("challenge_expired", 400);
  return row;
}

async function setupTokenOk(cfg, token) {
  return Boolean(cfg.setupToken) && (await safeEqual(String(token ?? ""), cfg.setupToken));
}

/**
 * Passkey registration: a signed-in person adds a passkey (`userId`), or someone new signs up
 * (allowed by the sign-up policy, or with the setup token for the very first person).
 */
export async function registrationOptions(db, cfg, { userId, setupToken, ip }) {
  let handle = userId;
  if (!userId) {
    await checkSignup(db, cfg, { ip, setupTokenOk: await setupTokenOk(cfg, setupToken) });
    handle = randomToken(12);
  }
  const existing = userId ? await db.all("SELECT id, transports FROM credentials WHERE user_id = ?", [userId]) : [];
  const options = await generateRegistrationOptions({
    rpName: "Harina",
    rpID: cfg.rpID,
    userName: "Harina",
    userID: new TextEncoder().encode(handle),
    attestationType: "none",
    excludeCredentials: existing.map((c) => ({ id: c.id, transports: c.transports ? JSON.parse(c.transports) : undefined })),
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
  });
  const challengeId = await saveChallenge(db, options.challenge, userId ? "register" : "signup", handle);
  return { challengeId, options };
}

/** Returns `{ userId, session? }`: a new session only when this created the person. */
export async function registrationVerify(db, cfg, { userId, setupToken, challengeId, response }) {
  const challenge = await takeChallenge(db, challengeId, userId ? "register" : "signup");
  if (userId && challenge.user_id !== userId) throw new AuthError("challenge_expired", 400);
  if (!userId && cfg.signup !== "open" && !(await setupNeeded(db) && (await setupTokenOk(cfg, setupToken)))) {
    throw new AuthError("signup_closed", 403);
  }
  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge.challenge,
      expectedOrigin: cfg.origin,
      expectedRPID: cfg.rpID,
      requireUserVerification: true,
    });
  } catch {
    throw new AuthError("passkey_failed", 400);
  }
  if (!verification.verified || !verification.registrationInfo) throw new AuthError("passkey_failed", 400);
  const owner = userId ?? (await createUser(db, { id: challenge.user_id })).id;
  const { credential } = verification.registrationInfo;
  await db.run("INSERT INTO credentials (id, user_id, public_key, counter, transports, created_at) VALUES (?, ?, ?, ?, ?, ?)", [
    credential.id,
    owner,
    isoBase64URL.fromBuffer(credential.publicKey),
    credential.counter,
    JSON.stringify(credential.transports ?? []),
    Date.now(),
  ]);
  return userId ? { userId } : { userId: owner, session: await createSession(db, owner) };
}

export async function authenticationOptions(db, cfg) {
  const options = await generateAuthenticationOptions({ rpID: cfg.rpID, userVerification: "required" });
  return { challengeId: await saveChallenge(db, options.challenge, "login"), options };
}

export async function authenticationVerify(db, cfg, { challengeId, response }) {
  const challenge = await takeChallenge(db, challengeId, "login");
  const cred = await db.first("SELECT * FROM credentials WHERE id = ?", [String(response?.id ?? "")]);
  if (!cred) throw new AuthError("passkey_failed", 400);
  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge: challenge.challenge,
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
  return createSession(db, cred.user_id);
}

export async function hasPasskey(db, userId) {
  return Boolean(await db.first("SELECT id FROM credentials WHERE user_id = ? LIMIT 1", [userId]));
}

export async function createSession(db, userId) {
  const token = randomToken();
  const now = Date.now();
  await db.run("DELETE FROM sessions WHERE expires_at < ?", [now]);
  await db.run("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)", [
    await sha256(token),
    userId,
    now,
    now + SESSION_TTL_MS,
  ]);
  return { token, expiresAt: now + SESSION_TTL_MS };
}

/** The person behind a session cookie, or null. */
export async function sessionUser(db, token) {
  if (!token) return null;
  const row = await db.first("SELECT user_id, expires_at FROM sessions WHERE token_hash = ?", [await sha256(token)]);
  return row && row.expires_at > Date.now() ? row.user_id : null;
}

export async function endSession(db, token) {
  if (token) await db.run("DELETE FROM sessions WHERE token_hash = ?", [await sha256(token)]);
}

// ----- One-time codes: 'link' (web to iPhone) and 'web' (iPhone to web) -----

export async function createCode(db, userId, purpose) {
  const code = linkCode();
  await db.run("DELETE FROM link_codes WHERE expires_at < ?", [Date.now()]);
  await db.run("INSERT INTO link_codes (code_hash, user_id, purpose, expires_at) VALUES (?, ?, ?, ?)", [
    await sha256(`${purpose}:${normalizeLinkCode(code)}`),
    userId,
    purpose,
    Date.now() + LINK_CODE_TTL_MS,
  ]);
  return { code, expiresAt: Date.now() + LINK_CODE_TTL_MS };
}

/** Takes a code once. Too many wrong codes void every open code of that purpose. */
async function takeCode(db, code, purpose) {
  const hash = await sha256(`${purpose}:${normalizeLinkCode(code)}`);
  const row = await db.first("SELECT * FROM link_codes WHERE code_hash = ?", [hash]);
  const key = `${purpose}_failures`;
  if (!row || row.expires_at < Date.now()) {
    await db.run("INSERT INTO meta (key, value) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET value = value + 1", [key]);
    const f = await db.first("SELECT value FROM meta WHERE key = ?", [key]);
    if (f.value >= MAX_LINK_FAILURES) {
      await db.run("DELETE FROM link_codes WHERE purpose = ?", [purpose]);
      await db.run("UPDATE meta SET value = 0 WHERE key = ?", [key]);
    }
    throw new AuthError(purpose === "link" ? "invalid_link_code" : "invalid_code", 400);
  }
  await db.run("DELETE FROM link_codes WHERE code_hash = ?", [hash]);
  return row.user_id;
}

async function newDevice(db, userId, name) {
  const token = randomToken();
  const id = randomToken(12);
  const deviceName = typeof name === "string" && name.trim() ? name.trim().slice(0, 100) : "iPhone";
  await db.run("INSERT INTO devices (id, user_id, name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)", [
    id,
    userId,
    deviceName,
    await sha256(token),
    Date.now(),
    Date.now(),
  ]);
  return { deviceId: id, token };
}

/** Trades a link code from the web for a device token of the same person. */
export async function linkDevice(db, { code, name }) {
  return newDevice(db, await takeCode(db, code, "link"), name);
}

/** Signs up from the iPhone: a new person with their personal space and this device's token. */
export async function signupDevice(db, cfg, { name, deviceName, ip }) {
  await checkSignup(db, cfg, { ip, setupTokenOk: false });
  const user = await createUser(db, { name });
  return { ...(await newDevice(db, user.id, deviceName)), userId: user.id };
}

/** Trades a code shown on the iPhone for a web session, so the person can add a passkey there. */
export async function redeemWebCode(db, { code }) {
  const userId = await takeCode(db, code, "web");
  return { userId, session: await createSession(db, userId) };
}

/** `{ id, userId }` of the device behind a token, or null. */
export async function deviceFromToken(db, token) {
  if (!token) return null;
  const row = await db.first("SELECT id, user_id FROM devices WHERE token_hash = ?", [await sha256(token)]);
  if (!row) return null;
  await db.run("UPDATE devices SET last_seen_at = ? WHERE id = ?", [Date.now(), row.id]);
  return { id: row.id, userId: row.user_id };
}

export async function listDevices(db, userId) {
  return db.all("SELECT id, name, created_at, last_seen_at FROM devices WHERE user_id = ? ORDER BY created_at", [userId]);
}

export async function revokeDevice(db, userId, id) {
  await db.run("DELETE FROM devices WHERE id = ? AND user_id = ?", [id, userId]);
}
