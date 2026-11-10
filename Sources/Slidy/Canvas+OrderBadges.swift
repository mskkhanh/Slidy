import AppKit
import CoreText
import QuartzCore

/// The small Fade order numbers shown next to objects while editing.
extension CanvasView {
    func updateOrderBadges() {
        badgeViews.forEach { $0.removeFromSuperview() }; badgeViews = []
        guard showsOrderBadges, !presenting, let slide else { return }
        let diameter = 14 / surfaceScale
        for (number, group) in slide.fadeGroups.enumerated() {
            let grouped = group.count > 1
            let width = diameter * (number + 1 > 9 ? 1.25 : 0.8)   // just the digits
            for item in group {
                let badge = OrderBadgeView(number: number + 1, grouped: grouped)
                // Text: the number sits right above the first character (its real ink, not the box, which can be much taller).
                // Anything else: above the top-left corner (a picture has a resize handle there, so its number starts after it).
                let gap = 2 / surfaceScale
                var frame = CGRect(x: item.frame.minX + (item.imageURL != nil ? 16 / surfaceScale : 0), y: item.frame.minY - diameter - gap, width: width, height: diameter)
                var beside = CGPoint(x: item.frame.minX - width - gap, y: item.frame.minY + gap)
                if !item.text.isEmpty, let first = layoutParagraphs(item).first(where: { $0.storage.length > 0 }) {
                    let glyphs = first.manager.glyphRange(for: first.container)
                    if glyphs.length > 0 {
                        let line = first.manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                        let place = first.manager.location(forGlyphAt: glyphs.location)
                        let font = first.attributes[.font] as? NSFont ?? .systemFont(ofSize: 22)
                        let left = item.frame.minX + (first.bullet != nil ? first.bulletX : first.origin.x + line.minX + place.x)
                        let baseline = item.frame.minY + first.origin.y + line.minY + place.y
                        let inkTop = baseline - font.capHeight - font.pointSize * 0.2   // room for an accent on the first letter
                        frame.origin = CGPoint(x: left, y: inkTop - diameter)
                        beside = CGPoint(x: left - width - 2 * gap, y: baseline - font.capHeight / 2 - diameter / 2)
                    }
                }
                // If that spot would cover the text of another object (a heading right above, say), the number goes
                // just left of the first line instead.
                let covered = slide.items.contains { other in
                    other !== item && other.canMove && other.imageURL == nil && other.fill == nil && !other.text.isEmpty && other.frame.intersects(frame)
                }
                if covered, item.imageURL == nil { frame.origin = beside }
                // Badges of objects that start at nearly the same corner would pile up: slide each one right of the others.
                while badgeViews.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).intersects(frame) }) { frame.origin.x += width + 2 }
                badge.frame = frame
                surface.addSubview(badge); badgeViews.append(badge)
            }
        }
        raiseOverlay()
    }
}
