// swift-tools-version:5.9
// SPDX-License-Identifier: MPL-2.0
// Pure logic of the iOS app (Foundation only), so it builds and tests on Linux CI too.
import PackageDescription

let package = Package(
    name: "HarinaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HarinaKit", targets: ["HarinaKit"])],
    targets: [
        .target(name: "HarinaKit"),
        .testTarget(name: "HarinaKitTests", dependencies: ["HarinaKit"]),
    ]
)
