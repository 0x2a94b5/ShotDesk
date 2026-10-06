import AppKit

enum Geometry {
    /// CGWindow 的 bounds 是全局左上原点，NSWindow/NSScreen 是左下原点。
    /// 换算基准必须是主屏（NSScreen.screens[0]）的高度，不是当前屏。
    static func cgToNS(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.origin.x,
                      y: primary.frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    /// 反向换算。公式和 cgToNS 相同（这个变换是自逆的）。
    static func nsToCG(_ rect: CGRect) -> CGRect {
        cgToNS(rect)
    }

    /// 将某块屏幕覆盖层里的左上原点坐标换成 CG 全局坐标。
    ///
    /// 每块屏幕必须使用独立覆盖窗口，不能用一个 NSWindow 横跨不同 Space 和
    /// backingScaleFactor 的显示器。把纯计算单独保留，方便覆盖各种屏幕排列测试。
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
}
