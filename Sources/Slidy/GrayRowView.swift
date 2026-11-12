import AppKit

/// Row with a soft gray selection, used by the slide list and the recent files list.
/// Buttons marked `HoverReveal.identifier` (the ✕ of a file or heading) are only visible while the pointer is over the row.
final class GrayRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 1, alpha: 0.30) : NSColor(white: 0, alpha: 0.18)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        // A row that appears under the pointer (after a reload) shows its button right away.
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { setReveal(true) } else { setReveal(false) }
    }
    override func mouseEntered(with event: NSEvent) { setReveal(true) }
    override func mouseExited(with event: NSEvent) { setReveal(false) }
    private func setReveal(_ shown: Bool) {
        func visit(_ view: NSView) {
            for child in view.subviews {
                if child.identifier == HoverReveal.identifier { child.alphaValue = shown ? 1 : 0 }
                if child.identifier == HoverReveal.hideIdentifier { child.alphaValue = shown ? 0 : 1 }
                visit(child)
            }
        }
        visit(self)
    }
    /// A cell that is added after the row appeared starts hidden.
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); DispatchQueue.main.async { [weak self] in self?.updateTrackingAreas() } }
}

enum HoverReveal {
    static let identifier = NSUserInterfaceItemIdentifier("hoverReveal")
    /// Small gray text (date, count) that gives way to the ✕ while the pointer is over the row.
    static let hideIdentifier = NSUserInterfaceItemIdentifier("hoverHide")
}
