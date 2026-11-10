// SPDX-License-Identifier: AGPL-3.0-only
// People and spaces (docs/adr/0006-people-and-spaces.md). Every person has a personal space; data
// rows belong to a space, and a person only ever reaches the spaces they are a member of.
import { randomToken, sha256 } from "./crypto.js";

/** Suggested categories every new personal space starts with (PRD). Same ids as the iPhone and web. */
export const DEFAULT_CATEGORIES = ["food", "groceries", "transport", "home", "health", "entertainment", "other"];
export const SIGNUPS_PER_HOUR_PER_IP = 5;
export const DEFAULT_MAX_USERS = 1000;

export class PeopleError extends Error {
  constructor(code, status = 403) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

export async function userCount(db) {
  return Number((await db.first("SELECT COUNT(*) AS n FROM users"))?.n ?? 0);
}

/** Creates a person with their personal space and its suggested categories. */
export async function createUser(db, { id = randomToken(12), name } = {}, now = Date.now()) {
  const space = randomToken(12);
  const cleanName = typeof name === "string" && name.trim() ? name.trim().slice(0, 100) : null;
  await db.batch([
    { sql: "INSERT INTO users (id, name, created_at) VALUES (?, ?, ?)", params: [id, cleanName, now] },
    ...newSpaceStatements(space, "personal", null, id, now),
  ]);
  return { id, name: cleanName, personalSpace: space };
}

/** A space with its owner and the suggested categories. */
export function newSpaceStatements(space, kind, name, ownerId, now = Date.now()) {
  const bump = { sql: "UPDATE meta SET value = value + 1 WHERE key = 'seq'", params: [] };
  return [
    { sql: "INSERT INTO spaces (id, kind, name, created_by, created_at) VALUES (?, ?, ?, ?, ?)", params: [space, kind, name, ownerId, now] },
    { sql: "INSERT INTO members (space_id, user_id, role, created_at) VALUES (?, ?, 'owner', ?)", params: [space, ownerId, now] },
    // updated_at 0: a phone that started offline with the same suggested ids always wins.
    ...DEFAULT_CATEGORIES.flatMap((key) => [
      bump,
      {
        sql: "INSERT INTO categories (space_id, id, key, name, updated_at, deleted, seq) VALUES (?, ?, ?, NULL, 0, 0, (SELECT value FROM meta WHERE key = 'seq'))",
        params: [space, `default-${key}`, key],
      },
    ]),
  ];
}

/** The person's spaces and the one new rows go to when a device does not say. */
export async function spacesOf(db, userId) {
  const rows = await db.all(
    "SELECT s.id, s.kind, s.name, m.role FROM members m JOIN spaces s ON s.id = m.space_id WHERE m.user_id = ? ORDER BY s.kind = 'personal' DESC, s.created_at",
    [userId],
  );
  const personal = rows.find((r) => r.kind === "personal")?.id ?? null;
  return { ids: rows.map((r) => r.id), personal, list: rows };
}

export async function getUser(db, userId) {
  return db.first("SELECT id, name, created_at FROM users WHERE id = ?", [userId]);
}

/**
 * Whether a new person may sign up now. `closed` (default): only the first person, with the
 * setup token. `open`: anyone, limited per IP and by HARINA_MAX_USERS.
 */
export async function checkSignup(db, cfg, { ip, setupTokenOk }, now = Date.now()) {
  const count = await userCount(db);
  if (count === 0 && setupTokenOk) return;
  if (cfg.signup !== "open") throw new PeopleError(count === 0 ? "setup_required" : "signup_closed", 403);
  if (count >= cfg.maxUsers) throw new PeopleError("signup_full", 403);
  const key = `signup:${(await sha256(String(ip ?? "unknown"))).slice(0, 16)}:${new Date(now).toISOString().slice(0, 13)}`;
  await db.run("DELETE FROM meta WHERE key LIKE 'signup:%' AND key NOT LIKE ?", [`signup:%:${new Date(now).toISOString().slice(0, 13)}`]);
  const used = Number((await db.first("SELECT value FROM meta WHERE key = ?", [key]))?.value ?? 0);
  if (used >= SIGNUPS_PER_HOUR_PER_IP) throw new PeopleError("rate_limited", 429);
  await db.run("INSERT INTO meta (key, value) VALUES (?, 1) ON CONFLICT (key) DO UPDATE SET value = value + 1", [key]);
}

/**
 * Deletes a person: their personal space with all its rows, their sign-in data and connections.
 * Shared spaces (phase 2) keep what they added; the person just leaves them.
 */
export async function deleteUser(db, userId) {
  const { leaveSpace } = await import("./spaces.js");
  for (const s of (await spacesOf(db, userId)).list.filter((x) => x.kind === "shared")) await leaveSpace(db, userId, s.id);
  const { list } = await spacesOf(db, userId);
  const personal = list.filter((s) => s.kind === "personal").map((s) => s.id);
  const stmts = [];
  for (const space of personal) {
    for (const t of ["transactions", "categories", "accounts", "members"]) {
      stmts.push({ sql: `DELETE FROM ${t} WHERE space_id = ?`, params: [space] });
    }
    stmts.push({ sql: "DELETE FROM spaces WHERE id = ?", params: [space] });
  }
  const grants = (await db.all("SELECT id FROM oauth_grants WHERE user_id = ?", [userId])).map((g) => g.id);
  for (const g of grants) {
    stmts.push({ sql: "DELETE FROM oauth_tokens WHERE grant_id = ?", params: [g] }, { sql: "DELETE FROM oauth_codes WHERE grant_id = ?", params: [g] });
  }
  for (const t of ["oauth_grants", "credentials", "sessions", "devices", "link_codes", "members"]) {
    stmts.push({ sql: `DELETE FROM ${t} WHERE user_id = ?`, params: [userId] });
  }
  stmts.push(
    { sql: "DELETE FROM meta WHERE key LIKE ?", params: [`%:${userId}`] },
    { sql: "DELETE FROM users WHERE id = ?", params: [userId] },
  );
  await db.batch(stmts);
}
