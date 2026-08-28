import AppKit
import Foundation
import ScreenCaptureKit

/// Debug: capture our own window to a PNG.
///
/// Needs the Screen Recording permission, granted once to whoever regenerates the
/// documentation screenshots. Without it the capture falls back to rendering the layer
/// tree, which cannot see Liquid Glass surfaces -- the sidebar and toolbar come out
/// blank -- and says so on stderr rather than quietly writing a broken image.
///
/// Usage:  open "build/iCloud GUI.app" --args --shot 1280x840
extension Notification.Name {
    static let selectAlbumForShot = Notification.Name("com.local.icloudgui.selectAlbumForShot")
    static let setGroupingForShot = Notification.Name("com.local.icloudgui.setGroupingForShot")
}

enum Shot {
    static func arm() {
        let args = CommandLine.arguments

        // --album / --group are useful on their own, not only when capturing, so they
        // are handled before the --shot guard.

        let wanted: String? = args.firstIndex(of: "--album").flatMap {
            $0 + 1 < args.count ? args[$0 + 1] : nil
        }
        let grouping: String? = args.firstIndex(of: "--group").flatMap {
            $0 + 1 < args.count ? args[$0 + 1] : nil
        }
        if wanted != nil || grouping != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if let wanted {
                    NotificationCenter.default.post(name: .selectAlbumForShot, object: wanted)
                }
                if let grouping {
                    NotificationCenter.default.post(name: .setGroupingForShot, object: grouping)
                }
            }
        }

        guard let i = args.firstIndex(of: "--shot") else { return }
        let size = i + 1 < args.count ? parse(args[i + 1]) : nil
        let out = URL(fileURLWithPath: "/tmp/icg-shot.png")

        Task { @MainActor in
            // Wait for the window rather than sleeping a fixed nine seconds and hoping.
            // The old fixed delay silently produced exit(3) -- "no visible window" --
            // whenever launch got slower than the guess, which is a miserable thing to
            // debug from a missing file.
            guard let main = await firstVisibleWindow(within: .seconds(40)) else {
                FileHandle.standardError.write(
                    "no visible window appeared within 40s\n".data(using: .utf8)!)
                exit(3)
            }
            if args.contains("--about") { About.show() }
            // A sheet is a child window; the About panel is a separate key window.
            let window = main.attachedSheet
                ?? (args.contains("--about") ? (NSApp.keyWindow ?? main) : main)
            if let size, main.attachedSheet == nil {
                window.setContentSize(size)
                window.displayIfNeeded()
            }
            // Let the resize, the album selection and the first thumbnails settle.
            try? await Task.sleep(for: .seconds(4))
            // A window capture records the window as it is drawn, so an app that lost
            // focus to the launching terminal is captured with dimmed chrome. Done here
            // rather than earlier, because the terminal takes focus back in the meantime.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            await capture(window, to: out)
            exit(0)
        }
    }

    /// Polls for the first visible window. SwiftUI creates the scene on its own
    /// schedule, and how long that takes depends on the machine, the library size and
    /// how warm the caches are -- none of which a fixed sleep can know.
    @MainActor
    private static func firstVisibleWindow(within timeout: Duration) async -> NSWindow? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = NSApp.windows.first(where: { $0.isVisible }) { return window }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private static func parse(_ s: String) -> NSSize? {
        let parts = s.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return NSSize(width: w, height: h)
    }

    @MainActor
    private static func capture(_ window: NSWindow, to url: URL) async {
        if let data = await windowCapture(window) {
            try? data.write(to: url)
            FileHandle.standardError.write("shot via window capture\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardError.write("""
            shot via layer render -- ScreenCaptureKit returned nothing.
            Liquid Glass surfaces will be blank in this image. Grant Screen Recording to
            the app in System Settings > Privacy & Security, then run --shot again.

            """.data(using: .utf8)!)
        layerCapture(window, to: url)
    }

    /// Preferred path. Liquid Glass surfaces -- the sidebar, toolbar and every control
    /// bezel -- are drawn by backdrop layers that sit outside the view's own layer tree,
    /// so the layer render below captures them as blank white. Only a compositor-level
    /// capture sees what is actually on screen.
    ///
    /// This used CGWindowListCreateImage until the deployment target moved to macOS 26,
    /// where that call is not merely deprecated but unavailable. ScreenCaptureKit is the
    /// replacement, and unlike the old call it needs the Screen Recording grant even for
    /// the app's own window. That cost lands only on whoever regenerates the
    /// documentation screenshots, never on someone using the app: nothing here runs
    /// without --shot.
    @MainActor
    private static func windowCapture(_ window: NSWindow) async -> Data? {
        let id = CGWindowID(window.windowNumber)
        guard id != 0 else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == id }) else {
                return nil
            }
            let config = SCStreamConfiguration()
            // Capture at backing scale, so the result matches what a Retina screenshot
            // would give rather than a soft point-sized one.
            let scale = window.backingScaleFactor
            config.width = Int(target.frame.width * scale)
            config.height = Int(target.frame.height * scale)
            config.showsCursor = false
            // Transparent behind the window, so the rounded corners and the shadow do
            // not come out sitting on whatever happened to be on the desktop.
            config.backgroundColor = .clear
            config.ignoreShadowsSingleWindow = false

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            guard image.width > 1, image.height > 1 else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } catch {
            FileHandle.standardError.write(
                "ScreenCaptureKit: \(error.localizedDescription)\n".data(using: .utf8)!)
            return nil
        }
    }

    @MainActor
    private static func layerCapture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { exit(4) }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(5) }

        // Render the layer tree rather than cacheDisplay: the latter skips AppKit
        // control titles, so every button comes out blank.
        if let layer = view.layer {
            NSGraphicsContext.saveGraphicsState()
            if let gctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = gctx
                gctx.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                gctx.cgContext.fill(bounds)
                // Core Animation's origin is top-left, AppKit's is bottom-left, so the
                // layer tree renders upside down without this flip.
                gctx.cgContext.translateBy(x: 0, y: bounds.height)
                gctx.cgContext.scaleBy(x: 1, y: -1)
                layer.render(in: gctx.cgContext)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(6) }
        try? data.write(to: url)
        FileHandle.standardError.write("shot \(Int(bounds.width))x\(Int(bounds.height))\n".data(using: .utf8)!)
    }
}
