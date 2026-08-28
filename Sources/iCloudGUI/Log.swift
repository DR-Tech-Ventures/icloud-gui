import AppKit
import OSLog

/// Breadcrumbs in the macOS unified log. Read them back with:
///
///     log show --predicate 'subsystem == "com.drtechventures.icloudgui"' --last 1h
///
/// Deliberately not a file the app writes: the unified log is already on every Mac,
/// already rotates, already timestamps, and survives the process being killed -- which
/// is exactly the case a log written by the app itself would miss. `RunLog` stays as it
/// is, because a backup tool's download failures belong beside the backup, not in a
/// system log the user will never think to look at.
///
/// Nothing here leaves the machine. os_log redacts interpolated strings as `<private>`
/// unless marked `.public`, so paths and album names stay out of it by default.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.drtechventures.icloudgui"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let library = Logger(subsystem: subsystem, category: "library")

    /// Records that this process started, and that it stopped on purpose.
    ///
    /// The second half is the point. An app that exits cleanly logs "terminating"; one
    /// that is killed -- by a rebuild deleting its bundle, by the system, by pkill --
    /// logs nothing at all. The absence of that line is the diagnosis.
    static func armLifecycle() {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        app.notice("launched \(version, privacy: .public) (\(build, privacy: .public)) pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public)")

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            app.notice("terminating normally")
        }
    }
}
