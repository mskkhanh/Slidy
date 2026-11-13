import AppKit

// Links on the slide: hovering a link shows a small "Copy" chip, clicking opens it in the default browser.

/// The little pill above a hovered link: just a Copy button.
final class LinkChip: NSView {
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    var address = ""
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7; layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.96).cgColor
        layer?.borderWidth = 1; layer?.borderColor = NSColor(white: 0.45, alpha: 0.5).cgColor
        copy.isBordered = false; copy.font = .systemFont(ofSize: 11, weight: .semibold); copy.contentTintColor = AppDelegate.accent
        copy.target = self; copy.action = #selector(copyAddress)
        addSubview(copy)
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ address: String) {
        self.address = address
        copy.title = "Copy"; copy.sizeToFit()
        frame.size = NSSize(width: copy.frame.width + 18, height: 22)
        copy.frame = NSRect(x: 9, y: (22 - copy.frame.height) / 2, width: copy.frame.width, height: copy.frame.height)
    }
    @objc func copyAddress() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
        copy.title = "Copied"; copy.sizeToFit()
        frame.size.width = copy.frame.width + 18; copy.frame.origin.x = 9
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

extension CanvasView {
    /// The link under a point of the slide (slide coordinates): its address and the rectangle of the linked text.
    func linkAt(_ point: CGPoint) -> (url: URL, rect: CGRect)? {
        guard let slide else { return nil }
        for item in slide.items.reversed() where item.textBody != nil && item.frame.contains(point) {
            for layout in layoutParagraphs(item) {
                let local = CGPoint(x: point.x - item.frame.minX - layout.origin.x, y: point.y - item.frame.minY - layout.origin.y)
                guard local.y >= 0, local.y <= layout.height, layout.storage.length > 0 else { continue }
                let glyph = layout.manager.glyphIndex(for: local, in: layout.container, fractionOfDistanceThroughGlyph: nil)
                let hit = layout.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: layout.container).insetBy(dx: -1, dy: -1)
                guard hit.contains(local) else { continue }
                let character = layout.manager.characterIndexForGlyph(at: glyph)
                var range = NSRange()
                guard character < layout.storage.length, let url = layout.storage.attribute(.slidyLink, at: character, effectiveRange: &range) as? URL else { continue }
                let glyphs = layout.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layout.manager.boundingRect(forGlyphRange: glyphs, in: layout.container)
                rect.origin.x += item.frame.minX + layout.origin.x; rect.origin.y += item.frame.minY + layout.origin.y
                return (url, rect)
            }
        }
        return nil
    }
    func slidePoint(_ event: NSEvent) -> CGPoint { surface.convert(event.locationInWindow, from: nil) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = linkTracking { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); linkTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard slide != nil, editor == nil, !isCropping, dragOrigin == nil else { hideLinkChip(); return }
        // Over the chip itself it stays (the canvas also hears moves that happen over the chip).
        if !linkChip.isHidden, linkChip.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) { cancelHideLinkChip(); return }
        guard let found = linkAt(slidePoint(event)) else { scheduleHideLinkChip(); return }
        NSCursor.pointingHand.set()
        guard !presenting else { return }
        cancelHideLinkChip()
        if linkChip.superview == nil { addSubview(linkChip) }
        if linkChip.address != found.url.absoluteString || linkChip.isHidden || linkChip.frame.width < 20 { linkChip.show(found.url.absoluteString) }
        linkChip.isHidden = false
        let rect = surface.convert(found.rect, to: self)
        // At the top right end of the link: the chip's right edge lines up with where the link ends.
        var origin = CGPoint(x: min(max(4, rect.maxX - linkChip.frame.width), max(4, bounds.width - linkChip.frame.width - 4)), y: rect.minY - linkChip.frame.height - 1)
        if origin.y < 4 { origin.y = rect.maxY + 1 }   // no room above: below the link
        linkChip.setFrameOrigin(origin)
    }
    override func mouseExited(with event: NSEvent) { scheduleHideLinkChip() }
    func hideLinkChip() { cancelHideLinkChip(); linkChip.isHidden = true }
    func cancelHideLinkChip() { linkHideTimer?.invalidate(); linkHideTimer = nil }
    /// A short delay, so the pointer can travel from the link to the chip.
    func scheduleHideLinkChip() {
        guard !linkChip.isHidden, linkHideTimer == nil else { return }
        linkHideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.hideLinkChip() }
    }
    func configureLinkChip() {
        linkChip.isHidden = true
        linkChip.onEnter = { [weak self] in self?.cancelHideLinkChip() }
        linkChip.onExit = { [weak self] in self?.scheduleHideLinkChip() }
    }

    /// A click on a link opens it; it waits out the double-click interval so double-clicking a link still edits its text.
    func openLinkAfterClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty, let found = linkAt(slidePoint(event)) else { return false }
        pendingLinkOpen?.cancel()
        let work = DispatchWorkItem { NSWorkspace.shared.open(found.url) }
        pendingLinkOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        return true
    }
    /// While presenting a click on a link opens it right away (and does not advance); elsewhere it advances as usual.
    func openLinkWhilePresenting(_ event: NSEvent) -> Bool {
        guard presenting, let found = linkAt(slidePoint(event)) else { return false }
        NSWorkspace.shared.open(found.url); return true
    }
}
