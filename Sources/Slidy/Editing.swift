import AppKit
import ArchiveBridge

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
    }
    /// Makes the box of an auto-fit text object hug its text: as wide as the longest line (up to the right margin)
    /// and as tall as its lines. Other boxes are left exactly as they are.
    func fitFrame(_ item: SlideItem) {
        guard item.autoFit, item.textBody != nil else { return }
        let maxWidth = max(80, size.width - item.frame.minX - textLeftMargin)
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
    /// Returns true when the box changed.
    @discardableResult
    func trimTextBox(_ item: SlideItem) -> Bool {
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
        let height = min(frame.height, max(12, ceil(used)))
        if anchor == "ctr" { frame.origin.y += (frame.height - height) / 2 } else if anchor == "b" { frame.origin.y += frame.height - height }
        frame.size.height = height
        guard item.frame.width - frame.width >= 2 || item.frame.height - frame.height >= 2 else { return false }
        item.updateFrame(frame)
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
    static let cellTextPrefix = "Cell text "
    /// Moves the text of every cell of a table into its own text box placed exactly over the cell, so each one
    /// can fade by itself (a .pptx table can only be animated as a whole). The table keeps its grid and fills.
    @discardableResult
    func splitCellText(ofTable tableID: String, in slide: Slide) -> [SlideItem] {
        let cells = slide.items.filter { $0.tableID == tableID && !$0.isTableFrame }
        guard let table = cells.first?.tableNode else { return [] }
        var created: [SlideItem] = []
        for cell in cells where !cell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let body = cell.node.child("txBody") else { continue }
            let id = nextID(slide)
            let props = cell.node.child("tcPr")
            func inset(_ name: String, _ standard: Int) -> Int { Int(props?.number(name, Double(standard)) ?? Double(standard)) }
            let node = fragment("<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(Self.cellTextPrefix)\(escapeXML(tableID))\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"\(inset("marL", 91440))\" tIns=\"\(inset("marT", 45720))\" rIns=\"\(inset("marR", 91440))\" bIns=\"\(inset("marB", 45720))\" anchor=\"\(props?.attr("anchor") ?? "t")\"><a:noAutofit/></a:bodyPr><a:lstStyle/></p:txBody></p:sp>")
            let paragraphs = body.all("p")
            let size = paragraphs.first?.child("r")?.child("rPr")?.attr("sz")
            for paragraph in paragraphs { paragraph.detach(); node.child("txBody")!.addChild(paragraph) }
            body.addChild(fragment("<a:p><a:endParaRPr\(size.map { " sz=\"\($0)\"" } ?? "")/></a:p>"))
            slide.tree.insertChild(node, at: table.index + 1 + created.count)
            let item = parseItem(node, inherited: nil, rels: [:])
            item.updateFrame(cell.frame)
            trimTextBox(item)   // hug the text, so its order badge sits right above it
            configureText(cell)
            let last = slide.items.lastIndex { $0.tableID == tableID || $0.cellTextOf == tableID } ?? (slide.items.count - 1)
            slide.items.insert(item, at: last + 1)
            created.append(item)
        }
        return created
    }
    func nextID(_ slide: Slide) -> String {
        String((slide.document.rootElement()?.descendants("cNvPr").compactMap { Int($0.attr("id") ?? "") }.max() ?? 1) + 1)
    }
    @discardableResult func addText(to slide: Slide, list: Bool, heading: Bool = false) -> SlideItem {
        let id = nextID(slide)
        let foreground = (slide.background.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5 ? "FFFFFF" : "1F2937"
        let name = heading ? "Heading" : (list ? "List" : "Text")
        let placeholder = heading ? "Heading" : (list ? "First item" : "Text")
        let fontSize = heading ? 4000 : 2400
        let typeface = heading ? majorFont : minorFont
        let bullet = list ? "<a:buChar char=\"•\"/>" : "<a:buNone/>"
        let p = "<a:p><a:pPr marL=\"\(list ? 304800 : 0)\" indent=\"\(list ? -304800 : 0)\"><a:lnSpc><a:spcPts val=\"\(heading ? 4800 : (list ? Int((Double(fontSize) * Self.listLineFactor).rounded()) : 3360))\"/></a:lnSpc>\(list ? "<a:spcBef><a:spcPts val=\"\(Int((Double(fontSize) * Self.listGapFactor).rounded()))\"/></a:spcBef>" : "")\(bullet)</a:pPr><a:r><a:rPr sz=\"\(fontSize)\" b=\"\(heading ? 1 : 0)\"><a:solidFill><a:srgbClr val=\"\(foreground)\"/></a:solidFill><a:latin typeface=\"\(escapeXML(typeface))\"/></a:rPr><a:t>\(placeholder)</a:t></a:r></a:p>"
        let node = fragment("<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr lIns=\"0\" rIns=\"0\" tIns=\"0\" bIns=\"0\" wrap=\"square\"/><a:lstStyle/>\(p)</p:txBody></p:sp>")
        slide.tree.addChild(node)
        let item = SlideItem(node: node, id: id, frame: .zero)
        item.updateFrame(CGRect(x: textLeftMargin, y: size.height * (heading ? 0.10 : 0.28),
                                width: size.width * (heading ? 0.86 : 0.65), height: size.height * (heading ? 0.19 : 0.4)))
        configureText(item); item.fade = true; item.order = (slide.items.map(\.order).max() ?? 0) + 1
        slide.items.append(item); slide.timingDirty = true
        return item
    }
    @discardableResult func addImage(to slide: Slide, url: URL, pasted: Bool = false) throws -> SlideItem {
        guard let sourceImage = NSImage(contentsOf: url), sourceImage.size.width > 0, sourceImage.size.height > 0 else { throw AppError.message("Can’t read this picture.") }
        let suffix = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(suffix) else { throw AppError.message("Choose a PNG or JPEG picture.") }
        let mediaName = "slidy-\(UUID().uuidString).\(suffix)"
        let media = folder.appendingPathComponent("ppt/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: media.appendingPathComponent(mediaName))
        let slideURL = folder.appendingPathComponent(slide.path)
        let relURL = slideURL.deletingLastPathComponent().appendingPathComponent("_rels/\(slideURL.lastPathComponent).rels")
        let relDoc = try (try? readXML(relURL)) ?? xml("<Relationships xmlns=\"\(packageNS)\"/>")
        let rid = "rIdSP" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let relationship = XMLElement(name: "Relationship", uri: packageNS)
        relationship.set("Id", rid); relationship.set("Type", relationshipNS + "/image"); relationship.set("Target", "../media/" + mediaName)
        relDoc.rootElement()!.addChild(relationship)
        try FileManager.default.createDirectory(at: relURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try relDoc.xmlData.write(to: relURL, options: .atomic)
        let typesURL = folder.appendingPathComponent("[Content_Types].xml")
        let types = try readXML(typesURL)
        if !types.rootElement()!.elements.contains(where: { $0.attr("Extension") == suffix }) {
            let entry = XMLElement(name: "Default", uri: "http://schemas.openxmlformats.org/package/2006/content-types")
            entry.set("Extension", suffix); entry.set("ContentType", suffix == "png" ? "image/png" : "image/jpeg")
            types.rootElement()!.addChild(entry); try types.xmlData.write(to: typesURL, options: .atomic)
        }
        let id = nextID(slide)
        let node = fragment("<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val 3000\"/></a:avLst></a:prstGeom></p:spPr></p:pic>")
        slide.tree.addChild(node)
        let item = SlideItem(node: node, id: id, frame: .zero)
        let maxWidth = size.width * (pasted ? 0.46 : 0.6)
        let maxHeight = size.height * (pasted ? 0.86 : 0.6)
        let ratio = min(maxWidth / sourceImage.size.width, maxHeight / sourceImage.size.height)
        let dimensions = CGSize(width: sourceImage.size.width * ratio, height: sourceImage.size.height * ratio)
        item.updateFrame(CGRect(x: size.width * (pasted ? 0.75 : 0.5) - dimensions.width / 2, y: (size.height - dimensions.height) / 2, width: dimensions.width, height: dimensions.height))
        item.imageURL = media.appendingPathComponent(mediaName); item.order = (slide.items.map(\.order).max() ?? 0) + 1
        item.geometry = "roundRect"; item.cornerRatio = 0.03   // slightly rounded corners, no shadow
        if pasted { item.enableFade(); slide.timingDirty = true }
        slide.items.append(item)
        return item
    }
    func writeTiming(_ slide: Slide) {
        guard !slide.originalTiming || slide.timingDirty else { return }
        let root = slide.document.rootElement()!
        root.child("timing")?.detach()
        let steps = slide.fadeSequence
        guard !steps.isEmpty else { return }
        var effects = "", id = 3
        for step in steps {
            effects += """
            <p:par><p:cTn id="\(id)" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>
            <p:par><p:cTn id="\(id+1)" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
            """
            id += 2
            for (index, entry) in step.enumerated() {
                let (item, paragraph) = entry
                let target = "<p:tgtEl><p:spTgt spid=\"\(item.id)\">" + (paragraph.map { "<p:txEl><p:pRg st=\"\($0)\" end=\"\($0)\"/></p:txEl>" } ?? "") + "</p:spTgt></p:tgtEl>"
                let nodeType = index == 0 ? "clickEffect" : "withEffect"
                effects += """
                <p:par><p:cTn id="\(id)" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" nodeType="\(nodeType)" grpId="0"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
                <p:set><p:cBhvr><p:cTn id="\(id+1)" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\(target)<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>
                <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="\(id+2)" dur="\(Int((item.fadeDuration(for: paragraph) * 1000).rounded()))"/>\(target)</p:cBhvr></p:animEffect>
                </p:childTnLst></p:cTn></p:par>
                """
                id += 3
            }
            effects += "</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>"
        }
        let timing = fragment("""
        <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst><p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\(effects)</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
        """)
        let builds = slide.fadeGroups.flatMap { $0 }.filter { $0.textBody != nil }.map {
            "<p:bldP spid=\"\($0.id)\" grpId=\"0\" build=\"\($0.fadesByParagraph ? "p" : "allAtOnce")\" uiExpand=\"1\" animBg=\"0\"/>"
        }.joined()
        if !builds.isEmpty { timing.addChild(fragment("<p:bldLst>\(builds)</p:bldLst>")) }
        if let ext = root.child("extLst"), let index = root.children?.firstIndex(of: ext) { root.insertChild(timing, at: index) }
        else { root.addChild(timing) }
    }
    /// Writes the edits back into the original file (atomic replace; no backup copy is made).
    func saveInPlace() throws {
        // Never overwrite changes made to the file by another app (PowerPoint, a sync tool...) since it was opened.
        if let stamp = sourceStamp, let now = Self.modificationDate(of: source), now != stamp {
            throw AppError.message("The file was changed outside Slidy, so Slidy won’t overwrite it. Use File > Save a Copy… to keep your changes, then reopen the file.")
        }
        try save(to: source, allowOverwrite: true)
        sourceStamp = Self.modificationDate(of: source)
    }
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    func save(to destination: URL, allowOverwrite: Bool = false) throws {
        guard allowOverwrite || destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
            throw AppError.message("Choose a different name for the copy.")
        }
        if orderDirty {
            try (try part("ppt/presentation.xml")).xmlData.write(to: folder.appendingPathComponent("ppt/presentation.xml"), options: .atomic)
            orderDirty = false
        }
        for slide in slides {
            writeTiming(slide)
            let data = slide.document.xmlData
            if data != slide.writtenXML {
                try data.write(to: folder.appendingPathComponent(slide.path), options: .atomic)
                slide.writtenXML = data
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Slidy-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var error = [CChar](repeating: 0, count: 1024)
        guard sp_pack(folder.path, temporary.path, &error, Int32(error.count)) == 0 else { throw AppError.message(String(cString: error)) }
        // Same-directory rename provides an atomic replacement, including on retry.
        // replaceItemAt swaps the file atomically and keeps its permissions, tags and creation date.
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch { throw AppError.message("Can’t save the file to that location.") }
    }
}
