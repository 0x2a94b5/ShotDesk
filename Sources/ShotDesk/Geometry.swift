import AppKit

enum Geometry {
    /// CGWindow bounds use a global top-left origin; NSWindow and NSScreen use a
    /// bottom-left origin. Conversion must use the primary screen's height.
    static func cgToNS(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.origin.x,
                      y: primary.frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    /// Reverse conversion. The same formula applies because the transform is
    /// self-inverse.
    static func nsToCG(_ rect: CGRect) -> CGRect {
        cgToNS(rect)
    }

    /// Converts top-left-origin coordinates in a screen overlay to global CG
    /// coordinates. Each display needs its own overlay because one NSWindow
    /// cannot span different Spaces and backing scale factors reliably.
    static func screenLocalToCG(_ rect: CGRect,
                                screenFrame: CGRect,
                                primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX,
               y: primaryMaxY - screenFrame.maxY + rect.minY,
               width: rect.width,
               height: rect.height)
    }

    static func screenLocalToCG(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return screenLocalToCG(rect,
                               screenFrame: screen.frame,
                               primaryMaxY: primary.frame.maxY)
    }

    /// Maps logical point coordinates to pixel coordinates in that display's
    /// frozen background. x and y use their actual image scale independently.
    static func screenLocalToImagePixels(_ rect: CGRect,
                                         screenSize: CGSize,
                                         imageSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }
        let scaleX = imageSize.width / screenSize.width
        let scaleY = imageSize.height / screenSize.height
        let pixels = CGRect(x: rect.minX * scaleX,
                            y: rect.minY * scaleY,
                            width: rect.width * scaleX,
                            height: rect.height * scaleY).integral
        return pixels.intersection(CGRect(origin: .zero, size: imageSize))
    }
}
