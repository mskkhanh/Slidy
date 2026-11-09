import AppKit

// Adding and removing whole slides: the slide part, its relationships, the content-type entry and the slide list.
extension Presentation {
    /// A slide's heading is its largest text; its body is the widest big text box below the heading.
    private func headingAndBody(of slide: Slide) -> (heading: SlideItem, body: SlideItem)? {
        let texts = slide.items.filter { $0.canMove && $0.textBody != nil && !$0.text.isEmpty }
        func fontSize(_ item: SlideItem) -> CGFloat {
            (item.paragraphs.first?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        guard let heading = texts.max(by: { fontSize($0) < fontSize($1) }) else { return nil }
        let bodies = texts.filter { $0 !== heading && $0.frame.width > size.width * 0.6 && $0.frame.minY >= heading.frame.minY }
        guard let body = bodies.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        return (heading, body)
    }
    /// The slide to copy the look from: the one at `index` if it has a heading and a body, else the nearest that does.
    private func referenceSlide(near index: Int) -> (slide: Slide, heading: SlideItem, body: SlideItem)? {
        for position in slides.indices.sorted(by: { abs($0 - index) < abs($1 - index) }) {
            if let found = headingAndBody(of: slides[position]) { return (slides[position], found.heading, found.body) }
        }
        return nil
    }
    private func nextSlideNumber() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("ppt/slides").path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasPrefix("slide"), name.hasSuffix(".xml") else { return nil }
            return Int(name.dropFirst(5).dropLast(4))
        }
        return (numbers.max() ?? 0) + 1
    }
    func editRelationships(_ change: (XMLElement) throws -> Void) throws {
        let url = folder.appendingPathComponent("ppt/_rels/presentation.xml.rels")
        let document = try readXML(url)
        guard let root = document.rootElement() else { throw AppError.message("A relationship is missing in the file.") }
        try change(root)
        try document.xmlData.write(to: url, options: .atomic)
    }
    func editContentTypes(_ change: (String) -> String) throws {
        let url = folder.appendingPathComponent("[Content_Types].xml")
        let text = try String(contentsOf: url, encoding: .utf8)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a slide after `index` with a heading and a body text box styled like the deck's other content slides:
    /// same background, layout, fonts, sizes, colours and positions. Returns the new slide.
    @discardableResult
    func insertSlide(after index: Int) throws -> Slide {
        guard slides.indices.contains(index), slides.allSatisfy({ $0.listEntry != nil }) else { throw AppError.message("Can’t add a slide to this file.") }
        guard let reference = referenceSlide(near: index) else { throw AppError.message("No slide with a heading and a body to copy the look from.") }
        guard let layoutPath = related(reference.slide.path, type: "slideLayouts"),
              (try part("ppt/presentation.xml")).rootElement()?.descendant("sectionLst") == nil else {
            throw AppError.message("Can’t add a slide to this file (no layout, or it has sections).")
        }
        let number = nextSlideNumber()
        let path = "ppt/slides/slide\(number).xml"
        // Copy the reference slide, keeping only its heading and body.
        guard let document = reference.slide.document.copy() as? XMLDocument, let root = document.rootElement(),
              let tree = root.child("cSld")?.child("spTree") else { throw AppError.message("The model slide is invalid.") }
        let keep: Set<String> = [reference.heading.id, reference.body.id]
        for child in tree.elements where !["nvGrpSpPr", "grpSpPr"].contains(child.localName ?? "") {
            if let id = child.descendant("cNvPr")?.attr("id"), keep.contains(id) { continue }
            child.detach()
        }
        root.child("timing")?.detach()
        root.child("cSld")?.set("name", "Slide \(slides.count + 1)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("ppt/slides/_rels"), withIntermediateDirectories: true)
        let target = "../" + layoutPath.replacingOccurrences(of: "ppt/", with: "")
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="\(packageNS)"><Relationship Id="rId1" Type="\(relationshipNS)/slideLayout" Target="\(target)"/></Relationships>
        """.write(to: folder.appendingPathComponent("ppt/slides/_rels/slide\(number).xml.rels"), atomically: true, encoding: .utf8)
        try document.xmlData.write(to: folder.appendingPathComponent(path), options: .atomic)
        try editContentTypes { text in
            text.replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/\(path)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/></Types>")
        }
        var relationshipID = "rId1"
        try editRelationships { root in
            let used = root.elements.compactMap { Int(($0.attr("Id") ?? "").dropFirst(3)) }
            relationshipID = "rId\((used.max() ?? 0) + 1)"
            let entry = XMLElement(name: "Relationship")
            entry.set("Id", relationshipID); entry.set("Type", "\(relationshipNS)/slide"); entry.set("Target", "slides/slide\(number).xml")
            root.addChild(entry)
        }
        guard let list = (try part("ppt/presentation.xml")).rootElement()?.child("sldIdLst"), let anchor = slides[index].listEntry else {
            throw AppError.message("The slide list is missing in the file.")
        }
        let nextID = (list.elements.compactMap { Int($0.attr("id") ?? "") }.max() ?? 255) + 1
        let entry = fragment("<p:sldId id=\"\(nextID)\" r:id=\"\(relationshipID)\"/>")
        list.insertChild(entry, at: anchor.index + 1)
        orderDirty = true
        let slide = Slide(path: path, document: document)
        slide.listEntry = entry
        xmlCache[path] = document
        try parse(slide)
        // Heading and body hug their text and grow with it.
        if let heading = slide.items.first(where: { $0.id == reference.heading.id }) { updateText(heading, text: "Heading"); enableAutoFit(heading) }
        if let body = slide.items.first(where: { $0.id == reference.body.id }) { updateText(body, text: "Text"); if body.hasList { setListSpacing(body, on: true) }; enableAutoFit(body) }
        // A new slide starts without any animation.
        slide.items.filter(\.hasFade).forEach { slide.removeFade(from: $0) }
        slides.insert(slide, at: index + 1)
        insertedSlidePaths.insert(path)
        return slide
    }

    /// Takes back a slide made by `insertSlide` (undo): the list entry, relationship, content type and files all go.
    func removeInsertedSlide(at index: Int) throws {
        guard slides.indices.contains(index), slides.count > 1, insertedSlidePaths.contains(slides[index].path) else {
            throw AppError.message("Only a slide you just added can be removed this way.")
        }
        let slide = slides.remove(at: index)
        let relationshipID = slide.listEntry?.attr("r:id")
        slide.listEntry?.detach()
        try editRelationships { root in root.elements.filter { $0.attr("Id") == relationshipID }.forEach { $0.detach() } }
        try editContentTypes { text in
            text.replacingOccurrences(of: "<Override PartName=\"/\(slide.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>", with: "")
        }
        let name = (slide.path as NSString).lastPathComponent
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(slide.path))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ppt/slides/_rels/\(name).rels"))
        xmlCache[slide.path] = nil
        insertedSlidePaths.remove(slide.path)
        orderDirty = true
    }
}

/// Everything needed to put a deleted slide back exactly as it was.
final class RemovedSlide {
    let slide: Slide
    let index: Int
    let entry: XMLElement
    let relationship: XMLElement?
    let overrides: [String]
    let moved: [(original: URL, backup: URL)]
    init(slide: Slide, index: Int, entry: XMLElement, relationship: XMLElement?, overrides: [String], moved: [(original: URL, backup: URL)]) {
        self.slide = slide; self.index = index; self.entry = entry; self.relationship = relationship; self.overrides = overrides; self.moved = moved
    }
}

extension Presentation {
    /// A relationship Target ("../slideLayouts/x.xml" or "/ppt/x.xml") as a path from the package root.
    /// `base` is the folder the relationships describe, e.g. "ppt/slides".
    static func resolveTarget(_ target: String, from base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }
    /// Every part target referenced by a .rels file of the package, as paths relative to the package root.
    private func referencedTargets(excluding excluded: Set<String>) -> Set<String> {
        var result = Set<String>()
        let root = folder.resolvingSymlinksInPath()   // the temp folder sits behind a /var -> /private/var link
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in walker where url.pathExtension == "rels" {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            guard !excluded.contains(relative), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let base = ((relative as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent   // folder the rels describe
            for chunk in text.components(separatedBy: "<Relationship ").dropFirst() {
                guard !chunk.contains("TargetMode=\"External\""), let start = chunk.range(of: "Target=\"") else { continue }
                let target = String(chunk[start.upperBound...].prefix { $0 != "\"" })
                result.insert(Self.resolveTarget(target, from: base))
            }
        }
        return result
    }
    /// Deletes a slide the way PowerPoint does: its list entry, relationship, content type, part and rels, its notes page,
    /// and media nobody else uses. Files are set aside (not erased) so `restoreSlide` can bring it all back.
    func removeSlide(at index: Int) throws -> RemovedSlide {
        guard slides.indices.contains(index), slides.count > 1, let entry = slides[index].listEntry else { throw AppError.message("Can’t delete this slide.") }
        let slide = slides[index]
        let rels = relationships(slide.path)
        let relsPath = ((slide.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("_rels/" + (slide.path as NSString).lastPathComponent + ".rels")
        var doomed = [slide.path, relsPath]
        var excluded: Set<String> = [relsPath]
        for target in rels.values where target.contains("/notesSlides/") {
            let notesRels = ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent("_rels/" + (target as NSString).lastPathComponent + ".rels")
            doomed += [target, notesRels]; excluded.insert(notesRels)
        }
        let stillUsed = referencedTargets(excluding: excluded)
        for target in rels.values where !target.contains("/notesSlides/") && !stillUsed.contains(target) { doomed.append(target) }   // media only this slide used
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.workFolderPrefix)removed-\(UUID().uuidString)", isDirectory: true)
        var moved: [(URL, URL)] = []
        for path in doomed {
            let original = folder.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: original.path) else { continue }
            let backup = holding.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: original, to: backup)
            moved.append((original, backup))
        }
        // Content-type overrides of the removed parts.
        var removedOverrides: [String] = []
        try editContentTypes { text in
            var result = text
            for path in doomed {
                guard let start = result.range(of: "<Override PartName=\"/\(path)\"") , let end = result[start.lowerBound...].range(of: "/>") else { continue }
                removedOverrides.append(String(result[start.lowerBound..<end.upperBound]))
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
            return result
        }
        let relationshipID = entry.attr("r:id")
        var savedRelationship: XMLElement?
        try editRelationships { root in
            for element in root.elements where element.attr("Id") == relationshipID { savedRelationship = element.copy() as? XMLElement; element.detach() }
        }
        entry.detach()
        slides.remove(at: index)
        xmlCache[slide.path] = nil
        holdingFolders.append(holding)
        orderDirty = true
        return RemovedSlide(slide: slide, index: index, entry: entry, relationship: savedRelationship, overrides: removedOverrides, moved: moved)
    }
    /// Undo of `removeSlide`: files, content types, relationship, list entry and the slide itself (Fade included).
    func restoreSlide(_ removed: RemovedSlide) throws {
        for (original, backup) in removed.moved {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: backup, to: original)
        }
        try editContentTypes { text in text.replacingOccurrences(of: "</Types>", with: removed.overrides.joined() + "</Types>") }
        if let relationship = removed.relationship?.copy() as? XMLElement { try editRelationships { $0.addChild(relationship) } }
        guard let list = (try part("ppt/presentation.xml")).rootElement()?.child("sldIdLst") else { throw AppError.message("The slide list is missing in the file.") }
        slides.insert(removed.slide, at: min(removed.index, slides.count))
        removed.slide.listEntry = removed.entry
        slides.forEach { $0.listEntry?.detach() }
        slides.forEach { if let entry = $0.listEntry { list.addChild(entry) } }
        xmlCache[removed.slide.path] = removed.slide.document
        orderDirty = true
    }
}
