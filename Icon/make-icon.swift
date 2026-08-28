// Generates AppIcon.icns. Run: ./Icon/make-icon.sh
//
// Drawn in code rather than committed as an uneditable binary: the design is a few
// lines here, and regenerating after a tweak is one command.
//
// Each size is rendered natively rather than downscaled from one master. Downscaling
// a 1024px render turns the 16px strokes to mush, which matters because 16 and 32px
// are where the icon is actually seen -- Finder list view, the Dock, Spotlight, the
// About panel. Small sizes get a heavier stroke and a slightly larger glyph so they
// survive; that is the same reason Apple ships per-size artwork.
import AppKit

// The symbol's two layers are ordered arrow-then-cloud, so this palette gives a
// white cloud with an amber arrow: the cloud stays instantly readable as iCloud while
// the accent falls on the action, which is what distinguishes this from Apple's own glyph.
let accent = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)
let tileTop = NSColor(srgbRed: 0.26, green: 0.55, blue: 0.99, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.08, green: 0.32, blue: 0.87, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState(); return rep
    }

    let inset = size * 0.09
    let side = size - inset * 2
    let rect = CGRect(x: inset, y: inset, width: side, height: side)
    let body = NSBezierPath(roundedRect: rect, xRadius: side * 0.2237, yRadius: side * 0.2237)

    // Shadow only where there are pixels to spare for it.
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor.white.setFill()
        body.fill()
        ctx.restoreGState()
    }

    ctx.saveGState()
    body.addClip()
    NSGradient(colors: [tileTop, tileBottom])!.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // Heavier strokes and a larger glyph at small sizes, or the cloud outline and the
    // arrow merge into a single blob once antialiased down to 16px.
    let weight: NSFont.Weight = size <= 32 ? .bold : (size <= 64 ? .semibold : .medium)
    let scale: CGFloat = size <= 32 ? 0.62 : (size <= 64 ? 0.56 : 0.50)

    let config = NSImage.SymbolConfiguration(pointSize: side * scale, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [accent, .white]))
    if let glyph = NSImage(systemSymbolName: "icloud.and.arrow.down",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let w = glyph.size.width, h = glyph.size.height
        glyph.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The single glyph layer for `Icon/AppIcon.icon`, the macOS 26 layered icon format.
///
/// Nothing here draws the rounded-rect container, the background, the shadow or the
/// specular highlight that `drawIcon` bakes into the .icns. On macOS 26 the system draws
/// all four itself and differently per appearance (default, dark, clear, tinted), so a
/// layer that brings its own gets a second squircle inside the real one and a shadow
/// that does not move with the light. The background is not an image at all -- it is the
/// `automatic-gradient` fill in icon.json, which is how Apple's own icons do it.
///
/// ponytail: one layer holds both the cloud and the arrow, rather than a layer each.
/// Ceiling: they get one shared shadow and specular pass instead of separate ones, and
/// in tinted mode they flatten to a single tint -- which they would anyway. Upgrade
/// path: emit cloud.png and arrow.png and give icon.json two entries in the group.
func drawGlyph(to directory: String) {
    let size: CGFloat = 1024
    try? FileManager.default.createDirectory(atPath: directory,
                                             withIntermediateDirectories: true)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Sized against the same 0.82 content square drawIcon uses, so the glyph sits on the
    // icon grid at the weight the .icns version has.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.82 * 0.50, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [accent, .white]))
    if let glyph = NSImage(systemSymbolName: "icloud.and.arrow.down",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let w = glyph.size.width, h = glyph.size.height
        glyph.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()

    let out = "\(directory)/glyph.png"
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}

if CommandLine.arguments.contains("--glyph") {
    drawGlyph(to: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon.icon/Assets")
    exit(0)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let rep = drawIcon(size: CGFloat(px))
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(sizes.count) natively rendered sizes to \(out)")
