-- Several people per instance, with personal and shared spaces (docs/adr/0006-people-and-spaces.md).
-- Harina is in testing and the owner authorized discarding existing data (2026-11-10): every table
-- is recreated from scratch. Devices relink and push what they still hold.

DROP TABLE IF EXISTS oauth_tokens;
DROP TABLE IF EXISTS oauth_codes;
DROP TABLE IF EXISTS oauth_grants;
DROP TABLE IF EXISTS oauth_requests;
DROP TABLE IF EXISTS oauth_clients;
DROP TABLE IF EXISTS link_codes;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS challenges;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS credentials;
DROP TABLE IF EXISTS meta;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS accounts;

-- People and spaces.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  name TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE spaces (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('personal', 'shared')),
  name TEXT,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE members (
  space_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (space_id, user_id)
);
CREATE INDEX members_user ON members (user_id);

-- Synced entities (docs/adr/0002-sync.md). Every row belongs to one space; ids are unique within
-- a space, so suggested categories keep their fixed ids (default-food) in every space.
CREATE TABLE accounts (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  card TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX accounts_seq ON accounts (seq);

CREATE TABLE categories (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  key TEXT,
  name TEXT,
  icon TEXT,
  color TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX categories_seq ON categories (seq);

CREATE TABLE transactions (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
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
  category_auto INTEGER NOT NULL DEFAULT 0,
  created_by TEXT,
  occurred_at TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX transactions_seq ON transactions (seq);
CREATE INDEX transactions_occurred ON transactions (space_id, occurred_at);

-- Server state: counters (seq), rate limits and per-person settings.
CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT INTO meta (key, value) VALUES ('seq', 0);

-- Authentication, per person.
CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL,
  transports TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE challenges (
  id TEXT PRIMARY KEY,
  challenge TEXT NOT NULL,
  purpose TEXT NOT NULL,
  user_id TEXT,
  expires_at INTEGER NOT NULL
);
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER
);
-- One-time codes: 'link' (web to iPhone) and 'web' (iPhone to web).
CREATE TABLE link_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK (purpose IN ('link', 'web')),
  expires_at INTEGER NOT NULL
);

-- OAuth for MCP (docs/adr/0004-oauth-and-mcp.md); grants belong to a person.
CREATE TABLE oauth_clients (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('cimd', 'dcr')),
  name TEXT,
  redirect_uris TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE oauth_requests (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  state TEXT,
  scopes TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  resource TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE oauth_grants (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  client_name TEXT,
  scopes TEXT NOT NULL,
  resource TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE oauth_codes (
  code_hash TEXT PRIMARY KEY,
  grant_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  resource TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE oauth_tokens (
  token_hash TEXT PRIMARY KEY,
  grant_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
  scopes TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX oauth_tokens_grant ON oauth_tokens (grant_id);
