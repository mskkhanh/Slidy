import AppKit

// Hyperlinks in text: <a:hlinkClick r:id="..."/> inside a run's properties, with the address in the slide's relationships
// (Type .../hyperlink, TargetMode External). PowerPoint reads the same markup.

extension Presentation {
    /// rId -> address of every external hyperlink of a slide.
    func hyperlinkTargets(_ slidePath: String) -> [String: String] {
        let name = (slidePath as NSString).lastPathComponent
        let rels = folder.appendingPathComponent((slidePath as NSString).deletingLastPathComponent).appendingPathComponent("_rels/\(name).rels")
        guard let document = try? readXML(rels) else { return [:] }
        var result: [String: String] = [:]
        for entry in document.rootElement()?.elements ?? [] where (entry.attr("Type") ?? "").hasSuffix("/hyperlink") && entry.attr("TargetMode") == "External" {
            if let id = entry.attr("Id"), let target = entry.attr("Target") { result[id] = target }
        }
        return result
    }
    /// The relationship id for `address` on this slide; one is added when the slide does not have it yet.
    func hyperlinkID(for address: String, slidePath: String) throws -> String {
        let name = (slidePath as NSString).lastPathComponent
        let directory = folder.appendingPathComponent((slidePath as NSString).deletingLastPathComponent)
        let rels = directory.appendingPathComponent("_rels/\(name).rels")
        try FileManager.default.createDirectory(at: rels.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = try readXML(rels)
        guard let root = document.rootElement() else { throw AppError.message("A relationship is missing in the file.") }
        if let found = root.elements.first(where: { ($0.attr("Type") ?? "").hasSuffix("/hyperlink") && $0.attr("Target") == address && $0.attr("TargetMode") == "External" }), let id = found.attr("Id") { return id }
        let used = root.elements.compactMap { Int(($0.attr("Id") ?? "").dropFirst(3)) }
        let id = "rId\((used.max() ?? 0) + 1)"
        let entry = XMLElement(name: "Relationship")
        entry.set("Id", id); entry.set("Type", "\(relationshipNS)/hyperlink"); entry.set("Target", address); entry.set("TargetMode", "External")
        root.addChild(entry)
        try document.xmlData.write(to: rels, options: .atomic)
        return id
    }
    /// Writes a link (or none) on every character: `addresses[paragraph][utf16 offset]`. Runs are split where it changes.
    func applyLinks(_ item: SlideItem, addresses: [[String?]]) {
        guard let body = item.textBody, let slide = slides.first(where: { $0.items.contains { $0 === item } }) else { return }
        let key = ObjectIdentifier(slide.document)
        func mark(_ run: XMLElement, _ address: String?) {
            let properties = run.child("rPr") ?? { let created = fragment("<a:rPr/>"); run.insertChild(created, at: 0); return created }()
            properties.child("hlinkClick")?.detach()
            guard let address, let id = try? hyperlinkID(for: address, slidePath: slide.path) else { return }
            linkTargets[key, default: [:]][id] = address
            let click = fragment("<a:hlinkClick r:id=\"\(id)\"/>")
            if let extra = properties.child("extLst") { properties.insertChild(click, at: extra.index) } else { properties.addChild(click) }
        }
        for (index, paragraph) in body.all("p").enumerated() where index < addresses.count {
            let line = addresses[index]
            let runs = paragraph.elements.filter { ["r", "br", "fld"].contains($0.localName ?? "") }
            let lengths = runs.map { $0.localName == "br" ? 1 : (($0.child("t")?.textContent ?? "") as NSString).length }
            guard lengths.reduce(0, +) == line.count else { continue }
            var offset = 0
            for (run, length) in zip(runs, lengths) {
                defer { offset += length }
                guard length > 0, run.localName == "r" else { continue }
                let part = Array(line[offset..<(offset + length)])
                if part.allSatisfy({ $0 == part[0] }) { mark(run, part[0]); continue }
                let text = (run.child("t")?.textContent ?? "") as NSString
                var position = run.index, start = 0
                run.detach()
                while start < length {
                    var end = start + 1
                    while end < length, part[end] == part[start] { end += 1 }
                    let piece = run.copy() as! XMLElement
                    piece.child("t")?.stringValue = text.substring(with: NSRange(location: start, length: end - start))
                    mark(piece, part[start])
                    paragraph.insertChild(piece, at: position); position += 1; start = end
                }
            }
        }
        configureText(item); fitFrame(item)
    }
    /// How a linked run is drawn in Slidy: just underlined, the text keeps its own color.
    func linkAttributes(_ base: [NSAttributedString.Key: Any], url: URL) -> [NSAttributedString.Key: Any] {
        var result = base
        result[.link] = url
        result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        return result
    }
}
