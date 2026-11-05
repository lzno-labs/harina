# ADR-0004: harina is its own OAuth 2.1 authorization server for a remote MCP endpoint

- **Status:** Accepted
- **Date:** 2026-11-05
- **Supersedes:** none (extends ADR-0003)
- **Author:** owner session (claude)

## Context

The owner wants to use harina from AI assistants (Claude, ChatGPT, others) through the Model Context Protocol. Remote MCP clients authorize with OAuth: the MCP specification (revision 2026-07-28) requires Protected Resource Metadata (RFC 9728), authorization server metadata (RFC 8414), resource indicators (RFC 8707) with audience-bound tokens, and recommends Client ID Metadata Documents (CIMD), with dynamic client registration (RFC 7591) deprecated but still used. Claude and ChatGPT require PKCE with S256, public clients, and fixed redirect URIs on their own domains. Each harina instance has one owner (ADR-0003), and the core must stay provider neutral and self-hostable.

## Options

1. **harina as its own minimal OAuth 2.1 authorization server**, in the same app, reusing the passkey login of ADR-0003 for the consent page. Opaque random tokens stored hashed. Cost 0. No new dependency.
2. **Cloudflare's workers-oauth-provider library:** less code, but ties the core to Workers and KV; self-hosters on Node would need a second implementation.
3. **An external identity provider** (Auth0, WorkOS, Stytch): a new account and vendor for a single-user app, data about every login leaves harina, and self-hosters must replicate it.
4. **Static bearer tokens pasted into the client:** works for developer tools (Claude Code, Gemini CLI) but not for Claude or ChatGPT connectors on web and mobile.

## Decision

Option 1:

- **Resource:** `<origin>/mcp`. Metadata at `/.well-known/oauth-protected-resource` (and `/mcp` suffixed). 401 responses carry `WWW-Authenticate: Bearer resource_metadata="…", scope="harina.read"`.
- **Authorization server:** issuer `<origin>`, metadata at `/.well-known/oauth-authorization-server`; `authorization_code` and `refresh_token` grants only; PKCE `S256` only; `token_endpoint_auth_methods_supported: ["none"]` (public clients); `client_id_metadata_document_supported: true`; DCR at `/oauth/register`; RFC 9207 `iss` in the redirect.
- **Clients:** a CIMD `client_id` is an https URL whose JSON is fetched (no redirects, 64 KB, 5 s, no IP-literal or local hosts) and cached a day; its `redirect_uris` must contain the requested one (loopback redirects match on any port). DCR clients get a random id; registration is capped.
- **Scopes:** `harina.read` (always) and `harina.write` (optional, chosen on the consent page). Write allows adding movements and setting categories; there is no scope to delete or change amounts.
- **Tokens:** access tokens 1 hour, refresh tokens 30 days, both opaque and stored as SHA-256 hashes, bound to the resource and to a grant. Refresh tokens rotate; reusing an old one revokes the whole grant. Codes are single use and expire in 5 minutes.
- **Consent:** `/oauth/authorize` validates the request and sends the browser to the web app's consent page, which requires the passkey session, shows the client's name and host and the scopes, and posts the decision with the same-origin checks of ADR-0003.
- **Revocation:** every grant is listed in Settings, "Conexiones", with its client, scopes and last use, and can be revoked; `/oauth/revoke` also exists.

## Consequences

- One login for everything (passkeys), no new vendor, works the same on Workers and Node.
- harina now runs security-sensitive OAuth code; it is covered by tests of the full flow, PKCE, redirect and resource checks, code reuse, refresh rotation and reuse detection.
- CIMD makes the server fetch a URL chosen by the client; on a self-hosted machine inside a private network this is a server-side request risk, limited by the host checks above. Self-hosters can turn CIMD off with `HARINA_OAUTH_CIMD=off`.
- Revisit if harina gets several people per instance (users and per-user grants), or if the MCP authorization profile changes again.
