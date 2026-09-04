// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TelemetryKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "TelemetryKit",
            type: .dynamic,
            targets: ["TelemetryKit"]
        )
    ],
    targets: [
        .target(
            name: "TelemetryKit",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "TelemetryKitTests",
            dependencies: ["TelemetryKit"]
        ),
        .testTarget(
            name: "TelemetryKitIntegrationTests",
            dependencies: ["TelemetryKit"]
        ),
        .testTarget(
            name: "TelemetryKitPerformanceTests",
            dependencies: ["TelemetryKit"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
