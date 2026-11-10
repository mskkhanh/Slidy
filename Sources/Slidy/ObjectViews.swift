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
