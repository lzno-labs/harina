# Contributing to harina

Thanks for helping. Issues and pull requests are welcome in English or Spanish.

## Sign your commits (DCO)

harina uses the [Developer Certificate of Origin](https://developercertificate.org/), not a CLA. Every commit must end with a `Signed-off-by:` line matching the commit author, which certifies you wrote the change or have the right to submit it under the project's licenses:

```sh
git commit -s -m "Fix amount parsing for 1.234,5"
```

CI rejects pull requests with unsigned commits. To fix the last commit: `git commit --amend -s --no-edit`; for several: `git rebase --signoff main`.

## Licenses of what you contribute

- Changes outside `ios/` are licensed under AGPL-3.0-only.
- Changes inside `ios/` are licensed under MPL-2.0 (see `ios/LICENSE`). Keep the `SPDX-License-Identifier: MPL-2.0` header in new Swift files.

## Before opening a pull request

```sh
npm ci && npm run lint && npm test
swift test --package-path ios/HarinaKit
```

- User-facing text never goes in code: add it to `locales/es.json` (web) or `ios/Harina/Resources/es.lproj/Localizable.strings` (iOS), in Spanish first.
- Money is stored as integers in minor units with its currency. Dates and numbers are formatted by region.
- Read the ADRs in `docs/adr/` before changing architecture. A change that contradicts one comes with a new ADR that supersedes it.
- A feature of more than a day, or one that touches personal data, security or money, starts with a short design in `docs/design/`.
- Keep pull requests small and focused, with tests.

Security issues: never in a public issue. See [SECURITY.md](SECURITY.md).
