import AppKit

/// 拖拽框选层。两种用法：
/// 1. `beginFreeCapture` —— 铺满所有显示器，框选 → 标注 → 回车抓图（手动截图主力路径）
/// 2. `begin(over:)`     —— 盖在某个窗口上，框出的区域存成该窗口的归一化预设
final class RegionSelector {
    static let shared = RegionSelector()
    /// 每块屏幕一个窗口。单个 NSWindow 横跨多块显示器时，只能拥有一个 Space、
    /// screen 和 backingScaleFactor，在混合 Retina 双屏下会导致部分屏幕无法交互。
    private var overlays: [OverlayWindow] = []

    private init() {}

    var isActive: Bool { !overlays.isEmpty }

    // MARK: - 全屏自由框选，可标注，回车抓图

    func beginFreeCapture(completion: @escaping (CGImage?) -> Void) {
        guard overlays.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        for screen in screens {
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.showsCrosshair = true
            view.allowsAnnotation = true
            let window = present(view: view, frame: screen.frame, activate: false)

            view.onFinish = { [weak self, weak window] result in
                guard let self = self else { return }
                guard let (rect, annotations) = result, let window = window else {
                    self.dismiss()
                    completion(nil)
                    return
                }

                // 必须在关掉覆盖层**之前**抓：optionOnScreenBelowWindow 只抓我们这层
                // 底下的内容，压暗、选框、工具栏都不会进到图里。
                let cgRect = Geometry.screenLocalToCG(rect, on: screen).integral
                let shot = CGWindowListCreateImage(cgRect,
                                                   .optionOnScreenBelowWindow,
                                                   CGWindowID(window.windowNumber),
                                                   [.bestResolution])
                self.dismiss()

                guard let shot = shot else {
                    completion(nil)
                    return
                }
                // 标注没进截图，在这里按当前屏幕的实际倍率重画一遍合成上去。
                completion(AnnotationRenderer.render(annotations, onto: shot, selection: rect))
            }
        }

        // 主屏先获得键盘焦点；点击其他屏幕的覆盖层后会自然切换 key window。
        if let primaryWindow = overlays.first {
            primaryWindow.makeKeyAndOrderFront(nil)
            primaryWindow.makeFirstResponder(primaryWindow.contentView)
        }
    }

    // MARK: - 盖在指定窗口上，存区域预设

    /// cgBounds 是目标窗口的全局左上原点矩形；回调给出从窗口四边内缩的点数
    func begin(over cgBounds: CGRect, completion: @escaping (CropInsets?) -> Void) {
        guard overlays.isEmpty else { return }

        let frame = Geometry.cgToNS(cgBounds)
        let view = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
        view.hint = "拖拽框出要保留的图表区域 · Esc 取消"
        view.confirmHint = "回车保存预设 · 拖动边角调整 · 框外重新拖拽可重选 · Esc 取消"
        present(view: view, frame: frame)

        view.onFinish = { [weak self] result in
            guard let self = self else { return }
            self.dismiss()

            guard let (rect, _) = result, frame.width > 0, frame.height > 0 else {
                completion(nil)
                return
            }
            // SelectionView 是 flipped 的，rect 已是左上原点，直接换算成四边内缩点数
            let insets = CropInsets(top: Double(rect.minY),
                                    left: Double(rect.minX),
                                    bottom: Double(frame.height - rect.maxY),
                                    right: Double(frame.width - rect.maxX))
            completion(insets.isZero ? nil : insets)
        }
    }

    // MARK: - 覆盖层生命周期

    @discardableResult
    private func present(view: SelectionView, frame: CGRect, activate: Bool = true) -> OverlayWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view

        overlays.append(window)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        } else {
            window.orderFrontRegardless()
        }
        return window
    }

    private func dismiss() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 框选 + 标注视图

