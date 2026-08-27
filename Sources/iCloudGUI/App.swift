import SwiftUI

@main
struct iCloudGUIApp: App {
    init() {
        if CommandLine.arguments.contains("--self-check") { SelfCheck.run() }
        if CommandLine.arguments.contains("--probe") { Probe.run() }
        if CommandLine.arguments.contains("--status") { Probe.status() }
        if CommandLine.arguments.contains("--albums") { Probe.albums() }
        if CommandLine.arguments.contains("--hidden") { Probe.hidden() }
        if CommandLine.arguments.contains("--extras") { Probe.extras() }
        if CommandLine.arguments.contains("--size") { Probe.size() }
        Shot.arm()
    }

    var body: some Scene {
        WindowGroup("iCloud GUI") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Replaces the default Help item so the guide is where people look for it.
            CommandGroup(replacing: .help) {
                Button("iCloud GUI Guide") {
                    NotificationCenter.default.post(name: .showGuide, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
