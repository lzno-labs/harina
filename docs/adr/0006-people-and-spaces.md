# ADR-0006: Several people per instance, with personal and shared spaces

- **Status:** Accepted
- **Date:** 2026-11-10
- **Supersedes:** ADR-0003 (extends ADR-0002, ADR-0004 and ADR-0005)
- **Author:** owner session (claude)

## Context

The owner decided that the hosted harina.lzno.app is a service for many people (SaaS), and that
people must be able to keep some finances to themselves and share others (a couple, a household).
ADR-0003 assumed one person per instance: one set of passkeys, sessions and devices, and every row
visible to all of them. Self-hosters must keep a simple single-person setup.

## Options

1. **Users plus spaces.** Each person is a user with their own passkeys, sessions and devices. Data
   lives in spaces: every user has one personal space, and can create or join shared spaces. Every
   account, category and transaction belongs to exactly one space. Sharing is choosing the space.
2. **Users only, with a per-row "shared with" list:** flexible, but every query and every sync
   needs row-level ACLs, and moving a row between people gets subtle.
3. **One shared household per instance** (everyone sees everything): simplest, but no private
   spending, which the owner wants.
4. **A separate instance per person** (database per tenant): strong isolation, but no shared
   finances across instances and much more to operate on the free tier.

## Decision

Option 1.

- **Identity:** `users`; passkeys, sessions, devices, link codes, OAuth grants and decider consent
  belong to a user. Device tokens and OAuth tokens act as their user.
- **Sign-up:** `HARINA_SIGNUP` = `closed` (default: the first user needs `HARINA_SETUP_TOKEN`, as
  today; later users only by invitation), `invite` or `open` (the hosted service). From the web with
  a passkey, or from the iPhone, which creates the user and its device token in one step; the app
  then helps add a passkey for the web (one-time code shown on the iPhone, typed on the web).
  Sign-up is rate limited per IP and capped by `HARINA_MAX_USERS`.
- **Spaces:** `spaces` (personal or shared, name), `members` (space, user, role owner or member),
  `invites` (one-time code or link, 7 days). Leaving a shared space keeps its data for the others.
- **Data:** `accounts`, `categories` and `transactions` get `space_id`; primary keys become
  `(space_id, id)` so suggested categories keep their fixed ids (`default-food`) in every space and
  offline devices still converge by id. Transactions record `created_by` (user).
- **Sync** (ADR-0002 unchanged otherwise): a pull returns rows of the spaces the user belongs to,
  plus the spaces and memberships; a push is refused for spaces the user is not in. When a user
  joins a space, their devices pull that space from the start.
- **Recovery:** passkeys sync through the platform keychain; the iPhone can always show a one-time
  web code. If a person loses both, the operator runs `npm run login-code [user id]` (self-hosted)
  and the person adds a new passkey after signing in with it.
- **Migration:** Harina is in testing, and the owner authorized discarding existing data
  (2026-11-10). The new schema is created from scratch: the hosted database is reset, the owner
  registers a new passkey and relinks the iPhones (rows still on a phone sync up again). Self-hosted
  instances in testing do the same; no data migration code is written.

## Consequences

- Isolation is enforced in every query by space membership; covered by tests that a user can never
  read or write another person's personal space, through sync, export, MCP or the decider.
- Last-writer-wins per row now spans people in a shared space; accepted (edits of the same row by
  two people at the same time are rare and visible).
- Export and «delete my data» are per user: personal space plus, optionally, what they created in
  shared spaces.
- Opening sign-up to the public needs a privacy notice and terms of use first (empresa `legal/`).
