// Makes the Mac companion's icon from the iPhone app icon, so both apps share
// one original mark. macOS icons sit inside a rounded square with a margin
// and a soft shadow, so the full-bleed iPhone artwork is placed that way.
//
//   xcrun swift genesis-iphone/design/build_mac_icon.swift
//
// Writes genesis-mapper/Assets/Genesis.png (1024 px) and Genesis.icns.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("genesis-iphone/ios/Resources/Assets.xcassets/AppIcon.appiconset/icon1024.png")
let assets = root.appendingPathComponent("genesis-mapper/Assets")
guard let art = NSImage(contentsOf: source) else { fatalError("missing \(source.path)") }

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    // Apple's macOS grid: an 824 px tile centred in 1024, corner radius about 185.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    art.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.08).setStroke()
    shape.lineWidth = max(1, 2 * s)
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(1024).write(to: assets.appendingPathComponent("Genesis.png"))
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Genesis-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("Genesis.icns").path]
try util.run(); util.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(util.terminationStatus == 0 ? "Wrote Genesis.png and Genesis.icns" : "iconutil failed")
