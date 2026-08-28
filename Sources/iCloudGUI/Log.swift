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

    /// Times a block and records how long it took.
    ///
    /// Left in rather than removed after the tuning it was written for: what is slow
    /// here depends entirely on the library it is pointed at -- 77 albums and 35,000
    /// assets on the machine this was measured on, and someone else's will differ. A
    /// bug report can answer "which part is slow" without a special build.
    @discardableResult
    static func measure<T>(_ label: StaticString, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try work()
        // Both components: `attoseconds` is only the fractional part, so using it alone
        // silently reports anything over a second as its remainder -- a 1.2s call looks
        // like 200ms, which is exactly the wrong direction to be wrong in.
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        library.notice("\(label, privacy: .public) took \(ms, format: .fixed(precision: 0), privacy: .public)ms")
        return result
    }

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

        // Time to a window on screen, which is the number a person actually feels. The
        // per-stage timings above say where it went; this says whether it matters.
        let start = ContinuousClock.now
        Task { @MainActor in
            while NSApp?.windows.first(where: { $0.isVisible }) == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let elapsed = (ContinuousClock.now - start).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            app.notice("window on screen after \(ms, format: .fixed(precision: 0), privacy: .public)ms")
        }
    }
}
