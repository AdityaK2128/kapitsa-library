// Draws three app icon concepts and a comparison sheet.
// Usage: swift concepts.swift OUTPUT_DIR
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS icon grid: an 824-point rounded tile on a 1024 canvas, with a soft shadow and top sheen.
func tile(_ ctx: CGContext, top: UInt32, bottom: UInt32) -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.12), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
    return shape
}

func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
}

func dot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// A: Kapitsa's pendulum, reduced to rod, bob, pivot and vibration marks.
func pendulum(_ ctx: CGContext) {
    _ = tile(ctx, top: 0x4D5BF0, bottom: 0x1B1F6E)
    let pivot = CGPoint(x: 512, y: 330), bob = CGPoint(x: 512, y: 700)
    line(ctx, CGPoint(x: 360, y: 330), CGPoint(x: 664, y: 330), width: 16, color: rgb(0xFFFFFF, 0.55))
    for (radius, alpha) in [(54.0, 0.75), (84.0, 0.4)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(0xFFFFFF, alpha)); ctx.setLineWidth(11); ctx.setLineCap(.round)
        // Short arcs left and right of the pivot: the base's fast vibration.
        for side in [0.0, CGFloat.pi] {
            ctx.addArc(center: pivot, radius: radius, startAngle: side - 0.45, endAngle: side + 0.45, clockwise: false)
            ctx.strokePath()
        }
    }
    line(ctx, pivot, bob, width: 26, color: rgb(0xFFFFFF))
    dot(ctx, pivot, 24, rgb(0xFFFFFF))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: rgb(0x000000, 0.3))
    dot(ctx, bob, 86, rgb(0xFFB547))
    ctx.restoreGState()
}

/// B: a geometric K whose upper arm is a pendulum ending in its bob.
func monogram(_ ctx: CGContext) {
    _ = tile(ctx, top: 0x34363E, bottom: 0x121317)
    let white = rgb(0xF5F5F7)
    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 262, width: 96, height: 500), cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()
    line(ctx, CGPoint(x: 440, y: 500), CGPoint(x: 660, y: 290), width: 92, color: white)
    line(ctx, CGPoint(x: 424, y: 520), CGPoint(x: 612, y: 676), width: 30, color: white)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgb(0x000000, 0.35))
    dot(ctx, CGPoint(x: 646, y: 706), 74, rgb(0xFFB547))
    ctx.restoreGState()
}

/// C: a terminal prompt on a chip — coding agents running on local silicon.
func silicon(_ ctx: CGContext) {
    _ = tile(ctx, top: 0x2BD4A7, bottom: 0x0B7E70)
    let white = rgb(0xFFFFFF), ink = rgb(0x0A6457)
    let body = CGRect(x: 302, y: 302, width: 420, height: 420)
    ctx.setFillColor(white)
    for i in 0..<4 {
        let offset = 362 + CGFloat(i) * 100
        for rect in [CGRect(x: offset - 14, y: 236, width: 28, height: 80), CGRect(x: offset - 14, y: 708, width: 28, height: 80),
                     CGRect(x: 236, y: offset - 14, width: 80, height: 28), CGRect(x: 708, y: offset - 14, width: 80, height: 28)] {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        }
    }
    ctx.fillPath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: rgb(0x000000, 0.25))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 72, cornerHeight: 72, transform: nil)); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(ink); ctx.setLineWidth(46); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 400, y: 600)); ctx.addLine(to: CGPoint(x: 486, y: 512)); ctx.addLine(to: CGPoint(x: 400, y: 424)); ctx.strokePath()
    line(ctx, CGPoint(x: 534, y: 424), CGPoint(x: 626, y: 424), width: 46, color: ink)
}

func render(_ draw: (CGContext) -> Void, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent(name))
}

let concepts: [(String, String, String, (CGContext) -> Void)] = [
    ("A", "Pendulum", "Kapitsa’s pendulum: stable because its base vibrates fast.", pendulum),
    ("B", "K Monogram", "Brand initial; the upper arm is the pendulum and its bob.", monogram),
    ("C", "Prompt on Silicon", "Coding agents running on your Mac’s own chip.", silicon),
]

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (key, _, _, draw) in concepts { save(render(draw, size: 1024), "concept-\(key).png") }

// Comparison sheet: large icon, Dock and menu sizes, on dark and light backgrounds.
let width = 1560, height = 900
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
cg.setFillColor(rgb(0x1C1C1E)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
cg.setFillColor(rgb(0xF2F2F7)); cg.fill(CGRect(x: 0, y: 0, width: width, height: 210))
let column = CGFloat(width) / 3
for (index, (key, title, note, draw)) in concepts.enumerated() {
    let x = column * CGFloat(index)
    cg.draw(render(draw, size: 640), in: CGRect(x: x + column / 2 - 170, y: 470, width: 340, height: 340))
    for (size, offset) in [(128, -110), (64, 40), (32, 130)] as [(Int, CGFloat)] {
        cg.draw(render(draw, size: size * 2), in: CGRect(x: x + column / 2 + offset - CGFloat(size) / 2, y: 300, width: CGFloat(size), height: CGFloat(size)))
    }
    for (size, offset) in [(64, -60), (32, 30), (16, 90)] as [(Int, CGFloat)] {
        cg.draw(render(draw, size: size * 2), in: CGRect(x: x + column / 2 + offset - CGFloat(size) / 2, y: 70, width: CGFloat(size), height: CGFloat(size)))
    }
    let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white]
    let noteAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
    let heading = NSAttributedString(string: "\(key)  ·  \(title)", attributes: titleAttrs)
    heading.draw(at: NSPoint(x: x + column / 2 - heading.size().width / 2, y: 840))
    let caption = NSAttributedString(string: note, attributes: noteAttrs)
    caption.draw(at: NSPoint(x: x + column / 2 - caption.size().width / 2, y: 246))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("concepts-sheet.png"))
print("Wrote concepts to \(out.path)")
