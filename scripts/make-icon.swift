// Generates the app icon as an .iconset directory (run: swift make-icon.swift <out.iconset>).
// Design: macOS Big Sur-style tile (10% margin + soft drop shadow), deep graphite gradient,
// black notch pill with camera dot, glowing equalizer bars — one amber "needs you" bar.
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

    // Apple icon grid: tile fills ~80% of the canvas, the rest is margin + shadow.
    let i = s * 0.80
    let o = (s - i) / 2
    let tileRect = NSRect(x: o, y: o, width: i, height: i)
    let radius = i * 0.2237
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

    // Drop shadow pass (solid fill casts it; gradient goes on top).
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.024
    shadow.set()
    NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Background: cold graphite, lit from the top.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.235, green: 0.250, blue: 0.290, alpha: 1),
        NSColor(calibratedRed: 0.118, green: 0.125, blue: 0.150, alpha: 1),
        NSColor(calibratedRed: 0.055, green: 0.060, blue: 0.078, alpha: 1),
    ])!.draw(in: tile, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()

    // Soft cyan glow rising from behind the bars (oval reaches past the tile so no edge shows).
    let glowRect = NSRect(x: o - i * 0.50, y: o - i * 0.75, width: i * 2.0, height: i * 2.0)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.12),
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.0),
    ])!.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    // Notch pill.
    let pillW = i * 0.44, pillH = i * 0.115
    let pillRect = NSRect(x: (s - pillW) / 2, y: o + i - pillH - i * 0.10, width: pillW, height: pillH)
    let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillH * 0.42, yRadius: pillH * 0.42)
    NSColor(calibratedWhite: 0, alpha: 1).setFill()
    pill.fill()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    pill.lineWidth = max(0.5, s * 0.004)
    pill.stroke()

    // Camera dot.
    let dotR = pillH * 0.16
    let dot = NSBezierPath(ovalIn: NSRect(
        x: pillRect.midX - dotR, y: pillRect.midY - dotR, width: dotR * 2, height: dotR * 2
    ))
    NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.22, alpha: 1).setFill()
    dot.fill()

    // Equalizer bars: cyan gradient with glow; third bar amber — a session needs you.
    let cyanTop = NSColor(calibratedRed: 0.42, green: 0.93, blue: 1.00, alpha: 1)
    let cyanBottom = NSColor(calibratedRed: 0.07, green: 0.66, blue: 0.84, alpha: 1)
    let amberTop = NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.42, alpha: 1)
    let amberBottom = NSColor(calibratedRed: 0.93, green: 0.53, blue: 0.22, alpha: 1)

    let heights: [CGFloat] = [0.20, 0.37, 0.27, 0.47]
    let barW = i * 0.082, gap = i * 0.052
    var x = (s - (4 * barW + 3 * gap)) / 2
    for (idx, h) in heights.enumerated() {
        let barRect = NSRect(x: x, y: o + i * 0.155, width: barW, height: i * h)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2)
        let top = idx == 2 ? amberTop : cyanTop
        let bottom = idx == 2 ? amberBottom : cyanBottom

        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = bottom.withAlphaComponent(0.55)
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = s * 0.028
        glow.set()
        bottom.setFill()
        bar.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGradient(colors: [top, bottom])!.draw(in: bar, angle: -90)
        x += barW + gap
    }

    // Rim light: subtle all around, brighter along the top edge.
    let rimInset = max(0.5, s * 0.003)
    let rim = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: rimInset, dy: rimInset),
        xRadius: radius - rimInset, yRadius: radius - rimInset
    )
    rim.lineWidth = rimInset * 2
    NSColor(calibratedWhite: 1, alpha: 0.07).setStroke()
    rim.stroke()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: o + i * 0.62, width: s, height: s)).addClip()
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    rim.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.restoreGraphicsState()
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
