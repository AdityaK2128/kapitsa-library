// Draws the README's engine comparison from Kapitsa's published benchmark tables
// (github.com/nace-ai/kapitsa, README "Models" section at commit b7a9711).
// Usage: swift engines.swift OUT.png (the README uses it as a JPEG: sips -s format jpeg -s formatOptions 90)
import AppKit

typealias Bar = (engine: String, value: Double?, note: String)

/// Decode tok/s: a 512-token coding answer at T 0.6 after a 4K-token prompt, each engine's best published method.
/// Each panel lists Kapitsa, the four engines most people compare with, and the fastest other engine when it
/// is none of those, so no faster engine is left out.
let models: [(title: String, subtitle: String, macs: [(mac: String, bars: [Bar])])] = [
    ("Qwen3.6 35B-A3B", "MoE, 3B active · 4-bit · 22.1 GB", [
        ("M5 Max · 128 GB", [("Kapitsa", 346, "KFlash"), ("Splash", 281, "fastest other"), ("oMLX", 189, ""), ("llama.cpp", 171, ""), ("Ollama", 162, ""), ("LM Studio", 136, "")]),
        ("M5 Pro · 48 GB", [("Kapitsa", 201, "KFlash"), ("Splash", 181, "fastest other"), ("oMLX", 144, ""), ("llama.cpp", 107, ""), ("Ollama", 102, ""), ("LM Studio", 96, "")]),
        ("M4 Pro · 48 GB", [("Kapitsa", 161, "KFlash"), ("Splash", 135, "fastest other"), ("oMLX", 127, ""), ("Ollama", 89, ""), ("LM Studio", 86, ""), ("llama.cpp", 69, "")]),
        ("M3 Pro · 36 GB", [("Kapitsa", 106, "KFlash"), ("Ollama", 58, "fastest other"), ("llama.cpp", 53, ""), ("oMLX", nil, ""), ("LM Studio", nil, "")]),
    ]),
    ("Qwen3.8 27B", "dense · 4-bit · 20.2 GB", [
        ("M5 Max · 128 GB", [("Kapitsa", 143, "KFlash"), ("mlx-serve", 128, "fastest other"), ("oMLX", 92, ""), ("Ollama", 71, ""), ("llama.cpp", 48, ""), ("LM Studio", 33, "")]),
        ("M5 Pro · 48 GB", [("mlx-serve", 78, "fastest"), ("Kapitsa", 77, "KFlash"), ("oMLX", 51, ""), ("Ollama", 40, ""), ("llama.cpp", 30, ""), ("LM Studio", 17, "")]),
        ("M4 Pro · 48 GB", [("Kapitsa", 63, "KFlash"), ("mlx-serve", 54, "fastest other"), ("oMLX", 45, ""), ("Ollama", 32, ""), ("llama.cpp", 18, ""), ("LM Studio", 15, "")]),
        ("M3 Pro · 36 GB", [("Kapitsa", 40, "KFlash"), ("Ollama", 23, "fastest other"), ("llama.cpp", 16, ""), ("oMLX", nil, ""), ("LM Studio", nil, "")]),
    ]),
]

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "engines.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func label(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ white: CGFloat, alpha: CGFloat = 1) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: NSColor(white: white, alpha: alpha)])
}

let width = 2400, height = 1800
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let H = CGFloat(height)

let base = CGGradient(colorsSpace: space, colors: [rgb(0x1E2026), rgb(0x0D0E11)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: H), end: CGPoint(x: CGFloat(width), y: 0), options: [])
let halo = CGGradient(colorsSpace: space, colors: [rgb(0xFFB547, 0.10), rgb(0xFFB547, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 300, y: H - 100), startRadius: 0, endCenter: CGPoint(x: 300, y: H - 100), endRadius: 1400, options: [])

label("Decode speed against other engines", 60, .bold, 1).draw(at: CGPoint(x: 100, y: H - 150))
label("Tokens per second, higher is better · a 512-token coding answer after a 4K-token prompt · published by the Kapitsa project",
      28, .regular, 0.62).draw(at: CGPoint(x: 102, y: H - 205))

let columnWidth: CGFloat = 1060, rowHeight: CGFloat = 330
for (column, model) in models.enumerated() {
    let x0 = 100 + CGFloat(column) * (columnWidth + 80)
    label(model.title, 40, .semibold, 1).draw(at: CGPoint(x: x0, y: H - 300))
    label(model.subtitle, 26, .regular, 0.55).draw(at: CGPoint(x: x0, y: H - 342))
    for (row, mac) in model.macs.enumerated() {
        let top = H - 400 - CGFloat(row) * rowHeight
        let card = CGRect(x: x0, y: top - rowHeight + 30, width: columnWidth, height: rowHeight - 30)
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(rgb(0xFFFFFF, 0.035)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 1, dy: 1), cornerWidth: 21, cornerHeight: 21, transform: nil))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(2); ctx.strokePath()
        label(mac.mac, 26, .semibold, 0.92).draw(at: CGPoint(x: x0 + 28, y: top - 64))

        let maxValue = mac.bars.compactMap(\.value).max() ?? 1
        let barLeft = x0 + 230, barSpan: CGFloat = columnWidth - 230 - 210
        for (index, bar) in mac.bars.enumerated() {
            let y = top - 100 - CGFloat(index) * 33
            let isKapitsa = bar.engine == "Kapitsa"
            let name = label(bar.engine, 23, isKapitsa ? .semibold : .regular, isKapitsa ? 1 : 0.75)
            name.draw(at: CGPoint(x: barLeft - 20 - name.size().width, y: y - 2))
            guard let value = bar.value else {
                label("not measured on this Mac", 21, .regular, 0.42).draw(at: CGPoint(x: barLeft, y: y))
                continue
            }
            let length = max(6, barSpan * CGFloat(value / maxValue))
            let rect = CGRect(x: barLeft, y: y + 2, width: length, height: 22)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(isKapitsa ? rgb(0xFFB547) : bar.note.hasPrefix("fastest") ? rgb(0x9AA3B2) : rgb(0x565C68))
            ctx.fillPath()
            let figure = label(String(format: "%.0f", value), 23, .semibold, isKapitsa ? 1 : 0.85)
            figure.draw(at: CGPoint(x: barLeft + length + 12, y: y - 2))
            if !bar.note.isEmpty && !isKapitsa {
                label(bar.note, 19, .regular, 0.5).draw(at: CGPoint(x: barLeft + length + 22 + figure.size().width, y: y + 1))
            }
        }
    }
}
label("Source: github.com/nace-ai/kapitsa (README, Models section, commit b7a9711, 2026-11-01). Each engine at its latest release and best published decoding method. Kapitsa’s own tables list every engine and Mac.",
      22, .regular, 0.45).draw(at: CGPoint(x: 100, y: 40))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
