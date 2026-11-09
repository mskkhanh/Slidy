import AppKit
import CoreText
import QuartzCore

// Lays out the paragraphs of a text object and draws them. Shared by the canvas, thumbnails and the editor.
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
func layoutParagraphs(_ item: SlideItem, night: Bool = false) -> [ParagraphLayout] {
    var y = item.insets.top
    var result: [ParagraphLayout] = []
    for (index, paragraph) in item.paragraphs.enumerated() {
        let content = NSMutableAttributedString(attributedString: night ? NightMode.text(paragraph.text) : paragraph.text)
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
        if index > 0 { y += paragraph.before }
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
