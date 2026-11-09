import AppKit
import CoreText
import QuartzCore

final class CanvasView: NSView {
    var presentation: Presentation?
    var slide: Slide?
    var onWillEdit: (() -> Void)?
    var onChanged: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onExit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var objectMenu: NSMenu?
    let surface = SlideSurface()
    var objectViews: [ObjectView] = []
    /// Editing aid only: numbered badges for Fade order. Never shown while presenting and never saved.
    var showsOrderBadges = false
    /// Main canvas and thumbnails may follow night mode; the presentation player never does.
    var usesNightMode = false
    var nightActive: Bool { usesNightMode && NightMode.isOn && !presenting }
    var onReorderFade: ((Int) -> Void)?
    var onJumpSlide: ((Int) -> Void)?
    private var badgeViews: [OrderBadgeView] = []
    private(set) var selection: [SlideItem] = []
    var selected: SlideItem? {
        get { selection.count == 1 ? selection.first : nil }
        set { select(newValue.map { [$0] } ?? []) }
    }
    /// The objects that are selected together with `item`: all cells of its table, or the object itself.
    func members(of item: SlideItem) -> [SlideItem] {
        guard let id = item.tableID, let slide else { return [item] }
        return slide.items.filter { $0.tableID == id }
    }
    /// ⌘A on the slide: selects every movable object.
    override func selectAll(_ sender: Any?) {
        guard !presenting, editor == nil, let slide else { return }
        select(slide.items.filter(\.canMove))
    }
    func select(_ items: [SlideItem]) {
        selection = items
        updateSelection()
    }
    var editor: InlineTextView?
    var presenting = false
    var fadeSteps: [[(NSView, Double)]] = []
    var step = 0
    private var dragOrigin: CGPoint?
    private var dragItem: SlideItem?
    private var dragFrames: [ObjectIdentifier: CGRect] = [:]
    private var pendingCollapse: SlideItem?
    private var originalFrame = CGRect.zero
    private var resizeCorner: CGPoint?
    private var marqueeStart: CGPoint?
    private var marqueeBase: [SlideItem] = []
    /// Editing zoom (pinch on the trackpad). 1 fits the slide to the window; it never changes the file.
    private(set) var zoom: CGFloat = 1
    private var panOffset = CGPoint.zero
    private var surfaceScale: CGFloat { max(0.01, surface.frame.width / max(1, surface.bounds.width)) }
    private var editedDrag = false
    /// Selection outline, handles and marquee are drawn by one transparent view kept above every object.
    private let overlay = SelectionOverlay()
    private var caretTimer: Timer?
    private var caretObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        clipsToBounds = true   // a zoomed slide must never spill over the sidebar or the toolbar
        surface.wantsLayer = true; surface.canvas = self
        addSubview(surface)
        surface.addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
    /// Pinch: zoom around the pointer so the point under it stays put.
    override func magnify(with event: NSEvent) {
        guard !presenting, presentation != nil else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        let oldFrame = surface.frame
        let newZoom = min(8, max(0.4, zoom * (1 + event.magnification)))
        guard newZoom != zoom else { return }
        let ratio = newZoom / zoom
        // New origin keeps the slide point under the pointer fixed.
        let newOrigin = CGPoint(x: pointer.x - (pointer.x - oldFrame.minX) * ratio, y: pointer.y - (pointer.y - oldFrame.minY) * ratio)
        zoom = newZoom
        let size = CGSize(width: oldFrame.width * ratio, height: oldFrame.height * ratio)
        panOffset = CGPoint(x: newOrigin.x - (bounds.width - size.width) / 2, y: newOrigin.y - (bounds.height - size.height) / 2)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    /// Two-finger scroll moves the slide while zoomed in.
    override func scrollWheel(with event: NSEvent) {
        guard !presenting, zoom > 1 else { super.scrollWheel(with: event); return }
        panOffset.x += event.scrollingDeltaX; panOffset.y += event.scrollingDeltaY
        needsLayout = true
    }
    var guideCount: Int { overlay.guides.count }
    func resetZoom() { zoom = 1; panOffset = .zero; needsLayout = true }
    override func layout() {
        super.layout()
        guard let presentation else { surface.isHidden = true; return }
        surface.isHidden = false
        let margin: CGFloat = presenting ? 0 : 28
        let scale = max(0.01, min((bounds.width - margin * 2) / presentation.size.width, (bounds.height - margin * 2) / presentation.size.height))
        let effectiveZoom = presenting ? 1 : zoom
        let size = CGSize(width: presentation.size.width * scale * effectiveZoom, height: presentation.size.height * scale * effectiveZoom)
        if zoom > 1 {   // keep at least part of the slide reachable
            let limitX = (size.width + bounds.width) / 2 - 80, limitY = (size.height + bounds.height) / 2 - 80
            panOffset.x = min(max(panOffset.x, -limitX), limitX); panOffset.y = min(max(panOffset.y, -limitY), limitY)
        }
        let pan = presenting || zoom <= 1 ? CGPoint.zero : panOffset
        surface.frame = CGRect(x: (bounds.width - size.width) / 2 + pan.x, y: (bounds.height - size.height) / 2 + pan.y, width: size.width, height: size.height)
        surface.bounds = CGRect(origin: .zero, size: presentation.size)
        updateSelection()
        updateOrderBadges()
        if editor != nil { updateCaret(restartBlink: false) }
    }
    func display(_ slide: Slide, in presentation: Presentation, presenting: Bool = false) {
        finishEditing(commit: true)
        endMarquee()
        self.presentation = presentation; self.slide = slide; self.presenting = presenting
        selected = nil
        rebuild(); needsLayout = true; needsDisplay = true
    }
    func rebuild() {
        guard let presentation, let slide else { return }
        objectViews.forEach { $0.removeFromSuperview() }; objectViews = []
        fadeSteps = []; step = 0
        surface.color = slide.background; surface.needsDisplay = true
        for item in slide.items {
            let view = ObjectView(item: item, presentation: presentation, canvas: self)
            objectViews.append(view); surface.addSubview(view)
        }
        updateOrderBadges()
        // The selection border must stay above object layers.
        raiseOverlay()
        if presenting {
            let views = Dictionary(uniqueKeysWithValues: objectViews.map { (ObjectIdentifier($0.item), $0) })
            fadeSteps = slide.fadeSequence.map { step in
                step.compactMap { entry -> (NSView, Double)? in
                    guard let object = views[ObjectIdentifier(entry.item)] else { return nil }
                    let view: NSView
                    if let paragraph = entry.paragraph,
                       let index = entry.item.paragraphs.firstIndex(where: { $0.xmlIndex == paragraph }) {
                        view = object.paragraphViews[index]
                    } else { view = object }
                    view.alphaValue = 0
                    return (view, entry.item.fadeDuration(for: entry.paragraph))
                }
            }
        }
        updateSelection()
    }
    private func resizeCorners(for item: SlideItem) -> [CGPoint] {
        let lowerRight = CGPoint(x: item.frame.maxX, y: item.frame.maxY)
        guard item.imageURL != nil else { return [lowerRight] }
        return [
            CGPoint(x: item.frame.minX, y: item.frame.minY),
            CGPoint(x: item.frame.maxX, y: item.frame.minY),
            CGPoint(x: item.frame.minX, y: item.frame.maxY),
            lowerRight
        ]
    }
    private func resizeHandle(at point: CGPoint, for item: SlideItem) -> CGPoint? {
        let radius: CGFloat = (item.imageURL == nil ? 6 : 10) / surfaceScale
        return resizeCorners(for: item)
            .filter { abs(point.x - $0.x) <= radius && abs(point.y - $0.y) <= radius }
            .min { hypot(point.x - $0.x, point.y - $0.y) < hypot(point.x - $1.x, point.y - $1.y) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, !presenting, editor == nil, let selected, selected.imageURL != nil,
           resizeHandle(at: surface.convert(point, from: superview), for: selected) != nil,
           let view = objectViews.first(where: { $0.item === selected }) { return view }
        return hit
    }
    override func mouseDown(with event: NSEvent) {
        if slide == nil {
            if event.clickCount == 2 { onOpenFile?() }
        } else { backgroundClick(event) }
    }
    override func mouseDragged(with event: NSEvent) { updateMarquee(event) }
    override func mouseUp(with event: NSEvent) { endMarquee() }
    func updateOrderBadges() {
        badgeViews.forEach { $0.removeFromSuperview() }; badgeViews = []
        guard showsOrderBadges, !presenting, let slide else { return }
        let diameter = 20 / surfaceScale
        for (number, group) in slide.fadeGroups.enumerated() {
            let grouped = group.count > 1
            let width = grouped ? diameter * 1.9 : diameter
            for item in group {
                let badge = OrderBadgeView(number: number + 1, grouped: grouped)
                var frame = CGRect(x: item.frame.maxX + diameter * 0.5 - width, y: item.frame.minY - diameter * 0.5, width: width, height: diameter)
                // Badges of objects that start at nearly the same corner would pile up: slide each one left of the others.
                while badgeViews.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).intersects(frame) }) { frame.origin.x -= width + 2 }
                badge.frame = frame
                surface.addSubview(badge); badgeViews.append(badge)
            }
        }
        raiseOverlay()
    }
    /// Keeps the selection overlay above every object, badge and editor, whatever their stacking order.
    private func raiseOverlay() {
        overlay.frame = surface.bounds
        surface.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.needsDisplay = true
    }
    func updateSelection() {
        let scale = surfaceScale
        if !selection.isEmpty, !presenting, editor == nil {
            var outlines: [CGRect] = [], tableIndex: [String: Int] = [:]
            for item in selection {   // a selected table is one outline, not one per cell
                if let id = item.tableID {
                    if let at = tableIndex[id] { outlines[at] = outlines[at].union(item.frame) } else { tableIndex[id] = outlines.count; outlines.append(item.frame) }
                } else { outlines.append(item.frame) }
            }
            overlay.rects = outlines
            overlay.handles = []
            if let selected, selected.canMove {
                let radius: CGFloat = (selected.imageURL == nil ? 4 : 6) / scale
                overlay.handles = resizeCorners(for: selected).map { CGRect(x: $0.x - radius, y: $0.y - radius, width: 2 * radius, height: 2 * radius) }
            }
            overlay.lineWidth = (selection.count > 1 ? 2 : 1.5) / scale
        } else { overlay.rects = []; overlay.handles = [] }
        raiseOverlay()
    }
    func backgroundClick(_ event: NSEvent) {
        if presenting { advance(); return }
        finishEditing(commit: true)
        window?.makeFirstResponder(self)
        guard event.type == .leftMouseDown else { return }
        marqueeBase = event.modifierFlags.contains(.shift) ? selection.filter(\.canMove) : []
        select(marqueeBase)
        marqueeStart = surface.convert(event.locationInWindow, from: nil)
    }
    func updateMarquee(_ event: NSEvent) {
        guard let start = marqueeStart, let slide else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        let existing = Set(marqueeBase.map(ObjectIdentifier.init))
        select(slide.items.filter { $0.canMove && (existing.contains(ObjectIdentifier($0)) || area.contains($0.frame)) })
        overlay.marquee = area; overlay.lineWidth = 1 / surfaceScale; overlay.needsDisplay = true
    }
    func endMarquee() {
        guard marqueeStart != nil else { return }
        marqueeStart = nil
        marqueeBase = []
        overlay.marquee = nil; overlay.needsDisplay = true
    }
    func objectMouseDown(_ view: ObjectView, event: NSEvent) {
        if presenting { advance(); return }
        finishEditing(commit: true)
        guard !view.item.inherited else { backgroundClick(event); return }
        window?.makeFirstResponder(self)
        dragOrigin = nil
        if event.type == .leftMouseDown, !event.modifierFlags.intersection([.shift, .command]).isEmpty {
            guard view.item.canMove || view.item.isTableCell else { return }
            let group = members(of: view.item)
            let present = selection.contains { $0 === view.item }
            select(present ? selection.filter { chosen in !group.contains { $0 === chosen } } : selection + group)
            return
        }
        let point = surface.convert(event.locationInWindow, from: nil)
        var target = view.item
        // ⌥-click picks the object underneath (e.g. the card behind its text); repeat to go deeper.
        if event.modifierFlags.contains(.option), let slide {
            let stack = slide.items.filter { $0.canMove && $0.frame.contains(point) }.reversed()
            let order = Array(stack)
            if let current = selected, let position = order.firstIndex(where: { $0 === current }) { target = order[(position + 1) % order.count] }
            else if order.count > 1 { target = order[1] }
        }
        // A plain click on one of several selected objects keeps the selection so they can be dragged together;
        // releasing without a drag then narrows the selection to the clicked object.
        let keepsMultiSelection = selection.count > 1 && selection.contains { $0 === target } && !event.modifierFlags.contains(.option)
        if !keepsMultiSelection { select(members(of: target)) }   // a click on a table cell selects the whole table
        pendingCollapse = keepsMultiSelection ? target : nil
        if event.clickCount == 2 && target.textBody != nil { selected = target; pendingCollapse = nil; startEditing(at: point); return }
        guard target.canMove else { return }
        dragOrigin = point; dragItem = target; originalFrame = target.frame; editedDrag = false
        dragFrames = keepsMultiSelection ? Dictionary(uniqueKeysWithValues: selection.filter(\.canMove).map { (ObjectIdentifier($0), $0.frame) }) : [:]
        resizeCorner = keepsMultiSelection ? nil : resizeHandle(at: point, for: target)
    }
    func objectMouseDragged(_ view: ObjectView, event: NSEvent) {
        if marqueeStart != nil { updateMarquee(event); return }
        guard let start = dragOrigin, let item = dragItem, let host = objectViews.first(where: { $0.item === item }), editor == nil, !presenting else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        guard abs(dx) + abs(dy) > 0.5 else { return }
        if !editedDrag { onWillEdit?(); editedDrag = true }
        if !dragFrames.isEmpty {   // several selected objects move together
            var dx = dx, dy = dy
            if !event.modifierFlags.contains(.command), let first = dragFrames.values.first {
                let union = dragFrames.values.dropFirst().reduce(first) { $0.union($1) }.offsetBy(dx: dx, dy: dy)
                let snap = snapped(union, excluding: Set(dragFrames.keys))
                dx += snap.dx; dy += snap.dy; overlay.guides = snap.guides
            } else { overlay.guides = [] }
            for moved in selection where moved.canMove {
                guard var frame = dragFrames[ObjectIdentifier(moved)] else { continue }
                frame.origin.x += dx; frame.origin.y += dy
                moved.updateFrame(frame); objectViews.first { $0.item === moved }?.frame = frame
            }
            updateSelection(); updateOrderBadges()
            return
        }
        var frame = originalFrame
        if let corner = resizeCorner {
            if item.imageURL != nil {
                let left = corner.x == originalFrame.minX
                let top = corner.y == originalFrame.minY
                let dw = (left ? -dx : dx) / originalFrame.width
                let dh = (top ? -dy : dy) / originalFrame.height
                let delta = abs(dw) >= abs(dh) ? dw : dh
                let scale = max(30 / originalFrame.width, 24 / originalFrame.height, 1 + delta)
                frame.size = CGSize(width: originalFrame.width * scale, height: originalFrame.height * scale)
                if left { frame.origin.x = originalFrame.maxX - frame.width }
                if top { frame.origin.y = originalFrame.maxY - frame.height }
            } else {
                frame.size.width = max(30, originalFrame.width + dx)
                frame.size.height = max(24, originalFrame.height + dy)
            }
            if !event.modifierFlags.contains(.command) {
                frame = snapResize(frame, original: originalFrame, corner: corner, isImage: item.imageURL != nil, item: item)
            } else { overlay.guides = [] }
        } else {
            frame.origin.x += dx; frame.origin.y += dy
            if !event.modifierFlags.contains(.command) {
                let snap = snapped(frame, excluding: [ObjectIdentifier(item)])
                frame.origin.x += snap.dx; frame.origin.y += snap.dy; overlay.guides = snap.guides
            } else { overlay.guides = [] }
        }
        item.updateFrame(frame); host.frame = frame; updateSelection()
    }
    /// Edges and centres that dragged or resized objects snap to: the other objects and the slide itself.
    private func snapTargets(excluding: Set<ObjectIdentifier>) -> [CGRect] {
        guard let slide, let presentation else { return [] }
        var targets = slide.items.filter { !excluding.contains(ObjectIdentifier($0)) && !$0.inherited && $0.frame.width > 0 }.map(\.frame)
        targets.append(CGRect(origin: .zero, size: presentation.size))
        return targets
    }
    private static func xs(_ r: CGRect) -> [CGFloat] { [r.minX, r.midX, r.maxX] }
    private static func ys(_ r: CGRect) -> [CGFloat] { [r.minY, r.midY, r.maxY] }
    /// The smallest move (within 6 screen points) that puts one of `values` on a target line, or nil.
    private func nearestSnap(_ values: [CGFloat], targets: [[CGFloat]]) -> CGFloat? {
        let threshold = 6 / surfaceScale
        var result: CGFloat?
        for line in targets { for target in line { for value in values {
            let delta = target - value
            if abs(delta) <= threshold, result == nil || abs(delta) < abs(result!) { result = delta }
        } } }
        return result
    }
    /// Guide lines for every edge or centre of `rect` that sits exactly on an edge or centre of a target.
    private func guideLines(for rect: CGRect, targets: [CGRect]) -> [(CGPoint, CGPoint)] {
        var guides: [(CGPoint, CGPoint)] = []
        for target in targets {
            for value in Self.xs(target) where Self.xs(rect).contains(where: { abs($0 - value) < 0.5 }) {
                guides.append((CGPoint(x: value, y: min(rect.minY, target.minY)), CGPoint(x: value, y: max(rect.maxY, target.maxY))))
            }
            for value in Self.ys(target) where Self.ys(rect).contains(where: { abs($0 - value) < 0.5 }) {
                guides.append((CGPoint(x: min(rect.minX, target.minX), y: value), CGPoint(x: max(rect.maxX, target.maxX), y: value)))
            }
        }
        return guides
    }
    /// Smart guides while moving: snaps a rectangle and returns the guide lines. Hold ⌘ to move freely.
    private func snapped(_ rect: CGRect, excluding: Set<ObjectIdentifier>) -> (dx: CGFloat, dy: CGFloat, guides: [(CGPoint, CGPoint)]) {
        let targets = snapTargets(excluding: excluding)
        let dx = nearestSnap(Self.xs(rect), targets: targets.map(Self.xs)) ?? 0
        let dy = nearestSnap(Self.ys(rect), targets: targets.map(Self.ys)) ?? 0
        return (dx, dy, guideLines(for: rect.offsetBy(dx: dx, dy: dy), targets: targets))
    }
    /// Smart guides while resizing: the edge being dragged snaps to other objects and the slide.
    private func snapResize(_ frame: CGRect, original: CGRect, corner: CGPoint, isImage: Bool, item: SlideItem) -> CGRect {
        let targets = snapTargets(excluding: [ObjectIdentifier(item)])
        let txs = targets.map(Self.xs), tys = targets.map(Self.ys)
        var frame = frame
        if !isImage {   // text and shapes grow from the bottom-right handle
            if let d = nearestSnap([frame.maxX], targets: txs) { frame.size.width = max(30, frame.width + d) }
            if let d = nearestSnap([frame.maxY], targets: tys) { frame.size.height = max(24, frame.height + d) }
        } else {        // images keep their proportions: snap the dragged corner on one axis and rescale
            let left = corner.x == original.minX, top = corner.y == original.minY
            var factor: CGFloat?
            if let d = nearestSnap([left ? frame.minX : frame.maxX], targets: txs) { factor = (frame.width + (left ? -d : d)) / frame.width }
            if let d = nearestSnap([top ? frame.minY : frame.maxY], targets: tys) {
                let other = (frame.height + (top ? -d : d)) / frame.height
                if factor == nil || abs(other - 1) < abs(factor! - 1) { factor = other }
            }
            if let factor, factor > 0.05 {
                frame.size = CGSize(width: frame.width * factor, height: frame.height * factor)
                if left { frame.origin.x = original.maxX - frame.width }
                if top { frame.origin.y = original.maxY - frame.height }
            }
        }
        overlay.guides = guideLines(for: frame, targets: targets)
        return frame
    }
    func objectMouseUp(_ view: ObjectView, event: NSEvent) {
        overlay.guides = []; overlay.needsDisplay = true
        endMarquee()
        if !editedDrag, let clicked = pendingCollapse { select(members(of: clicked)) }
        pendingCollapse = nil; dragFrames = [:]
        dragOrigin = nil
        if editedDrag { editedDrag = false; rebuild(); onChanged?() }
    }
    /// Builds the inline editor so its text sits exactly where the rendered text is: same insets, indents,
    /// line height, alignment, vertical anchor and run styles. Bullets are shown as "•<tab>" lines.
    func makeEditor(for item: SlideItem) -> InlineTextView {
        let night = nightActive
        let view = InlineTextView(frame: item.frame)
        view.isRichText = true; view.importsGraphics = false; view.usesFontPanel = false; view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.allowsUndo = true
        var fallbackColor = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil } ?? .labelColor
        var editorBackground = item.fill ?? slide?.background ?? .white
        if night { fallbackColor = NightMode.ink(fallbackColor); editorBackground = NightMode.surface(editorBackground) }
        if usesNightMode, !presenting { editorBackground = NightMode.separated(editorBackground) }
        let fallbackFont = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil } ?? .systemFont(ofSize: 24)
        let content = NSMutableAttributedString()
        var firstAttributes: [NSAttributedString.Key: Any] = [.font: fallbackFont, .foregroundColor: fallbackColor]
        for (index, paragraph) in item.paragraphs.enumerated() {
            let text = night ? NightMode.text(paragraph.text) : paragraph.text
            var attributes: [NSAttributedString.Key: Any] = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [.font: fallbackFont, .foregroundColor: fallbackColor]
            let style = NSMutableParagraphStyle()
            style.alignment = paragraph.alignment
            style.minimumLineHeight = paragraph.spacing; style.maximumLineHeight = paragraph.spacing
            style.paragraphSpacingBefore = index == 0 ? 0 : paragraph.before
            style.paragraphSpacing = paragraph.after
            style.lineBreakMode = .byWordWrapping
            style.headIndent = paragraph.left
            style.firstLineHeadIndent = paragraph.bullet == nil ? paragraph.left : max(0, paragraph.left + paragraph.indent)
            if paragraph.bullet != nil { style.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.left)]; style.defaultTabInterval = 36 }
            attributes[.paragraphStyle] = style
            if index == 0 { firstAttributes = attributes }
            let line = NSMutableAttributedString()
            if let marker = paragraph.bullet { line.append(NSAttributedString(string: marker + "\t", attributes: attributes)) }
            line.append(text)
            if index < item.paragraphs.count - 1 { line.append(NSAttributedString(string: "\n", attributes: attributes)) }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            content.append(line)
        }
        view.textStorage?.setAttributedString(content)
        view.typingAttributes = firstAttributes
        view.backgroundColor = editorBackground
        view.insertionPointColor = (firstAttributes[.foregroundColor] as? NSColor) ?? fallbackColor
        let top = layoutParagraphs(item, night: night).first?.origin.y ?? item.insets.top
        view.textContainerInset = CGSize(width: item.insets.left, height: top)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: max(1, item.frame.width - item.insets.left - item.insets.right), height: 100000)
        view.isVerticallyResizable = true; view.maxSize = CGSize(width: item.frame.width, height: 100000)
        return view
    }
    /// While typing in an auto-fit box the editor grows and shrinks with its text (width up to the margin, then more lines).
    private func fitEditor() {
        guard let editor, let item = selected, item.autoFit, let presentation, let storage = editor.textStorage,
              let container = editor.textContainer, let manager = editor.layoutManager else { return }
        let maxWidth = max(80, presentation.size.width - item.frame.minX - presentation.textLeftMargin)
        let natural = storage.boundingRect(with: CGSize(width: 100000, height: 1000), options: [.usesLineFragmentOrigin]).width
        let width = min(maxWidth, max(60, ceil(natural) + item.insets.left + item.insets.right + 2))
        container.containerSize = CGSize(width: max(1, width - item.insets.left - item.insets.right), height: 100000)
        editor.maxSize = CGSize(width: maxWidth, height: 100000)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + editor.textContainerInset.height + item.insets.bottom
        editor.setFrameSize(NSSize(width: width, height: max(24, ceil(used))))
        updateCaret(restartBlink: false)
    }
    // The text caret is drawn by Slidy (in the overlay above everything) and blinks on its own timer.
    // The system caret did not blink inside the scaled, layered slide view.
    private func startCaret(for editor: InlineTextView) {
        overlay.caretColor = editor.insertionPointColor
        editor.insertionPointColor = .clear
        caretObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in
            self?.updateCaret(restartBlink: true)
        }
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.overlay.caret != nil else { return }
            self.hideSystemCaret()
            self.overlay.caretOn.toggle(); self.overlay.needsDisplay = true
        }
        updateCaret(restartBlink: true)
    }
    /// macOS 14+ draws its own insertion indicator inside the text view; keep it hidden so only Slidy's caret shows.
    private func hideSystemCaret() {
        func walk(_ view: NSView) {
            for case let indicator as NSTextInsertionIndicator in view.subviews { indicator.displayMode = .hidden }
            view.subviews.forEach(walk)
        }
        if let editor { walk(editor) }
    }
    private func stopCaret() {
        caretTimer?.invalidate(); caretTimer = nil
        if let caretObserver { NotificationCenter.default.removeObserver(caretObserver) }
        caretObserver = nil
        overlay.caret = nil; overlay.needsDisplay = true
    }
    /// Where the caret is, in slide coordinates (nil while text is selected).
    var caretRect: CGRect? { overlay.caret }
    func updateCaret(restartBlink: Bool) {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer, let storage = editor.textStorage else { overlay.caret = nil; return }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { overlay.caret = nil; overlay.needsDisplay = true; return }
        manager.ensureLayout(for: container)
        var line = CGRect.zero, x: CGFloat = 0
        let length = storage.length
        if length == 0 || (selection.location >= length && storage.string.hasSuffix("\n")) {
            line = manager.extraLineFragmentRect
            if line == .zero { line = CGRect(x: 0, y: 0, width: 1, height: 24) }
            x = manager.extraLineFragmentUsedRect.minX
        } else if selection.location >= length {
            let glyph = manager.glyphIndexForCharacter(at: length - 1)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
        } else {
            let glyph = manager.glyphIndexForCharacter(at: selection.location)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + manager.location(forGlyphAt: glyph).x
        }
        let fontSize = (editor.typingAttributes[.font] as? NSFont)?.pointSize ?? 24
        let height = min(line.height, fontSize * 1.25)
        let origin = editor.textContainerOrigin
        let local = CGRect(x: origin.x + x, y: origin.y + line.minY + (line.height - height) / 2, width: 1.5, height: height)
        overlay.caret = surface.convert(local, from: editor)
        hideSystemCaret()
        if restartBlink { overlay.caretOn = true }
        overlay.needsDisplay = true
    }
    /// `point` (slide coordinates) puts the caret where the person double-clicked instead of at the end.
    func startEditing(selectContents: Bool = false, at point: CGPoint? = nil) {
        guard let item = selected, item.textBody != nil, editor == nil else { return }
        let view = makeEditor(for: item)
        view.finish = { [weak self] commit in self?.finishEditing(commit: commit) }
        if item.autoFit { view.onTextChange = { [weak self] in self?.fitEditor() } }
        surface.addSubview(view); editor = view
        startCaret(for: view)
        updateOrderBadges()   // keep the order badges above the editor
        objectViews.first { $0.item === item }?.isHidden = true
        updateSelection(); window?.makeFirstResponder(view)
        if !selectContents, let point {
            let inEditor = surface.convert(point, to: view)
            var location = view.characterIndexForInsertion(at: inEditor)
            // Never land inside a list marker ("•<tab>" or "2.<tab>"): put the caret after it.
            let text = view.string as NSString
            let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
            let line = text.substring(with: text.lineRange(for: NSRange(location: lineStart, length: 0))).trimmingCharacters(in: .newlines)
            if let marker = InlineTextView.marker(in: line), location < lineStart + marker.length { location = lineStart + marker.length }
            view.setSelectedRange(NSRange(location: max(0, min(location, text.length)), length: 0))
        }
        if selectContents {
            let start = InlineTextView.marker(in: view.string.components(separatedBy: "\n").first ?? "")?.length ?? 0
            view.setSelectedRange(NSRange(location: start, length: (view.string as NSString).length - start))
        }
    }
    func finishEditing(commit: Bool) {
        guard let editor else { return }
        if commit, let item = selected {
            let existingBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
            let existingNumbered = Set(item.paragraphs.indices.filter { item.paragraphs[$0].isNumbered })
            let bullets = editor.bulletRows, numbered = editor.numberedRows
            let text = editor.plainText
            if text != item.text || bullets != existingBullets || numbered != existingNumbered {
                onWillEdit?()
                presentation?.updateText(item, text: text, bulletRows: bullets, numberedRows: numbered)
                if !existingBullets.isEmpty || !bullets.isEmpty { slide?.timingDirty = true }
                onChanged?()
            }
        }
        stopCaret()
        let editedCell = selected?.isTableCell == true ? selected : nil
        editor.removeFromSuperview(); self.editor = nil
        rebuild(); window?.makeFirstResponder(self)
        if let editedCell { select(members(of: editedCell)) }
    }
    func advance() {
        if step < fadeSteps.count {
            let entries = fadeSteps[step]; step += 1
            CATransaction.begin()
            for (view, duration) in entries {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    view.animator().alphaValue = 1
                }
            }
            CATransaction.commit()
        } else { onNavigate?(1) }
    }
    /// Shows every Fade effect at once (used when coming back to an earlier slide).
    func revealAll() {
        for entries in fadeSteps { for (view, _) in entries { view.layer?.removeAllAnimations(); view.alphaValue = 1 } }
        step = fadeSteps.count
    }
    func back() {
        if step > 0 {
            step -= 1
            for (view, _) in fadeSteps[step] { view.layer?.removeAllAnimations(); view.alphaValue = 0 }
        }
        else { onNavigate?(-1) }
    }
    override func keyDown(with event: NSEvent) {
        if presenting {
            // ⌘↓ / ⌘↑ jump to the next / previous slide, shown complete.
            if [125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                if !event.isARepeat { onJumpSlide?(event.keyCode == 125 ? 1 : -1) }
                return
            }
            switch event.keyCode {
            case 53: onExit?()
            case 123, 126, 116: back()
            case 51, 117: onNavigate?(-1)
            case 124, 125, 121, 49, 36: advance()
            default: break
            }
            return
        }
        if [125, 126].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .option] {
            if !event.isARepeat { onReorderFade?(event.keyCode == 126 ? -1 : 1) }
            return
        }
        if [51, 117].contains(event.keyCode), !selection.isEmpty,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { onDelete?() }
            return
        }
        if event.keyCode == 36 { startEditing(); return }
        if [123, 124, 125, 126].contains(event.keyCode), let selected, selected.canMove {
            onWillEdit?(); var frame = selected.frame
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode { case 123: frame.origin.x -= distance; case 124: frame.origin.x += distance; case 125: frame.origin.y += distance; default: frame.origin.y -= distance }
            selected.updateFrame(frame); rebuild(); onChanged?()
        } else { super.keyDown(with: event) }
    }
}
