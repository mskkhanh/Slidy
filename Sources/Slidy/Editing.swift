import AppKit
import ArchiveBridge

extension Presentation {
    func updateText(_ item: SlideItem, text: String, bulletRows: Set<Int>? = nil) {
        guard let body = item.textBody else { return }
        let previousBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
        guard text != item.text || (bulletRows.map { $0 != previousBullets } ?? false) else { return }
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
            let hasBullet = p.child("pPr")?.child("buChar") != nil || p.child("pPr")?.child("buAutoNum") != nil
            if wantsBullet != hasBullet {
                let pp = p.child("pPr") ?? XMLElement(name: "a:pPr")
                if pp.parent == nil { p.insertChild(pp, at: 0) }
                for name in ["buNone", "buChar", "buAutoNum"] { pp.child(name)?.detach() }
                let bullet = fragment(wantsBullet ? "<a:buChar char=\"•\"/>" : "<a:buNone/>")
                if let next = pp.elements.first(where: { ["tabLst", "defRPr", "extLst"].contains($0.localName ?? "") }) {
                    pp.insertChild(bullet, at: next.index)
                } else { pp.addChild(bullet) }
                pp.set("marL", wantsBullet ? "285750" : "0")
                pp.set("indent", wantsBullet ? "-285750" : "0")
            }
            body.addChild(p)
        }
        configureText(item)
    }
    func nextID(_ slide: Slide) -> String {
        String((slide.document.rootElement()?.descendants("cNvPr").compactMap { Int($0.attr("id") ?? "") }.max() ?? 1) + 1)
    }
    @discardableResult func addText(to slide: Slide, list: Bool, heading: Bool = false) -> SlideItem {
        let id = nextID(slide)
        let foreground = (slide.background.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5 ? "FFFFFF" : "1F2937"
        let name = heading ? "Tiêu đề" : (list ? "Danh sách" : "Văn bản")
        let placeholder = heading ? "Tiêu đề" : (list ? "Mục đầu tiên" : "Nội dung")
        let fontSize = heading ? 4000 : 2400
        let typeface = heading ? majorFont : minorFont
        let bullet = list ? "<a:buChar char=\"•\"/>" : "<a:buNone/>"
        let p = "<a:p><a:pPr marL=\"\(list ? 304800 : 0)\" indent=\"\(list ? -304800 : 0)\"><a:lnSpc><a:spcPts val=\"\(heading ? 4800 : 3360)\"/></a:lnSpc>\(bullet)</a:pPr><a:r><a:rPr sz=\"\(fontSize)\" b=\"\(heading ? 1 : 0)\"><a:solidFill><a:srgbClr val=\"\(foreground)\"/></a:solidFill><a:latin typeface=\"\(escapeXML(typeface))\"/></a:rPr><a:t>\(placeholder)</a:t></a:r></a:p>"
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
        guard let sourceImage = NSImage(contentsOf: url), sourceImage.size.width > 0, sourceImage.size.height > 0 else { throw AppError.message("Không đọc được ảnh này.") }
        let suffix = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(suffix) else { throw AppError.message("Hãy chọn ảnh PNG hoặc JPEG.") }
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
        let node = fragment("<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Ảnh\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>")
        slide.tree.addChild(node)
        let item = SlideItem(node: node, id: id, frame: .zero)
        let maxWidth = size.width * (pasted ? 0.46 : 0.6)
        let maxHeight = size.height * (pasted ? 0.86 : 0.6)
        let ratio = min(maxWidth / sourceImage.size.width, maxHeight / sourceImage.size.height)
        let dimensions = CGSize(width: sourceImage.size.width * ratio, height: sourceImage.size.height * ratio)
        item.updateFrame(CGRect(x: size.width * (pasted ? 0.75 : 0.5) - dimensions.width / 2, y: (size.height - dimensions.height) / 2, width: dimensions.width, height: dimensions.height))
        item.imageURL = media.appendingPathComponent(mediaName); item.order = (slide.items.map(\.order).max() ?? 0) + 1
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
            throw AppError.message("File đã bị thay đổi bên ngoài Slidy nên Slidy không ghi đè. Dùng Tệp > Lưu bản sao… để giữ thay đổi, rồi mở lại file.")
        }
        try save(to: source, allowOverwrite: true)
        sourceStamp = Self.modificationDate(of: source)
    }
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    func save(to destination: URL, allowOverwrite: Bool = false) throws {
        guard allowOverwrite || destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
            throw AppError.message("Hãy chọn tên khác để lưu bản sao.")
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
        } catch { throw AppError.message("Không thể lưu file tại vị trí đã chọn.") }
    }
}
