import AppKit

/// Drag-selection overlay with two modes:
/// 1. `beginFreeCapture`: cover all displays, select, annotate, and capture.
/// 2. `begin(over:)`: cover one window and save its selected area as a normalized preset.
final class RegionSelector {
    static let shared = RegionSelector()
    /// One window per display. A single NSWindow spanning displays has only one
    /// Space, screen, and backing scale factor, which breaks interaction on mixed-DPI setups.
    private var overlays: [OverlayWindow] = []

    private init() {}

    var isActive: Bool { !overlays.isEmpty }

    // MARK: - Free-region capture with annotations

    func beginFreeCapture(completion: @escaping (CGImage?) -> Void) {
        guard overlays.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(nil)
            return
        }

        // Freeze every display as the first action after the hot key. Transient UI
        // such as TradingView date tooltips can dismiss on focus loss.
        let snapshots = screens.compactMap { screen -> (screen: NSScreen, image: CGImage)? in
            let fullRect = Geometry.screenLocalToCG(
                CGRect(origin: .zero, size: screen.frame.size), on: screen
            ).integral
            guard let image = CGWindowListCreateImage(fullRect,
                                                      .optionOnScreenOnly,
                                                      kCGNullWindowID,
                                                      [.bestResolution]) else {
                return nil
            }
            return (screen, image)
        }
        guard snapshots.count == screens.count else {
            completion(nil)
            return
        }

        for snapshot in snapshots {
            let screen = snapshot.screen
            let backdrop = snapshot.image
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.showsCrosshair = true
            view.allowsAnnotation = true
            view.backdrop = NSImage(cgImage: backdrop, size: screen.frame.size)
            _ = present(view: view, frame: screen.frame, activate: false)

            view.onFinish = { [weak self] result in
                guard let self = self else { return }
                guard let (rect, annotations) = result else {
                    self.dismiss()
                    completion(nil)
                    return
                }

                // Crop the background frozen at hot-key time instead of capturing now.
                // This preserves transient UI and guarantees the ShotDesk overlay is absent.
                let pixelRect = Geometry.screenLocalToImagePixels(
                    rect, screenSize: screen.frame.size,
                    imageSize: CGSize(width: backdrop.width, height: backdrop.height)
                )
                let shot = backdrop.cropping(to: pixelRect)
                self.dismiss()

                guard let shot = shot else {
                    completion(nil)
                    return
                }
                // Annotations are absent from the background and are composited at
                // the display's actual scale here.
                completion(AnnotationRenderer.render(annotations, onto: shot, selection: rect))
            }
        }

        // Give the primary-display overlay keyboard focus first; clicking another
        // display's overlay naturally makes it key.
        if let primaryWindow = overlays.first {
            primaryWindow.makeKeyAndOrderFront(nil)
            primaryWindow.makeFirstResponder(primaryWindow.contentView)
        }
    }

    // MARK: - Save a crop preset over a specific window

    /// `cgBounds` is the target's global top-left-origin rectangle. The callback
    /// returns point insets from each window edge.
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
            // SelectionView is flipped, so `rect` already uses a top-left origin.
            let insets = CropInsets(top: Double(rect.minY),
                                    left: Double(rect.minX),
                                    bottom: Double(frame.height - rect.maxY),
                                    right: Double(frame.width - rect.maxX))
            completion(insets.isZero ? nil : insets)
        }
    }

    // MARK: - Overlay lifecycle

    @discardableResult
    private func present(view: SelectionView, frame: CGRect, activate: Bool = true) -> OverlayWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view

        overlays.append(window)
        if activate {
            window.orderFrontRegardless()
            window.makeKey()
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

/// Receives mouse and keyboard input without activating ShotDesk, preventing
/// transient menus and popovers from dismissing when the source app loses focus.
private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection and annotation view

private final class SelectionView: NSView, NSTextFieldDelegate {
    /// Returns annotation data; nil means cancellation.
    var onFinish: (((CGRect, [Annotation]))?) -> Void = { _ in }
    var showsCrosshair = false
    var allowsAnnotation = false
    /// A snapshot from hot-key time. It shows a frozen background and preserves
    /// transient UI that would otherwise disappear immediately.
    var backdrop: NSImage?
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

    // Annotations
    private var tool: AnnotationTool = .select
    private var annotations: [Annotation] = []
    private var pending: Annotation?          // Annotation currently being dragged.
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

    /// Use a top-left origin to align with CGImage and global CG coordinates.
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

    // MARK: - Hit testing

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
        // Only the Select tool adjusts a selection; other tools draw annotations.
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

    // MARK: - Mouse handling

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

        // An annotation tool starts drawing only inside the selection.
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

        // Ignore clicks outside the selection while an annotation tool is active;
        // switch back to Select before drawing a new selection.
        if phase == .adjusting, tool != .select { return }

        // A click outside starts a new selection and clears annotations because
        // their coordinate basis has changed.
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
                // Discard accidental, extremely short arrows and tiny rectangles.
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
        // Treat an undersized selection as an accidental drag and return to idle.
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

    /// The selected handle determines the edge to move. Crossing over flips the
    /// rectangle and normalizes it afterward.
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

    // MARK: - Toolbar

    private func handleToolbar(_ item: ToolbarItem) {
        switch item {
        case .tool(let t): tool = t
        case .color: colorIndex = (colorIndex + 1) % palette.count
        case .undo: if !annotations.isEmpty { annotations.removeLast() }
        case .done: confirm()
        }
        needsDisplay = true
    }

    /// Prefer below the selection, then above it, then inside it when space is limited.
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

    // MARK: - Text input

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
        // NSTextField has roughly a 2-point inner inset; compensate so preview and
        // final output align.
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

    // MARK: - Keyboard handling

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
        case 36, 76:                  // Return / keypad Enter
            confirm()
        case 123, 124, 125, 126:      // Arrow-key nudging
            nudge(keyCode: event.keyCode,
                  step: event.modifierFlags.contains(.shift) ? 10 : 1,
                  resize: event.modifierFlags.contains(.option))
        case 9, 18:  selectTool(.select)   // V / 1
        case 15, 19: selectTool(.rect)     // R / 2
        case 0, 20:  selectTool(.arrow)    // A / 3
        case 17, 21: selectTool(.text)     // T / 4
        case 8:                            // C cycles color
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

    /// Moves the entire selection by default; Option adjusts its bottom-right
    /// corner for fine size changes.
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }

        backdrop?.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selection else {
            if showsCrosshair, let c = cursor { drawCrosshair(at: c) }
            drawLabel(hint, at: CGPoint(x: bounds.midX - 110, y: bounds.midY - 14))
            return
        }

        // Restore the selected region from the frozen background over the dimming
        // layer. Fall back to a transparent cutout without a background.
        if let backdrop = backdrop {
            ctx.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            backdrop.draw(in: bounds)
            ctx.restoreGraphicsState()
        } else {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .clear
            rect.fill()
            ctx.restoreGraphicsState()
        }

        // Annotation preview; AnnotationRenderer redraws the final image at Retina scale.
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

        // Display the actual captured pixel size (twice the logical size on Retina).
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
            // Simplified pointer triangle.
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
