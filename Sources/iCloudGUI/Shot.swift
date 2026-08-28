import AppKit
import Foundation

/// Debug: render our own window to a PNG. Needs no Screen Recording permission,
/// because an app may always draw its own views.
/// Usage:  open "build/iCloud GUI.app" --args --shot 960x640
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            if args.contains("--about") { About.show() }
            guard let main = NSApp.windows.first(where: { $0.isVisible }) else { exit(3) }
            // A sheet is a child window; the About panel is a separate key window.
            let window = main.attachedSheet
                ?? (args.contains("--about") ? (NSApp.keyWindow ?? main) : main)
            if let size, main.attachedSheet == nil {
                window.setContentSize(size)
                window.displayIfNeeded()
            }
            // Let the resize settle before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                capture(window, to: out)
                exit(0)
            }
        }
    }

    private static func parse(_ s: String) -> NSSize? {
        let parts = s.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return NSSize(width: w, height: h)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
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
