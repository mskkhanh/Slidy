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
    var onMoveLayer: ((Int) -> Void)?
    var onJumpSlide: ((Int) -> Void)?
    var badgeViews: [OrderBadgeView] = []
    private(set) var selection: [SlideItem] = []
    var selected: SlideItem? {
        get { selection.count == 1 ? selection.first : nil }
        set { select(newValue.map { [$0] } ?? []) }
    }
    /// ⌘C / ⌘X on the slide copy (or cut) the selected objects; ⌘V pastes them, on this slide or another.
    @objc func copy(_ sender: Any?) {
        guard editor == nil, !presenting, let slide, !selection.isEmpty else { NSSound.beep(); return }
        ObjectClipboard.write(selection, from: slide)
    }
    @objc func cut(_ sender: Any?) {
        guard editor == nil, !presenting, !selection.isEmpty else { NSSound.beep(); return }
        copy(sender); onDelete?()
    }
    /// The objects that are selected together with `item`: all cells of its table, or the object itself.
    func members(of item: SlideItem) -> [SlideItem] {
        guard let id = item.tableID ?? item.cellTextOf, let slide else { return [item] }
        let group = slide.items.filter { $0.tableID == id || $0.cellTextOf == id }   // a table with the texts split out of its cells
        return group.contains(where: \.isTableCell) ? group : [item]
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
    var dragOrigin: CGPoint?
    var dragItem: SlideItem?
    var dragFrames: [ObjectIdentifier: CGRect] = [:]
    /// Tables being dragged: their <p:graphicFrame> and its starting offset in EMU.
    var dragTables: [(node: XMLElement, x: Double, y: Double)] = []
    var pendingCollapse: SlideItem?
    var originalFrame = CGRect.zero
    var resizeCorner: CGPoint?
    var marqueeStart: CGPoint?
    var marqueeBase: [SlideItem] = []
    /// Editing zoom (pinch on the trackpad). 1 fits the slide to the window; it never changes the file.
    private(set) var zoom: CGFloat = 1
    var panOffset = CGPoint.zero
    var surfaceScale: CGFloat { max(0.01, surface.frame.width / max(1, surface.bounds.width)) }
    var editedDrag = false
    /// Crop mode (double-click a picture): which picture, the whole picture's rectangle, the current crop rectangle and the drag in progress.
    var cropItem: SlideItem?
    var cropOriginalFrame = CGRect.zero
    var cropOriginalInsets = NSEdgeInsets()
    var cropDrag: (edges: CropHandles.Edges, start: CGPoint, rect: CGRect)?
    var isCropping: Bool { cropItem != nil }
    /// Selection outline, handles and marquee are drawn by one transparent view kept above every object.
    let overlay = SelectionOverlay()
    var caretTimer: Timer?
    var caretObserver: NSObjectProtocol?
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
    var badgeFrames: [CGRect] { badgeViews.map(\.frame) }
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
                step.flatMap { entry -> [(NSView, Double)] in
                    guard let object = views[ObjectIdentifier(entry.item)] else { return [] }
                    if entry.item.isTableFrame {   // the whole table: all of its cells appear together
                        let cellViews = objectViews.filter { $0.item.tableID == entry.item.tableID }
                        cellViews.forEach { $0.alphaValue = 0 }
                        return cellViews.map { ($0 as NSView, entry.item.fadeDuration(for: nil)) }
                    }
                    let view: NSView
                    if let paragraph = entry.paragraph,
                       let index = entry.item.paragraphs.firstIndex(where: { $0.xmlIndex == paragraph }) {
                        view = object.paragraphViews[index]
                    } else { view = object }
                    view.alphaValue = 0
                    return [(view, entry.item.fadeDuration(for: entry.paragraph))]
                }
            }
        }
        updateSelection()
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
    override func mouseDragged(with event: NSEvent) { continueDrag(event) }   // also a resize that started on a handle outside the slide
    override func mouseUp(with event: NSEvent) { finishDrag() }
    /// Keeps the selection overlay above every object, badge and editor, whatever their stacking order.
    func raiseOverlay() {
        overlay.frame = surface.bounds
        surface.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.needsDisplay = true
    }
    func updateSelection() {
        let scale = surfaceScale
        if !selection.isEmpty, !presenting, editor == nil, cropItem == nil {
            var outlines: [CGRect] = [], tableIndex: [String: Int] = [:]
            for item in selection {   // a selected table is one outline, not one per cell
                if let id = item.tableID ?? item.cellTextOf.flatMap({ table in selection.contains { $0.tableID == table } ? table : nil }) {
                    if let at = tableIndex[id] { outlines[at] = outlines[at].union(item.frame) } else { tableIndex[id] = outlines.count; outlines.append(item.frame) }
                } else { outlines.append(item.frame) }
            }
            overlay.rects = outlines
            overlay.handles = []
            if let selected, selected.canMove {
                let radius: CGFloat = (selected.imageURL == nil ? 5.5 : 7) / scale
                overlay.handles = resizeCorners(for: selected).map { CGRect(x: $0.x - radius, y: $0.y - radius, width: 2 * radius, height: 2 * radius) }
            }
            overlay.lineWidth = 1 / scale
        } else { overlay.rects = []; overlay.handles = [] }
        raiseOverlay()
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
        if cropItem != nil {   // crop mode: Return applies, Esc cancels, everything else waits
            switch event.keyCode {
            case 36, 76: commitCrop()
            case 53: cancelCrop()
            default: NSSound.beep()
            }
            return
        }
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
        // Layers: ⌥⌘↑ / ⌥⌘↓ move the selection one step. Fade order: ⇧↑ / ⇧↓. (⌘↑ / ⌘↓ switch slides.)
        // On objects without Fade, ⇧↑ / ⇧↓ keep nudging by 10 points.
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let hasFadeSelected = selection.contains { $0.canMove && $0.hasFade }
        if [125, 126].contains(event.keyCode), flags == [.command, .option], !selection.isEmpty {
            if !event.isARepeat { onMoveLayer?(event.keyCode == 126 ? 1 : -1) }
            return
        }
        if [125, 126].contains(event.keyCode), flags == .shift && hasFadeSelected {
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
