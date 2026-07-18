// Generates the app icon as an .iconset directory (run: swift make-icon.swift <out.iconset>).
// Design: dark rounded tile, black notch pill up top, cyan equalizer bars — the app's compact UI.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(_ pixel: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixel)

    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [
        NSColor(calibratedWhite: 0.14, alpha: 1),
        NSColor(calibratedWhite: 0.03, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    let pillW = s * 0.46, pillH = s * 0.125
    let pill = NSBezierPath(
        roundedRect: NSRect(x: (s - pillW) / 2, y: s - pillH - s * 0.11, width: pillW, height: pillH),
        xRadius: pillH * 0.38, yRadius: pillH * 0.38
    )
    NSColor.black.setFill()
    pill.fill()
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    pill.lineWidth = max(1, s * 0.008)
    pill.stroke()

    let heights: [CGFloat] = [0.17, 0.32, 0.23, 0.38]
    let barW = s * 0.075, gap = s * 0.05
    var x = (s - (4 * barW + 3 * gap)) / 2
    for h in heights {
        let bar = NSBezierPath(
            roundedRect: NSRect(x: x, y: s * 0.20, width: barW, height: s * h),
            xRadius: barW / 2, yRadius: barW / 2
        )
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 1).setFill()
        bar.fill()
        x += barW + gap
    }
    return rep
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = draw(size * scale)
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("iconset written to \(outDir)")
