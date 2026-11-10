# ADR-0007: Passkeys inside the iPhone app, and continuing after a reinstall

- **Status:** Accepted
- **Date:** 2026-11-10
- **Extends:** ADR-0006
- **Author:** owner session (claude)

## Context

Under ADR-0006 the iPhone holds a device token in the Keychain, and passkeys only exist on the web.
A person who signed up from the iPhone and never opened the web has no passkey. If they delete the
app, the UserDefaults that said "linked to this server" go away, the first launch drops the old
link, and nothing lets them back into their account: their data is safe on the server but out of
reach. Even with a passkey, getting back in meant going to a computer for a one-time code.

## Options

1. **Keep the link in the Keychain and offer to continue.** iOS keeps Keychain items when an app
   is deleted. Storing the server next to the token lets a reinstall on the same iPhone ask the
   server who the token belongs to and offer "Continue as Ana". No code, no passkey. It does not
   help on a new iPhone, and the behavior depends on iOS keeping Keychain items.
2. **Passkeys in the app** (AuthenticationServices). The app asks iOS for a passkey of the server's
   domain and trades the assertion for a device token. Works on a new iPhone (passkeys travel with
   iCloud Keychain). iOS only allows it for domains listed in the app's Associated Domains
   entitlement, confirmed by the domain's `/.well-known/apple-app-site-association`, so it is tied
   to whoever signs the build.
3. **Recovery codes or email.** A printed code is easy to lose; email adds a provider and personal
   data to every account. Neither is needed if 1 and 2 exist.

## Decision

Options 1 and 2, plus a warning while an account has no passkey.

- The Keychain stores the server URL next to the device token (`harina.server`). A fresh install
  checks `GET /api/me` with them and offers to continue; the one-time reset of ADR-0006 only runs
  when UserDefaults still holds an old link.
- `GET /api/me` (session or device) returns `{ id, name, hasPasskey }`.
- `POST /api/auth/register/{options,verify}` also accept a device token, so the app adds a passkey
  to its own account.
- `POST /api/auth/device/login/{options,verify}` work like the web login, but return a new device
  token instead of a cookie. They are anonymous and, like the iPhone sign-up, need no Origin header.
  The assertion is still checked against the server's origin and rpID: a native passkey is bound
  to `https://<rpID>`, which is the origin of a server served at its domain root.
- `/.well-known/apple-app-site-association` lists `HARINA_APPLE_APP_IDS` (comma separated
  `TEAMID.bundle.id`) under `webcredentials`, and returns 404 when it is empty.
- The app shows passkey actions only for the host in `HARINA_PASSKEY_DOMAIN` (Info.plist), which
  the signer sets together with the entitlement. Every other server keeps linking with a code.
- While `hasPasskey` is false, Settings warns that only this iPhone can open the account and
  offers to create a passkey in the app (or on the web, where the app cannot).

## Consequences

- No new data and no new provider. The core stays provider neutral: the entitlement, the app id and
  the domain live in each deployment's build and server settings, never in the open repo.
- The device login endpoints are as exposed as the web login: one challenge per attempt, five
  minute expiry, single use, and the same phishing protection from the rpID and origin checks.
- Each device login creates a device; old ones stay listed and can be revoked from the web.
- If a future iOS deletes Keychain items with the app, option 1 stops working and the passkey
  remains the way back in.
