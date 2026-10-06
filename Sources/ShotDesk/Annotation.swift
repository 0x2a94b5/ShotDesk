import AppKit

enum AnnotationTool {
    case select, rect, arrow, text
}

struct Annotation {
    enum Kind {
        case rect(CGRect)                          // 视图坐标（左上原点）
        case arrow(from: CGPoint, to: CGPoint)
        case text(String, at: CGPoint)             // at = 文字左上角
    }
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
}

/// 把标注合成到抓下来的图上。
/// 覆盖层的内容不会进到截图里（抓的是覆盖层**底下**的画面），
/// 所以标注必须在这里重画一遍——好处是能按 Retina 倍率画，线条是清晰的矢量结果。
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

        // 视图是左上原点，位图是左下原点，这里做一次显式换算。
        // 不翻转 CTM 的原因：AppKit 文字绘制看的是上下文的 flipped 标志而不是 CTM，
        // 翻了 CTM 文字会上下颠倒。
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
                // map 给的是文字左上角在位图里的位置，draw(at:) 要的是左下角
                str.draw(at: CGPoint(x: origin.x, y: origin.y - str.size().height))
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? image
    }

    /// 箭头 = 一条线 + 实心三角箭头。箭头大小跟着线宽走，细线配小头才协调。
    static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 1 else { return }

        let angle = atan2(dy, dx)
        let headLength = min(max(lineWidth * 4, 10), length * 0.5)
        let headAngle: CGFloat = .pi / 7

        // 线画到箭头根部就停，避免线头从三角形里透出来
        let shaftEnd = CGPoint(x: to.x - cos(angle) * headLength * 0.85,
                               y: to.y - sin(angle) * headLength * 0.85)
        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: CGPoint(x: to.x - cos(angle - headAngle) * headLength,
                              y: to.y - sin(angle - headAngle) * headLength))
        head.line(to: CGPoint(x: to.x - cos(angle + headAngle) * headLength,
                              y: to.y - sin(angle + headAngle) * headLength))
        head.close()
        head.fill()
    }
}
