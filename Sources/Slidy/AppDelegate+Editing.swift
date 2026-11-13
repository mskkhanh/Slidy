import AppKit
import UniformTypeIdentifiers

// Object actions on the slide: insert, paste, layer order, delete.
extension AppDelegate {
    @objc func addText() { insertText(list: false) }
    @objc func addList() { insertText(list: true) }
    @objc func addHeading() { insertText(list: false, heading: true) }
    func insertText(list: Bool, heading: Bool = false) {
        guard let presentation, !busy else { return }
        canvas.finishEditing(commit: true); checkpoint()
        let item = presentation.addText(to: presentation.slides[index], list: list, heading: heading)
        canvas.selected = item; canvas.rebuild(); didChange(); canvas.startEditing(selectContents: true)
    }
    @objc func addImage() {
        guard let presentation, !busy else { return }; canvas.finishEditing(commit: true)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.insertImage(url, into: presentation) }
            catch { self.showError(error) }
        }
    }
    func insertImage(_ url: URL, into presentation: Presentation, pasted: Bool = false) throws {
        guard !pasted || permitTimingEdit() else { return }
        checkpoint()
        let item = try presentation.addImage(to: presentation.slides[index], url: url, pasted: pasted)
        canvas.selected = item
        canvas.rebuild()
        window.makeFirstResponder(canvas)
        didChange()
    }
    @objc func pasteIntoSlide() {
        if let editor = canvas.editor, window.firstResponder === editor {
            editor.pasteAsPlainText(nil)
            return
        }
        // Any other text being edited (the filter box, a name, the link field) takes the paste itself.
        if let text = window.firstResponder as? NSTextView, text.isEditable { text.pasteAsPlainText(nil); return }
        guard let presentation, !busy, showWindow == nil else { return }
        if let payload = ObjectClipboard.read(), let slide = canvas.slide { pasteObjects(payload, into: slide, in: presentation); return }
        let clipboard = NSPasteboard.general
        do {
            let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if let url = urls.first(where: { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }) {
                try insertImage(url, into: presentation, pasted: true)
                return
            }
            guard let image = NSImage(pasteboard: clipboard),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url, options: .atomic)
            try insertImage(url, into: presentation, pasted: true)
        } catch { showError(error) }
    }
    @objc func bringForward() { moveLayer(by: 1) }
    @objc func sendBackward() { moveLayer(by: -1) }
    /// ⌥⌘↑ / ⌥⌘↓: moves the selected objects one layer forward / backward (one step per press).
    /// A table moves as one unit with all of its cells.
    func moveLayer(by delta: Int) {
        guard !busy, let slide = canvas.slide, !canvas.selection.isEmpty else { return }
        func key(_ item: SlideItem) -> ObjectIdentifier { ObjectIdentifier(item.tableNode ?? item.node) }
        var units: [[SlideItem]] = []
        var unitIndex: [ObjectIdentifier: Int] = [:]
        for item in slide.items {
            if let at = unitIndex[key(item)] { units[at].append(item) } else { unitIndex[key(item)] = units.count; units.append([item]) }
        }
        func movable(_ unit: [SlideItem]) -> Bool { unit[0].canMove || unit[0].isTableCell }   // a table starts with its frame item
        let selectedKeys = Set(canvas.selection.map(key))
        var chosen = units.indices.filter { selectedKeys.contains(key(units[$0][0])) && movable(units[$0]) }
        guard !chosen.isEmpty else { return }
        if delta > 0 { chosen.reverse() }
        var moves: [(from: Int, to: Int)] = []
        var order = Array(units.indices)   // current stacking order of unit ids
        for unit in chosen {
            guard let at = order.firstIndex(of: unit) else { continue }
            var next = at + (delta > 0 ? 1 : -1)
            while order.indices.contains(next), !movable(units[order[next]]) { next += delta > 0 ? 1 : -1 }
            guard order.indices.contains(next), !selectedKeys.contains(key(units[order[next]][0])) else { continue }
            moves.append((unit, order[next])); order.swapAt(at, next)
        }
        guard !moves.isEmpty else { return }
        checkpoint()
        func node(_ unit: [SlideItem]) -> XMLElement { unit[0].tableNode ?? unit[0].node }
        for move in moves {
            let mine = node(units[move.from]), other = node(units[move.to])
            mine.detach()
            slide.tree.insertChild(mine, at: delta > 0 ? other.index + 1 : other.index)
        }
        slide.items = order.flatMap { units[$0] }
        canvas.rebuild(); didChange()
    }
    /// Delete: removes every selected object. A selected table (any of its cells) goes as a whole.
    @objc func deleteObject() {
        guard let slide = canvas.slide, !canvas.selection.isEmpty else { return }
        canvas.finishEditing(commit: true)
        var doomed: [SlideItem] = []
        for item in canvas.selection {
            if item.isTableCell { doomed += slide.items.filter { $0.tableID == item.tableID || ($0.cellTextOf != nil && $0.cellTextOf == item.tableID) } }   // the table and the texts split out of its cells
            else if item.canMove { doomed.append(item) }
        }
        guard !doomed.isEmpty else { return }
        checkpoint()
        var detachedTables = Set<ObjectIdentifier>()
        for item in doomed {
            if let table = item.tableNode { if detachedTables.insert(ObjectIdentifier(table)).inserted { table.detach() } }
            else { item.node.detach() }
        }
        slide.items.removeAll { item in doomed.contains { $0 === item } }
        slide.timingDirty = true
        canvas.selected = nil; canvas.rebuild(); didChange()
    }
}

extension AppDelegate {
    /// ⌘V with copied objects: same look and position on another slide; shifted a little when pasted on the same slide.
    func pasteObjects(_ payload: ObjectClipboard.Payload, into slide: Slide, in presentation: Presentation) {
        canvas.finishEditing(commit: true)
        let board = NSPasteboard.general
        let key = "\(board.changeCount)|\(slide.path)"
        pasteRepeats = (key == lastPasteKey) ? pasteRepeats + 1 : (payload.slide == slide.path ? 1 : 0)
        lastPasteKey = key
        checkpoint()
        do {
            let created = try presentation.importObjects(payload, into: slide, shift: CGFloat(pasteRepeats) * 24)
            guard !created.isEmpty else { NSSound.beep(); return }
            canvas.rebuild()
            canvas.select(created)
            didChange()
            enforceStandardListSpacing([slide])   // a pasted list takes the standard spacing too
        } catch { showError(error) }
    }
}