private final class SelectionView: NSView, NSTextFieldDelegate {
    /// 回调带上标注数据；nil 表示取消
    var onFinish: (((CGRect, [Annotation]))?) -> Void = { _ in }
    var showsCrosshair = false
    var allowsAnnotation = false
    var hint = "拖拽框选区域 · Esc 取消"
    var confirmHint = "回车截图 · 拖动边角调整 · 框外重新拖拽可重选 · Esc 取消"

    private enum Phase { case idle, creating, adjusting }
    private enum Grip {
        case none, move
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private enum ToolbarItem {
        case tool(AnnotationTool), color, undo, done
    }

    private var phase: Phase = .idle
    private var selection: CGRect?
    private var anchor: CGPoint?
    private var cursor: CGPoint?
    private var grip: Grip = .none
    private var gripOrigin: CGPoint = .zero
    private var gripStartRect: CGRect = .zero
    private var tracking: NSTrackingArea?

    // 标注
    private var tool: AnnotationTool = .select
    private var annotations: [Annotation] = []
    private var pending: Annotation?          // 正在拖的那个
    private var drawStart: CGPoint?
    private var textField: NSTextField?
    private var textAnchor: CGPoint?
    private var colorIndex = 0
    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    private var color: NSColor { palette[colorIndex % palette.count] }
    private let lineWidth: CGFloat = 3
    private let fontSize: CGFloat = 18

    private var toolbarButtons: [(ToolbarItem, CGRect)] = []

    private let handleSize: CGFloat = 8
    private let handleSlop: CGFloat = 10
    private let minSide: CGFloat = 8

    /// 翻转成左上原点：和 CGImage、CG 全局坐标一致，省掉一次换算
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: 命中判定

