import AppKit
import CoreText
import QuartzCore

// Small views that make up a slide: objects, the slide surface, the inline text editor, badges and the slide counter.
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
        for layout in layoutParagraphs(item, night: canvas?.nightActive ?? false) {
            let view = ParagraphView(layout: layout, width: item.frame.width)
            paragraphViews.append(view); addSubview(view)
        }
        if item.rotation != 0 { frameCenterRotation = -item.rotation }
        applyShadow()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(item.text.isEmpty ? "Picture or shape" : item.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The object's own shadow lives on its layer, so it fades in and out together with the object when presenting.
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyShadow() }   // the layer's flip state is final once in a window
    private func applyShadow() {
        guard let shadow = item.shadow, let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = shadow.color.withAlphaComponent(1).cgColor
        layer.shadowOpacity = Float(shadow.color.alphaComponent)
        layer.shadowRadius = shadow.blur / 2
        layer.shadowOffset = CGSize(width: shadow.dx, height: layer.isGeometryFlipped ? shadow.dy : -shadow.dy)   // +dy is downwards
    }
    override func draw(_ dirtyRect: NSRect) {
        let path: NSBezierPath
        if item.geometry == "ellipse" { path = NSBezierPath(ovalIn: bounds) }
        else if item.geometry == "roundRect" { path = NSBezierPath(roundedRect: bounds, xRadius: min(bounds.height / 2, 14), yRadius: min(bounds.height / 2, 14)) }
        else { path = NSBezierPath(rect: bounds) }
        let night = canvas?.nightActive ?? false
        if let fill = item.fill { (night ? NightMode.fill(fill, on: canvas?.slide?.background) : fill).setFill(); path.fill() }
        if let stroke = item.stroke { (night ? NightMode.ink(stroke) : stroke).setStroke(); path.lineWidth = item.strokeWidth; path.stroke() }
        if let image = presentation.image(for: item) {
            // Rounded pictures are clipped to their rounded outline; the layer shadow then follows that shape.
            if item.geometry == "roundRect" {
                let radius = item.cornerRatio * min(bounds.width, bounds.height)
                NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
            }
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
    override func draw(_ dirtyRect: NSRect) {
        var shade = color
        if canvas?.nightActive == true { shade = NightMode.surface(color) }
        if canvas?.usesNightMode == true, canvas?.presenting != true { shade = NightMode.separated(shade) }
        shade.setFill(); bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { canvas?.backgroundClick(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.continueDrag(event) }
    override func mouseUp(with event: NSEvent) { canvas?.finishDrag() }
}
final class InlineTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    var onTextChange: (() -> Void)?
    private var renumbering = false
    /// Set once ⌘B changed something, so the run styles are written back when editing ends.
    private(set) var boldEdited = false
    private static let boldKey = NSAttributedString.Key("slidyBold")
    private static func isBold(_ font: NSFont?) -> Bool { font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false }
    /// ⌘B: bold on / off for the selected text.
    func toggleBold() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { NSSound.beep(); return }
        var allBold = true
        for index in range.location..<NSMaxRange(range) where !bold(at: index) { allBold = false; break }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont else { return }
            let manager = NSFontManager.shared
            storage.addAttribute(.font, value: allBold ? manager.convert(font, toNotHaveTrait: .boldFontMask) : manager.convert(font, toHaveTrait: .boldFontMask), range: part)
        }
        storage.addAttribute(Self.boldKey, value: !allBold, range: range)
        storage.endEditing()
        boldEdited = true
        needsDisplay = true; onTextChange?()
    }
    private func bold(at index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length else { return false }
        return (storage.attribute(Self.boldKey, at: index, effectiveRange: nil) as? Bool) ?? Self.isBold(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }
    /// Bold on / off for every character of every line, list markers left out (same lines as `plainText`).
    var boldFlags: [[Bool]] {
        var location = 0
        return lines.map { line in
            let length = (line as NSString).length, skip = Self.marker(in: line)?.length ?? 0
            defer { location += length + 1 }
            return (skip..<length).map { bold(at: location + $0) }
        }
    }
    /// Slidy draws the text itself: NSTextView cuts glyphs at the top of a tight line box, which removed
    /// stacked Vietnamese accents (Ế, Ẫ) in headings. The layout manager draws them whole.
    override func draw(_ dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer else { super.draw(dirtyRect); return }
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: textContainerOrigin)
        manager.drawGlyphs(forGlyphRange: range, at: textContainerOrigin)
    }
    // Accents sit outside their line box, so a partial redraw would leave them stale: always redraw the whole editor.
    override func setNeedsDisplay(_ invalidRect: NSRect) { super.setNeedsDisplay(bounds) }
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) { super.setNeedsDisplay(bounds, avoidAdditionalLayout: flag) }

    /// A paragraph that is a list item starts with its marker and a tab: "•<tab>" or "2.<tab>".
    static func marker(in line: String) -> (length: Int, numbered: Bool)? {
        if line.hasPrefix("•\t") { return (2, false) }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < 4, line.dropFirst(digits.count).hasPrefix(".\t") else { return nil }
        return (digits.count + 2, true)
    }
    private var lines: [String] { string.components(separatedBy: "\n") }
    var bulletRows: Set<Int> { Set(lines.enumerated().compactMap { Self.marker(in: $0.element) != nil ? $0.offset : nil }) }
    var numberedRows: Set<Int> { Set(lines.enumerated().compactMap { Self.marker(in: $0.element)?.numbered == true ? $0.offset : nil }) }
    var plainText: String {
        lines.map { line in Self.marker(in: line).map { String(line.dropFirst($0.length)) } ?? line }.joined(separator: "\n")
    }
    /// The text of the current line before the caret.
    private var linePrefixRange: NSRange {
        let text = string as NSString
        let end = selectedRange().location
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end))
        let start = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        return NSRange(location: start, length: end - start)
    }
    private var currentLineRange: NSRange { (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)) }

    /// Numbered items count 1, 2, 3... within each run of consecutive numbered lines (the first one keeps its number).
    func renumber() {
        guard !renumbering, let storage = textStorage else { return }
        renumbering = true; defer { renumbering = false }
        let selection = selectedRange()
        var expected: Int?
        var shift = 0
        var location = 0
        var edits: [(NSRange, String)] = []
        for line in lines {
            if let marker = Self.marker(in: line), marker.numbered {
                let current = Int(line.prefix(marker.length - 2)) ?? 1
                let number = expected ?? current
                if number != current { edits.append((NSRange(location: location, length: marker.length - 2), String(number))) }
                expected = number + 1
            } else { expected = nil }
            location += (line as NSString).length + 1
        }
        guard !edits.isEmpty else { return }
        for (range, text) in edits.reversed() { storage.replaceCharacters(in: range, with: text) }
        for (range, text) in edits where range.location < selection.location { shift += text.count - range.length }
        setSelectedRange(NSRange(location: max(0, selection.location + shift), length: selection.length))
    }
    override func didChangeText() { super.didChangeText(); renumber(); onTextChange?() }

    override func keyDown(with event: NSEvent) {
        let prefix = (string as NSString).substring(with: linePrefixRange)
        let line = (string as NSString).substring(with: currentLineRange).trimmingCharacters(in: .newlines)
        if event.keyCode == 53 { finish?(false) }
        else if event.keyCode == 36 && event.modifierFlags.contains(.shift) { insertText("\u{2028}", replacementRange: selectedRange()) }
        else if event.keyCode == 36, let marker = Self.marker(in: prefix) {
            if line.count == marker.length && selectedRange().length == 0 {
                // Return on an empty list item leaves the list.
                insertText("", replacementRange: linePrefixRange)
            } else {
                let next = marker.numbered ? "\((Int(prefix.prefix(marker.length - 2)) ?? 0) + 1).\t" : "•\t"
                insertText("\n" + next, replacementRange: selectedRange())
            }
        } else if event.characters == " ", selectedRange().length == 0, prefix == "-" {
            insertText("•\t", replacementRange: linePrefixRange)
        } else if event.characters == " ", selectedRange().length == 0, let number = Self.typedNumber(prefix) {
            // "1" or "1." followed by a space starts a numbered list.
            insertText("\(number).\t", replacementRange: linePrefixRange)
        } else { super.keyDown(with: event) }
    }
    /// "1" or "12." typed alone at the start of a line.
    static func typedNumber(_ prefix: String) -> Int? {
        let digits = prefix.hasSuffix(".") ? String(prefix.dropLast()) : prefix
        guard !digits.isEmpty, digits.count < 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}

