// Draws the placeholder app icon (a keycap showing ⌘↩ on a rounded square) and
// writes it as an .icns file.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//
// Rerun it after changing the drawing; commit the .icns it writes.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift OUTPUT.icns\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // The macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    tileShadow.shadowOffset = NSSize(width: 0, height: -10)
    tileShadow.shadowBlurRadius = 24
    tileShadow.set()
    NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.20, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    let tileGradient = NSGradient(
        starting: NSColor(calibratedRed: 0.98, green: 0.58, blue: 0.25, alpha: 1),
        ending: NSColor(calibratedRed: 0.86, green: 0.27, blue: 0.18, alpha: 1)
    )!
    tileGradient.draw(in: tilePath, angle: -90)

    // The keycap: a light, raised key with a darker base below it.
    let capBase = NSRect(x: 252, y: 262, width: 520, height: 500)
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    NSBezierPath(roundedRect: capBase, xRadius: 96, yRadius: 96).fill()
    let capTop = NSRect(x: 252, y: 300, width: 520, height: 462)
    NSGraphicsContext.saveGraphicsState()
    let capShadow = NSShadow()
    capShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    capShadow.shadowOffset = NSSize(width: 0, height: -6)
    capShadow.shadowBlurRadius = 10
    capShadow.set()
    let capGradient = NSGradient(
        starting: NSColor(calibratedWhite: 1.0, alpha: 1),
        ending: NSColor(calibratedWhite: 0.92, alpha: 1)
    )!
    capGradient.draw(in: NSBezierPath(roundedRect: capTop, xRadius: 92, yRadius: 92), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let font = NSFont.systemFont(ofSize: 230, weight: .semibold)
    let roundedFont = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 230) } ?? font
    let label = NSAttributedString(string: "⌘↩", attributes: [
        .font: roundedFont,
        .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.10, alpha: 1),
        .kern: 6,
    ])
    let labelSize = label.size()
    label.draw(at: NSPoint(x: capTop.midX - labelSize.width / 2, y: capTop.midY - labelSize.height / 2 + 6))

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("stew-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try drawIcon(pixels: points * density).representation(using: .png, properties: [:])!.write(to: file)
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")
