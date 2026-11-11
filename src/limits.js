// SPDX-License-Identifier: AGPL-3.0-only
// Per-IP limits on what anyone can do without signing in (docs/security-review-2026-11.md): each
// anonymous request that writes to the database, and every wrong one-time code, counts per hour.
import { sha256 } from "./crypto.js";
import { PeopleError } from "./people.js";

/** Requests per IP and hour. */
export const LIMITS = {
  challenge: 60, // passkey sign-in options (each stores a challenge)
  oauth_register: 20, // dynamic client registration (each stores a client)
  oauth_authorize: 60, // authorization requests (each stores a pending request, may fetch a CIMD)
  wrong_code: 10, // wrong link, web or invite codes
};

const hour = (now) => new Date(now).toISOString().slice(0, 13);

async function key(bucket, ip, now) {
  return `rl:${bucket}:${(await sha256(String(ip ?? "unknown"))).slice(0, 16)}:${hour(now)}`;
}

async function used(db, k) {
  return Number((await db.first("SELECT value FROM meta WHERE key = ?", [k]))?.value ?? 0);
}

async function bump(db, k, now) {
  await db.run("DELETE FROM meta WHERE key LIKE 'rl:%' AND key NOT LIKE ?", [`rl:%:${hour(now)}`]);
  await db.run("INSERT INTO meta (key, value) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET value = value + 1", [k]);
}

/** Counts one request; throws 429 once the IP used its hour. */
export async function hit(db, bucket, ip, now = Date.now()) {
  const k = await key(bucket, ip, now);
  if ((await used(db, k)) >= LIMITS[bucket]) throw new PeopleError("rate_limited", 429);
  await bump(db, k, now);
}

/**
 * Runs a one-time code redemption. An IP with too many wrong codes this hour is refused before the
 * code is even looked at; a wrong code counts against it. Nobody else's codes are affected.
 */
export async function guardCode(db, ip, run, now = Date.now()) {
  const k = await key("wrong_code", ip, now);
  if ((await used(db, k)) >= LIMITS.wrong_code) throw new PeopleError("rate_limited", 429);
  try {
    return await run();
  } catch (e) {
    if (["invalid_link_code", "invalid_code", "invalid_invite"].includes(e?.code)) await bump(db, k, now);
    throw e;
  }
}
