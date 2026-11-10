import AppKit

/// Adding new objects to a slide: text boxes and pictures.
extension Presentation {
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
}
