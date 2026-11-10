// SPDX-License-Identifier: AGPL-3.0-only
// Shared spaces (docs/design/people-and-spaces.md, phase 2): create, invite, join, leave.
// Only members reach a space; only its owner renames it, removes members or deletes it.
import { linkCode, normalizeLinkCode, randomToken, sha256 } from "./crypto.js";
import { newSpaceStatements, PeopleError } from "./people.js";

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_INVITE_FAILURES = 10;
export const MAX_SPACES_PER_USER = 20;

const cleanName = (name) => (typeof name === "string" && name.trim() ? name.trim().slice(0, 60) : null);

async function membership(db, userId, spaceId) {
  return db.first(
    "SELECT s.id, s.kind, s.name, m.role FROM members m JOIN spaces s ON s.id = m.space_id WHERE m.user_id = ? AND m.space_id = ?",
    [userId, String(spaceId ?? "")],
  );
}

async function needShared(db, userId, spaceId, { owner = false } = {}) {
  const m = await membership(db, userId, spaceId);
  if (!m) throw new PeopleError("not_found", 404);
  if (m.kind !== "shared") throw new PeopleError("personal_space", 400);
  if (owner && m.role !== "owner") throw new PeopleError("owner_only", 403);
  return m;
}

/** The person's spaces with their members (names only: nothing else about other people). */
export async function listSpaces(db, userId) {
  const spaces = await db.all(
    "SELECT s.id, s.kind, s.name, m.role FROM members m JOIN spaces s ON s.id = m.space_id WHERE m.user_id = ? ORDER BY s.kind DESC, s.created_at",
    [userId],
  );
  if (!spaces.length) return [];
  const ids = spaces.map((s) => s.id);
  const members = await db.all(
    `SELECT m.space_id, m.user_id, m.role, u.name FROM members m JOIN users u ON u.id = m.user_id WHERE m.space_id IN (${ids.map(() => "?").join(",")}) ORDER BY m.created_at`,
    ids,
  );
  return spaces.map((s) => ({
    ...s,
    members: members.filter((m) => m.space_id === s.id).map((m) => ({ id: m.user_id, name: m.name, role: m.role, me: m.user_id === userId })),
  }));
}

export async function createSpace(db, userId, { name }) {
  const n = cleanName(name);
  if (!n) throw new PeopleError("name_required", 400);
  const count = Number((await db.first("SELECT COUNT(*) AS n FROM members WHERE user_id = ?", [userId])).n);
  if (count >= MAX_SPACES_PER_USER) throw new PeopleError("too_many_spaces", 400);
  const id = randomToken(12);
  await db.batch(newSpaceStatements(id, "shared", n, userId));
  return id;
}

export async function renameSpace(db, userId, spaceId, { name }) {
  await needShared(db, userId, spaceId, { owner: true });
  const n = cleanName(name);
  if (!n) throw new PeopleError("name_required", 400);
  await db.run("UPDATE spaces SET name = ? WHERE id = ?", [n, spaceId]);
}

/** Deletes a shared space and everything in it, for every member (owner only). */
export async function deleteSpace(db, userId, spaceId) {
  await needShared(db, userId, spaceId, { owner: true });
  await dropSpace(db, spaceId);
}

async function dropSpace(db, spaceId) {
  await db.batch(
    ["transactions", "categories", "accounts", "members", "invites"]
      .map((t) => ({ sql: `DELETE FROM ${t} WHERE space_id = ?`, params: [spaceId] }))
      .concat([{ sql: "DELETE FROM spaces WHERE id = ?", params: [spaceId] }]),
  );
}

export async function createInvite(db, userId, spaceId) {
  await needShared(db, userId, spaceId);
  const code = linkCode();
  await db.run("DELETE FROM invites WHERE expires_at < ?", [Date.now()]);
  await db.run("INSERT INTO invites (code_hash, space_id, created_by, expires_at) VALUES (?, ?, ?, ?)", [
    await sha256(`invite:${normalizeLinkCode(code)}`),
    spaceId,
    userId,
    Date.now() + INVITE_TTL_MS,
  ]);
  return { code, expiresAt: Date.now() + INVITE_TTL_MS };
}

/** Joins the space of a one-time invite. Too many wrong codes void every open invite. */
export async function acceptInvite(db, userId, { code }) {
  const hash = await sha256(`invite:${normalizeLinkCode(code)}`);
  const row = await db.first("SELECT * FROM invites WHERE code_hash = ?", [hash]);
  if (!row || row.expires_at < Date.now()) {
    await db.run("INSERT INTO meta (key, value) VALUES ('invite_failures', 1) ON CONFLICT (key) DO UPDATE SET value = value + 1");
    const f = await db.first("SELECT value FROM meta WHERE key = 'invite_failures'");
    if (f.value >= MAX_INVITE_FAILURES) {
      await db.run("DELETE FROM invites");
      await db.run("UPDATE meta SET value = 0 WHERE key = 'invite_failures'");
    }
    throw new PeopleError("invalid_invite", 400);
  }
  await db.run("DELETE FROM invites WHERE code_hash = ?", [hash]);
  const space = await db.first("SELECT id, name FROM spaces WHERE id = ?", [row.space_id]);
  if (!space) throw new PeopleError("invalid_invite", 400);
  await db.run("INSERT INTO members (space_id, user_id, role, created_at) VALUES (?, ?, 'member', ?) ON CONFLICT (space_id, user_id) DO NOTHING", [
    space.id,
    userId,
    Date.now(),
  ]);
  return space;
}

/**
 * Leaves a shared space. What the person added stays for the others. An owner hands the space to
 * the longest-standing member; the last member leaving deletes it.
 */
export async function leaveSpace(db, userId, spaceId) {
  const m = await needShared(db, userId, spaceId);
  const others = await db.all("SELECT user_id FROM members WHERE space_id = ? AND user_id != ? ORDER BY created_at", [spaceId, userId]);
  if (!others.length) return dropSpace(db, spaceId);
  const stmts = [{ sql: "DELETE FROM members WHERE space_id = ? AND user_id = ?", params: [spaceId, userId] }];
  if (m.role === "owner" && !(await db.first("SELECT 1 FROM members WHERE space_id = ? AND role = 'owner' AND user_id != ?", [spaceId, userId]))) {
    stmts.push({ sql: "UPDATE members SET role = 'owner' WHERE space_id = ? AND user_id = ?", params: [spaceId, others[0].user_id] });
  }
  await db.batch(stmts);
}

export async function removeMember(db, userId, spaceId, memberId) {
  await needShared(db, userId, spaceId, { owner: true });
  if (memberId === userId) throw new PeopleError("use_leave", 400);
  await db.run("DELETE FROM members WHERE space_id = ? AND user_id = ?", [spaceId, memberId]);
}

export async function renameMe(db, userId, { name }) {
  await db.run("UPDATE users SET name = ? WHERE id = ?", [cleanName(name), userId]);
}
