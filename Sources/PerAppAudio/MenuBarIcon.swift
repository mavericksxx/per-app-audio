import AppKit

/// The menu-bar mark: a headphone splitter — one jack in, two out.
///
/// Drawn in code rather than shipped as an asset. A SwiftPM package has no asset
/// catalog, and adding a resource bundle just to carry one 16pt glyph is more moving
/// parts than the glyph is worth. A drawing handler also re-renders at whatever backing
/// scale the bar asks for, so it stays crisp on any display.
enum MenuBarIcon {
    /// The design is specified on a 16x16 box with y increasing *downward*, as in the
    /// source drawing, so the numbers below transcribe it literally. The drawing handler
    /// is asked for a flipped context to match.
    private static let designBox: CGFloat = 16

    /// Where the ink actually lands in that box, stroke width included: the input jack's
    /// outer edge reaches x = -0.05 and the output jacks' reaches x = 13.75, so the mark
    /// sits left of centre and is clipped by a hair if drawn as specified. Everything is
    /// positioned against this rect rather than the box, which centres it and pulls the
    /// clipped edge back inside. Vertically it is already centred on 8.
    private static let ink = CGRect(x: -0.05, y: 2.45, width: 13.8, height: 11.1)

    /// Menu-bar items are laid out on an ~18pt square.
    private static let pointSize = NSSize(width: 18, height: 18)

    static let image: NSImage = {
        let image = NSImage(size: pointSize, flipped: true) { rect in
            let scale = rect.width / designBox
            let originX = rect.midX - ink.midX * scale
            let originY = rect.midY - ink.midY * scale

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: originX + x * scale, y: originY + y * scale)
            }

            func circle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(origin: point(cx - r, cy - r),
                                            size: NSSize(width: 2 * r * scale,
                                                         height: 2 * r * scale)))
            }

            // Template masking reads alpha only, so a translucent stroke would silently
            // thin the mark rather than lighten it.
            NSColor.black.setStroke()

            let cable = NSBezierPath()
            cable.move(to: point(3.8, 8))
            cable.line(to: point(5.6, 8))
            cable.curve(to: point(10, 4.6),
                        controlPoint1: point(7.8, 8), controlPoint2: point(7.8, 4.6))
            cable.move(to: point(5.6, 8))
            cable.curve(to: point(10, 11.4),
                        controlPoint1: point(7.8, 8), controlPoint2: point(7.8, 11.4))
            cable.lineWidth = 1.4 * scale
            cable.lineCapStyle = .round
            cable.lineJoinStyle = .round
            cable.stroke()

            for jack in [circle(cx: 2.2, cy: 8, r: 1.6),
                         circle(cx: 11.6, cy: 4.6, r: 1.5),
                         circle(cx: 11.6, cy: 11.4, r: 1.5)] {
                jack.lineWidth = 1.3 * scale
                jack.stroke()
            }

            return true
        }
        // Lets the bar tint it for light/dark and for the pressed state.
        image.isTemplate = true
        return image
    }()
}
