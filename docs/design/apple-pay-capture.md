# Design: "Registrar pago en harina" (Apple Pay capture with Shortcuts)

- **Issue:** founding PR (PRD: captura automática de Apple Pay)
- **Status:** Approved for v1 (written before the code, reviewed with it in the founding PR)
- **Author:** founding agent (claude)
- **Touches:** data, money, security

## Goal

Every Apple Pay payment made with the iPhone (and with the Apple Watch, if it triggers the iPhone automation) is saved in harina as an uncategorized expense, even with no signal, with no typing. Out of scope: online or physical card payments (Wallet does not report them to Shortcuts), Apple Watch app, widgets, Siri phrases beyond the default App Shortcut.

## Relevant ADRs

- ADR-0002 (sync): the capture only writes a local row marked dirty; sync is the normal push.
- ADR-0003 (authentication): capturing needs no Face ID; syncing uses the device token from the Keychain, readable after first unlock.

## Approach

1. **Trigger:** the person creates, once, a personal automation in Shortcuts: "Transaction" (iOS 17+), their Wallet cards, "When I tap", "Run immediately". The app's settings show the six steps and open Shortcuts.
2. **Action:** the app ships an App Intent, `RecordPaymentIntent` ("Registrar pago en harina"), with parameters `amount` (text, required), `merchant` (text) and `card` (text). The person maps the automation's "Shortcut Input" fields Amount, Merchant and Card or Pass. Text parameters are used on purpose: Shortcuts passes the amount as localized currency text (for example `₡4 500,00` or `$12.50`), and text never fails to bind.
3. **Run:** `openAppWhenRun = false`. iOS runs the intent in the app's process in the background. `perform()`:
   - parses the amount with `AmountParser` (HarinaKit): the last `,` or `.` followed by one or two digits is the decimal mark; `₡`/`CRC` means CRC, `$`/`US$`/`USD` means USD;
   - finds the account whose card matches the reported card name (normalized), or creates one named after the card;
   - inserts a `Movement` (`source = apple_pay`, `kind = expense`, no category, `dirty = true`) in SwiftData and saves it **before** any network call;
   - tries one sync (20 s timeout). Without signal it fails quietly; the row stays dirty.
4. **Never lose a payment:** if the amount cannot be read, the row is still saved with amount 0, the raw text in `raw_amount` and `needs_review = 1`. If the text had no currency, the default currency (setting, CRC by default) is used and the row is marked for review.
5. **Later sync:** dirty rows are pushed when the app becomes active, when the network comes back while it is open, on the next capture with signal, and from a `BGAppRefreshTask` that iOS runs at its discretion.
6. **Review:** uncategorized expenses and `needs_review` rows appear in "Por revisar". harina suggests the category last used for the same normalized merchant; one tap applies it.

Data model: no new fields beyond the v1 schema (`source`, `card`, `raw_amount`, `needs_review` exist for this). Export includes them.

## Alternatives considered

- `IntentCurrencyAmount` parameter: cleaner type, but whether Shortcuts converts the Transaction amount into it is not documented; text is guaranteed.
- Parsing Wallet notifications or emails: not possible on iOS, and emails would mean reading the inbox.
- Connecting to the bank: excluded by the PRD.

## Risks and safeguards

- **Data:** merchant, amount and card name only, stored on the iPhone (app sandbox, iOS data protection) and on the person's own server. Nothing goes to third parties or AI. Exported in CSV and JSON; deleted with the rest.
- **Security:** any shortcut on the phone can call the intent and add a row (it cannot read data). Accepted: worst case is a wrong row that the person sees and deletes. Inputs are trimmed and length limited; the server validates again.
- **Money:** harina only records. A wrong amount shows up in the summary and is corrected by hand.
- **AI:** none.

## Testing and rollout

- HarinaKit unit tests (Linux CI on every PR): amount formats, currency detection, unreadable amounts, CSV, merge rules.
- Server tests: push and pull of `apple_pay` rows, stale pushes, tombstones.
- Manual, first week (owner, on the iPhone): (1) pay with the iPhone and check the row appears; (2) pay with the Apple Watch and check whether the iPhone automation fires; (3) turn on airplane mode, pay, check the row appears in the app with the pending icon, turn airplane mode off, open harina and check it reaches the web.
- Rollback: delete the automation in Shortcuts; manual entry keeps working.
