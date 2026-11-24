// Draws the app icon and writes an .iconset directory. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [
        NSColor(red: 0.16, green: 0.09, blue: 0.33, alpha: 1),
        NSColor(red: 0.93, green: 0.26, blue: 0.42, alpha: 1),
    ])!.draw(in: shape, angle: 60)

    // Concentric ring + play triangle.
    let c = NSPoint(x: s / 2, y: s / 2)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let r = body.width * 0.3
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ring.lineWidth = s * 0.035
    ring.stroke()
    let t = body.width * 0.13
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: c.x - t * 0.7, y: c.y + t))
    tri.line(to: NSPoint(x: c.x - t * 0.7, y: c.y - t))
    tri.line(to: NSPoint(x: c.x + t * 1.05, y: c.y))
    tri.close()
    NSColor.white.setFill()
    tri.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
