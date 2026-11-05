-- harina schema v1. Applied by `wrangler d1 migrations apply` on Cloudflare and by
-- src/storage/migrate.js everywhere else. Never edit an applied migration: add a new file.

-- Synced entities. Every row carries:
--   updated_at  client clock in ms, used for last-writer-wins
--   deleted     tombstone (1) so deletions sync to every device
--   seq         server change counter, used by GET /api/sync?since=
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  card TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL
);
CREATE INDEX accounts_seq ON accounts (seq);

-- `key` marks a default category; its visible name comes from the locale files
-- until the person renames it (then `name` wins).
CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  key TEXT,
  name TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL
);
CREATE INDEX categories_seq ON categories (seq);

-- Amounts are integers in the currency's minor unit (cents for CRC and USD).
CREATE TABLE transactions (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('expense', 'income')),
  amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  category_id TEXT,
  account_id TEXT,
  merchant TEXT,
  note TEXT,
  card TEXT,
  source TEXT NOT NULL CHECK (source IN ('manual', 'apple_pay')),
  raw_amount TEXT,
  needs_review INTEGER NOT NULL DEFAULT 0,
  occurred_at TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL
);
CREATE INDEX transactions_seq ON transactions (seq);
CREATE INDEX transactions_occurred ON transactions (occurred_at);

-- Server state.
CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT INTO meta (key, value) VALUES ('seq', 7), ('link_failures', 0);

CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL,
  transports TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE challenges (id TEXT PRIMARY KEY, challenge TEXT NOT NULL, purpose TEXT NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER
);
CREATE TABLE link_codes (code_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);

-- Default categories (PRD). Names live in locales/<lang>.json under categories.default.
INSERT INTO categories (id, key, name, updated_at, deleted, seq) VALUES
  ('default-food', 'food', NULL, 0, 0, 1),
  ('default-groceries', 'groceries', NULL, 0, 0, 2),
  ('default-transport', 'transport', NULL, 0, 0, 3),
  ('default-home', 'home', NULL, 0, 0, 4),
  ('default-health', 'health', NULL, 0, 0, 5),
  ('default-entertainment', 'entertainment', NULL, 0, 0, 6),
  ('default-other', 'other', NULL, 0, 0, 7);
