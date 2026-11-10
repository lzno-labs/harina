# ADR-0005: hosted category decider behind a core interface, provider in the deployment

- **Status:** Proposed
- **Date:** 2026-11-10
- **Supersedes:** none (extends ADR-0001 and ADR-0002)
- **Author:** owner session (claude)

## Context

Automatic category runs on the iPhone: the person's history, then Apple Intelligence where the
device has it (`docs/design/apple-intelligence.md`). iPhones without Apple Intelligence (iPhone 14
Pro and older) only learn from history, so they ask a lot in the first weeks. The owner wants the
hosted version to help those devices with a decision model (a "System One" classifier that scores
a fixed set of options instead of generating text). The core must stay provider neutral and
self-hostable (AGENTS.md §1), and data reaching an AI needs explicit consent (§8).

## Options

1. **Core interface plus a provider file in the deployment.** The core defines `src/decider.js`
   (a stub that returns "not available") and an endpoint that uses it. The hosted deployment copies
   its own `src/decider.js` over the core (the same mechanism that already copies `wrangler.toml`),
   implemented with Cloudflare Workers AI `@cf/cloudflare/clef-flash`. Self-hosters can write their
   own (for example the open Clef weights on their machine) or leave the stub.
2. **Call Clef from the core directly:** simplest, but ties the open core to Cloudflare.
3. **A separate pro Worker:** a second deployment, a second auth path and a service-to-service
   secret for one endpoint.
4. **Jev (TypeSafe AI):** comparable, but a new vendor and account (the owner's to create) and
   closed weights.

## Decision

Option 1, with Clef-flash for the hosted version: existing Cloudflare account, open weights
(Apache 2.0) so the choice is reversible, zero data retention, 0.038 USD per million input tokens
and no output charge.

## Consequences

- The core keeps no provider code; `GET /api/decider` tells the app whether the server offers it.
- Every call is counted in D1 and stops at a monthly cap in code (AGENTS.md §5).
- The deploy copy-over now also replaces a source file. A core change to `src/decider.js`'s
  interface must be matched in the deployment in the same release; the smoke test calls
  `/api/decider`.
