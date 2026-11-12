import AppKit

// The slide list: a modest centered thumbnail with a thin border, a small number on the left, badges for Fade and
// hidden slides, and a ring (not a gray block) around the selected one.

enum SlideThumb {
    /// Slide height / width of the open deck (16:9 until a deck says otherwise).
    static var aspect: CGFloat = 9 / 16
    static let verticalPadding: CGFloat = 7
    /// The thumbnail is about two thirds of the column, centered.
    static func frame(in bounds: NSRect) -> NSRect {
        let width = (min(max(bounds.width * 0.64, 90), 260)).rounded()
        let height = (width * aspect).rounded()
        return NSRect(x: ((bounds.width - width) / 2).rounded(), y: verticalPadding, width: width, height: height)
    }
    static func rowHeight(columnWidth: CGFloat) -> CGFloat { frame(in: NSRect(x: 0, y: 0, width: columnWidth, height: 0)).height + verticalPadding * 2 }
}

final class SlideThumbCell: NSTableCellView {
    private let image = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private let hiddenIcon = NSImageView(), fadeIcon = NSImageView(), liveDot = NSBox()
    override var isFlipped: Bool { true }

    init(row: Int, thumbnail: NSImage?, slide: Slide, presenting: Bool) {
        super.init(frame: .zero)
        image.image = thumbnail; image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.borderWidth = 1; image.layer?.borderColor = NSColor(white: 0.5, alpha: 0.38).cgColor   // a dark slide never melts into the black column
        image.layer?.cornerRadius = 2; image.layer?.masksToBounds = true
        image.alphaValue = slide.isHidden ? 0.4 : 1
        number.stringValue = "\(row + 1)"
        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); number.textColor = NSColor(white: 0.5, alpha: 0.95)
        number.alignment = .right
        for (icon, name, label) in [(hiddenIcon, "eye.slash", "Hidden slide"), (fadeIcon, "sparkles", "Has Fade effects")] {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            icon.contentTintColor = .white; icon.toolTip = label; icon.imageAlignment = .alignCenter
            icon.wantsLayer = true; icon.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor; icon.layer?.cornerRadius = 3   // readable on a light slide too
        }
        hiddenIcon.isHidden = !slide.isHidden
        fadeIcon.isHidden = slide.fadeGroups.isEmpty
        liveDot.boxType = .custom; liveDot.borderWidth = 0; liveDot.fillColor = AppDelegate.accent; liveDot.cornerRadius = 2.5
        liveDot.isHidden = !presenting; liveDot.toolTip = "Being presented"
        for view in [image, number, hiddenIcon, fadeIcon, liveDot] { addSubview(view) }
        setAccessibilityLabel("Slide \(row + 1). \(slide.title)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let thumb = SlideThumb.frame(in: bounds)
        image.frame = thumb
        number.frame = NSRect(x: 4, y: thumb.minY - 1, width: max(14, thumb.minX - 10), height: 13)
        liveDot.frame = NSRect(x: number.frame.maxX - 5, y: thumb.minY + 16, width: 5, height: 5)
        let step: CGFloat = 16
        var x = thumb.maxX - 17
        for icon in [fadeIcon, hiddenIcon] where !icon.isHidden { icon.frame = NSRect(x: x, y: thumb.maxY - 17, width: 14, height: 14); x -= step }
    }
}

/// Row of the slide list: no gray block; a thin ring around the thumbnail when selected, a fainter one under the pointer.
final class SlideRowView: NSTableRowView {
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    private func ring(width: CGFloat, color: NSColor) {
        let path = NSBezierPath(roundedRect: SlideThumb.frame(in: bounds).insetBy(dx: -3.5, dy: -3.5), xRadius: 4, yRadius: 4)
        color.setStroke(); path.lineWidth = width; path.stroke()
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovered, !isSelected { ring(width: 1, color: NSColor(white: 1, alpha: 0.28)) }
    }
    override func drawSelection(in dirtyRect: NSRect) { ring(width: 2, color: AppDelegate.accent) }
}

extension Slide {
    /// <p:sld show="0">: the slide is skipped while presenting (it stays in the file).
    var isHidden: Bool { document.rootElement()?.attr("show") == "0" }
    func setHidden(_ hidden: Bool) {
        guard let root = document.rootElement() else { return }
        if hidden { root.set("show", "0") } else { root.removeAttribute(forName: "show") }
    }
}

/// A soft dark edge where the slide meets the column, so a zoomed-in slide never ends in a bright stripe against it.
final class EdgeShade: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor.black, NSColor.black.withAlphaComponent(0)])?.draw(in: bounds, angle: 0)
    }
}
