import AppKit

// Room to breathe in table cells: the margins inside every cell (<a:tcPr marL marR marT marB>, the PowerPoint way) and the text
// centered between top and bottom (anchor="ctr").
// Rows grow with their text; the table keeps its width and its left edge.
extension Presentation {
    static let tableMarginX = 164592.0   // 0.18 in, left and right
    static let tableMarginY = 109728.0   // 0.12 in, top and bottom

    /// Tables of a slide whose cells do not have the margins yet.
    func tablesNeedingPadding(in slide: Slide) -> [String] {
        slide.items.filter(\.isTableFrame).compactMap { whole -> String? in
            guard let id = whole.tableID, let node = whole.tableNode else { return nil }
            let padded = node.descendants("tc").allSatisfy { tc in
                guard let pr = tc.child("tcPr") else { return false }
                return pr.attr("anchor") == "ctr" && abs(pr.number("marL", -1) - Self.tableMarginX) < 1 && abs(pr.number("marR", -1) - Self.tableMarginX) < 1
                    && abs(pr.number("marT", -1) - Self.tableMarginY) < 1 && abs(pr.number("marB", -1) - Self.tableMarginY) < 1
            }
            return padded ? nil : id
        }
    }
    /// Gives every cell of the table the margins, grows the rows that need it, and moves the text boxes split out of the cells
    /// (see `splitCellText`) with them. Returns the bottom edge of the table in slide points, or nil when nothing could be done.
    @discardableResult
    func padTable(_ tableID: String, in slide: Slide) -> CGFloat? {
        guard let whole = slide.items.first(where: { $0.isTableFrame && $0.tableID == tableID }), let node = whole.tableNode, let table = node.descendant("tbl") else { return nil }
        let cells = slide.items.filter { $0.tableID == tableID && !$0.isTableFrame }
        let rows = table.all("tr")
        let tcs = rows.flatMap { $0.all("tc") }
        guard tcs.count == cells.count else { return nil }
        // Text boxes split out of the cells: each belongs to the cell that contains its center.
        var boxOf: [Int: SlideItem] = [:]
        for box in slide.items where box.cellTextOf == tableID {
            let center = CGPoint(x: box.frame.midX, y: box.frame.midY)
            if let at = cells.firstIndex(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(center) }) { boxOf[at] = box }
        }
        let marginX = Self.tableMarginX, marginY = Self.tableMarginY
        for tc in tcs {
            let properties: XMLElement
            if let existing = tc.child("tcPr") { properties = existing }
            else {
                properties = fragment("<a:tcPr/>")
                if let extra = tc.child("extLst") { tc.insertChild(properties, at: extra.index) } else { tc.addChild(properties) }
            }
            properties.set("marL", String(Int(marginX))); properties.set("marR", String(Int(marginX)))
            properties.set("marT", String(Int(marginY))); properties.set("marB", String(Int(marginY)))
            properties.set("anchor", "ctr")   // the text sits in the middle of the cell, top to bottom
        }
        // Row heights: as tall as the tallest cell needs (never shorter than before).
        var index = 0
        var total = 0.0
        for row in rows {
            var needed = row.number("h")
            for _ in row.all("tc") {
                let cell = cells[index]
                let holder = boxOf[index] ?? cell
                let saved = (holder.frame, holder.insets, holder.anchor)
                holder.frame.size.width = cell.frame.width
                holder.insets = NSEdgeInsets(top: marginY / emu, left: marginX / emu, bottom: marginY / emu, right: marginX / emu)
                holder.anchor = "t"
                let layouts = layoutParagraphs(holder)
                let bottom = (layouts.last.map { $0.origin.y + $0.height } ?? holder.insets.top) + holder.insets.bottom
                (holder.frame, holder.insets, holder.anchor) = saved
                needed = max(needed, Double(bottom) * emu)
                index += 1
            }
            row.set("h", String(Int(needed.rounded())))
            total += needed.rounded()
        }
        node.child("xfrm")?.child("ext")?.set("cy", String(Int(total)))
        // The model follows the XML: frames and margins of the cells, then the split text boxes.
        let fresh = parseTable(node)
        if let first = fresh.first { whole.frame = first.frame }
        for (old, new) in zip(cells, fresh.dropFirst()) {
            old.frame = new.frame
            configureText(old); old.insets = new.insets
        }
        for (at, box) in boxOf {
            box.updateFrame(cells[at].frame)
            if let properties = box.textBody?.child("bodyPr") {
                properties.set("lIns", String(Int(marginX))); properties.set("rIns", String(Int(marginX)))
                properties.set("tIns", String(Int(marginY))); properties.set("bIns", String(Int(marginY)))
                properties.set("anchor", "ctr")
            }
            configureText(box)
            trimTextBox(box)
        }
        return whole.frame.maxY
    }
}
