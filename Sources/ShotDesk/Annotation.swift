import AppKit

enum AnnotationTool {
    case select, rect, arrow, text
}

struct Annotation {
    enum Kind {
        case rect(CGRect)                          // View coordinates (top-left origin)
        case arrow(from: CGPoint, to: CGPoint)
        case text(String, at: CGPoint)             // `at` is the text's top-left corner
    }
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
}

/// Composites annotations onto a captured image.
/// The overlay is excluded from the capture, so annotations are redrawn here at
/// the Retina scale for crisp vector output.
enum AnnotationRenderer {

    static func render(_ annotations: [Annotation],
                       onto image: CGImage,
                       selection: CGRect) -> CGImage {
        guard !annotations.isEmpty, selection.width > 0 else { return image }

        let w = image.width, h = image.height
        let scale = CGFloat(w) / selection.width

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.shouldAntialias = true

        // Views use a top-left origin while bitmaps use a bottom-left origin.
        // Do not flip the CTM: AppKit text follows the context's flipped flag and
        // would render upside down.
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - selection.minX) * scale,
                    y: (selection.maxY - p.y) * scale)
        }

        for a in annotations {
            a.color.setStroke()
            a.color.setFill()
            let lw = a.lineWidth * scale

            switch a.kind {
            case .rect(let r):
                let p0 = map(CGPoint(x: r.minX, y: r.minY))
                let p1 = map(CGPoint(x: r.maxX, y: r.maxY))
                let mapped = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                    width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                let path = NSBezierPath(rect: mapped)
                path.lineWidth = lw
                path.stroke()

            case .arrow(let from, let to):
                drawArrow(from: map(from), to: map(to), lineWidth: lw)

            case .text(let s, let at):
                guard !s.isEmpty else { break }
                let font = NSFont.systemFont(ofSize: a.fontSize * scale, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: a.color
                ]
                let str = NSAttributedString(string: s, attributes: attrs)
                let origin = map(at)
                // `map` returns the bitmap position of the text's top-left corner;
                // `draw(at:)` expects its bottom-left corner.
                str.draw(at: CGPoint(x: origin.x, y: origin.y - str.size().height))
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? image
    }

    /// A solid callout arrow with a pointed tail and a gradually widening body.
    /// Its endpoints exactly match the user's drag endpoints, avoiding the look
    /// of a conventional connector line.
    static func taperedArrowPoints(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> [CGPoint] {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return [] }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)
        // Balanced callout proportions: a clear, compact head and a slightly
        // wider neck to avoid an abrupt shoulder.
        let headLength = min(max(lineWidth * 6.7, 18), max(length * 0.16, lineWidth * 2))
        let headHalfWidth = min(headLength * 0.5, max(lineWidth * 3, 8))
        let neckHalfWidth = min(lineWidth * 1.15, headHalfWidth * 0.48)
        let headBase = CGPoint(x: to.x - unit.x * headLength, y: to.y - unit.y * headLength)

        return [
            from,
            CGPoint(x: headBase.x + perpendicular.x * neckHalfWidth,
                    y: headBase.y + perpendicular.y * neckHalfWidth),
            CGPoint(x: headBase.x + perpendicular.x * headHalfWidth,
                    y: headBase.y + perpendicular.y * headHalfWidth),
            to,
            CGPoint(x: headBase.x - perpendicular.x * headHalfWidth,
                    y: headBase.y - perpendicular.y * headHalfWidth),
            CGPoint(x: headBase.x - perpendicular.x * neckHalfWidth,
                    y: headBase.y - perpendicular.y * neckHalfWidth)
        ]
    }

    /// A pointed, tapered body plus a solid head; its length follows the drag.
    static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat) {
        let points = taperedArrowPoints(from: from, to: to, lineWidth: lineWidth)
        guard let first = points.first else { return }

        let arrow = NSBezierPath()
        arrow.move(to: first)
        for point in points.dropFirst() { arrow.line(to: point) }
        arrow.close()
        arrow.fill()
    }
}
