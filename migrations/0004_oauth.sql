-- OAuth 2.1 for the MCP endpoint (docs/adr/0004-oauth-and-mcp.md). Auth state, never exported.

-- Clients: CIMD documents (id is their https URL, cached) and dynamically registered clients.
CREATE TABLE oauth_clients (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('cimd', 'dcr')),
  name TEXT,
  redirect_uris TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

-- Validated authorization requests waiting for the person's decision on the consent page.
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

-- One grant per approved connection; listed and revocable in settings.
CREATE TABLE oauth_grants (
  id TEXT PRIMARY KEY,
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

-- Access and refresh tokens, stored hashed. A used refresh token stays (used = 1) to detect reuse.
CREATE TABLE oauth_tokens (
  token_hash TEXT PRIMARY KEY,
  grant_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
  scopes TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX oauth_tokens_grant ON oauth_tokens (grant_id);
