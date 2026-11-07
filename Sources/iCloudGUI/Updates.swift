import AppKit
import Foundation

/// "Check for Updates…", and nothing else.
///
/// This is the only code in the app that opens a network connection, and it runs solely
/// when someone picks the menu item. That is deliberate: the app's whole claim is that
/// it reads your library through macOS and sends nothing anywhere, and a background
/// updater quietly telling a server "this Mac is running iCloud GUI" every few hours
/// would make that claim false. A menu item the user chooses to click does not.
///
/// It also does not install anything. Replacing a running app bundle changes the code
/// signature macOS has tied the Photos grant to, and getting that wrong means the user
/// silently loses access to their own library -- for a tool that is only run occasionally,
/// opening the release page is the better trade.
enum Updates {
    /// Reads the release feed of whatever repository About points at, so the two cannot
    /// drift apart.
    private static var latestReleaseAPI: URL? {
        guard let path = URL(string: About.repository)?.path else { return nil }
        return URL(string: "https://api.github.com/repos\(path)/releases/latest")
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Strips the `v` that release tags carry and release names do not.
    static func normalise(_ tag: String) -> String {
        var version = tag.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return version
    }

    /// `.numeric` compares runs of digits as numbers, so 1.10 sorts above 1.9 -- which a
    /// plain string comparison gets backwards, and which is exactly the comparison that
    /// starts mattering on the tenth release rather than the first.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        normalise(candidate).compare(normalise(current), options: .numeric) == .orderedDescending
    }

    /// The release page to open, or nil if the response named somewhere else.
    ///
    /// `html_url` is a string out of a JSON body that ends up at
    /// `NSWorkspace.shared.open`, which hands whatever it is given to LaunchServices --
    /// `file:///` and registered app schemes included. Nothing but GitHub should get to
    /// choose what this app launches, so the scheme and host are checked rather than
    /// assumed. It takes breaking TLS to put a hostile value here, which is precisely
    /// why the check is a guard and not a dialog: there is no legitimate case where
    /// GitHub's own API answers with a non-GitHub URL, so the honest move is to refuse.
    static func releasePage(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }
        return url
    }

    // MARK: - The menu item

    @MainActor
    static func check() {
        Task {
            do {
                let (tag, page) = try await fetchLatest()
                present(latest: tag, page: page)
            } catch {
                present(failure: error)
            }
        }
    }

    /// `--updates`, alongside the other probe flags. The alert path needs a click and a
    /// running app; this exercises the half that can actually break on its own -- the
    /// request, GitHub's response shape, and the comparison.
    static func probe() -> Never {
        Task {
            let report: String
            do {
                let (tag, page) = try await fetchLatest()
                report = """
                    current: \(currentVersion)
                    latest:  \(tag) -> \(normalise(tag))
                    newer:   \(isNewer(tag, than: currentVersion))
                    page:    \(page)
                    """
            } catch {
                report = "failed: \(error.localizedDescription)"
            }
            print(report)
            exit(0)
        }
        // Parks the main thread so the task above can finish; it is what exits. Reached
        // only via --updates, before any UI exists, so there is nothing else to service.
        RunLoop.main.run()
        fatalError("unreachable: RunLoop.main.run() does not return")
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    static func fetchLatest() async throws -> (tag: String, page: URL) {
        guard let api = latestReleaseAPI else { throw Failure.noReleases }
        var request = URLRequest(url: api, timeoutInterval: 15)
        // GitHub rejects API requests with no User-Agent outright.
        request.setValue("iCloud-GUI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 is the ordinary answer for a repository that has not published a release
        // yet, not a broken connection, so it gets its own message.
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw Failure.noReleases
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.server((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let page = releasePage(release.html_url) else { throw Failure.untrustedPage }
        return (release.tag_name, page)
    }

    enum Failure: LocalizedError {
        case noReleases
        case server(Int)
        case untrustedPage

        var errorDescription: String? {
            switch self {
            case .noReleases: return "No published releases were found."
            case .server(let code): return "GitHub replied with HTTP \(code)."
            // Its own case rather than folding into noReleases: "no releases found" for
            // a reply that did not come from GitHub sends anyone debugging it to the
            // wrong place entirely.
            case .untrustedPage:
                return "The reply did not come from GitHub and was ignored."
            }
        }
    }

    // MARK: - Alerts

    @MainActor
    private static func present(latest tag: String, page: URL) {
        let alert = NSAlert()
        if isNewer(tag, than: currentVersion) {
            alert.messageText = "Version \(normalise(tag)) is available"
            alert.informativeText = """
                You are running \(currentVersion).

                Releases are published on GitHub as a signed, notarised disk image. \
                Open it and drag iCloud GUI onto the Applications shortcut, replacing \
                the copy you have.
                """
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            show(alert) { if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(page) } }
        } else {
            alert.messageText = "iCloud GUI is up to date"
            alert.informativeText = "You are running \(currentVersion), the latest release."
            alert.addButton(withTitle: "OK")
            show(alert) { _ in }
        }
    }

    @MainActor
    private static func present(failure: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not check for updates"
        alert.informativeText = """
            \(failure.localizedDescription)

            You can check by hand at \(About.repository)/releases.
            """
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Cancel")
        show(alert) {
            guard $0 == .alertFirstButtonReturn,
                  let url = URL(string: About.repository + "/releases") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private static func show(_ alert: NSAlert, then handle: (NSApplication.ModalResponse) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        handle(alert.runModal())
    }
}
