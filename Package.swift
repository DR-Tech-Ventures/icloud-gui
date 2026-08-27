// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCloudGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iCloudGUI",
            path: "Sources/iCloudGUI",
            // ponytail: Swift 5 language mode. PhotoKit's PHAsset/PHAssetCollection are
            // non-Sendable reference types, so strict concurrency would demand @unchecked
            // Sendable wrappers around every fetch result for no runtime benefit in a
            // single-window app. Ceiling: no compile-time data-race checking. Upgrade path:
            // move to .v6 and wrap PhotoKit access in a dedicated actor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
