import AppKit

/// Changing the text of an object: content, list markers and spacing, bold.
extension Presentation {
    func updateText(_ item: SlideItem, text: String, bulletRows: Set<Int>? = nil, numberedRows: Set<Int>? = nil) {
        guard let body = item.textBody else { return }
        let previousBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
        let previousNumbered = Set(item.paragraphs.indices.filter { item.paragraphs[$0].isNumbered })
        guard text != item.text || (bulletRows.map { $0 != previousBullets } ?? false) || (numberedRows.map { $0 != previousNumbered } ?? false) else { return }
        let old = body.all("p")
        let lines = text.components(separatedBy: "\n")
        if lines.count != old.count, !item.paragraphDurations.isEmpty {
            let oldLines = item.paragraphs.map { $0.text.string }
            let changes = lines.difference(from: oldLines)
            var inserted = Set<Int>(), removed = Set<Int>()
            for change in changes {
                switch change {
                case .insert(let index, _, _): inserted.insert(index)
                case .remove(let index, _, _): removed.insert(index)
                }
            }
            let retained = zip(oldLines.indices.filter { !removed.contains($0) }, lines.indices.filter { !inserted.contains($0) })
            item.paragraphDurations = Dictionary(uniqueKeysWithValues: retained.compactMap { oldIndex, newIndex in
                item.paragraphDurations[oldIndex].map { (newIndex, $0) }
            })
        }
        let list = item.hasList
        let template = old.first
        for p in old { p.detach() }
        for (index, line) in lines.enumerated() {
            let original = index < old.count ? old[index] : template
            let p = (original?.copy() as? XMLElement) ?? fragment("<a:p><a:pPr/><a:r><a:rPr sz=\"2400\"/><a:t/></a:r></a:p>")
            let originalText = p.elements.filter { $0.localName == "r" || $0.localName == "br" }.map { $0.localName == "br" ? "\u{2028}" : ($0.child("t")?.stringValue ?? "") }.joined()
            if line != originalText {
                // Preserve styles on the unchanged prefix/suffix, including mixed runs.
                let attributed = NSMutableAttributedString(string: "")
                for run in p.elements where run.localName == "r" || run.localName == "br" {
                    let value = run.localName == "br" ? "\u{2028}" : (run.child("t")?.stringValue ?? "")
                    let style = run.child("rPr")?.xmlString ?? "<a:rPr sz=\"2400\"/>"
                    attributed.append(NSAttributedString(string: value, attributes: [NSAttributedString.Key("xmlStyle"): style]))
                }
                let before = Array(attributed.string.utf16), after = Array(line.utf16)
                var prefix = 0, suffix = 0
                while prefix < min(before.count, after.count) && before[prefix] == after[prefix] { prefix += 1 }
                while suffix < min(before.count, after.count) - prefix && before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
                let replacement = (line as NSString).substring(with: NSRange(location: prefix, length: after.count - prefix - suffix))
                let style = attributed.length > 0 ? attributed.attribute(NSAttributedString.Key("xmlStyle"), at: min(prefix, attributed.length - 1), effectiveRange: nil) as? String : nil
                attributed.replaceCharacters(in: NSRange(location: prefix, length: before.count - prefix - suffix), with: NSAttributedString(string: replacement, attributes: [NSAttributedString.Key("xmlStyle"): style ?? "<a:rPr sz=\"2400\"/>"]))
                p.elements.filter { ["r", "br", "fld"].contains($0.localName ?? "") }.forEach { $0.detach() }
                let ending = p.child("endParaRPr"); ending?.detach()
                attributed.enumerateAttribute(NSAttributedString.Key("xmlStyle"), in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    let style = value as? String ?? "<a:rPr sz=\"2400\"/>"
                    let pieces = (attributed.string as NSString).substring(with: range).components(separatedBy: "\u{2028}")
                    for (partIndex, piece) in pieces.enumerated() {
                        if partIndex > 0 { p.addChild(fragment("<a:br>\(style)</a:br>")) }
                        p.addChild(fragment("<a:r>\(style)<a:t>\(escapeXML(piece))</a:t></a:r>"))
                    }
                }
                if let ending { p.addChild(ending) }
            }
            let wantsBullet = bulletRows?.contains(index) ?? list
            let wantsNumber = wantsBullet && (numberedRows?.contains(index) ?? false)
            let hasBullet = p.child("pPr")?.child("buChar") != nil || p.child("pPr")?.child("buAutoNum") != nil
            let hasNumber = p.child("pPr")?.child("buAutoNum") != nil
            if wantsBullet != hasBullet || (wantsBullet && wantsNumber != hasNumber) {
                let pp = p.child("pPr") ?? XMLElement(name: "a:pPr")
                if pp.parent == nil { p.insertChild(pp, at: 0) }
                for name in ["buNone", "buChar", "buAutoNum"] { pp.child(name)?.detach() }
                let bullet = fragment(wantsBullet ? (wantsNumber ? "<a:buAutoNum type=\"arabicPeriod\"/>" : "<a:buChar char=\"•\"/>") : "<a:buNone/>")
                if let next = pp.elements.first(where: { ["tabLst", "defRPr", "extLst"].contains($0.localName ?? "") }) {
                    pp.insertChild(bullet, at: next.index)
                } else { pp.addChild(bullet) }
                // A paragraph that becomes a list item gets the standard list line spacing.
                if wantsBullet, !hasBullet { Self.applyListLineSpacing(to: pp, paragraph: p) }
                let hanging = wantsNumber ? "342900" : "285750"
                pp.set("marL", wantsBullet ? hanging : "0")
                pp.set("indent", wantsBullet ? "-" + hanging : "0")
            }
            body.addChild(p)
        }
        configureText(item)
        fitFrame(item)
        growTextBox(item)
    }
    /// The list rhythm Khanh settled on by eye: 1.94 × the font size from one paragraph to the next (42.6 pt for 22 pt text).
    /// Lines inside one paragraph stay compact (1.2 × the font size); the rest of the distance is space before the paragraph.
    static let listPitchFactor = 4259.0 / 2200.0
    static let listLineFactor = 1.2
    static let listGapFactor = listPitchFactor - listLineFactor
    /// Sets the standard spacing on one list paragraph (<a:lnSpc> and <a:spcBef> in points; <a:spcAft> removed).
    static func applyListLineSpacing(to properties: XMLElement, paragraph: XMLElement) {
        let size = Double(paragraph.child("r")?.child("rPr")?.attr("sz") ?? "2400") ?? 2400
        properties.child("lnSpc")?.detach(); properties.child("spcBef")?.detach(); properties.child("spcAft")?.detach()
        properties.insertChild(fragment("<a:spcBef><a:spcPts val=\"\(Int((size * listGapFactor).rounded()))\"/></a:spcBef>"), at: 0)
        properties.insertChild(fragment("<a:lnSpc><a:spcPts val=\"\(Int((size * listLineFactor).rounded()))\"/></a:lnSpc>"), at: 0)
    }
    /// Gives every list paragraph of a text object the standard spacing. Returns true when something changed.
    @discardableResult
    func standardizeListSpacing(_ item: SlideItem) -> Bool {
        guard let body = item.textBody else { return false }
        var changed = false
        for paragraph in body.all("p") {
            guard let properties = paragraph.child("pPr"), properties.child("buChar") != nil || properties.child("buAutoNum") != nil else { continue }
            let before = properties.xmlString
            Self.applyListLineSpacing(to: properties, paragraph: paragraph)
            if properties.xmlString != before { changed = true }
        }
        if changed { configureText(item); fitFrame(item) }
        return changed
    }
    /// Writes bold on / off per character (`flags[paragraph][utf16 offset]`) into the runs, splitting runs where it changes.
    func applyBold(_ item: SlideItem, flags: [[Bool]]) {
        guard let body = item.textBody else { return }
        for (index, paragraph) in body.all("p").enumerated() where index < flags.count {
            let line = flags[index]
            let runs = paragraph.elements.filter { ["r", "br", "fld"].contains($0.localName ?? "") }
            let lengths = runs.map { $0.localName == "br" ? 1 : (($0.child("t")?.stringValue ?? "") as NSString).length }
            guard lengths.reduce(0, +) == line.count else { continue }
            var offset = 0
            for (run, length) in zip(runs, lengths) {
                defer { offset += length }
                guard length > 0 else { continue }
                let part = Array(line[offset..<(offset + length)])
                func mark(_ element: XMLElement, _ bold: Bool) {
                    let properties = element.child("rPr") ?? { let created = fragment("<a:rPr/>"); element.insertChild(created, at: 0); return created }()
                    properties.set("b", bold ? "1" : "0")
                }
                if run.localName != "r" || part.allSatisfy({ $0 == part[0] }) { mark(run, part[0]); continue }
                let text = (run.child("t")?.stringValue ?? "") as NSString
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
}
