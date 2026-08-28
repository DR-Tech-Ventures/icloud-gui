import AppKit
import Photos

/// Screenshot mode: real UI, real layout, no real content.
///
/// Documentation screenshots of a photo app are a disclosure risk twice over — the
/// photos themselves, and the sidebar, which lists album names people give to their
/// children, relatives and holidays. This substitutes generic album names and
/// generated tiles so a screenshot shows the interface and nothing about its owner.
enum Demo {
    /// Read straight from the arguments rather than set at launch: it never changes
    /// after the process starts, so as a `let` there is no shared mutable state for
    /// Swift 6 to object to and no window in which it could be read before it is set.
    static let enabled = CommandLine.arguments.contains("--demo")

    private static let albumNames = [
        "Vacation", "Weekend Trip", "Family", "Garden", "Hiking",
        "City Break", "Old Photos", "Projects", "Recipes", "Concerts",
        "Road Trip", "Beach", "Winter", "Studio", "Archive",
    ]
    private static let sharedNames = [
        "Shared Album", "Trip Photos", "Group Album", "Event", "Reunion",
    ]

    /// Stable generic name for a user album, so the sidebar reads the same each run.
    static func albumName(_ original: String, index: Int, shared: Bool) -> String {
        let pool = shared ? sharedNames : albumNames
        return pool[index % pool.count] + (index >= pool.count ? " \(index / pool.count + 1)" : "")
    }

    /// A plausible-looking photo tile derived from the asset id, so the same asset
    /// always yields the same tile and the grid does not shimmer while scrolling.
    static func thumbnail(seed: String, size: CGFloat) -> NSImage {
        var hash = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ Int(byte) }
        let hue = Double(abs(hash) % 360) / 360.0
        let variant = abs(hash / 360) % 3

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let base = NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.82, alpha: 1)
        let dark = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.45, alpha: 1)
        NSGradient(colors: [base, dark])!.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                                               angle: -70)

        // A little structure so the tiles read as imagery rather than swatches.
        NSColor.white.withAlphaComponent(0.22).setFill()
        switch variant {
        case 0:
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: 0, y: size * 0.30))
            hill.curve(to: NSPoint(x: size, y: size * 0.38),
                       controlPoint1: NSPoint(x: size * 0.35, y: size * 0.62),
                       controlPoint2: NSPoint(x: size * 0.62, y: size * 0.10))
            hill.line(to: NSPoint(x: size, y: 0))
            hill.line(to: NSPoint(x: 0, y: 0))
            hill.close()
            hill.fill()
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: size * 0.68, y: size * 0.70,
                                        width: size * 0.14, height: size * 0.14)).fill()
        case 1:
            NSBezierPath(ovalIn: NSRect(x: size * 0.22, y: size * 0.24,
                                        width: size * 0.56, height: size * 0.56)).fill()
        default:
            NSBezierPath(roundedRect: NSRect(x: size * 0.18, y: size * 0.20,
                                             width: size * 0.64, height: size * 0.42),
                         xRadius: size * 0.05, yRadius: size * 0.05).fill()
        }
        image.unlockFocus()
        return image
    }
}
