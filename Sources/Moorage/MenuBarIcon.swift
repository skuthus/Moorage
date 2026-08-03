import AppKit

/// The menu bar glyph: a ring. Open (stroked) when idle, filled (solid) when a
/// device is mounted. Drawn as a template image so the system tints it for
/// light/dark menu bars.
enum MenuBarIcon {

    private static let pointSize: CGFloat = 15

    static func image(mounted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            let lineWidth: CGFloat = pointSize * 0.16
            let inset = mounted ? 1.5 : lineWidth / 2 + 1.5
            let rect = NSRect(x: inset, y: inset,
                              width: pointSize - inset * 2, height: pointSize - inset * 2)
            let circle = NSBezierPath(ovalIn: rect)
            NSColor.black.set()
            if mounted {
                circle.fill()
            } else {
                circle.lineWidth = lineWidth
                circle.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
