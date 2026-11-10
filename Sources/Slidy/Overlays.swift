import AppKit
import CoreText
import QuartzCore

// Views drawn above the slide objects: order numbers, the slide counter, the selection overlay and crop handles.
final class OrderBadgeView: NSView {
    private let number: Int
    private let grouped: Bool
    init(number: Int, grouped: Bool) { self.number = number; self.grouped = grouped; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Quiet on purpose: just a small gray number, no disc and no background, so it never competes with the slide.
    /// Grouped effects (⌘G) play together; their number is underlined.
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(white: 0.5, alpha: 0.95)
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: bounds.height * 0.78, weight: .medium), .foregroundColor: color])
        let size = text.size()
        let origin = NSPoint(x: 0, y: bounds.midY - size.height / 2)   // flush left with the object's edge
        text.draw(at: origin)
        guard grouped else { return }
        color.setFill()
        NSRect(x: 0, y: bounds.maxY - max(0.7, bounds.height * 0.07), width: size.width, height: max(0.7, bounds.height * 0.07)).fill()
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

