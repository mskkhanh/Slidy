import AppKit

/// Splitting the text of table cells into text boxes, so each can fade by itself.
extension Presentation {
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
}
