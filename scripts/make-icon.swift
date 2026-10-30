// Renders Resources/AppIcon.icns: a display with a pin, on a blue squircle.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824 pt squircle centered on a 1024 pt canvas.
    let inset = size * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.45, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.33, green: 0.20, blue: 0.85, alpha: 1)])!
        .draw(in: shape, angle: -70)

    func symbol(_ name: String, points: CGFloat, color: NSColor, center: NSPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        image.draw(in: NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }
    symbol("display", points: size * 0.40, color: .white, center: NSPoint(x: size * 0.47, y: size * 0.47))

    // Pin badge on the top-right corner of the screen.
    let badgeCenter = NSPoint(x: size * 0.70, y: size * 0.67)
    let badgeRadius = size * 0.125
    let ring = badgeRadius + size * 0.025
    NSColor(srgbRed: 0.24, green: 0.32, blue: 0.93, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - ring, y: badgeCenter.y - ring, width: 2 * ring, height: 2 * ring)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                                width: 2 * badgeRadius, height: 2 * badgeRadius)).fill()
    symbol("pin.fill", points: size * 0.11, color: NSColor(srgbRed: 0.24, green: 0.32, blue: 0.93, alpha: 1), center: badgeCenter)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
