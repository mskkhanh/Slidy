import AppKit

/// Keeping a text box the right size for its text: grow, auto-fit, trim.
extension Presentation {
    /// A plain text box (no fill, no outline) whose text no longer fits gets taller, so its frame always surrounds the text.
    func growTextBox(_ item: SlideItem) {
        guard !item.autoFit, item.canMove, item.textBody != nil, item.fill == nil, item.stroke == nil, item.node.child("style") == nil else { return }
        let anchor = item.anchor; item.anchor = "t"
        let layouts = layoutParagraphs(item)
        item.anchor = anchor
        let used = ceil((layouts.last.map { $0.origin.y + $0.height } ?? item.insets.top) + item.insets.bottom)
        guard used > item.frame.height + 1 else { return }
        var frame = item.frame
        if anchor == "ctr" { frame.origin.y -= (used - frame.height) / 2 } else if anchor == "b" { frame.origin.y -= used - frame.height }
        frame.size.height = used
        item.updateFrame(frame)
    }
    /// How wide an auto-fit text box may grow before its text wraps: up to the slide's right margin, or, when the box
    /// sits on a card (a filled shape that contains it), up to the card's right edge with the same padding as on the left.
    func maxAutoFitWidth(for item: SlideItem) -> CGFloat {
        var limit = size.width - textLeftMargin
        let slide = slides.first { $0.items.contains { $0 === item } }
        let cards = slide?.items.filter { $0 !== item && $0.canMove && $0.fill != nil && $0.imageURL == nil && $0.frame.insetBy(dx: -1, dy: -1).contains(item.frame.origin)
            && $0.frame.maxY >= item.frame.minY + min(item.frame.height, 12) } ?? []
        if let card = cards.min(by: { $0.frame.width < $1.frame.width }) {
            limit = min(limit, card.frame.maxX - max(0, item.frame.minX - card.frame.minX))
        }
        return max(80, limit - item.frame.minX)
    }
    /// Makes the box of an auto-fit text object hug its text: as wide as the longest line (up to the right margin)
    /// and as tall as its lines. Other boxes are left exactly as they are.
    func fitFrame(_ item: SlideItem) {
        guard item.autoFit, item.textBody != nil else { return }
        let maxWidth = maxAutoFitWidth(for: item)
        var natural: CGFloat = 0
        for paragraph in item.paragraphs {
            let line = paragraph.text.boundingRect(with: CGSize(width: 100000, height: 1000), options: [.usesLineFragmentOrigin]).width
            natural = max(natural, line + paragraph.left + (paragraph.bullet != nil ? 24 : 0))
        }
        var frame = item.frame
        frame.size.width = min(maxWidth, max(60, ceil(natural) + item.insets.left + item.insets.right + 2))
        item.frame = frame
        let anchor = item.anchor; item.anchor = "t"   // measure from the top, whatever the stored anchor
        let layouts = layoutParagraphs(item)
        item.anchor = anchor
        let used = (layouts.last.map { $0.origin.y + $0.height } ?? item.insets.top) + item.insets.bottom
        frame.size.height = max(24, ceil(used))
        item.updateFrame(frame)
    }
    /// Shrinks a plain text box (no fill, no outline) to its text, so the box and its order badge sit next to what you see.
    /// The text stays exactly where it is: a left-aligned box keeps its left edge, a centered one its center, and so on.
    /// A box whose text wraps keeps its width (only the empty space below goes), so no line breaks differently.
    /// Returns true when the box changed (with `dryRun`, when it would change; nothing is touched then).
    @discardableResult
    func trimTextBox(_ item: SlideItem, dryRun: Bool = false) -> Bool {
        guard item.canMove, item.textBody != nil, item.imageURL == nil, item.fill == nil, item.stroke == nil,
              item.rotation == 0, item.node.child("style") == nil,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = item.anchor; item.anchor = "t"
        let layouts = layoutParagraphs(item)
        item.anchor = anchor
        guard !layouts.isEmpty, layouts.count == item.paragraphs.count else { return false }
        var needed: CGFloat = 0, wraps = false
        for (layout, paragraph) in zip(layouts, item.paragraphs) {
            let glyphs = layout.manager.glyphRange(for: layout.container)
            var lines = 0, index = glyphs.location
            while index < NSMaxRange(glyphs) {
                var range = NSRange(); layout.manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
                lines += 1; index = NSMaxRange(range)
            }
            let breaks = paragraph.text.string.components(separatedBy: "\u{2028}").count
            if lines > breaks { wraps = true }
            needed = max(needed, layout.origin.x + layout.manager.usedRect(for: layout.container).width + item.insets.right)
        }
        let alignments = Set(item.paragraphs.map(\.alignment))
        var frame = item.frame
        if !wraps, alignments.count == 1, let alignment = alignments.first, alignment != .justified {
            let width = min(frame.width, ceil(needed * 1.03 + 4))   // a little slack: PowerPoint measures text slightly differently
            if alignment == .center { frame.origin.x += (frame.width - width) / 2 } else if alignment == .right { frame.origin.x += frame.width - width }
            frame.size.width = width
        }
        let used = (layouts.last.map { $0.origin.y + $0.height } ?? item.insets.top) + item.insets.bottom
        let height = max(12, ceil(used))   // exactly the text: shorter boxes shrink, boxes the text overflows grow
        if anchor == "ctr" { frame.origin.y += (frame.height - height) / 2 } else if anchor == "b" { frame.origin.y += frame.height - height }
        frame.size.height = height
        // A one-line, left-aligned box becomes auto-fit, so it grows again when more text is typed.
        let bodyPr = item.textBody?.child("bodyPr")
        let makesAutoFit = !wraps && !item.autoFit && anchor == "t" && (alignments == [.left] || alignments == [.natural]) && bodyPr != nil
        let shrinks = item.frame.width - frame.width >= 2 || abs(item.frame.height - frame.height) >= 2
        guard shrinks || makesAutoFit else { return false }
        if dryRun { return true }
        if makesAutoFit, let bodyPr {
            for name in ["normAutofit", "noAutofit", "spAutoFit"] { bodyPr.child(name)?.detach() }
            bodyPr.addChild(fragment("<a:spAutoFit/>"))
            item.autoFit = true
        }
        if shrinks { item.updateFrame(frame) }
        return true
    }
    /// Switches a text object to auto-fit and sizes it to its text.
    func enableAutoFit(_ item: SlideItem) {
        guard let bodyPr = item.textBody?.child("bodyPr") else { return }
        for name in ["normAutofit", "noAutofit", "spAutoFit"] { bodyPr.child(name)?.detach() }
        bodyPr.addChild(fragment("<a:spAutoFit/>"))
        item.autoFit = true
        fitFrame(item)
    }
}
