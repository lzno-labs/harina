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

1. Open harina and allow Face ID.
2. On the web, Settings, "Generar código de vinculación". In the app, Settings, "Vincular con el servidor": type the server address and the code. (Optional: the app works without a server.)
3. In the app, Settings, "Cómo anotar los pagos solos", and follow the six steps to create the Shortcuts "Transaction" automation.
4. Pay with Apple Pay. The payment appears in "Por revisar" as an uncategorized expense.
