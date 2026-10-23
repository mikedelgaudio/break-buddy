// Turns full-bleed square artwork into a macOS app icon: Apple's 1024 grid (824pt body,
// 100pt margin), rounded-rect mask, soft drop shadow. Writes a 1024 PNG.
// Usage: swift scripts/make-icon.swift <artwork.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <artwork.png> <out.png>\n".utf8))
    exit(2)
}

let canvas: CGFloat = 1024, body: CGFloat = 824, radius: CGFloat = 185
let rect = NSRect(x: (canvas - body) / 2, y: (canvas - body) / 2 + 10, width: body, height: body)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
art.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()

// Hairline edge so the icon holds its shape on light backgrounds.
NSColor.white.withAlphaComponent(0.18).setStroke()
shape.lineWidth = 2
shape.stroke()
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
