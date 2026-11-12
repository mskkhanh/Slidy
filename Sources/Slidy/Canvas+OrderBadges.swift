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
                // Text: the number sits right before the first character, on its line (its real position, not the box,
                // which can be much taller). Anything else (a picture, a shape): just left of its top-left corner.
                let gap = 3 / surfaceScale
                var frame = CGRect(x: item.frame.minX - width - gap, y: item.frame.minY, width: width, height: diameter)
                // A picture has resize handles on all four corners, so its number sits above the top edge, past the corner handle.
                if item.imageURL != nil { frame.origin = CGPoint(x: item.frame.minX + 16 / surfaceScale, y: item.frame.minY - diameter - gap) }
                if !item.text.isEmpty, let first = layoutParagraphs(item).first(where: { $0.storage.length > 0 }) {
                    let glyphs = first.manager.glyphRange(for: first.container)
                    if glyphs.length > 0 {
                        let line = first.manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                        let place = first.manager.location(forGlyphAt: glyphs.location)
                        let font = first.attributes[.font] as? NSFont ?? .systemFont(ofSize: 22)
                        let left = item.frame.minX + (first.bullet != nil ? first.bulletX : first.origin.x + line.minX + place.x)
                        let baseline = item.frame.minY + first.origin.y + line.minY + place.y
                        frame.origin = CGPoint(x: left - width - gap, y: baseline - font.capHeight / 2 - diameter / 2)
                    }
                }
                // Numbers of objects that start at the same place would pile up: each one goes further left.
                while badgeViews.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).intersects(frame) }) { frame.origin.x -= width + 2 }
                badge.frame = frame
                surface.addSubview(badge); badgeViews.append(badge)
            }
        }
        raiseOverlay()
    }
}
