import AppKit
import Foundation
import ImageIO
import ArchiveBridge

// The open .pptx: extracts it to a temp folder, parses slides, resolves themes, images and fonts, and saves it back.
final class Presentation {
    let folder: URL
    let source: URL
    /// Modification time of the file when it was opened or last saved by Slidy, to notice outside changes.
    var sourceStamp: Date?
    /// Slide order changed since presentation.xml was last written into the work folder.
    var orderDirty = false
    /// Slides created in this session (their files may be removed again by undo).
    var insertedSlidePaths = Set<String>()
    /// Where files of deleted slides wait in case of undo.
    var holdingFolders: [URL] = []
    var slides: [Slide] = []
    var size = CGSize(width: 960, height: 540)
    lazy var textLeftMargin: CGFloat = {
        let margins = slides.compactMap { slide in
            slide.items.compactMap { item -> CGFloat? in
                guard item.canMove, !item.text.isEmpty else { return nil }
                let paragraph = item.paragraphs.first
                let bulletIndent = paragraph?.bullet == nil ? 0 : (paragraph?.indent ?? 0)
                let x = item.frame.minX + item.insets.left + (paragraph?.left ?? 0) + bulletIndent
                return (0...size.width * 0.25).contains(x) ? x : nil
            }.min()
        }
        let clusters = Dictionary(grouping: margins) { Int(($0 / 8).rounded()) }
        guard let cluster = clusters.values.sorted(by: {
            $0.count == $1.count ? $0.min()! < $1.min()! : $0.count > $1.count
        }).first else { return size.width * 0.07 }
        return cluster.sorted()[cluster.count / 2]
    }()
    var colors: [String: NSColor] = [:]
    var majorFont = "Helvetica Neue"
    var minorFont = "Helvetica Neue"
    var missingFonts = Set<String>()
    var xmlCache: [String: XMLDocument] = [:]
    let imageCache = NSCache<NSString, NSImage>()
    init(url: URL) throws {
        source = url
        sourceStamp = Self.modificationDate(of: url)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.workFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        imageCache.totalCostLimit = 48 * 1024 * 1024
        do {
            var error = [CChar](repeating: 0, count: 1024)
            guard sp_extract(url.path, folder.path, &error, Int32(error.count)) == 0 else { throw AppError.message(String(cString: error)) }
            try load()
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    deinit { discardWorkFolder() }
    /// The extracted copy of the .pptx lives in the temp folder. Quitting does not run deinit, so it is removed explicitly.
    func discardWorkFolder() {
        try? FileManager.default.removeItem(at: folder)
        holdingFolders.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    /// Removes work folders left by earlier runs that quit or crashed before cleaning up.
    static func removeStaleWorkFolders() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(workFolderPrefix) { try? FileManager.default.removeItem(at: temp.appendingPathComponent(name)) }
    }
    static let workFolderPrefix = "Slidy-"
    func part(_ path: String) throws -> XMLDocument {
        if let value = xmlCache[path] { return value }
        let value = try readXML(folder.appendingPathComponent(path)); xmlCache[path] = value; return value
    }
    /// Moves a slide to a new position: the slide array and the <p:sldIdLst> in presentation.xml. Slide files
    /// and everything inside a slide (Fade timing included) are untouched.
    func moveSlide(from source: Int, to destination: Int) throws {
        guard slides.indices.contains(source), slides.indices.contains(destination), source != destination else { return }
        let list = try part("ppt/presentation.xml").rootElement()?.child("sldIdLst")
        guard let list, slides.allSatisfy({ $0.listEntry != nil }) else { throw AppError.message("Can’t reorder slides in this file.") }
        if (try part("ppt/presentation.xml")).rootElement()?.descendant("sectionLst") != nil {
            throw AppError.message("This presentation has sections; Slidy can’t reorder slides in it yet.")
        }
        let moved = slides.remove(at: source)
        slides.insert(moved, at: destination)
        slides.forEach { $0.listEntry?.detach() }
        slides.forEach { if let entry = $0.listEntry { list.addChild(entry) } }
        orderDirty = true
    }
    func relationships(_ path: String) -> [String: String] {
        let url = folder.appendingPathComponent(path)
        let rel = url.deletingLastPathComponent().appendingPathComponent("_rels").appendingPathComponent(url.lastPathComponent + ".rels")
        guard let doc = try? readXML(rel) else { return [:] }
        var result: [String: String] = [:]
        for element in doc.rootElement()?.elements ?? [] {
            guard element.attr("TargetMode") != "External", let id = element.attr("Id"), let target = element.attr("Target") else { continue }
            let resolved: URL
            if target.hasPrefix("/") { resolved = folder.appendingPathComponent(String(target.dropFirst())) }
            else { resolved = folder.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL }
            guard resolved.path.hasPrefix(folder.path + "/") else { continue }
            result[id] = String(resolved.path.dropFirst(folder.path.count + 1))
        }
        return result
    }
    func related(_ path: String, type: String) -> String? {
        relationships(path).values.first { $0.contains("/\(type)/") }
    }
    private func load() throws {
        let presentation = try part("ppt/presentation.xml")
        guard let root = presentation.rootElement(), let slideList = root.child("sldIdLst") else { throw AppError.message("The file has no valid slide list.") }
        if let s = root.child("sldSz") { size = CGSize(width: s.number("cx") / emu, height: s.number("cy") / emu) }
        guard size.width > 0, size.height > 0 else { throw AppError.message("Invalid slide size.") }
        let themePath = related("ppt/presentation.xml", type: "theme") ?? "ppt/theme/theme1.xml"
        if let theme = try? part(themePath).rootElement() {
            for entry in theme.descendant("clrScheme")?.elements ?? [] { colors[entry.localName ?? ""] = color(entry) }
            majorFont = theme.descendant("majorFont")?.child("latin")?.attr("typeface") ?? majorFont
            minorFont = theme.descendant("minorFont")?.child("latin")?.attr("typeface") ?? minorFont
        }
        let rels = relationships("ppt/presentation.xml")
        for entry in slideList.elements {
            guard let path = rels[entry.attr("r:id") ?? ""] else { throw AppError.message("A slide link is missing in the file.") }
            let slide = Slide(path: path, document: try part(path))
            slide.listEntry = entry
            try parse(slide)
            slides.append(slide)
        }
        guard !slides.isEmpty else { throw AppError.message("The presentation has no slides.") }
    }
    func color(_ element: XMLElement?) -> NSColor? {
        guard let element else { return nil }
        let child = element.child("srgbClr") ?? element.child("schemeClr") ?? element.child("sysClr")
        guard let child else { return nil }
        var result: NSColor
        if child.localName == "schemeClr" {
            let key = child.attr("val") ?? "tx1"
            let alias = ["tx1": "dk1", "tx2": "dk2", "bg1": "lt1", "bg2": "lt2"]
            result = colors[alias[key] ?? key] ?? .black
        } else { result = NSColor(hex: child.attr("val") == "windowText" ? "000000" : (child.attr("lastClr") ?? child.attr("val") ?? "000000")) }
        if let tint = child.child("tint") { result = result.blended(withFraction: tint.number("val") / 100000, of: .white) ?? result }
        if let shade = child.child("shade") { result = result.blended(withFraction: 1 - shade.number("val") / 100000, of: .black) ?? result }
        if let alpha = child.child("alpha") { result = result.withAlphaComponent(alpha.number("val") / 100000) }
        return result
    }
    func parse(_ slide: Slide) throws {
        guard let root = slide.document.rootElement(), let tree = root.child("cSld")?.child("spTree") else { throw AppError.message("Invalid slide structure.") }
        slide.items = []; slide.warnings = []
        let layout = related(slide.path, type: "slideLayouts")
        let master = layout.flatMap { related($0, type: "slideMasters") }
        let parents = [layout, master].compactMap { $0 }.compactMap { try? part($0).rootElement() }
        let backgrounds = [root] + parents
        slide.background = backgrounds.compactMap { color($0.child("cSld")?.child("bg")?.child("bgPr")?.child("solidFill")) }.first ?? .white
        // Draw inherited decorative objects before the slide's own objects.
        if root.attr("showMasterSp") != "0" {
            for parent in parents.reversed() {
                for node in parent.child("cSld")?.child("spTree")?.elements ?? [] where node.localName == "sp" && node.descendant("ph") == nil {
                    let item = parseItem(node, inherited: nil, rels: [:]); item.inherited = true; slide.items.append(item)
                }
            }
        }
        let rels = relationships(slide.path)
        for node in tree.elements {
            switch node.localName {
            case "sp", "pic":
                var inherited: XMLElement?
                if let ph = node.descendant("ph") {
                    inherited = parents.flatMap { $0.child("cSld")?.child("spTree")?.all("sp") ?? [] }.first {
                        guard let other = $0.descendant("ph") else { return false }
                        return other.attr("idx") == ph.attr("idx") && (other.attr("type") ?? "body") == (ph.attr("type") ?? "body")
                    }
                }
                let item = parseItem(node, inherited: inherited, rels: rels)
                item.order = slide.items.count
                slide.items.append(item)
            case "graphicFrame":
                if node.descendant("tbl") != nil { slide.items += parseTable(node) }
                else { slide.warnings.append("Charts and SmartArt are not shown yet.") }
            case "grpSp": slide.warnings.append("Grouped shapes are not shown yet.")
            default: break
            }
        }
        if let timing = root.child("timing") {
            var order = 0
            var clickGroups: [ObjectIdentifier: (key: String, order: Int)] = [:]
            for effect in timing.descendants("animEffect") where effect.attr("filter") == "fade" {
                guard let target = effect.descendant("spTgt"), let item = slide.items.first(where: { $0.id == target.attr("spid") }) else { continue }
                let firstEffect = !item.fade
                if firstEffect { item.order = order; order += 1 }
                item.fade = true
                let seconds = (effect.descendant("cTn")?.number("dur", 350) ?? 350) / 1000
                if let range = target.descendant("pRg"), let index = Int(range.attr("st") ?? ""), range.attr("end") == range.attr("st") {
                    item.paragraphDurations[index] = seconds
                } else {
                    item.duration = seconds
                    var ancestor = effect.parent as? XMLElement
                    while let element = ancestor {
                        let parent = element.parent as? XMLElement
                        if parent?.localName == "childTnLst",
                           (parent?.parent as? XMLElement)?.attr("nodeType") == "mainSeq" {
                            let identity = ObjectIdentifier(element)
                            let group = clickGroups[identity] ?? (UUID().uuidString, item.order)
                            clickGroups[identity] = group
                            item.fadeGroup = group.key
                            item.order = group.order
                            break
                        }
                        ancestor = parent
                    }
                }
            }
            for group in slide.fadeGroups where group.count == 1 && !group[0].hasList {
                group[0].fadeGroup = nil
            }
            if !timing.descendants("anim").isEmpty || timing.descendants("animEffect").contains(where: { $0.attr("filter") != "fade" }) {
                slide.warnings.append("Complex original effects are kept in the file; Slidy only plays Fade.")
            }
        }
    }
    func parseItem(_ node: XMLElement, inherited: XMLElement?, rels: [String: String]) -> SlideItem {
        let props = node.child("spPr")
        let xfrm = props?.child("xfrm") ?? inherited?.child("spPr")?.child("xfrm")
        let frame = CGRect(x: (xfrm?.child("off")?.number("x") ?? 0) / emu, y: (xfrm?.child("off")?.number("y") ?? 0) / emu,
                           width: max(1, (xfrm?.child("ext")?.number("cx") ?? 1270000) / emu), height: max(1, (xfrm?.child("ext")?.number("cy") ?? 635000) / emu))
        let item = SlideItem(node: node, id: node.descendant("cNvPr")?.attr("id") ?? UUID().uuidString, frame: frame)
        item.rotation = (xfrm?.number("rot") ?? 0) / 60000
        item.fill = color(props?.child("solidFill")); item.stroke = color(props?.child("ln")?.child("solidFill"))
        item.strokeWidth = (props?.child("ln")?.number("w", 12700) ?? 0) / emu
        item.geometry = props?.child("prstGeom")?.attr("prst") ?? "rect"
        if let adjust = props?.child("prstGeom")?.child("avLst")?.all("gd").first(where: { $0.attr("name") == "adj" }), let formula = adjust.attr("fmla"),
           let value = Double(formula.replacingOccurrences(of: "val ", with: "")) { item.cornerRatio = CGFloat(value / 100000) }
        if let imageID = node.descendant("blip")?.attr("r:embed"), let path = rels[imageID] { item.imageURL = folder.appendingPathComponent(path) }
        if let shadow = node.child("spPr")?.child("effectLst")?.child("outerShdw") {
            let angle = shadow.number("dir") / 60000 * .pi / 180, distance = shadow.number("dist") / emu
            item.shadow = ObjectShadow(blur: shadow.number("blurRad") / emu, dx: CGFloat(cos(angle) * distance), dy: CGFloat(sin(angle) * distance),
                                       color: color(shadow) ?? NSColor(white: 0, alpha: 0.25))
        }
        if let crop = node.descendant("srcRect") { item.imageCrop = NSEdgeInsets(top: crop.number("t") / 100000, left: crop.number("l") / 100000, bottom: crop.number("b") / 100000, right: crop.number("r") / 100000) }
        configureText(item, inherited: inherited)
        return item
    }
    func configureText(_ item: SlideItem, inherited: XMLElement? = nil) {
        guard let body = item.textBody else { return }
        let props = body.child("bodyPr")
        item.insets = NSEdgeInsets(top: (props?.number("tIns", 45720) ?? 45720) / emu, left: (props?.number("lIns", 91440) ?? 91440) / emu, bottom: (props?.number("bIns", 45720) ?? 45720) / emu, right: (props?.number("rIns", 91440) ?? 91440) / emu)
        item.anchor = props?.attr("anchor") ?? "t"
        item.autoFit = props?.child("spAutoFit") != nil
        var autoNumber = 0
        item.paragraphs = body.all("p").enumerated().map { index, p in
            let level = Int(p.child("pPr")?.number("lvl") ?? 0) + 1
            let defaults = body.child("lstStyle")?.child("lvl\(level)pPr") ?? inherited?.child("txBody")?.child("lstStyle")?.child("lvl\(level)pPr")
            let pp = p.child("pPr")
            let pr = pp?.child("defRPr") ?? defaults?.child("defRPr")
            let text = NSMutableAttributedString(string: "")
            for run in p.elements {
                if run.localName == "r" || run.localName == "fld" {
                    text.append(NSAttributedString(string: run.child("t")?.stringValue ?? "", attributes: attributes(run.child("rPr"), fallback: pr)))
                } else if run.localName == "br" { text.append(NSAttributedString(string: "\u{2028}", attributes: attributes(run.child("rPr"), fallback: pr))) }
            }
            let bulletProps = pp?.child("buNone") != nil ? nil : (pp?.child("buChar") ?? pp?.child("buAutoNum") ?? defaults?.child("buChar"))
            // Numbered items count within each run of consecutive numbered paragraphs.
            if bulletProps?.localName == "buAutoNum" { autoNumber += 1 } else { autoNumber = 0 }
            let bullet = bulletProps.map { $0.localName == "buAutoNum" ? "\(Int($0.number("startAt", 1)) + autoNumber - 1)." : ($0.attr("char") ?? "•") }
            let alignment: NSTextAlignment = ["ctr": .center, "r": .right, "just": .justified][pp?.attr("algn") ?? defaults?.attr("algn") ?? "l"] ?? .left
            let fontSize = (text.length > 0 ? (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize : nil) ?? 22
            let line = pp?.child("lnSpc") ?? defaults?.child("lnSpc")
            let spacing = line?.child("spcPts").map { $0.number("val") / 100 } ?? ((line?.child("spcPct")?.number("val", 120000) ?? 120000) / 100000 * fontSize)
            return Paragraph(text: text, bullet: bullet, left: (pp?.number("marL", defaults?.number("marL") ?? 0) ?? 0) / emu, indent: (pp?.number("indent", defaults?.number("indent") ?? 0) ?? 0) / emu, spacing: spacing, before: (pp?.child("spcBef")?.child("spcPts")?.number("val") ?? 0) / 100, after: (pp?.child("spcAft")?.child("spcPts")?.number("val") ?? 0) / 100, alignment: alignment, xmlIndex: index)
        }
    }
    private func attributes(_ properties: XMLElement?, fallback: XMLElement?) -> [NSAttributedString.Key: Any] {
        func value(_ name: String) -> String? { properties?.attr(name) ?? fallback?.attr(name) }
        let size = max(1, (Double(value("sz") ?? "2200") ?? 2200) / 100)
        var family = properties?.child("latin")?.attr("typeface") ?? fallback?.child("latin")?.attr("typeface") ?? minorFont
        if family.hasPrefix("+mj") { family = majorFont }; if family.hasPrefix("+mn") { family = minorFont }
        var font = NSFont(name: family, size: size)
        if font == nil { missingFonts.insert(family); font = NSFont.systemFont(ofSize: size) }
        if value("b") == "1" { font = NSFontManager.shared.convert(font!, toHaveTrait: .boldFontMask) }
        if value("i") == "1" { font = NSFontManager.shared.convert(font!, toHaveTrait: .italicFontMask) }
        return [.font: font!, .foregroundColor: color(properties?.child("solidFill")) ?? color(fallback?.child("solidFill")) ?? colors["dk1"] ?? .black, .kern: (Double(value("spc") ?? "0") ?? 0) / 100]
    }
    func parseTable(_ node: XMLElement) -> [SlideItem] {
        guard let table = node.descendant("tbl"), let transform = node.child("xfrm") else { return [] }
        let startX = (transform.child("off")?.number("x") ?? 0) / emu
        var y = (transform.child("off")?.number("y") ?? 0) / emu
        let widths = table.child("tblGrid")?.all("gridCol").map { $0.number("w") / emu } ?? []
        var items: [SlideItem] = []
        for row in table.all("tr") {
            var x = startX; let height = row.number("h") / emu
            for (index, cell) in row.all("tc").enumerated() {
                let width = index < widths.count ? widths[index] : 100
                let item = SlideItem(node: cell, id: "cell-\(node.descendant("cNvPr")?.attr("id") ?? "t")-\(items.count)", frame: CGRect(x: x, y: y, width: width, height: height))
                item.isTableCell = true
                item.tableNode = node; item.tableID = node.descendant("cNvPr")?.attr("id") ?? "table"
                let props = cell.child("tcPr")
                item.fill = color(props?.child("solidFill")); item.stroke = color(props?.child("lnB")?.child("solidFill")); item.strokeWidth = 0.7
                configureText(item)
                item.insets = NSEdgeInsets(top: (props?.number("marT", 45720) ?? 45720) / emu, left: (props?.number("marL", 91440) ?? 91440) / emu, bottom: (props?.number("marB", 45720) ?? 45720) / emu, right: (props?.number("marR", 91440) ?? 91440) / emu)
                items.append(item); x += width
            }
            y += height
        }
        return items
    }
    /// Writes a picture's crop as the standard <a:srcRect> (fractions of the whole picture cut from each side).
    func setImageCrop(_ item: SlideItem, _ crop: NSEdgeInsets) {
        guard let blipFill = item.node.child("blipFill") else { return }
        blipFill.child("srcRect")?.detach()
        func value(_ fraction: CGFloat) -> String { String(Int((max(0, fraction) * 100000).rounded())) }
        if [crop.left, crop.top, crop.right, crop.bottom].contains(where: { $0 > 0.0005 }) {
            let rect = fragment("<a:srcRect l=\"\(value(crop.left))\" t=\"\(value(crop.top))\" r=\"\(value(crop.right))\" b=\"\(value(crop.bottom))\"/>")
            if let blip = blipFill.child("blip") { blipFill.insertChild(rect, at: blip.index + 1) } else { blipFill.addChild(rect) }
        }
        item.imageCrop = crop
    }
    func image(for item: SlideItem) -> NSImage? {
        guard let url = item.imageURL else { return nil }
        let key = url.path as NSString
        if let image = imageCache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
}
