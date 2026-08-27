// Generates AppIcon.icns. Run: ./Icon/make-icon.sh
//
// Drawn in code rather than committed as a binary blob nobody can edit: the design is
// a few lines here, and regenerating after a tweak is one command.
import AppKit

let canvas: CGFloat = 1024
// macOS icons sit inset inside their canvas, with a squircle-ish corner radius.
let inset: CGFloat = canvas * 0.09
let side = canvas - inset * 2
let radius = side * 0.2237

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

let rect = CGRect(x: inset, y: inset, width: side, height: side)
let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Soft drop shadow, as system icons have.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012),
              blur: canvas * 0.03,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.white.setFill()
body.fill()
ctx.restoreGState()

// Blue gradient body.
ctx.saveGState()
body.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.29, green: 0.56, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.11, green: 0.32, blue: 0.83, alpha: 1),
])!
gradient.draw(in: rect, angle: -90)
ctx.restoreGState()

// Glyph: a photo stack with a download arrow, which is what the app does.
let config = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .medium)
if let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                        accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
    symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let w = symbol.size.width, h = symbol.size.height
    tinted.draw(in: CGRect(x: (canvas - w) / 2,
                           y: (canvas - h) / 2 + side * 0.03,
                           width: w, height: h))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else { exit(2) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// The exact set macOS expects.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    scaled.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try? scaled.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(sizes.count) sizes to \(out)")
