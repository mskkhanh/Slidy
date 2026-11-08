import AppKit
import CoreText
import QuartzCore

struct ParagraphLayout {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    let origin: CGPoint
    let height: CGFloat
    let bullet: String?
    let bulletX: CGFloat
    let attributes: [NSAttributedString.Key: Any]
}
func layoutParagraphs(_ item: SlideItem) -> [ParagraphLayout] {
    var y = item.insets.top
    var result: [ParagraphLayout] = []
    for paragraph in item.paragraphs {
        let content = NSMutableAttributedString(attributedString: paragraph.text)
        let style = NSMutableParagraphStyle()
        style.alignment = paragraph.alignment
        style.minimumLineHeight = paragraph.spacing
        style.maximumLineHeight = paragraph.spacing
        style.lineBreakMode = .byWordWrapping
        if content.length > 0 { content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length)) }
        let storage = NSTextStorage(attributedString: content)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, item.frame.width - item.insets.left - item.insets.right - paragraph.left), height: 100000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let height = max(paragraph.spacing, manager.usedRect(for: container).height)
        y += paragraph.before
        let attributes = content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : [.font: NSFont.systemFont(ofSize: 22)]
        result.append(ParagraphLayout(storage: storage, manager: manager, container: container, origin: CGPoint(x: item.insets.left + paragraph.left, y: y), height: height, bullet: paragraph.bullet, bulletX: item.insets.left + paragraph.left + paragraph.indent, attributes: attributes))
        y += height + paragraph.after
    }
    let available = item.frame.height - item.insets.bottom
    let offset = item.anchor == "ctr" ? max(0, (available - y) / 2) : (item.anchor == "b" ? max(0, available - y) : 0)
    guard offset > 0 else { return result }
    return result.map { ParagraphLayout(storage: $0.storage, manager: $0.manager, container: $0.container, origin: CGPoint(x: $0.origin.x, y: $0.origin.y + offset), height: $0.height, bullet: $0.bullet, bulletX: $0.bulletX, attributes: $0.attributes) }
}
final class ParagraphView: NSView {
    let layout: ParagraphLayout
    override var isFlipped: Bool { true }
    init(layout: ParagraphLayout, width: CGFloat) {
        self.layout = layout
        super.init(frame: CGRect(x: 0, y: layout.origin.y, width: width, height: layout.height))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let range = layout.manager.glyphRange(for: layout.container)
        layout.manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: layout.origin.x, y: 0))
        if let bullet = layout.bullet, range.length > 0, let context = NSGraphicsContext.current?.cgContext {
            let font = layout.attributes[.font] as? NSFont ?? .systemFont(ofSize: 22)
            let color = layout.attributes[.foregroundColor] as? NSColor ?? .labelColor
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: bullet, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ]))
            let firstLine = layout.manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
            let baseline = firstLine.minY + layout.manager.location(forGlyphAt: range.location).y
            // Center the dot on the lowercase body, independent of accents and line spacing.
            let offset = bullet == "•" ? CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).midY - font.xHeight / 2 : 0
            context.saveGState()
            context.translateBy(x: layout.bulletX, y: baseline + offset)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
