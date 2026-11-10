# Automatic category: Apple Intelligence for what the history does not cover

Status: accepted, 2026-11-10. Extends `fijos-y-categoria-automatica.md`.

## Problem

The local decision model (naive Bayes over the person's own history) only acts on merchants the
person already categorized. In the first weeks, and for every new merchant, it asks. That is the
cold start: correct, but slow to become useful.

## Decision

Two steps, the second only when the first is not sure. Nothing leaves the phone.

1. **The person's history** (unchanged). It acts when calibration says it is right at least 95
   times in 100. A merchant the person categorized is decided by their history.
2. **Apple Intelligence on the iPhone** (Foundation Models framework, iOS 26+, devices with Apple
   Intelligence). Guided generation (`@Generable`) returns the name of one of the person's
   categories, or "ninguna", plus `sure`. The prompt holds the category names, up to 40 recent
   merchant to category examples from the person's history, and the new payment's merchant and
   amount. Sure: acts. Not sure: becomes the first suggestion in the notification. No match, an
   error or more than 8 seconds: the payment is saved the usual way and the notification asks.

Same rules for Apple Pay captures (`RecordPaymentIntent`) and Siri entries (`AddMovementIntent`).
The review screen ranks with step 1 only (no model call while scrolling).

## Privacy and AI disclosure

- Step 2 runs on the device. No server, no account, no cost. `AGENTS.md` §8 asks to say when
  something uses AI: settings show a toggle «Usar Apple Intelligence», on by default, with the
  explanation that it runs on the iPhone and nothing leaves it. Devices without Apple Intelligence
  see why it is not used.
- Merchant names are the person's data and go into the prompt. Output is constrained to the
  category list, so a crafted merchant name can at worst pick a wrong category, which the person
  sees (✨) and can change.

## Not done (and why)

- **A curated list of well-known merchants**: rejected by the owner. A large deterministic list
  is costly to maintain and is not how harina should learn.
- **Private Cloud Compute** (iOS 27): it also needs a device with Apple Intelligence, so it does
  not help devices without it; it needs an entitlement Apple grants on request, and data would
  leave the phone, which needs explicit consent and a PRD change. Revisit if on-device answers are poor.
- **Wallet's merchant category**: the Transaction trigger can filter by category, but the
  shortcut input only exposes amount, merchant, card and name.
- **Hosted model** (Cloudflare Workers AI): not needed; zero cost and no data leaving the phone.

Devices without Apple Intelligence keep today's behavior: they learn from the person's history.

## Data format

No change. AI assignments are `category_auto = 1` like the local model, so training keeps ignoring
them, a correction becomes `2`, and live stats count them together.

## How we will know it works

First week on two phones (one with, one without Apple Intelligence): share of Apple Pay payments
categorized without asking, and how many were corrected (Settings, «En uso real»).
