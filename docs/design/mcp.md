# Design: use harina from AI assistants (remote MCP server)

- **Issue:** owner request, 2026-11-05; PRD change in `lzno-labs/empresa` (harina 1.2)
- **Status:** Approved by the owner in chat; PRD change pending merge
- **Author:** owner session (claude)
- **Touches:** data (leaves to the person's assistant with consent), security (OAuth), AI (the assistant is external)

## Goal

The person adds `https://<their harina>/mcp` as a connector in Claude, ChatGPT or another MCP client, signs in with their passkey, and can ask "¿cuánto llevo en comida este mes?" or say "anota ₡4 500 en la soda". Out of scope: deleting or editing amounts, several people per instance, server-initiated messages.

## Relevant ADRs

- ADR-0004: harina as its own OAuth server (this design implements it).
- ADR-0003: passkeys and same-origin checks protect the consent page.
- ADR-0002: writes go through the same validated sync path, so iPhones receive them.

## Approach

### Endpoint

`POST /mcp`, JSON-RPC over Streamable HTTP, JSON responses (no SSE, no sessions). `GET` and `DELETE` answer 405.

- **Both protocol eras.** Clients that start with `initialize` (2025-06-18, 2025-11-25) get the legacy behavior: version negotiation in `initialize`, `notifications/*` answered 202. Clients on 2026-07-28 send the version in `_meta` and the `MCP-Protocol-Version` header; harina implements `server/discover`, checks that headers match the body (`-32020`) and answers unknown versions with `-32022` and the supported list.
- **Origin:** a request with an `Origin` header that is not harina's own origin (or one listed in `HARINA_MCP_ORIGINS`) is refused with 403.
- **Auth:** `Authorization: Bearer` only. Missing or invalid token: 401 with the `WWW-Authenticate` challenge. A write tool without `harina.write`: 403 `insufficient_scope` so the client can ask for more.

### Tools

Titles and descriptions come from `locales/es.json` (they are visible in the assistant). Results are `structuredContent` plus the same JSON as text. Amounts are decimal strings with their currency.

| Tool | Scope | What it does |
| --- | --- | --- |
| `get_month_summary` | read | Spent and income per currency, by category, month projection, pending review count. |
| `search_transactions` | read | Movements filtered by text, dates, category, kind; at most 100. |
| `list_recurring` | read | Fixed charges: next date, status, price changes. |
| `list_to_review` | read | Uncategorized payments with the decision model's suggestion. |
| `list_categories` | read | Active categories with id, name and emoji. |
| `add_transaction` | write | Adds an expense or income (amount, currency, merchant, category by id or name, date, note). |
| `categorize_transaction` | write | Sets the category of a movement (records a correction if it was automatic). |

Tools are listed according to the granted scopes; read tools are marked `readOnlyHint`.

### Consent and connections

`/oauth/authorize` stores the validated request and redirects to `/#/autorizar/<id>`. The web app asks for the passkey if needed, then shows the client name and host, "Podrá ver" and an optional "Podrá anotar y categorizar" switch, and a warning that the data will be processed by that assistant under its own rules. Allow or deny posts to `/api/oauth/decision`; the app then sends the browser back to the client with the code. Settings, "Conexiones", lists grants and revokes them.

### Data

Migration `0004_oauth.sql`: `oauth_clients` (CIMD cache and DCR clients), `oauth_requests` (pending consent, 10 minutes), `oauth_codes`, `oauth_grants`, `oauth_tokens` (hashed, with kind, expiry, resource and rotation state). None of it is exported (auth state, like passkeys).

## Alternatives considered

- A separate pro service: needs its own login and API for no protection (the sync API is open). Rejected by the owner.
- Personal tokens only: cannot be used by Claude or ChatGPT on web and mobile.

## Risks and safeguards

- **Data:** leaves only to the assistant the person authorizes on the consent page, scoped to read unless write is chosen; revocable at any time; tokens expire in an hour.
- **Security:** PKCE S256 required; exact redirect URI match; resource bound tokens; single-use short codes; refresh rotation with reuse detection; hashed tokens; capped DCR; CIMD host checks; Origin checks on `/mcp`; consent behind passkey and same-origin checks; clickjacking blocked by CSP `frame-ancestors 'none'`.
- **Prompt injection:** merchant names and notes come from the person's own data and are returned as JSON fields; tools cannot delete or change amounts, which bounds what a manipulated assistant could do.
- **Money and AI:** harina does not call any AI and spends nothing.

## Testing and rollout

- Tests: metadata, DCR and CIMD flows end to end (fake client fetch), PKCE failure, redirect and resource mismatches, code reuse, refresh rotation and reuse detection, revocation, both MCP eras, tools per scope, 401 and 403 challenges, Origin and header checks.
- Manual: add the connector in Claude and in ChatGPT against the hosted instance, ask for the month summary, add a movement, see it on the iPhone, revoke in Settings.
- Rollback: revoke all connections; remove the `/mcp` route.
