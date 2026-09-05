// swift-tools-version: 5.9

import PackageDescription

// Used only in the temporary XCFramework staging package. The distribution
// script embeds the privacy manifest directly in each framework slice.
let package = Package(
    name: "TelemetryKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TelemetryKit", type: .dynamic, targets: ["TelemetryKit"])],
    targets: [.target(name: "TelemetryKit", exclude: ["Resources"])],
    swiftLanguageVersions: [.v5]
)
