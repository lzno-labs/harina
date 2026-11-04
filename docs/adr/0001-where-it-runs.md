# ADR-0001: Hosted server on Cloudflare Workers and D1, iOS app through TestFlight

- **Status:** Accepted
- **Date:** 2026-11-04
- **Supersedes:** none
- **Author:** founding agent (claude)

## Context

harina has two parts: a server with a web app (sync, backup, export, use from any device) and a native iOS app that captures Apple Pay payments offline. The PRD sets the first user (the maintainer), a total budget well under 30 USD per month, Costa Rica first, data export in open formats, and a core that installs on any machine. The organization already has a Cloudflare account with the `lzno.app` zone. The data is personal finances: low volume (tens of rows a day), but it must not be lost.

## Options

### Server

1. **Cloudflare Workers + D1 (SQLite), free plan:** 100k requests per day, 5 GB of D1, static assets free. Cost 0 USD. Existing account and zone, custom domain `harina.lzno.app`, one command rollback. D1 is SQLite, so the schema and queries are the same as the self-hosted build. Lock-in: low; only `src/worker.js` and `src/storage/d1.js` are provider specific.
2. **A small VPS (for example 4 to 6 USD per month) with Node and SQLite:** full control, but a monthly cost, a new account, and OS patching for the operations agent.
3. **Fly.io or Render free tiers:** free tiers keep changing, often sleep, and need a new account. Persistent volumes cost money.
4. **Supabase or Firebase:** free tiers exist, but the data model and auth would depend on the provider, against the core being provider independent.

### iOS distribution

1. **TestFlight internal testing:** included in the Apple Developer Program (99 USD per year, already approved), no App Store review, up to 100 internal testers. Builds expire after 90 days.
2. **App Store:** review, privacy labels and public listing; out of scope for v1 (PRD).
3. **Ad hoc or development builds from Xcode:** no extra cost, but each build expires after 7 days with a free account and needs the Mac connected; not sustainable.

## Decision

Server option 1 and iOS option 1. Workers and D1 cost nothing at this scale, reuse the existing account and zone, and keep the code provider neutral because D1 speaks SQLite. TestFlight is the only way to keep the app on the maintainer's iPhone without weekly reinstalls or App Store review.

## Consequences

- The hosted deployment config (`wrangler.toml` with the D1 database id) lives outside this repository; `wrangler.example.toml` documents it. D1 migrations use the same `migrations/*.sql` files as SQLite.
- Free plan limits (100k requests per day, 10 ms CPU per request) are far above one person's use. Passkey verification is the heaviest request; if it ever hits the CPU limit, the Workers paid plan (5 USD per month) is the fallback and needs an owner decision.
- TestFlight builds expire after 90 days: a new build must ship at least every three months.
- Revisit if D1 or Workers start charging at this volume, or if several people use the hosted version.
- **Self-hosting without Cloudflare:** `npm start` runs the same app on any machine with Node 22.13 or newer, storing data in one SQLite file (`HARINA_DB`). Put it behind any HTTPS reverse proxy (passkeys need HTTPS, except on `localhost`). The iOS app builds with Xcode and links to any harina server.
