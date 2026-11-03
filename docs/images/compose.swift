// Composes the README images from app window captures (screencapture -o -l <window>).
// Usage: swift compose.swift SHOTS_DIR ICON_PNG OUT_DIR
import AppKit

let args = CommandLine.arguments
let shots = URL(fileURLWithPath: args[1]), iconURL = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func image(_ url: URL) -> CGImage {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

/// Runs `draw` in a bitmap with AppKit text support, then writes a PNG.
func canvas(_ width: Int, _ height: Int, _ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("Wrote \(name) (\(width)×\(height))")
}

func background(_ ctx: CGContext, _ width: CGFloat, _ height: CGFloat, glow: UInt32, at point: CGPoint) {
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x1E2026), rgb(0x0D0E11)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    let halo = CGGradient(colorsSpace: space, colors: [rgb(glow, 0.22), rgb(glow, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: point, startRadius: 0, endCenter: point, endRadius: max(width, height) * 0.55, options: [])
}

func window(_ ctx: CGContext, _ shot: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: rgb(0x000000, 0.6))
    ctx.draw(shot, in: rect)
    ctx.restoreGState()
    // A hairline edge keeps the dark window distinct from the dark background.
    let edge = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: rect.width * 0.0105, cornerHeight: rect.width * 0.0105, transform: nil)
    ctx.addPath(edge); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(2); ctx.strokePath()
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: CGPoint, tracking: CGFloat = 0) {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking])
        .draw(at: point)
}

func chip(_ string: String, at point: CGPoint) -> CGFloat {
    let label = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor(white: 0.88, alpha: 1)])
    let size = label.size()
    let rect = CGRect(x: point.x, y: point.y, width: size.width + 48, height: 64)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 32, cornerHeight: 32, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.07)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 31, cornerHeight: 31, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2); ctx.strokePath()
    label.draw(at: CGPoint(x: point.x + 24, y: point.y + (64 - size.height) / 2))
    return rect.width
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let icon = image(iconURL)

// Hero: icon, name and promise on the left; the Home screen bleeding off the right edge.
canvas(2400, 1200, "hero.png") { ctx in
    background(ctx, 2400, 1200, glow: 0xFFB547, at: CGPoint(x: 330, y: 820))
    // A tall window is cropped from the top so its title bar and live panel stay in frame.
    let full = image(shots.appendingPathComponent("home.png"))
    let home = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: min(full.height, full.width * 3 / 4)))!
    let width: CGFloat = 1480, height = width * CGFloat(home.height) / CGFloat(home.width)
    window(ctx, home, in: CGRect(x: 1080, y: (1200 - height) / 2 - 20, width: width, height: height))
    ctx.draw(icon, in: CGRect(x: 100, y: 700, width: 300, height: 300))
    text("Kapitsa Library", size: 104, weight: .bold, color: .white, at: CGPoint(x: 140, y: 548), tracking: -1.5)
    text("Local models for your coding agents, on your Mac.", size: 40, weight: .regular, color: NSColor(white: 0.72, alpha: 1), at: CGPoint(x: 144, y: 478))
    var x: CGFloat = 140
    for label in ["Claude Code", "OpenCode", "Codex", "Pi"] { x += chip(label, at: CGPoint(x: x, y: 330)) + 16 }
    x = 140
    for label in ["Memory-safe loading", "Built-in benchmarks"] { x += chip(label, at: CGPoint(x: x, y: 248)) + 16 }
    text("Powered by the Kapitsa inference engine for Apple silicon", size: 26, weight: .regular, color: NSColor(white: 0.5, alpha: 1), at: CGPoint(x: 144, y: 150))
}

// One framed image per page, each with its own soft accent.
let pages: [(String, UInt32)] = [("home", 0x4A8CD9), ("discover", 0xFFB547), ("models", 0x34C38F), ("agents", 0x8B7CF6), ("benchmarks", 0xFF7A59)]
for (name, accent) in pages {
    let shot = image(shots.appendingPathComponent("\(name).png"))
    let pad: CGFloat = 120
    let width = CGFloat(shot.width) + pad * 2, height = CGFloat(shot.height) + pad * 2
    canvas(Int(width), Int(height), "\(name).png") { ctx in
        background(ctx, width, height, glow: accent, at: CGPoint(x: width * 0.5, y: height * 0.95))
        window(ctx, shot, in: CGRect(x: pad, y: pad, width: CGFloat(shot.width), height: CGFloat(shot.height)))
    }
}
