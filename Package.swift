// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iCloudGUI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "iCloudGUI",
            path: "Sources/iCloudGUI"
        )
    ]
)
