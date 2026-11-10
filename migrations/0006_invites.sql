-- Invitations to shared spaces (docs/design/people-and-spaces.md): one use, 7 days, stored hashed.
CREATE TABLE invites (
  code_hash TEXT PRIMARY KEY,
  space_id TEXT NOT NULL,
  created_by TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX invites_space ON invites (space_id);
