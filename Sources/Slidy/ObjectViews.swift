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
        let night = canvas?.nightActive ?? false
        if let fill = item.fill { (night ? NightMode.surface(fill) : fill).setFill(); path.fill() }
        if let stroke = item.stroke { (night ? NightMode.ink(stroke) : stroke).setStroke(); path.lineWidth = item.strokeWidth; path.stroke() }
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
    override func draw(_ dirtyRect: NSRect) {
        var shade = color
        if canvas?.nightActive == true { shade = NightMode.surface(color) }
        if canvas?.usesNightMode == true, canvas?.presenting != true { shade = NightMode.separated(shade) }
        shade.setFill(); bounds.fill()
    }
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

final class OrderBadgeView: NSView {
    private let number: Int
    init(number: Int) { self.number = number; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 0.92).setFill(); NSBezierPath(ovalIn: bounds).fill()
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: bounds.height * 0.58, weight: .semibold), .foregroundColor: NSColor.white])
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