final class OrderBadgeView: NSView {
    private let number: Int
    private let grouped: Bool
    init(number: Int, grouped: Bool) { self.number = number; self.grouped = grouped; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Quiet on purpose: a small, faint gray disc with a gray number, so it never competes with the slide.
    /// Grouped effects (⌘G) play together; their badge has a thin ring.
    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor(white: 0.5, alpha: 0.16).setFill(); disc.fill()
        if grouped { NSColor(white: 0.5, alpha: 0.75).setStroke(); disc.lineWidth = max(0.6, bounds.height * 0.07); disc.stroke() }
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: bounds.height * (number > 9 ? 0.56 : 0.64), weight: .medium), .foregroundColor: NSColor(white: 0.5, alpha: 0.95)])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// Small, quiet slide counter for presentation mode. It never takes clicks.
final class SlideNumberLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textColor = NSColor(white: 0.5, alpha: 0.7)
    }
}

/// Transparent view above all objects: draws the selection outline, resize handles and the marquee.
final class SelectionOverlay: NSView {
    var rects: [CGRect] = []
    var handles: [CGRect] = []
    var marquee: CGRect?
    /// Alignment guides shown while dragging (slide coordinates).
    var guides: [(CGPoint, CGPoint)] = []
    var lineWidth: CGFloat = 1
    /// The text caret while editing (Slidy draws and blinks it itself).
    var caret: CGRect?
    var caretColor: NSColor = .white
    var caretOn = true
    /// Crop mode: the whole picture dimmed, the part that stays bright, and its eight handles.
    var cropImage: NSImage?
    var cropFull = CGRect.zero
    var cropRect = CGRect.zero
    var cropHandleSize: CGFloat = 10
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let image = cropImage {
            image.draw(in: cropFull, from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cropRect).addClip()
            image.draw(in: cropFull, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let frame = NSBezierPath(rect: cropRect); frame.lineWidth = lineWidth * 1.5; frame.stroke()
            for point in CropHandles.points(of: cropRect) {
                let square = CGRect(x: point.x - cropHandleSize / 2, y: point.y - cropHandleSize / 2, width: cropHandleSize, height: cropHandleSize)
                NSColor(white: 0.96, alpha: 1).setFill(); NSBezierPath(rect: square).fill()
                NSColor(white: 0.35, alpha: 1).setStroke(); let edge = NSBezierPath(rect: square); edge.lineWidth = lineWidth; edge.stroke()
            }
        }
        if let caret, caretOn { caretColor.setFill(); NSBezierPath(rect: caret).fill() }
        let accent = NSColor.controlAccentColor
        // Thin, soft gray outline so it never fights with the object's own text; handles are small visible squares
        // (the grab area around them is much larger).
        NSColor(white: 0.62, alpha: 0.55).setStroke()
        for rect in rects { let path = NSBezierPath(rect: rect); path.lineWidth = lineWidth; path.stroke() }
        for handle in handles {
            NSColor(white: 0.96, alpha: 0.95).setFill(); NSBezierPath(rect: handle).fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            let path = NSBezierPath(rect: handle); path.lineWidth = lineWidth; path.stroke()
        }
        if !guides.isEmpty {
            NSColor.systemPink.setStroke()
            for (from, to) in guides { let line = NSBezierPath(); line.lineWidth = lineWidth; line.move(to: from); line.line(to: to); line.stroke() }
        }
        if let marquee {
            accent.withAlphaComponent(0.15).setFill(); NSBezierPath(rect: marquee).fill()
            let path = NSBezierPath(rect: marquee); path.lineWidth = lineWidth; path.stroke()
        }
    }
}

/// The eight crop handles of a crop rectangle: corners and edge midpoints, with the edges each one moves.
enum CropHandles {
    struct Edges: OptionSet { let rawValue: Int; static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8) }
    static func list(of r: CGRect) -> [(point: CGPoint, edges: Edges)] {
        [(CGPoint(x: r.minX, y: r.minY), [.left, .top]), (CGPoint(x: r.maxX, y: r.minY), [.right, .top]),
         (CGPoint(x: r.minX, y: r.maxY), [.left, .bottom]), (CGPoint(x: r.maxX, y: r.maxY), [.right, .bottom]),
         (CGPoint(x: r.midX, y: r.minY), .top), (CGPoint(x: r.midX, y: r.maxY), .bottom),
         (CGPoint(x: r.minX, y: r.midY), .left), (CGPoint(x: r.maxX, y: r.midY), .right)]
    }
    static func points(of r: CGRect) -> [CGPoint] { list(of: r).map(\.point) }
}
