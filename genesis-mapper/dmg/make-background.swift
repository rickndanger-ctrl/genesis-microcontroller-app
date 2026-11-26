// Draws the installer window's background: an arrow from the app to
// Applications and one line saying what to do.
// Usage: swift make-background.swift <out.png> <scale>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: make-background.swift <out.png> <scale>\n".data(using: .utf8)!); exit(2)
}
let size = NSSize(width: 600, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: soft off-white, matching the support site.
NSColor(srgbRed: 0.965, green: 0.965, blue: 0.955, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Arrow between the two icons (icons sit at y = 190 from the top, x = 150 and 450).
let arrowY = size.height - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 236, y: arrowY))
arrow.line(to: NSPoint(x: 352, y: arrowY))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
let ink = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.86, alpha: 1)
ink.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 368, y: arrowY))
head.line(to: NSPoint(x: 346, y: arrowY + 14))
head.line(to: NSPoint(x: 346, y: arrowY - 14))
head.close()
ink.setFill()
head.fill()

func centered(_ text: String, y: CGFloat, size points: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: points, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: style]
    NSAttributedString(string: text, attributes: attrs)
        .draw(in: NSRect(x: 0, y: size.height - y - points * 1.4, width: size.width, height: points * 1.6))
}
centered("Drag Agent Micro Controller into Applications", y: 52, size: 17, weight: .semibold,
         color: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1))
centered("Then open it from Applications. Its setup window walks you through the rest.", y: 320, size: 12.5, weight: .regular,
         color: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.44, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
