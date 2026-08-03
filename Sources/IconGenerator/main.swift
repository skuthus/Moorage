import AppKit
import Foundation

// Draws the Moorage app icon: a cleat hitch — a steel horn cleat whose two
// horns stick straight out to the sides, with a white rope tied in a clean
// figure-eight over the centre, on deep navy. Modelled on the reference mark:
// round rope loops, subtle twist lines, a thin navy outline separating rope
// from cleat, no mooring tail.
//
// Flat shapes plus a dashed groove overlay for the rope's lay. Geometry is
// authored in a 512-unit square (AppKit's bottom-up y) and scaled to the
// requested pixel size. Twist and highlights drop at small sizes, where the
// figure-eight silhouette carries the icon on its own.
//
// Usage: IconGenerator <output.png> [pixelSize]

// MARK: - Palette

let field   = NSColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x5E / 255, alpha: 1) // deep navy
let edge    = NSColor(srgbRed: 0x17 / 255, green: 0x2E / 255, blue: 0x4C / 255, alpha: 1) // navy outline
let cleat   = NSColor(srgbRed: 0x9E / 255, green: 0xA4 / 255, blue: 0xAA / 255, alpha: 1) // steel grey
let cleatHi = NSColor(srgbRed: 0xBE / 255, green: 0xC3 / 255, blue: 0xC8 / 255, alpha: 1) // steel highlight
let rope    = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255, alpha: 1) // white
let groove  = NSColor(srgbRed: 0xC3 / 255, green: 0xCC / 255, blue: 0xD6 / 255, alpha: 1) // twist line

let unit: CGFloat = 512
let center = NSPoint(x: 256, y: 256)

// MARK: - Small-size tuning

struct Tuning {
    var ropeWidth: CGFloat
    var drawsTwist: Bool
    var drawsHighlights: Bool
    var drawsOutline: Bool

    static func forPixelSize(_ px: Int) -> Tuning {
        if px <= 16 {
            return Tuning(ropeWidth: 58, drawsTwist: false, drawsHighlights: false, drawsOutline: false)
        } else if px <= 32 {
            return Tuning(ropeWidth: 52, drawsTwist: false, drawsHighlights: false, drawsOutline: false)
        } else if px <= 64 {
            return Tuning(ropeWidth: 46, drawsTwist: true, drawsHighlights: true, drawsOutline: false)
        }
        return Tuning(ropeWidth: 44, drawsTwist: true, drawsHighlights: true, drawsOutline: false)
    }
}

// MARK: - Cleat

// The rope is a tight knot, so the metal must fill the inside of each loop —
// no background shows through. Each horn is therefore a bulb that fills its
// rope loop plus a tapered tip sticking out past it. `side` is -1 (left)/+1.
let lobeDX: CGFloat = 70          // bulb centre offset from the middle
let lobeRX: CGFloat = 80          // bulb half-width (fills the loop to the rope)
let lobeRY: CGFloat = 104          // bulb half-height
let hornTipX: CGFloat = 202       // horn tip, past the rope lobe

func hornPath(side: CGFloat) -> NSBezierPath {
    let bulbCX = center.x + side * lobeDX
    let cy = center.y

    // Bulb: the part that fills the loop interior.
    let bulb = NSBezierPath(ovalIn: NSRect(x: bulbCX - lobeRX, y: cy - lobeRY,
                                           width: lobeRX * 2, height: lobeRY * 2))
    // Tip: a tapered bar from the bulb out to the horn tip.
    let baseX = bulbCX + side * (lobeRX - 8)
    let tipX = center.x + side * hornTipX
    let baseHalf: CGFloat = 30
    let tipHalf: CGFloat = 23
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: baseX, y: cy + baseHalf))
    tip.line(to: NSPoint(x: tipX, y: cy + tipHalf))
    tip.appendArc(withCenter: NSPoint(x: tipX, y: cy), radius: tipHalf,
                  startAngle: 90, endAngle: -90, clockwise: side > 0)
    tip.line(to: NSPoint(x: baseX, y: cy - baseHalf))
    tip.close()

    let p = NSBezierPath()
    p.append(bulb)
    p.append(tip)
    p.windingRule = .nonZero
    return p
}

/// Both horns plus a centre bridge, one filled silhouette behind the rope.
func cleatSilhouette() -> NSBezierPath {
    let p = NSBezierPath()
    p.append(hornPath(side: -1))
    p.append(hornPath(side: 1))
    p.append(NSBezierPath(roundedRect: NSRect(x: center.x - 90, y: center.y - 34, width: 180, height: 68),
                          xRadius: 30, yRadius: 30))
    p.windingRule = .nonZero
    return p
}

// MARK: - Rope

/// A figure-eight with round lobes (a stretched lemniscate), crossing at the
/// centre, lobes left/right so the rope wraps around the horns.
func figureEight(halfWidth a: CGFloat, height c: CGFloat, samples: Int = 300) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let d = 1 + sin(t) * sin(t)
        let x = center.x + a * cos(t) / d
        let y = center.y + c * sin(t) * cos(t) / d
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Strokes the rope: optional navy outline, white base, then a dashed groove
/// overlay for the twist. The overlay drops when `twist` is false.
func drawRope(_ path: NSBezierPath, width: CGFloat, tuning t: Tuning) {
    if t.drawsOutline {
        let outline = path.copy() as! NSBezierPath
        outline.lineWidth = width + 5
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round
        edge.setStroke()
        outline.stroke()
    }
    let base = path.copy() as! NSBezierPath
    base.lineWidth = width
    base.lineCapStyle = .round
    base.lineJoinStyle = .round
    rope.setStroke()
    base.stroke()

    guard t.drawsTwist else { return }
    let g = path.copy() as! NSBezierPath
    g.lineWidth = width * 0.5      // only the rope's middle, so ticks don't fan out like lashes
    g.lineCapStyle = .butt
    g.setLineDash([width * 0.09, width * 0.8], count: 2, phase: 0)
    groove.setStroke()
    g.stroke()
}

func renderIcon(pixelSize px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    let t = Tuning.forPixelSize(px)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let scale = CGFloat(px) / unit
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Field (macOS squircle proportion).
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: unit, height: unit),
                 xRadius: unit * 0.2237, yRadius: unit * 0.2237).also { field.setFill(); $0.fill() }

    // Cleat behind the knot; horn tips stick out past the lobes on each side.
    let cleatShape = cleatSilhouette()
    cleat.setFill()
    cleatShape.fill()
    if t.drawsHighlights {
        for side: CGFloat in [-1, 1] {
            NSGraphicsContext.saveGraphicsState()
            hornPath(side: side).setClip()
            let hi = NSBezierPath(rect: NSRect(x: center.x - 210, y: center.y + 8, width: 420, height: 10))
            cleatHi.setFill()
            hi.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // White figure-eight rope over the cleat.
    drawRope(figureEight(halfWidth: 146, height: 300), width: t.ropeWidth, tuning: t)

    return rep.representation(using: .png, properties: [:])
}

private extension NSBezierPath {
    func also(_ body: (NSBezierPath) -> Void) { body(self) }
}

// MARK: - Entry point

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let pixelSize = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024

guard pixelSize > 0, let pngData = renderIcon(pixelSize: pixelSize) else {
    FileHandle.standardError.write("Failed to render icon at \(pixelSize)px\n".data(using: .utf8)!)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(pixelSize)px)")
