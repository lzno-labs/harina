# Security review before opening the repository (2026-11-11)

Scope: the server (`src/`), the web app (`public/`) and the account and sync parts of the iOS
app, at the commit that made the repository public. Reviewer: owner session (claude).

## What holds

- **Isolation between people.** Every query of synced data, export, MCP tool and decider call is
  limited to the spaces the caller is a member of (`members`). A push to a space outside them is
  refused. Only owners rename a space, remove members or delete it.
- **Sessions.** `__Host-` cookie, `HttpOnly`, `SameSite=Strict`, `Secure`. Every cookie
  authenticated write must come with our own `Origin`. JSON bodies only.
- **Secrets at rest.** Session, device, OAuth and one-time code tokens are stored as SHA-256
  hashes. Passkeys keep only public keys.
- **Passkeys.** The challenge is single use and expires in 5 minutes. The server checks origin and
  rpID and requires user verification. The iPhone login (ADR-0007) uses the same checks.
- **OAuth and MCP.** Public clients with PKCE S256 only, and exact redirect URIs. Read and write
  are separate scopes, and refresh tokens are hashed. A failed request never redirects to an
  unverified redirect URI.
- **Web.** Strict CSP (`script-src 'self'`, no inline script), and no `innerHTML`. Also
  `frame-ancestors 'none'`, `nosniff`, `no-referrer` and HSTS.
- **Exports.** CSV cells that start with `= + - @` are prefixed, so spreadsheets do not run them.
- **Hosted decider.** It needs per-person consent and has an hourly call limit and a monthly token
  cap. It sends only the fields listed in the consent text.
- **Secrets in the repository.** gitleaks runs on the whole history in CI.

## Fixed in this review

1. **Wrong codes voided everyone's codes.** Five wrong link or web codes, or ten wrong invites, from
   anyone deleted every open code on the instance. On a shared instance a stranger could keep
   everyone from linking a phone or joining a space. Now wrong codes count per IP (10 per hour,
   then 429), and nobody else's codes are touched. Codes have about 40 bits and live 10 minutes
   (invites 7 days), so guessing stays out of reach.
2. **Anonymous writes had no limit.** Passkey sign-in options, OAuth client registration and
   OAuth authorization requests each store a row and need no account. They are now limited per IP
   and hour (`src/limits.js`). On the hosted plan this also protects the database's daily write
   quota.
3. **Deleting an account used `LIKE '%:<id>'` on settings keys.** `_` in an id is a wildcard,
   so it could match another person's key. It now deletes the exact key.

## Known risks, accepted for now

- **Storage quota per person.** A signed-in person can push up to 500 rows per request, without a
  total cap. Sign-up is limited per IP and by `HARINA_MAX_USERS`, and accounts can be deleted. A
  quota needs a row counter (a `COUNT` per push would cost too many reads on D1).
- **The decider's limits are per instance, not per person.** One person could use the hour's
  calls or the month's tokens. Money stays bounded by the cap.
- **Client ID Metadata Documents on a self-hosted server.** The server fetches the client's https
  URL. Names, IPs and local hosts are refused by name, but a public name that resolves to a
  private address is not. Workers cannot reach private networks; on your own machine, set
  `HARINA_OAUTH_CIMD=off` if that matters.
- **Device tokens do not expire.** They can be revoked from the web. A stolen token can also add a
  passkey (ADR-0007). Getting it requires the unlocked phone or its backups.
- **Text from your data reaches your AI assistant through MCP.** A merchant name could carry
  instructions meant for it. Assistants should treat tool results as data.
