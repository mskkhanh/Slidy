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
    private func editRelationships(_ change: (XMLElement) throws -> Void) throws {
        let url = folder.appendingPathComponent("ppt/_rels/presentation.xml.rels")
        let document = try readXML(url)
        guard let root = document.rootElement() else { throw AppError.message("Thiếu liên kết trong file.") }
        try change(root)
        try document.xmlData.write(to: url, options: .atomic)
    }
    private func editContentTypes(_ change: (String) -> String) throws {
        let url = folder.appendingPathComponent("[Content_Types].xml")
        let text = try String(contentsOf: url, encoding: .utf8)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a slide after `index` with a heading and a body text box styled like the deck's other content slides:
    /// same background, layout, fonts, sizes, colours and positions. Returns the new slide.
    @discardableResult
    func insertSlide(after index: Int) throws -> Slide {
        guard slides.indices.contains(index), slides.allSatisfy({ $0.listEntry != nil }) else { throw AppError.message("Không thêm được slide vào file này.") }
        guard let reference = referenceSlide(near: index) else { throw AppError.message("Không có slide mẫu (tiêu đề và nội dung) để tạo slide mới.") }
        guard let layoutPath = related(reference.slide.path, type: "slideLayouts"),
              (try part("ppt/presentation.xml")).rootElement()?.descendant("sectionLst") == nil else {
            throw AppError.message("Không thêm được slide vào file này (thiếu layout hoặc có Section).")
        }
        let number = nextSlideNumber()
        let path = "ppt/slides/slide\(number).xml"
        // Copy the reference slide, keeping only its heading and body.
        guard let document = reference.slide.document.copy() as? XMLDocument, let root = document.rootElement(),
              let tree = root.child("cSld")?.child("spTree") else { throw AppError.message("Slide mẫu không hợp lệ.") }
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
            throw AppError.message("Thiếu danh sách slide trong file.")
        }
        let nextID = (list.elements.compactMap { Int($0.attr("id") ?? "") }.max() ?? 255) + 1
        let entry = fragment("<p:sldId id=\"\(nextID)\" r:id=\"\(relationshipID)\"/>")
        list.insertChild(entry, at: anchor.index + 1)
        orderDirty = true
        let slide = Slide(path: path, document: document)
        slide.listEntry = entry
        xmlCache[path] = document
        try parse(slide)
        if let heading = slide.items.first(where: { $0.id == reference.heading.id }) { updateText(heading, text: "Tiêu đề") }
        if let body = slide.items.first(where: { $0.id == reference.body.id }) { updateText(body, text: "Nội dung") }
        // A new slide starts without any animation.
        slide.items.filter(\.hasFade).forEach { slide.removeFade(from: $0) }
        slides.insert(slide, at: index + 1)
        insertedSlidePaths.insert(path)
        return slide
    }

    /// Takes back a slide made by `insertSlide` (undo): the list entry, relationship, content type and files all go.
    func removeInsertedSlide(at index: Int) throws {
        guard slides.indices.contains(index), slides.count > 1, insertedSlidePaths.contains(slides[index].path) else {
            throw AppError.message("Chỉ hoàn tác được slide vừa tạo.")
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
