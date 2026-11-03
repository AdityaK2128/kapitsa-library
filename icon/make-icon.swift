// Draws the Kapitsa Library app icon: a geometric K whose upper arm is a pendulum ending in its bob,
// after Kapitsa's pendulum, which the engine is named for. Usage: swift make-icon.swift OUT.png [size]
// (icon/concepts.swift renders the alternatives that were considered.)
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

func stroke(_ a: CGPoint, _ b: CGPoint, width: CGFloat) {
    ctx.setStrokeColor(rgb(0xF5F5F7)); ctx.setLineWidth(width); ctx.setLineCap(.round)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
}

// The K: stem, lower leg, and an upper arm drawn as the pendulum's rod.
ctx.setFillColor(rgb(0xF5F5F7))
ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 262, width: 96, height: 500), cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.fillPath()
stroke(CGPoint(x: 440, y: 500), CGPoint(x: 660, y: 290), width: 92)
stroke(CGPoint(x: 424, y: 520), CGPoint(x: 612, y: 676), width: 30)

// The pendulum's bob.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgb(0x000000, 0.35))
ctx.setFillColor(rgb(0xFFB547))
ctx.fillEllipse(in: CGRect(x: 646 - 74, y: 706 - 74, width: 148, height: 148))
ctx.restoreGState()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path) (\(size)px)")
