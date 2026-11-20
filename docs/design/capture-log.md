# Design: capture history on the iPhone

- **Issue:** owner report, 2026-11-20: two payments in Wallet never reached Harina, with no way
  to tell why.
- **Status:** approved scope (owner asked to find out what is happening)
- **Author:** owner session (claude)

## Problem

A Shortcuts «Transaction» automation runs «Registrar pago en Harina» after an Apple Pay payment
(docs/design/apple-pay-capture.md). When a payment is missing, nobody can tell whether iOS never
ran the action or the action failed:

- The trigger fires only when the iPhone or Apple Watch taps a terminal. Some banks show every card
  charge in Wallet (online, in-app, physical card), and none of those start the automation.
- The trigger waits for the bank's notice to Wallet. When that notice is late, the automation times
  out and fails silently (Apple Developer Forums 765516, 773745).
- iOS can ask «Permitir una vez / Permitir siempre» before running an imported shortcut, and the
  answer does not always persist (forum 850369). An unanswered prompt means no run.
- The action itself can fail (store error) or be stopped by iOS before it saves.

## Decision

Each run of the action is recorded on the iPhone:

- **Start:** written before anything else, with what Wallet sent: merchant, amount text and card.
- **Saved:** the movement id, whether it waits in «Por revisar», and who set the category.
- **Done**, or the error if it failed.

A run still at «start» after two minutes was stopped by iOS. The movement's own state tells whether
it reached the server.

Settings, «Pagos con Apple Pay», «Historial de capturas» shows the runs, a 30-day summary and the
usual reasons a payment never shows up. A payment in Wallet but not in this list means iOS never
started the action. A plain-text copy can be shared for support.

## Privacy

The history stays in this iPhone's settings: at most 300 runs, never synced, never sent. It holds
the same fields as the movements already on the phone, so the privacy notice does not change. The
person can delete it, and only sharing it on purpose sends it anywhere.

## Alternatives

- **Usage analytics sent to the server or a third party:** this needs a change to the privacy
  notice and consent, and moves data off the phone. It could not see runs that iOS never started
  either.
- **Reading Wallet transactions (FinanceKit):** only Apple's own cards in a few countries, behind an
  entitlement. It does not cover Costa Rican banks.
