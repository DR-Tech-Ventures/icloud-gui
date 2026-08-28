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
        if CommandLine.arguments.contains("--tags") { Probe.tags() }
        if CommandLine.arguments.contains("--updates") { Updates.probe() }
        Log.armLifecycle()
        Shot.arm()
    }

    var body: some Scene {
        WindowGroup("iCloud GUI") {
            ContentView()
        }
        // Comfortably above ContentView's 1180pt minimum, which is itself set by what
        // the toolbar needs: narrower than that and SwiftUI folds trailing items into
        // the "»" overflow menu, Download first. This is the size the window opens at
        // the first time; after that macOS restores whatever the user left.
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About iCloud GUI") { About.show() }
                // The one place the app touches the network, and only when clicked --
                // see the note at the top of Updates.swift.
                Button("Check for Updates…") { Updates.check() }
            }
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
