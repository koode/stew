// Draws the stew app icon (the steaming pot from stewcli.com on a paprika tile) and
// writes it as an .icns file for the Mac app or as a 1024 px PNG for the iPhone app.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//   swift scripts/make-icon.swift ios/App/Stew/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The Mac icon is a tile on the macOS icon grid with the site's dark edge and hard
// shadow. The iPhone icon fills the whole square, because iOS rounds the corners.
// Rerun it after changing the drawing; commit the files it writes.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2, ["icns", "png"].contains(URL(fileURLWithPath: arguments[1]).pathExtension) else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift OUTPUT.icns|OUTPUT.png\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])

let paprika = NSColor(srgbRed: 0xE4 / 255, green: 0x57 / 255, blue: 0x2E / 255, alpha: 1)
let edge = NSColor(srgbRed: 0x2A / 255, green: 0x1A / 255, blue: 0x12 / 255, alpha: 1)
let cream = NSColor(srgbRed: 0xFF / 255, green: 0xF6 / 255, blue: 0xEC / 255, alpha: 1)

/// The pot from the site's PotIcon, drawn on its 32 unit grid (y grows downward)
/// into `box`, a square in the icon's coordinates.
func drawPot(in box: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let grid = NSAffineTransform()
    grid.translateX(by: box.minX, yBy: box.maxY)
    grid.scaleX(by: box.width / 32, yBy: -box.height / 32)
    grid.concat()
    cream.set()

    let steam = NSBezierPath()
    for (column, top) in [(11.0, 4.5), (16.0, 3.5), (21.0, 4.5)] {
        steam.move(to: NSPoint(x: column, y: top))
        steam.curve(
            to: NSPoint(x: column, y: top + 4.2),
            controlPoint1: NSPoint(x: column - 1.2, y: top + 1.4),
            controlPoint2: NSPoint(x: column + 1.2, y: top + 2.6)
        )
    }
    steam.lineWidth = 1.8
    steam.lineCapStyle = .round
    steam.stroke()

    NSBezierPath(roundedRect: NSRect(x: 3, y: 12, width: 26, height: 3.4), xRadius: 1.7, yRadius: 1.7).fill()

    // The body starts under the lid rim, so no seam shows between them.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 5.5, y: 14.6))
    body.line(to: NSPoint(x: 26.5, y: 14.6))
    body.line(to: NSPoint(x: 26.5, y: 21.5))
    body.appendArc(withCenter: NSPoint(x: 20, y: 21.5), radius: 6.5, startAngle: 0, endAngle: 90, clockwise: false)
    body.line(to: NSPoint(x: 12, y: 28))
    body.appendArc(withCenter: NSPoint(x: 12, y: 21.5), radius: 6.5, startAngle: 90, endAngle: 180, clockwise: false)
    body.close()
    body.fill()

    for handleX in [1.0, 27.0] {
        NSBezierPath(roundedRect: NSRect(x: handleX, y: 17, width: 4, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// The Mac icon: a paprika tile with a dark edge and a hard shadow down and to the
/// right, like the logo on stewcli.com, kept inside the 824 pt macOS icon grid.
func drawMacIcon() {
    let tile = NSRect(x: 97, y: 127, width: 800, height: 800)
    let radius: CGFloat = 180
    edge.setFill()
    NSBezierPath(roundedRect: tile.offsetBy(dx: 30, dy: -30), xRadius: radius, yRadius: radius).fill()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
    paprika.setFill()
    let inset: CGFloat = 26
    NSBezierPath(roundedRect: tile.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset).fill()
    let potSide: CGFloat = 540
    drawPot(in: NSRect(x: tile.midX - potSide / 2, y: tile.midY - potSide / 2, width: potSide, height: potSide))
}

/// The iPhone icon: paprika to every edge; iOS applies its own rounded mask.
func drawPhoneIcon() {
    paprika.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let potSide: CGFloat = 620
    drawPot(in: NSRect(x: 512 - potSide / 2, y: 512 - potSide / 2, width: potSide, height: potSide))
}

func render(pixels: Int, opaque: Bool, draw: () -> Void) -> NSBitmapImageRep {
    // Opaque output skips the alpha byte, so the PNG has no alpha channel.
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alphaInfo.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

if output.pathExtension == "png" {
    // App Store icons must have no alpha channel.
    try render(pixels: 1024, opaque: true, draw: drawPhoneIcon).representation(using: .png, properties: [:])!.write(to: output)
    print("wrote \(output.path)")
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("stew-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try render(pixels: points * density, opaque: false, draw: drawMacIcon).representation(using: .png, properties: [:])!.write(to: file)
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")
