# Design: categorize from the notification, and add movements with Siri

- **Issue:** owner request, 2026-11-06; scope approved by the owner (harina 1.3)
- **Status:** Approved by the owner in chat; PRD change pending merge
- **Author:** owner session (claude)
- **Touches:** data (new movements), money (amounts by voice)

## Goal

1. When an Apple Pay payment arrives and the automatic category did not act, a local notification shows the amount and merchant and offers the three most likely categories as buttons. One tap sets the category without opening harina, on the iPhone or on the Apple Watch (notifications mirror there).
2. "Oye Siri, anota un gasto en harina": Siri asks the amount and what it was for, harina saves it on the iPhone (offline too) and confirms. For SINPE Móvil, cash and transfers, which have no automatic signal.

Out of scope: reading bank SMS or email, a watchOS app, editing or deleting by voice.

## Relevant ADRs and designs

- ADR-0002: both paths only create or update local rows marked dirty; sync is unchanged.
- `apple-pay-capture.md`: the capture intent stays the source of Apple Pay rows; the notification is a follow-up.
- `fijos-y-categoria-automatica.md`: the decision model's ranking chooses the three buttons; a category set from the notification counts as the person's label.

## Approach

### Notification after capture

- `RecordPaymentIntent`, after saving: if the model acted, nothing more (the Shortcuts dialog already says "Anotado: ₡4 500 en Súper"). If the amount could not be read, a notification "Revisa este pago" opens the review tab. Otherwise, a notification titled "₡4 500 en Soda Tapia", body "¿En qué categoría va?", with up to three category actions (emoji and name, ranked by the model, then alphabetically) plus "Otra…".
- Actions run in the background (`UNNotificationAction` without `.foreground`): the app delegate finds the movement by id, sets the category as the person's choice, marks it dirty and syncs. "Otra…" and tapping the notification open harina on "Por revisar".
- Notification categories are registered per combination of three category ids (`pick.<a>|<b>|<c>`), keeping the most recent 30, because action titles are fixed per category.
- Permission: asked in the onboarding capture step (before opening Shortcuts) and from Settings, where "Avisarme para categorizar" can be turned off. No notification without permission.

### Siri

- `AddMovementIntent` ("Anotar en harina"), `openAppWhenRun = false`, with parameters: amount (number, Siri asks "¿Cuánto fue?"), concept (text, "¿En qué fue?"), kind (expense or income, default expense), currency (CRC or USD, default from settings) and category (optional, an app entity that Siri matches by name).
- App Shortcuts phrases (Spanish): "Anota un gasto en harina", "Anota un ingreso en harina" (kind in the phrase), "Anotar en harina".
- Saves a `manual` movement on the device first, then tries to sync. Without a category, the decision model categorizes it only in the act band; otherwise it stays in review. Siri replies "Anotado: ₡4 500 en SINPE a Juan (Comida)".

## Alternatives considered

- Dynamic notification content extension with a category grid: richer, but a separate extension target and more code; buttons cover the common case.
- Free-text dictation parsed by harina ("cuatro mil quinientos en la soda"): Siri's parameter prompts already give clean values in Spanish.

## Risks and safeguards

- **Data:** notifications show amount and merchant on the lock screen; they follow the system's preview setting (people can hide previews). Nothing leaves the device.
- **Money:** a misheard amount is visible in Siri's confirmation and in the list, and can be edited; nothing moves money.
- **Security:** notification actions only set a category on an existing movement; Siri only adds movements.

## Testing and rollout

- HarinaKit: unit tests for the action identifiers and the category id combination (pure functions).
- iOS build on the macOS runner (App Shortcuts strings are validated at build time).
- Manual on the iPhone: pay with Apple Pay at a new merchant and categorize from the notification (also from the Apple Watch); say "Oye Siri, anota un gasto en harina" in airplane mode and check it appears, then syncs.
- Rollback: turn off "Avisarme para categorizar"; Siri phrases disappear if the intent is removed.
