# Hosted decision model for iPhones without Apple Intelligence

Status: proposed, 2026-11-10. Architecture: ADR-0005. Extends `apple-intelligence.md`.

## Goal

On iPhones without Apple Intelligence, categorize Apple Pay and Siri payments whose merchant the
person's history does not cover, using a hosted decision model, only with the person's explicit
consent. Success: in the first week on the owner's iPhone 14 Pro, most new merchants are
categorized without asking, and few are corrected (Settings, «En uso real»).

## Flow

1. The phone decides with the history (unchanged). If it is sure, done.
2. Else, if the device has Apple Intelligence and it is on, it asks it (unchanged).
3. Else, if the phone is linked, the server offers the decider and the person turned it on, the
   phone calls `POST /api/categorize` with `{ merchant, amount_minor, currency }` (device token,
   5 second timeout). Offline or any error: the notification asks, as today.
4. The server builds one Clef `choice` question:
   - `criteria`: the person's active expense categories, `id` to name (2 to 255).
   - `state`: the merchant, the amount, and up to 40 recent «merchant: category» pairs the person
     chose (no notes, cards, dates or other fields).
   It returns `{ category_id, confidence }`.
5. The phone acts when `confidence` reaches the person's threshold (default 0.5, from 30 % to 95 % in
   Settings, «Categoría automática»; per iPhone) and assigns, marked ✨, `category_auto = 1`; otherwise it
   puts that category first in the notification and in «Por revisar» (kept on the phone only, never
   synced). The first threshold, 0.9, never acted: on 2026-11-11 Clef-flash gave 0.73 to 0.88 to
   clear merchants (a gas station, Netflix, Uber, McDonalds), 0.33 to 0.56 to correct but less
   obvious ones, and 0.04 to one it could not place. The owner chose 0.5 as the default, reviewed with
   the corrections recorded as `category_auto = 2`.

## Consent and disclosure (AGENTS.md §8)

- Off by default. Turning it on shows what is sent (merchant, amount, recent merchant to category
  pairs), to whom (Cloudflare Workers AI, zero data retention), that it is AI, and that it can be
  turned off any time. The server stores the consent date and refuses calls without it.
- Shown only on devices without Apple Intelligence (others do it on the phone for free).
- The PRD changes accordingly (owner approval).

## Cost and cap (AGENTS.md §5)

- About 500 input tokens per call; 300 payments a month cost about 0.006 USD. Inside the Workers AI
  free daily allowance in practice.
- `ai_usage(month, calls, input_tokens)` in D1; the provider file refuses calls once the month
  reaches the cap (`HARINA_AI_CAP_USD`, default 1 USD, inside the 15 USD AI cap). Before enabling,
  Operaciones runs `lzno.py permitir ia 1`.

## Pro

It is a feature of the hosted version (it costs per use and depends on the deployment). There is
nothing to charge yet, so every account on harina.lzno.app that consents can use it, under the
cap. When Lzno charges for harina, this is a pro feature.

## Security

- Merchant names are the person's data, sent as `state`, never as `instructions`; Clef only scores
  the given options, so a crafted name can at worst pick a wrong category, which the person sees.
- Same auth as sync (device token). Rate limit: 60 calls an hour per device.

## Not in scope

The web, retraining or fine-tuning, and sending anything beyond the fields above.