final class ObjectView: NSView {
    let item: SlideItem
    weak var canvas: CanvasView?
    let presentation: Presentation
    var paragraphViews: [ParagraphView] = []
    override var isFlipped: Bool { true }
    init(item: SlideItem, presentation: Presentation, canvas: CanvasView?) {
        self.item = item; self.presentation = presentation; self.canvas = canvas
        super.init(frame: item.frame)
        wantsLayer = true
        for layout in layoutParagraphs(item) {
            let view = ParagraphView(layout: layout, width: item.frame.width)
            paragraphViews.append(view); addSubview(view)
        }
        if item.rotation != 0 { frameCenterRotation = -item.rotation }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(item.text.isEmpty ? "Ảnh hoặc hình" : item.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let path: NSBezierPath
        if item.geometry == "ellipse" { path = NSBezierPath(ovalIn: bounds) }
        else if item.geometry == "roundRect" { path = NSBezierPath(roundedRect: bounds, xRadius: min(bounds.height / 2, 14), yRadius: min(bounds.height / 2, 14)) }
        else { path = NSBezierPath(rect: bounds) }
        if let fill = item.fill { fill.setFill(); path.fill() }
        if let stroke = item.stroke { stroke.setStroke(); path.lineWidth = item.strokeWidth; path.stroke() }
        if let image = presentation.image(for: item) {
            let crop = item.imageCrop
            let source = CGRect(x: image.size.width * crop.left, y: image.size.height * crop.bottom, width: image.size.width * max(0.01, 1 - crop.left - crop.right), height: image.size.height * max(0.01, 1 - crop.top - crop.bottom))
            image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
    override func mouseDown(with event: NSEvent) { canvas?.objectMouseDown(self, event: event) }
    override func mouseDragged(with event: NSEvent) { canvas?.objectMouseDragged(self, event: event) }
    override func mouseUp(with event: NSEvent) { canvas?.objectMouseUp(self, event: event) }
    override func rightMouseDown(with event: NSEvent) { canvas?.objectMouseDown(self, event: event); if let menu = canvas?.objectMenu { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
}
final class SlideSurface: NSView {
    var color = NSColor.white
    weak var canvas: CanvasView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) { canvas?.backgroundClick(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.updateMarquee(event) }
    override func mouseUp(with event: NSEvent) { canvas?.endMarquee() }
}
final class InlineTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    private let bulletPrefix = "•\t"
    var bulletRows: Set<Int> {
        Set(string.components(separatedBy: "\n").enumerated().compactMap { $0.element.hasPrefix(bulletPrefix) ? $0.offset : nil })
    }
    var plainText: String {
        string.components(separatedBy: "\n").map { $0.hasPrefix(bulletPrefix) ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
    }
    private var linePrefixRange: NSRange {
        let text = string as NSString
        let end = selectedRange().location
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end))
        let start = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        return NSRange(location: start, length: end - start)
    }
    override func keyDown(with event: NSEvent) {
        let prefix = (string as NSString).substring(with: linePrefixRange)
        if event.keyCode == 53 { finish?(false) }
        else if event.keyCode == 36 && event.modifierFlags.contains(.shift) { insertText("\u{2028}", replacementRange: selectedRange()) }
        else if event.keyCode == 36 && prefix.hasPrefix(bulletPrefix) {
            insertText("\n" + bulletPrefix, replacementRange: selectedRange())
        } else if event.characters == " ", prefix == "-", selectedRange().length == 0 {
            insertText(bulletPrefix, replacementRange: linePrefixRange)
        } else { super.keyDown(with: event) }
    }
}
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
    private(set) var selection: [SlideItem] = []
    var selected: SlideItem? {
        get { selection.count == 1 ? selection.first : nil }
        set { select(newValue.map { [$0] } ?? []) }
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
    private var originalFrame = CGRect.zero
    private var resizeCorner: CGPoint?
    private var marqueeStart: CGPoint?
    private var marqueeBase: [SlideItem] = []
    private let marqueeLayer = CAShapeLayer()
    private var surfaceScale: CGFloat { max(0.01, surface.frame.width / max(1, surface.bounds.width)) }
    private var editedDrag = false
    private var selectionLayer = CAShapeLayer()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        surface.wantsLayer = true; surface.canvas = self
        addSubview(surface)
        selectionLayer.fillColor = nil; selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        surface.layer?.addSublayer(selectionLayer)
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        surface.layer?.addSublayer(marqueeLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { (presenting ? NSColor.black : NSColor.windowBackgroundColor).setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        guard let presentation else { surface.isHidden = true; return }
        surface.isHidden = false
        let margin: CGFloat = presenting ? 0 : 28
        let scale = max(0.01, min((bounds.width - margin * 2) / presentation.size.width, (bounds.height - margin * 2) / presentation.size.height))
        let size = CGSize(width: presentation.size.width * scale, height: presentation.size.height * scale)
        surface.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        surface.bounds = CGRect(origin: .zero, size: presentation.size)
        updateSelection()
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
        // The selection border must stay above object layers.
        selectionLayer.removeFromSuperlayer()
        surface.layer?.addSublayer(selectionLayer)
        marqueeLayer.removeFromSuperlayer()
        surface.layer?.addSublayer(marqueeLayer)
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
    func updateSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !selection.isEmpty, !presenting, editor == nil {
            let scale = surfaceScale
            let path = CGMutablePath()
            for item in selection { path.addRect(item.frame) }
            if let selected, selected.canMove {
                let radius: CGFloat = (selected.imageURL == nil ? 4 : 6) / scale
                for corner in resizeCorners(for: selected) {
                    path.addRect(CGRect(x: corner.x - radius, y: corner.y - radius, width: 2 * radius, height: 2 * radius))
                }
            }
            selectionLayer.path = path; selectionLayer.lineWidth = 1 / scale
        } else { selectionLayer.path = nil }
        CATransaction.commit()
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
        select(slide.items.filter { $0.canMove && (existing.contains(ObjectIdentifier($0)) || area.intersects($0.frame)) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.lineWidth = 1 / surfaceScale
        marqueeLayer.path = CGPath(rect: area, transform: nil)
        CATransaction.commit()
    }
    func endMarquee() {
        guard marqueeStart != nil else { return }
        marqueeStart = nil
        marqueeBase = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.path = nil
        CATransaction.commit()
    }
    func objectMouseDown(_ view: ObjectView, event: NSEvent) {
        if presenting { advance(); return }
        finishEditing(commit: true)
        guard !view.item.inherited else { backgroundClick(event); return }
        window?.makeFirstResponder(self)
        dragOrigin = nil
        if event.type == .leftMouseDown, !event.modifierFlags.intersection([.shift, .command]).isEmpty {
            guard view.item.canMove else { return }
            let items = selection.filter(\.canMove)
            select(items.contains(where: { $0 === view.item }) ? items.filter { $0 !== view.item } : items + [view.item])
            return
        }
        selected = view.item
        if event.clickCount == 2 && view.item.textBody != nil { startEditing(); return }
        guard view.item.canMove else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        dragOrigin = point; originalFrame = view.item.frame; editedDrag = false
        resizeCorner = resizeHandle(at: point, for: view.item)
    }
    func objectMouseDragged(_ view: ObjectView, event: NSEvent) {
        if marqueeStart != nil { updateMarquee(event); return }
        guard let start = dragOrigin, editor == nil, !presenting else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        guard abs(dx) + abs(dy) > 0.5 else { return }
        if !editedDrag { onWillEdit?(); editedDrag = true }
        var frame = originalFrame
        if let corner = resizeCorner {
            if view.item.imageURL != nil {
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
        } else { frame.origin.x += dx; frame.origin.y += dy }
        view.item.updateFrame(frame); view.frame = frame; updateSelection()
    }
    func objectMouseUp(_ view: ObjectView, event: NSEvent) {
        endMarquee()
        dragOrigin = nil
        if editedDrag { editedDrag = false; rebuild(); onChanged?() }
    }
    func startEditing(selectContents: Bool = false) {
        guard let item = selected, item.textBody != nil, editor == nil else { return }
        let view = InlineTextView(frame: item.frame)
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.allowsUndo = true
        view.textContainerInset = CGSize(width: item.insets.left, height: item.insets.top)
        view.textContainer?.lineFragmentPadding = 0
        view.font = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil } ?? .systemFont(ofSize: 24)
        view.textColor = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil } ?? .labelColor
        view.backgroundColor = item.fill ?? slide?.background ?? .white
        view.insertionPointColor = view.textColor ?? .labelColor
        view.string = item.paragraphs.map { ($0.bullet == nil ? "" : "•\t") + $0.text.string }.joined(separator: "\n")
        view.isVerticallyResizable = true; view.maxSize = CGSize(width: item.frame.width, height: 100000)
        view.textContainer?.widthTracksTextView = true
        view.finish = { [weak self] commit in self?.finishEditing(commit: commit) }
        surface.addSubview(view); editor = view
        objectViews.first { $0.item === item }?.isHidden = true
        updateSelection(); window?.makeFirstResponder(view)
        if selectContents {
            let start = view.string.hasPrefix("•\t") ? 2 : 0
            view.setSelectedRange(NSRange(location: start, length: (view.string as NSString).length - start))
        }
    }
    func finishEditing(commit: Bool) {
        guard let editor else { return }
        if commit, let item = selected {
            let existingBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
            let bullets = editor.bulletRows
            let text = editor.plainText
            if text != item.text || bullets != existingBullets {
                onWillEdit?()
                presentation?.updateText(item, text: text, bulletRows: bullets)
                if !existingBullets.isEmpty || !bullets.isEmpty { slide?.timingDirty = true }
                onChanged?()
            }
        }
        editor.removeFromSuperview(); self.editor = nil
        rebuild(); window?.makeFirstResponder(self)
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
    func back() {
        if step > 0 {
            step -= 1
            for (view, _) in fadeSteps[step] { view.layer?.removeAllAnimations(); view.alphaValue = 0 }
        }
        else { onNavigate?(-1) }
    }
    override func keyDown(with event: NSEvent) {
        if presenting {
            switch event.keyCode {
            case 53: onExit?()
            case 123, 126, 116: back()
            case 124, 125, 121, 49, 36: advance()
            default: break
            }
            return
        }
        if [51, 117].contains(event.keyCode), selected?.canMove == true,
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
