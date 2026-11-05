# Design: recurring expenses and automatic categories (decision model)

- **Issue:** owner request, 2026-11-05; PRD change in `lzno-labs/empresa` (harina 1.1)
- **Status:** Approved by the owner in chat; PRD change pending merge
- **Author:** owner session (claude)
- **Touches:** data (one new column), money (projections are estimates), AI (none; a hosted model is a separate decision)

## Goal

With no setup:

1. **Automatic category.** A payment captured by the Shortcuts automation gets its category on its own when harina is confident, marked as automatic and easy to change. When harina is unsure, the payment goes to "Por revisar" with its suggestions ranked by probability.
2. **Recurring expenses ("Fijos").** harina finds charges that repeat (subscriptions, utilities, rent), shows what is coming and when, flags price changes and missed charges, and projects how the month will close.

Out of scope: sending data to any AI or third party, manual "this is recurring" toggles, budgets.

## Relevant ADRs

- ADR-0002 (sync): one new optional synced column on transactions; last-writer-wins unchanged.
- ADR-0001 (where it runs): everything runs on the device or in the browser; no new server work, no provider.

## Approach

### Decision model for categories

We follow the decision-model pattern described by Cloudflare (Clef) and others: a typed question ("which category?"), a closed set of answers, a probability per answer and a calibrated confidence that drives code through bands (act / suggest / ask). Instead of a hosted model, v1.1 uses a small model trained on the person's own labels, on the device, with the same contract, so a hosted model can be added later as an escalation tier without changing the callers.

- **State:** merchant, card, amount, currency.
- **Model:** multinomial naive Bayes, retrained on demand from the person's labels. Features: the whole normalized merchant (`m:`, counted 3 times), each merchant word (`w:`), the card (`c:`), and the currency with a log2 amount bucket (`a:`). Laplace smoothing (alpha 1). Output: probability per category (softmax of log scores).
- **Labels:** categorized expenses whose category was set or corrected by the person. Automatic categories are not used for training, to avoid feedback loops.
- **Confidence:** `(p_max - 1/n) / (1 - 1/n)`, 0 to 1, where `n` is the number of categories with labels.
- **Calibration on the person's history:** replay the labeled expenses in date order; each one is predicted by a model trained only on the earlier ones. The auto threshold is the lowest value in 0.50, 0.55, ... 0.99 where predictions at or above it were right at least 95 times in 100, over at least 20 cases. With less history there is no threshold, so nothing is categorized automatically yet.
- **Bands:** (1) **act**: confidence at or above the threshold and the exact merchant was labeled before; the payment gets the category with `category_auto = 1`. (2) **suggest**: confidence at least 0.4; the top category is highlighted in review. (3) **ask**: otherwise; categories are still ordered by probability.
- **Where it acts:** on the iPhone, in the "Registrar pago en harina" intent (works offline). Can be turned off in settings ("Categorizar sola"). The web uses the same model to rank and highlight suggestions.
- **Learning from corrections:** changing an automatic category sets `category_auto = 2` (corrected). Live precision = automatic kept / (automatic kept + corrected), shown in settings with the calibrated threshold and coverage.

### Recurring expenses

For each group of expenses with the same normalized merchant and currency, sorted by date:

- **Cadence:** median interval in days between charges: weekly (5 to 9), monthly (25 to 35) or yearly (350 to 380). At least 75% of intervals must fall in the window (all of them with two charges). Groups with irregular intervals (rides, supermarket) do not qualify.
- **Amount:** the largest and smallest amounts are within a factor of 1.35 (allows one price change). A change of more than 2% between the last two charges is a **price change**.
- **Next charge:** last date plus the median interval. Status: **soon** (within 7 days), **missed** (past due by more than 5 days for monthly, 2 for weekly, 15 for yearly), **ended** (no charge for 2.5 cadences; not listed), otherwise **scheduled**. Two charges make it **likely**, three or more **sure**.
- **Month projection** (per currency, from day 3 of the current month): spent so far + fixed charges still due this month + average daily variable spending so far times the days left.

Both algorithms live twice, in `public/insights.js` (web, tests in Node) and `HarinaKit/Insights.swift` (iPhone, tests on Linux), and are checked against the same fixtures in `tests/fixtures/insights.json` so they agree.

### Data

- Migration `0003_category_auto.sql`: `ALTER TABLE transactions ADD COLUMN category_auto INTEGER NOT NULL DEFAULT 0` (0 manual, 1 automatic, 2 automatic then corrected). Validated as 0, 1 or 2; exported in JSON and CSV.

## Alternatives considered

- **Hosted decision model (Clef-flash on Workers AI) now:** good for merchants never seen, but it is external AI (PRD and `AGENTS.md` §8), needs consent and a separate pro service, and cannot run offline at capture time. Pending owner decision with real accuracy numbers from this model.
- **Fixed rule "same merchant, same category last time":** simpler, but no probabilities, no calibration and no ranking for review.
- **On-device Core ML text classifier:** iPhone only; the web would need a second model.

## Risks and safeguards

- **Data:** no new personal data; everything is computed locally from the person's own movements.
- **Wrong automatic category:** only above a threshold that was right 95 of 100 times on the person's own history, only for merchants labeled before, always marked and one tap to change; corrections are counted and shown.
- **Money:** projections are estimates and are labeled as such; harina never acts on money.
- **AI:** none.

## Testing and rollout

- Shared fixtures for both implementations: predictions and confidences, calibration threshold, recurring detection (monthly, weekly, yearly, price change, missed, irregular, ended), projection.
- Server tests: `category_auto` validation and sync.
- Manual on the iPhone: categorize the same merchant a few times by hand, then pay there again with Apple Pay; it should arrive categorized with the automatic mark.
- Rollback: turn off "Categorizar sola"; the migration only adds a column with a default.
