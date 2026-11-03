// Draws the Nearloop app icon: a loop, the agent's work cycle, with an amber point travelling on it, kept
// close (near) on your Mac. Usage: swift make-icon.swift OUT.png [size]
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "AppIcon-1024.png")
let size = arguments.count > 2 ? Int(arguments[2]) ?? 1024 : 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)  // draw on a 1024 grid; y grows upward

// macOS icon grid: an 824-point rounded tile on a 1024 canvas, with a soft shadow and a top sheen.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.35))
ctx.addPath(tile); ctx.setFillColor(rgb(0x121317)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [rgb(0x34363E), rgb(0x121317)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.12), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// The loop: a thick ring with a gap where the point is passing, so the point reads as moving along it.
let center = CGPoint(x: 512, y: 512), radius: CGFloat = 228, point = CGFloat.pi / 4
ctx.setStrokeColor(rgb(0xF5F5F7)); ctx.setLineWidth(88); ctx.setLineCap(.round)
ctx.addArc(center: center, radius: radius, startAngle: point + 0.64, endAngle: point - 0.64 + 2 * .pi, clockwise: false)
ctx.strokePath()

// The point on the loop.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgb(0x000000, 0.35))
ctx.setFillColor(rgb(0xFFB547))
let dot = CGPoint(x: center.x + radius * cos(point), y: center.y + radius * sin(point))
ctx.fillEllipse(in: CGRect(x: dot.x - 78, y: dot.y - 78, width: 156, height: 156))
ctx.restoreGState()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path) (\(size)px)")
