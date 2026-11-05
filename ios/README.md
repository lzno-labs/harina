# harina for iOS

SwiftUI app for iOS 17 or newer, licensed under [MPL-2.0](LICENSE) (the rest of the repository is AGPL-3.0-only).

- `HarinaKit/`: pure logic (amount parsing, payment capture, sync rules, CSV). Foundation only; `swift test` runs on macOS and Linux.
- `Harina/`: the app. SwiftData storage, sync with any harina server, Face ID lock, and the App Intent "Registrar pago en harina" used by the Shortcuts automation. Design: [`docs/design/apple-pay-capture.md`](../docs/design/apple-pay-capture.md).
- Visible text: `Harina/Resources/es.lproj/` (Spanish is the development language).

## Build

```sh
brew install xcodegen
cd ios && xcodegen          # generates Harina.xcodeproj (not committed)
open Harina.xcodeproj
```

To run on your iPhone, create `Config/Signing.xcconfig` (ignored by git) with your Apple team and a bundle id of yours:

```
DEVELOPMENT_TEAM = ABCDE12345
HARINA_BUNDLE_ID = com.yourname.harina
```

## Use

The first launch walks you through it (design: [`docs/design/onboarding.md`](../docs/design/onboarding.md)):

1. Main currency and your categories (suggestions on, more to add; hold one to change its name, emoji or color).
2. The Shortcuts "Transaction" automation, with "Abrir Atajos". harina waits for your first Apple Pay payment and celebrates it.
3. Face ID (optional).
4. Backup and web (optional): on the web, Settings, "Vincular iPhone", scan the QR with the iPhone camera and confirm in harina. You can also type the code.

For the first two weeks the summary shows a "Primera semana" card: an iPhone payment, an Apple Watch payment and a payment without signal.
