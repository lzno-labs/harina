# Envelopes, reminders, subscription alerts and savings

Status: proposed, 2026-11-10 (owner asked for the four at once). Extends ADR-0002 (sync) and
ADR-0006 (spaces). Scope approved by the owner.

## Goals

1. **Subscription alerts:** the day before a detected fixed charge, the iPhone says
   «Mañana: Netflix, $12». Also when one goes up in price or did not arrive.
2. **Payment reminders:** payments Harina cannot see (credit card, electricity, water, internet,
   paid by SINPE or at the bank): «Pagar tarjeta BAC, el 15 de cada mes», amount optional. «Ya
   pagué» offers to record the expense.
3. **Envelopes:** a monthly limit for one or more categories («Mesada ₡20 000»), showing what is
   left, with alerts at 80 % and 100 %.
4. **Savings pots:** money set aside («Emergencias», «Viaje», goal optional). Deposits are not
   spending; an expense paid from a pot counts as spending and lowers the pot.

## Data (synced like every row: space, client id, last-writer-wins, tombstones)

- `reminders`: name, amount_minor and currency (optional), day_of_month (1 to 31; short months
  use their last day), category_id and account_id (optional, used by «Ya pagué»), paid_month
  (`YYYY-MM` of the last payment), note.
- `budgets` (envelopes): name, amount_minor, currency, category_ids (JSON list, 1 to 20 ids of the
  same space). Monthly; spending of the month in that currency and those categories.
- `pots` (savings): name, currency, goal_minor and goal_date (optional).
- `transactions`: new kinds `saving` (money into a pot) and `withdrawal` (money out of a pot back
  to everyday money), and `pot_id`. An `expense` with `pot_id` is spending paid from the pot.
  Pot balance = savings − withdrawals − expenses paid from it. Month totals keep counting only
  `expense` and `income`, so moving money to savings is never «spending».

Migration 0007 creates the three tables and rebuilds `transactions` to widen the `kind` check
(SQLite cannot alter a check), copying every row.

## Where it shows

- **Summary:** envelopes with a bar and «te quedan»; pots with balance and goal progress;
  «Próximos pagos» (reminders due in the next 7 days, and unpaid ones of the month).
- **iPhone notifications** (local, scheduled after each sync, up to 40 at a time, at 9:00 by
  default, configurable): fixed charges the day before; reminders the day before and on the day;
  envelope at 80 % and 100 % when a payment is saved; the Apple Pay notification adds «Te quedan
  ₡4 500 en Mesada» when the payment's category has an envelope.
- **Web:** the same cards and management pages; no push notifications on the web.
- **Settings** (both): «Sobres», «Ahorros», «Recordatorios» rows under «Tu dinero»; notification
  time and toggles under Apple Pay / notifications.

## Not in scope

Rolling over what is left of an envelope, weekly or yearly envelopes, reminders that repeat other
than monthly, interest, and linking a pot to a real bank account balance.

## Privacy and cost

All local or on the person's own server; nothing new leaves the phone; no provider, no cost.
