# ADR-0003: Passkeys on the web, device tokens linked by one-time code on the iPhone

- **Status:** Superseded by ADR-0006
- **Date:** 2026-11-04
- **Supersedes:** none
- **Author:** founding agent (claude)

## Context

Each harina instance belongs to one person (PRD: no shared finances in v1). The data is financial, so no passwords to phish or reuse, no email dependency (no mailbox yet), and no third party identity provider in the open core. The iPhone app syncs in the background, possibly with the phone locked, so it cannot ask for a passkey on every request.

## Options

1. **Passkeys (WebAuthn) on the web, plus a long random device token for the iPhone obtained by typing a one-time code generated in the web; Face ID gates opening the app.**
2. **Email magic links:** needs a mailbox and an email provider; weaker (email account takeover).
3. **Password plus TOTP:** phishable, and more to build and support.
4. **Sign in with Apple:** ties the open core to Apple and does not fit Android or self-hosting.
5. **Passkey inside the iOS app too:** possible with Associated Domains, but it ties the app to one domain (bad for self-hosters) and does not solve background sync.

## Decision

Option 1:

- **First run:** while no passkey exists, registration requires `HARINA_SETUP_TOKEN` (set by the operator; a self-hosted server prints a random one at startup if unset). After the first passkey, registration needs a logged-in session. User verification is required.
- **Sessions:** random 256-bit token in an `HttpOnly`, `SameSite=Strict`, `Secure` cookie (`__Host-` prefix on HTTPS), stored hashed (SHA-256), 30 days. Cookie-authenticated writes also require our own `Origin` header.
- **iPhone linking:** the web generates a code like `K7QF-M2XA` (40 bits, 10 minutes, single use, stored hashed; five wrong codes void all open codes). The app trades it for a 256-bit device token, stored hashed on the server and in the iPhone Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced to iCloud). Device tokens can only sync and export; they cannot manage devices, link others or delete data. The web lists devices and revokes them.
- **Face ID:** the app asks for Face ID (or the passcode) when opened. Capturing a payment through Shortcuts does not need it, by design: it only adds a row.
- **Recovery:** passkeys sync through the platform keychain. If all are lost, the operator runs `npm run reset-passkeys` (or deletes the rows in D1) and sets up again with the setup token. Data is untouched.
- WebAuthn verification uses `@simplewebauthn/server`, pinned.

## Consequences

- No passwords, no email, no third party auth. Works on any device with passkeys (iOS 16+, Android 9+, modern desktops).
- Losing the iPhone means revoking it on the web; the token alone cannot read anything else than sync and export.
- Adding more people to one instance later needs a users table and a new ADR.
- Self-hosters must serve harina over HTTPS on a stable hostname: passkeys are bound to it (`HARINA_ORIGIN`).
