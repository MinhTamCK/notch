// Draws Clawd (Claude Code's pixel mascot) on a transparent 180×180 canvas.
// Usage: swift make-clawd.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "agent-claude.png"
let size = 180

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let coral = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

// Rects are (x, y-from-top, w, h) in a 180pt space, converted to AppKit's bottom-left origin.
func fill(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    color.setFill()
    NSRect(x: x, y: CGFloat(size) - yTop - h, width: w, height: h).fill()
}

fill(30, 40, 120, 85, coral)   // body
fill(12, 70, 18, 40, coral)    // left arm
fill(150, 70, 18, 40, coral)   // right arm
fill(48, 60, 18, 18, .black)   // left eye
fill(114, 60, 18, 18, .black)  // right eye
fill(40, 125, 14, 35, coral)   // legs (two pairs)
fill(62, 125, 14, 35, coral)
fill(104, 125, 14, 35, coral)
fill(126, 125, 14, 35, coral)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
