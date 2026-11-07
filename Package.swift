// swift-tools-version: 6.4
//
// 6.4 rather than 6.2 for one concrete reason: `.v27` below does not exist before
// PackageDescription 6.4 ("'v27' was introduced in PackageDescription 6.4"). Spelling
// the platform as `.macOS("27.0")` would build under 6.2, but a string bypasses the
// check that catches a typo at manifest-parse time, and build.sh reads this line with a
// regex to stamp the binary -- both want the enum.
import PackageDescription

let package = Package(
    name: "iCloudGUI",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(
            name: "iCloudGUI",
            path: "Sources/iCloudGUI"
        )
    ]
)