    private func handleRects(for rect: CGRect) -> [(Grip, CGRect)] {
        let h = handleSlop
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - h / 2, y: y - h / 2, width: h, height: h)
        }
        return [
            (.topLeft,     box(rect.minX, rect.minY)),
            (.top,         box(rect.midX, rect.minY)),
            (.topRight,    box(rect.maxX, rect.minY)),
            (.right,       box(rect.maxX, rect.midY)),
            (.bottomRight, box(rect.maxX, rect.maxY)),
            (.bottom,      box(rect.midX, rect.maxY)),
            (.bottomLeft,  box(rect.minX, rect.maxY)),
            (.left,        box(rect.minX, rect.midY))
        ]
    }

    private func grip(at point: CGPoint) -> Grip {
        // 只有选择工具才能调整选区，否则拖拽是在画标注
        guard phase == .adjusting, tool == .select, let rect = selection else { return .none }
        for (g, box) in handleRects(for: rect) where box.contains(point) { return g }
        return rect.contains(point) ? .move : .none
    }

    private func toolbarHit(_ p: CGPoint) -> ToolbarItem? {
        for (item, rect) in toolbarButtons where rect.contains(p) { return item }
        return nil
    }

    private func applyCursor(at p: CGPoint) {
        if toolbarHit(p) != nil { NSCursor.arrow.set(); return }
        if tool != .select { NSCursor.crosshair.set(); return }
        switch grip(at: p) {
        case .none: NSCursor.crosshair.set()
        case .move: NSCursor.openHand.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
        }
    }

    // MARK: 鼠标

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        applyCursor(at: p)
        if showsCrosshair || phase == .adjusting { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        commitTextIfEditing()

        if let item = toolbarHit(p) {
            handleToolbar(item)
            return
        }

        if event.clickCount == 2, phase == .adjusting, tool == .select,
           selection?.contains(p) == true {
            confirm()
            return
        }

        // 标注工具：在选区内按下开始画
        if phase == .adjusting, tool != .select, let sel = selection, sel.contains(p) {
            if tool == .text {
                beginTextEntry(at: p)
            } else {
                drawStart = p
            }
            return
        }

        let g = grip(at: p)
        if g != .none, let rect = selection {
            grip = g
            gripOrigin = p
            gripStartRect = rect
            if g == .move { NSCursor.closedHand.set() }
            return
        }

        // 标注工具激活时，框外点击不做任何事——否则手抖一下标注全没了，
        // 要重框先切回选择工具
        if phase == .adjusting, tool != .select { return }

        // 框外按下：重新开始画选区（标注一并清掉，因为坐标基准变了）
        phase = .creating
        anchor = p
        selection = nil
        annotations.removeAll()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p

        if let start = drawStart, let sel = selection {
            let q = CGPoint(x: min(max(p.x, sel.minX), sel.maxX),
                            y: min(max(p.y, sel.minY), sel.maxY))
            switch tool {
            case .rect:
                let r = CGRect(x: min(start.x, q.x), y: min(start.y, q.y),
                               width: abs(q.x - start.x), height: abs(q.y - start.y))
                pending = Annotation(kind: .rect(r), color: color,
                                     lineWidth: lineWidth, fontSize: fontSize)
            case .arrow:
                pending = Annotation(kind: .arrow(from: start, to: q), color: color,
                                     lineWidth: lineWidth, fontSize: fontSize)
            default: break
            }
            needsDisplay = true
            return
        }

        if grip != .none {
            selection = resized(gripStartRect, grip: grip,
                                by: CGPoint(x: p.x - gripOrigin.x, y: p.y - gripOrigin.y))
            needsDisplay = true
            return
        }

        guard phase == .creating, let anchor = anchor else { return }
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drawStart != nil {
            drawStart = nil
            if let a = pending {
                // 太短的箭头/太小的框当误触丢掉
                if isMeaningful(a) { annotations.append(a) }
                pending = nil
            }
            needsDisplay = true
            return
        }

        if grip != .none {
            grip = .none
            applyCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        defer { anchor = nil }
        // 太小的当误触：清掉选区回到初始态，而不是取消整个操作
        guard let rect = selection, rect.width > 4, rect.height > 4 else {
            selection = nil
            phase = .idle
            needsDisplay = true
            return
        }
        phase = .adjusting
        needsDisplay = true
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        switch a.kind {
        case .rect(let r): return r.width > 3 && r.height > 3
        case .arrow(let f, let t): return hypot(t.x - f.x, t.y - f.y) > 8
        case .text(let s, _): return !s.isEmpty
        }
    }

    /// 按住的控制点决定改哪条边；拖过头会自动翻转，最后归位
    private func resized(_ rect: CGRect, grip: Grip, by d: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        switch grip {
        case .move:
            var moved = rect.offsetBy(dx: d.x, dy: d.y)
            moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
            return moved
        case .topLeft:     minX += d.x; minY += d.y
        case .top:         minY += d.y
        case .topRight:    maxX += d.x; minY += d.y
        case .right:       maxX += d.x
        case .bottomRight: maxX += d.x; maxY += d.y
        case .bottom:      maxY += d.y
        case .bottomLeft:  minX += d.x; maxY += d.y
        case .left:        minX += d.x
        case .none:        break
        }

        let r = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY))
        return r.intersection(bounds)
    }

    // MARK: 工具栏

    private func handleToolbar(_ item: ToolbarItem) {
        switch item {
        case .tool(let t): tool = t
        case .color: colorIndex = (colorIndex + 1) % palette.count
        case .undo: if !annotations.isEmpty { annotations.removeLast() }
        case .done: confirm()
        }
        needsDisplay = true
    }

    /// 工具栏默认贴在选区下方，下方放不下就翻到上方，再放不下就贴进选区内
    private func layoutToolbar(for rect: CGRect) {
        guard allowsAnnotation, phase == .adjusting else {
            toolbarButtons = []
            return
        }
        let bw: CGFloat = 38, bh: CGFloat = 30, gap: CGFloat = 2, pad: CGFloat = 6
        let items: [ToolbarItem] = [
            .tool(.select), .tool(.rect), .tool(.arrow), .tool(.text),
            .color, .undo, .done
        ]
        let total = CGFloat(items.count) * bw + CGFloat(items.count - 1) * gap + pad * 2
        let barH = bh + pad * 2

        var x = rect.midX - total / 2
        x = min(max(x, bounds.minX + 8), bounds.maxX - total - 8)

        var y = rect.maxY + 10
        if y + barH > bounds.maxY { y = rect.minY - barH - 10 }
        if y < bounds.minY { y = rect.maxY - barH - 10 }

        toolbarBar = CGRect(x: x, y: y, width: total, height: barH)
        toolbarButtons = items.enumerated().map { i, item in
            (item, CGRect(x: x + pad + CGFloat(i) * (bw + gap),
                          y: y + pad, width: bw, height: bh))
        }
    }

    private var toolbarBar: CGRect = .zero

    // MARK: 文本输入

    private func beginTextEntry(at p: CGPoint) {
        commitTextIfEditing()
        let tf = NSTextField(frame: CGRect(x: p.x, y: p.y, width: 220, height: fontSize + 10))
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        tf.textColor = color
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tf.focusRingType = .none
        tf.delegate = self
        tf.placeholderString = "输入文字，回车确认"
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        textAnchor = p
    }

    private func commitTextIfEditing() {
        guard let tf = textField, let at = textAnchor else { return }
        let s = tf.stringValue
        tf.removeFromSuperview()
        textField = nil
        textAnchor = nil
        window?.makeFirstResponder(self)
        guard !s.isEmpty else { return }
        // NSTextField 内部有约 2 点内边距，补偿一下让预览和成图对齐
        annotations.append(Annotation(kind: .text(s, at: CGPoint(x: at.x + 2, y: at.y + 4)),
                                      color: color, lineWidth: lineWidth, fontSize: fontSize))
        needsDisplay = true
    }

    private func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        textAnchor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitTextIfEditing()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    // MARK: 键盘

    override func cancelOperation(_ sender: Any?) {
        onFinish(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 6 {   // ⌘Z
            if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
            return
        }

        switch event.keyCode {
        case 53:                      // Esc
            onFinish(nil)
        case 36, 76:                  // Return / 小键盘 Enter
            confirm()
        case 123, 124, 125, 126:      // 方向键微调
            nudge(keyCode: event.keyCode,
                  step: event.modifierFlags.contains(.shift) ? 10 : 1,
                  resize: event.modifierFlags.contains(.option))
        case 9, 18:  selectTool(.select)   // V / 1
        case 15, 19: selectTool(.rect)     // R / 2
        case 0, 20:  selectTool(.arrow)    // A / 3
        case 17, 21: selectTool(.text)     // T / 4
        case 8:                            // C 换颜色
            colorIndex = (colorIndex + 1) % palette.count
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    private func selectTool(_ t: AnnotationTool) {
        guard allowsAnnotation, phase == .adjusting else { return }
        tool = t
        needsDisplay = true
    }

    /// 默认整体移动；按住 Option 是改右下角，用于精修尺寸
    private func nudge(keyCode: UInt16, step: CGFloat, resize: Bool) {
        guard phase == .adjusting, var rect = selection else { return }
        var d = CGPoint.zero
        switch keyCode {
        case 123: d.x = -step
        case 124: d.x = step
        case 125: d.y = step
        case 126: d.y = -step
        default: break
        }
        if resize {
            rect.size.width = max(minSide, rect.width + d.x)
            rect.size.height = max(minSide, rect.height + d.y)
        } else {
            rect = rect.offsetBy(dx: d.x, dy: d.y)
        }
        selection = rect.intersection(bounds)
        needsDisplay = true
    }

    private func confirm() {
        commitTextIfEditing()
        guard phase == .adjusting, let rect = selection,
              rect.width >= minSide, rect.height >= minSide else { return }
        onFinish((rect.intersection(bounds), annotations))
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }

        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selection else {
            if showsCrosshair, let c = cursor { drawCrosshair(at: c) }
            drawLabel(hint, at: CGPoint(x: bounds.midX - 110, y: bounds.midY - 14))
            return
        }

        // 在压暗层上挖出选区，让下面的内容原样可见
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        rect.fill()
        ctx.restoreGraphicsState()

        // 标注预览（最终成图由 AnnotationRenderer 按 Retina 倍率重画）
        ctx.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for a in annotations { drawAnnotation(a) }
        if let p = pending { drawAnnotation(p) }
        ctx.restoreGraphicsState()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()

        if phase == .adjusting, tool == .select { drawHandles(for: rect) }

        // 标注实际抓到的像素数（Retina 屏是逻辑尺寸的 2 倍）
        let scale = window?.backingScaleFactor ?? 1
        let size = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let labelY = rect.minY > 26 ? rect.minY - 24 : rect.maxY + 4
        drawLabel(size, at: CGPoint(x: rect.minX, y: labelY))

        if phase == .adjusting {
            layoutToolbar(for: rect)
            drawToolbar()
            if !allowsAnnotation {
                drawLabel(confirmHint, at: CGPoint(x: bounds.midX - 180, y: bounds.maxY - 44))
            }
        }
    }

    private func drawAnnotation(_ a: Annotation) {
        a.color.setStroke()
        a.color.setFill()
        switch a.kind {
        case .rect(let r):
            let p = NSBezierPath(rect: r)
            p.lineWidth = a.lineWidth
            p.stroke()
        case .arrow(let f, let t):
            AnnotationRenderer.drawArrow(from: f, to: t, lineWidth: a.lineWidth)
        case .text(let s, let at):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
                .foregroundColor: a.color
            ]
            NSAttributedString(string: s, attributes: attrs).draw(at: at)
        }
    }

    private func drawToolbar() {
        guard !toolbarButtons.isEmpty else { return }

        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: toolbarBar, xRadius: 8, yRadius: 8).fill()

        for (item, r) in toolbarButtons {
            var active = false
            if case .tool(let t) = item, t == tool { active = true }
            if active {
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            drawToolbarIcon(item, in: r)
        }
    }

    private func drawToolbarIcon(_ item: ToolbarItem, in r: CGRect) {
        let c = NSColor.white
        c.setStroke()
        c.setFill()
        let box = r.insetBy(dx: 11, dy: 8)

        switch item {
        case .tool(.select):
            // 简化的指针三角
            let p = NSBezierPath()
            p.move(to: CGPoint(x: box.minX + 2, y: box.minY))
            p.line(to: CGPoint(x: box.minX + 2, y: box.maxY))
            p.line(to: CGPoint(x: box.midX + 1, y: box.midY + 2))
            p.close()
            p.fill()
        case .tool(.rect):
            let p = NSBezierPath(rect: box)
            p.lineWidth = 1.5
            p.stroke()
        case .tool(.arrow):
            AnnotationRenderer.drawArrow(from: CGPoint(x: box.minX, y: box.maxY),
                                         to: CGPoint(x: box.maxX, y: box.minY),
                                         lineWidth: 1.5)
        case .tool(.text):
            drawGlyph("T", in: r, size: 15, weight: .bold)
        case .color:
            color.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1))
            ring.lineWidth = 1
            ring.stroke()
        case .undo:
            drawGlyph("↩", in: r, size: 16, weight: .medium)
        case .done:
            drawGlyph("✓", in: r, size: 16, weight: .bold)
        }
    }

    private func drawGlyph(_ s: String, in r: CGRect, size: CGFloat, weight: NSFont.Weight) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    private func drawHandles(for rect: CGRect) {
        for (_, slop) in handleRects(for: rect) {
            let box = CGRect(x: slop.midX - handleSize / 2, y: slop.midY - handleSize / 2,
                             width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: box)
            p.fill()
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func drawCrosshair(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: p.x, y: 0))
        path.line(to: CGPoint(x: p.x, y: bounds.maxY))
        path.move(to: CGPoint(x: 0, y: p.y))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y))
        path.stroke()
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        let box = CGRect(x: point.x, y: point.y,
                         width: size.width + 12, height: size.height + 6)

        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }
}
