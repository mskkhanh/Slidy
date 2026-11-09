import AppKit

/// Copy and paste of slide objects (also across slides): shapes and text boxes travel as their XML, tables as a whole,
/// images as the picture file. Pasted objects keep their look and position and start without animation.
enum ObjectClipboard {
    static let type = NSPasteboard.PasteboardType("com.khanh.slidy.objects")
    struct Object: Codable {
        var kind: String          // "shape", "table" or "image"
        var xml: String?
        var image: String?
        var frame: [Double]       // x, y, width, height in slide points
    }
    struct Payload: Codable {
        var slide: String         // the slide the objects were copied from
        var objects: [Object]
    }
    @discardableResult
    static func write(_ selection: [SlideItem], from slide: Slide) -> Bool {
        var objects: [Object] = []
        var seenTables = Set<ObjectIdentifier>()
        var texts: [String] = []
        for item in selection {
            let frame = [item.frame.minX, item.frame.minY, item.frame.width, item.frame.height].map(Double.init)
            if item.isTableCell {
                guard let table = item.tableNode, seenTables.insert(ObjectIdentifier(table)).inserted else { continue }
                objects.append(Object(kind: "table", xml: table.xmlString, image: nil, frame: frame))
            } else if item.canMove {
                if let url = item.imageURL { objects.append(Object(kind: "image", xml: item.node.xmlString, image: url.path, frame: frame)) }
                else { objects.append(Object(kind: "shape", xml: item.node.xmlString, image: nil, frame: frame)); if !item.text.isEmpty { texts.append(item.text) } }
            }
        }
        guard !objects.isEmpty, let data = try? JSONEncoder().encode(Payload(slide: slide.path, objects: objects)) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([type, .string], owner: nil)
        board.setData(data, forType: type)
        board.setString(texts.joined(separator: "\n"), forType: .string)
        return true
    }
    static func read() -> Payload? {
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}

extension Presentation {
    private func clipboardFragment(_ text: String) -> XMLElement? {
        guard let document = try? xml("<root xmlns:p=\"\(presentationNS)\" xmlns:a=\"\(drawingNS)\" xmlns:r=\"\(relationshipNS)\">\(text)</root>"),
              let element = document.rootElement()?.elements.first else { return nil }
        element.detach(); return element
    }
    /// Adds copied objects to `slide`, moved by `shift` points when pasting onto the slide they came from.
    @discardableResult
    func importObjects(_ payload: ObjectClipboard.Payload, into slide: Slide, shift: CGFloat) throws -> [SlideItem] {
        var created: [SlideItem] = []
        for object in payload.objects where object.frame.count == 4 {
            let frame = CGRect(x: object.frame[0] + shift, y: object.frame[1] + shift, width: object.frame[2], height: object.frame[3])
            switch object.kind {
            case "shape":
                guard let text = object.xml, let node = clipboardFragment(text), node.localName == "sp" else { continue }
                node.descendant("ph")?.detach()   // a pasted shape stands on its own, not on a layout placeholder
                node.descendant("cNvPr")?.set("id", nextID(slide))
                slide.tree.addChild(node)
                let item = parseItem(node, inherited: nil, rels: [:])
                item.updateFrame(frame)
                item.order = (slide.items.map(\.order).max() ?? 0) + 1
                slide.items.append(item); created.append(item)
            case "table":
                guard let text = object.xml, let node = clipboardFragment(text), node.localName == "graphicFrame", node.descendant("tbl") != nil else { continue }
                node.descendant("cNvPr")?.set("id", nextID(slide))
                if shift != 0, let offset = node.child("xfrm")?.child("off") {
                    offset.set("x", String(Int(offset.number("x") + Double(shift) * emu))); offset.set("y", String(Int(offset.number("y") + Double(shift) * emu)))
                }
                slide.tree.addChild(node)
                let cells = parseTable(node)
                slide.items += cells; created += cells
            case "image":
                guard let path = object.image, FileManager.default.fileExists(atPath: path) else { continue }
                let item = try addImage(to: slide, url: URL(fileURLWithPath: path))
                item.updateFrame(frame); created.append(item)
                // A copied picture keeps its own corners and shadow, whatever a freshly inserted one would get.
                if let text = object.xml, let original = clipboardFragment(text), let source = original.child("spPr"), let properties = item.node.child("spPr") {
                    properties.child("prstGeom")?.detach(); properties.child("effectLst")?.detach()
                    if let geometry = source.child("prstGeom")?.copy() as? XMLElement { properties.addChild(geometry) }
                    if let effects = source.child("effectLst")?.copy() as? XMLElement { properties.addChild(effects) }
                    item.geometry = source.child("prstGeom")?.attr("prst") ?? "rect"; item.cornerRatio = 1.0 / 6; item.shadow = nil
                    if let adjust = source.child("prstGeom")?.child("avLst")?.all("gd").first(where: { $0.attr("name") == "adj" }), let formula = adjust.attr("fmla"), let value = Double(formula.replacingOccurrences(of: "val ", with: "")) { item.cornerRatio = CGFloat(value / 100000) }
                    if let shadow = source.child("effectLst")?.child("outerShdw") {
                        let angle = shadow.number("dir") / 60000 * .pi / 180, distance = shadow.number("dist") / emu
                        item.shadow = ObjectShadow(blur: shadow.number("blurRad") / emu, dx: CGFloat(cos(angle) * distance), dy: CGFloat(sin(angle) * distance), color: color(shadow) ?? NSColor(white: 0, alpha: 0.25))
                    }
                }
            default: continue
            }
        }
        // Pasted objects start without animation.
        created.filter { $0.canMove && $0.hasFade }.forEach { slide.removeFade(from: $0) }
        slide.timingDirty = true
        return created
    }
}
