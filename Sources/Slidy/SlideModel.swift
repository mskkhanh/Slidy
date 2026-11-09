import AppKit
import Foundation
import ImageIO
import Foundation

// Slide model: paragraphs, objects (SlideItem) and slides, parsed from and written back to the .pptx XML.
let defaultFadeDuration = 0.1

struct Paragraph {
    var text: NSAttributedString
    var bullet: String?
    /// A numbered item ("1.", "2." ...) rather than a dot.
    var isNumbered: Bool { bullet?.first?.isNumber == true }
    var left: CGFloat
    var indent: CGFloat
    var spacing: CGFloat
    var before: CGFloat
    var after: CGFloat
    var alignment: NSTextAlignment
    var xmlIndex: Int
}
final class SlideItem {
    let node: XMLElement
    let id: String
    var frame: CGRect
    var rotation: CGFloat = 0
    var fill: NSColor?
    var stroke: NSColor?
    var strokeWidth: CGFloat = 0
    var geometry = "rect"
    var paragraphs: [Paragraph] = []
    var insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    var anchor = "t"
    var imageURL: URL?
    var imageCrop = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    var isTableCell = false
    var inherited = false
    private static let fadeOffURI = "urn:slidepresent:fade-off"
    private var fadeOffMarker: XMLElement? {
        node.child("extLst")?.all("ext").first { $0.attr("uri") == Self.fadeOffURI }
    }
    var fade = false
    var hasFade: Bool { fade || (hasList && fadeOffMarker == nil) }
    func removeFade() {
        fade = false
        fadeGroup = nil
        if hasList && fadeOffMarker == nil {
            node.ensure("p:extLst").addChild(fragment("<p:ext uri=\"\(Self.fadeOffURI)\"/>"))
        }
    }
    func enableFade() {
        if let marker = fadeOffMarker {
            let list = marker.parent as? XMLElement
            marker.detach()
            if list?.elements.isEmpty == true { list?.detach() }
        }
        fade = true
    }
    var duration = defaultFadeDuration
    var fadeGroup: String?
    var fadesByParagraph: Bool { hasList && fadeGroup == nil }
    var paragraphDurations: [Int: Double] = [:]
    func fadeDuration(for paragraph: Int?) -> Double { paragraph.flatMap { paragraphDurations[$0] } ?? duration }
    var order = 0
    var hasList: Bool { paragraphs.contains { $0.bullet != nil } }
    var textBody: XMLElement? { node.child("txBody") }
    var canMove: Bool { !isTableCell && !inherited }
    var text: String { paragraphs.map { $0.text.string }.joined(separator: "\n") }
    init(node: XMLElement, id: String, frame: CGRect) { self.node = node; self.id = id; self.frame = frame }
    func updateFrame(_ value: CGRect) {
        frame = value
        let xfrm = node.ensure("p:spPr").ensure("a:xfrm")
        let off = xfrm.ensure("a:off"), ext = xfrm.ensure("a:ext")
        off.set("x", String(Int(value.minX * emu))); off.set("y", String(Int(value.minY * emu)))
        ext.set("cx", String(Int(value.width * emu))); ext.set("cy", String(Int(value.height * emu)))
    }
}
final class Slide {
    let path: String
    /// This slide's <p:sldId> entry in presentation.xml; moving it there is how slides are reordered.
    var listEntry: XMLElement?
    var document: XMLDocument
    var items: [SlideItem] = []
    var background = NSColor.white
    var originalTiming: Bool
    var timingDirty = false
    var writtenXML: Data
    var warnings: [String] = []
    var title: String { items.first(where: { !$0.text.isEmpty })?.text.replacingOccurrences(of: "\n", with: " ") ?? "Slide" }
    var tree: XMLElement { document.rootElement()!.child("cSld")!.child("spTree")! }
    init(path: String, document: XMLDocument) {
        self.path = path; self.document = document; self.writtenXML = document.xmlData
        originalTiming = document.rootElement()?.child("timing") != nil
    }
    var fadeGroups: [[SlideItem]] {
        let ordered = items.enumerated().filter {
            $0.element.canMove && $0.element.hasFade
        }.sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
        var groups: [[SlideItem]] = []
        var positions: [String: Int] = [:]
        for (_, item) in ordered {
            if let key = item.fadeGroup, let position = positions[key] {
                groups[position].append(item)
            } else {
                if let key = item.fadeGroup { positions[key] = groups.count }
                groups.append([item])
            }
        }
        return groups
    }
    var fadeSequence: [[(item: SlideItem, paragraph: Int?)]] {
        fadeGroups.flatMap { group -> [[(SlideItem, Int?)]] in
            if group.count == 1, let item = group.first, item.fadesByParagraph {
                return item.paragraphs.filter { !$0.text.string.isEmpty }.map { [(item, $0.xmlIndex)] }
            }
            return [group.map { ($0, nil) }]
        }
    }
    func applyFade(to selection: [SlideItem]) {
        let group = selection.count > 1 ? UUID().uuidString : nil
        let order = (items.map(\.order).max() ?? 0) + 1
        for item in selection {
            item.enableFade()
            item.duration = defaultFadeDuration
            item.paragraphDurations.removeAll()
            item.fadeGroup = group
            item.order = order
        }
        timingDirty = true
    }
    func removeFade(from item: SlideItem) {
        item.removeFade()
        timingDirty = true
    }
    /// Renumbers effects 0, 1, 2... in their current order (members of a group share one number).
    func normalizeFadeOrder() {
        for (index, items) in fadeGroups.enumerated() { for item in items { item.order = index } }
    }
    func moveFadeGroup(from source: Int, to insertion: Int) {
        var groups = fadeGroups
        let group = groups.remove(at: source)
        groups.insert(group, at: insertion > source ? insertion - 1 : insertion)
        for (index, items) in groups.enumerated() {
            for item in items { item.order = index }
        }
        timingDirty = true
    }
}
