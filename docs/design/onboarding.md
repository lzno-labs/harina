# Design: iPhone-first onboarding, QR linking, first-week card and editable categories

- **Issue:** owner request in the founding session (2026-11-04)
- **Status:** Approved by the owner (iPhone first, QR linking, first-week card, editable categories)
- **Author:** founding agent (claude)
- **Touches:** data (category fields), security (deep link with a link code)

## Goal

A new person sees their first Apple Pay payment recorded on its own in about two minutes, without reading documentation, and starts with categories that fit them.

- **iPhone onboarding**, shown once: welcome, main currency, categories, Apple Pay capture, Face ID, and where to keep the data. Value first, permissions last, everything optional can be skipped.
- **Where to keep the data** (2026-11-10, owner request): the last step asks to choose between «Solo en este iPhone» and «Con un servidor» (the build's default server, for example harina.lzno.app, or the person's own), each with its pros and cons. On iPhones without Apple Intelligence, the hosted category model is listed as a server advantage. Choosing the server shows the QR steps and the manual code; choosing local finishes. Either can be changed later in Settings.
- **Categories:** start from suggestions (the 7 PRD defaults on, more suggestions off). The person can turn them on and off, rename them, pick an emoji and a color, add their own and delete any, during onboarding and later (iPhone settings and web settings).
- **QR linking:** the web shows a QR; the iPhone camera opens harina and links after one confirmation tap. Manual entry stays as a fallback.
- **First payment moment:** when the first payment arrives from the automation, harina celebrates it and asks for its category.
- **First-week card** on the iPhone summary with the PRD's first-week checks: first iPhone payment, Apple Watch payment (the person confirms, harina cannot tell the device), a payment without signal that reached the server.
- **Web:** an empty dashboard shows a three-step start list instead of blank cards.

Out of scope: accounts for several people, invitations, onboarding analytics sent anywhere.

## Relevant ADRs

- ADR-0002 (sync): categories gain two optional synced fields. Suggested categories use deterministic ids (`default-<key>`), the same on every device and on the server, so an iPhone that starts offline and a server that seeded the defaults converge by id with last-writer-wins instead of duplicating. Turning a suggestion off is a tombstone.
- ADR-0003 (authentication): QR linking reuses the one-time link code (10 minutes, single use, five wrong tries void it). Only the transport changes.

## Approach

### Data

- Migration `0002_category_look.sql`: `ALTER TABLE categories ADD COLUMN icon TEXT` and `ADD COLUMN color TEXT`. Validation: `icon` up to 16 characters (one emoji, possibly with modifiers), `color` `#rrggbb`. Both optional; when empty, the look comes from the category key (suggestions) or a hash of the id (custom).
- Suggestion catalog, same keys on web and iPhone: food, groceries, transport, home, health, entertainment, other (on by default, seeded by the server as before), plus coffee, utilities, subscriptions, clothing, pets, education, travel, gifts, personal care, kids, sports and salary (off). Names come from the locale files.
- iPhone: `CategoryItem` gains `icon` and `color` (optional, so SwiftData migrates lightly). The onboarding creates the chosen suggestions locally with `default-<key>` ids, and tombstones the defaults the person turned off.
- Export already includes every category column.

### QR link

- Web, Settings: "Vincular iPhone" creates the link code and shows a QR of `harina://link?server=<origin>&code=<code>`, plus the code in text. The QR is drawn as SVG nodes from a vendored, pinned, MIT licensed encoder (`qrcode-generator`), no network calls.
- iPhone: registers the `harina` URL scheme. On `harina://link`, it shows a sheet: "Vincular este iPhone con **harina.lzno.app**", the code, and Vincular / Cancelar. It never links without that tap, only accepts `https` servers (or `localhost` for development), and asks before replacing an existing link.

### iPhone onboarding

`AppSettings.onboarded` (false on first launch) shows `OnboardingView` instead of the tabs:

1. Welcome (what harina does, no bank, no AI).
2. Main currency (CRC or USD), used when a payment does not say it.
3. Categories: grid of suggestions with on/off toggles; tap to edit name, emoji and color; "Agregar categoría".
4. Apple Pay capture: illustrated steps, "Abrir Atajos", then "Esperando tu primer pago". "Lo haré después" continues.
5. Face ID: "Proteger con Face ID" (evaluates once to confirm) or skip. The app lock now defaults to off until chosen.
6. Backup and web (optional): scan the QR from the web with the camera, or enter the code by hand, or "Más tarde".

### First payment and first week

- After onboarding, the first `apple_pay` movement shows a celebration sheet with the amount, merchant and one-tap categories.
- First-week card (14 days from onboarding, dismissible): iPhone payment (any `apple_pay` movement), Apple Watch payment (Sí / No buttons; "No" shows what to check), offline payment (the capture intent records the id of a payment that could not sync right away; the item is done when that movement is no longer dirty).

## Alternatives considered

- Universal links instead of a URL scheme: safer against other apps claiming the scheme, but tied to one domain through Associated Domains, which breaks self-hosting. The confirmation sheet covers the risk.
- Scanning the QR inside the app: needs camera permission and code; the system camera already opens URL schemes.
- Categories with kinds (expense or income): not needed for v1; salary is just a category.

## Risks and safeguards

- **Data:** two new optional columns, synced and exported. No new personal data.
- **Security:** a crafted `harina://link` could point to an attacker's server. Safeguards: confirmation sheet that names the host, https only, explicit replace prompt; nothing syncs before the tap. Link codes keep their limits.
- **Money and AI:** none.

## Testing and rollout

- Server tests: icon and color validation, migration 0002, suggested ids converge without duplicates.
- Web: screenshots of the start list, the category editor and the QR; the QR decodes to the deep link.
- iPhone (owner, on device): fresh install shows onboarding; categories chosen there reach the web after linking; scanning the QR links after the confirmation; first Apple Pay payment shows the celebration; first-week items tick.
- Rollback: onboarding is skipped by setting `onboarded`; the migration only adds nullable columns.
