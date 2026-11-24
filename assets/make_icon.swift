// mTALKIE — icône d'appli : squircle plat uni (sans effet, sans contour, sans ombre), bulle verte traversée d'une forme d'onde.
// Usage : swift make_icon.swift icon-1024.png
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let inset: CGFloat = 100, side = S - 2 * inset
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0x16/255, green: 0x16/255, blue: 0x19/255, alpha: 1).cgColor); ctx.fillPath()
    // bulle
    let s = side, ox = inset, oy = inset
    let r = CGRect(x: ox + s * 0.14, y: oy + s * 0.18, width: s * 0.72, height: s * 0.5)
    let green = NSColor(srgbRed: 0x22/255, green: 0xc5/255, blue: 0x5e/255, alpha: 1).cgColor
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.14, cornerHeight: s * 0.14, transform: nil)); ctx.setFillColor(green); ctx.fillPath()
    let bubble = CGMutablePath()   // queue, remplie à part (pas de recouvrement évidé)
    bubble.move(to: CGPoint(x: ox + s * 0.30, y: r.maxY - 40)); bubble.addLine(to: CGPoint(x: ox + s * 0.24, y: oy + s * 0.84))
    bubble.addLine(to: CGPoint(x: ox + s * 0.47, y: r.maxY - 40)); bubble.closeSubpath()
    ctx.addPath(bubble); ctx.setFillColor(NSColor(srgbRed: 0x22/255, green: 0xc5/255, blue: 0x5e/255, alpha: 1).cgColor); ctx.fillPath()
    // forme d'onde
    let bars: [CGFloat] = [0.12, 0.24, 0.36, 0.22, 0.32, 0.16, 0.08]
    let bw = s * 0.05, gap = s * 0.035
    var x = ox + s / 2 - (CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap) / 2
    ctx.setFillColor(NSColor(srgbRed: 0x16/255, green: 0x16/255, blue: 0x19/255, alpha: 1).cgColor)
    for b in bars { let h = b * s
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: r.midY - h / 2, width: bw, height: h), cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)); ctx.fillPath()
        x += bw + gap }
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)); NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
