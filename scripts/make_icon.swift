// Generiert das App-Icon (Waveform-Balken auf Verlauf) als .iconset-PNGs.
// Aufruf: swift scripts/make_icon.swift <output-iconset-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(px)
    // macOS-Icons zeichnen die abgerundete Kachel selbst, mit Rand drumherum.
    let margin = size * 0.09
    let tile = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: size * 0.185, yRadius: size * 0.185)
    NSGradient(
        starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.42, alpha: 1),
        ending: NSColor(calibratedRed: 0.47, green: 0.22, blue: 0.78, alpha: 1)
    )!.draw(in: tilePath, angle: -60)

    // Fünf Pegelbalken als Waveform
    NSColor.white.set()
    let heights: [CGFloat] = [0.30, 0.52, 0.74, 0.52, 0.30]
    let barWidth = size * 0.06
    let gap = size * 0.06
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (size - totalWidth) / 2
    for h in heights {
        let barHeight = tile.height * h * 0.82
        let bar = NSRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in sizes {
    let rep = render(px: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}
print("Iconset geschrieben nach \(outputDir)")
