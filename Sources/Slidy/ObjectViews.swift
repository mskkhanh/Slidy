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
        setAccessibilityLabel(item.text.isEmpty ? "Ảnh hoặc hình" : item.text)
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
        if let fill = item.fill { (night ? NightMode.surface(fill) : fill).setFill(); path.fill() }
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
    /// Grouped effects (⌘G) play together; their badge is a pill with a small link symbol after the number.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let height = bounds.height
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: height * 0.58, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let numberCentre = grouped ? height / 2 : bounds.midX
        text.draw(at: NSPoint(x: numberCentre - size.width / 2, y: bounds.midY - size.height / 2))
        guard grouped, let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: "Nhóm"),
              let configured = symbol.withSymbolConfiguration(.init(pointSize: height * 0.5, weight: .semibold)) else { return }
        let tinted = configured.copy() as! NSImage
        tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceIn); tinted.unlockFocus()
        let side = height * 0.55
        tinted.draw(in: NSRect(x: height + (bounds.width - height - side) / 2 - 1, y: bounds.midY - side / 2, width: side, height: side))
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
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
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
