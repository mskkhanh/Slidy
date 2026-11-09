import AppKit
import UniformTypeIdentifiers

// Slide editing actions: insert, paste, delete, order, Fade.
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
    func toggleSelectedFade() {
        let selection = canvas.selection.filter(\.canMove)
        guard !busy, !selection.isEmpty else { return }
        // F toggles: if every selected object already has Fade, remove it from all of them; otherwise add Fade.
        setFade(for: selection, enabled: !selection.allSatisfy(\.hasFade))
    }
    func setFade(for selection: [SlideItem], enabled: Bool) {
        guard !busy, !selection.isEmpty, let slide = canvas.slide, permitTimingEdit() else { return }
        checkpoint()
        if enabled { slide.applyFade(to: selection) }
        else { selection.forEach { slide.removeFade(from: $0) } }
        didChange()
    }
    /// Slides the wand button will touch: those with objects but no Fade at all. Slides you animated yourself are left alone.
    func slidesWithoutEffects(in presentation: Presentation) -> [Slide] {
        presentation.slides.filter { $0.fadeGroups.isEmpty && $0.items.contains(where: \.canMove) }
    }
    /// Gives every movable object of `slides` a Fade, numbered from the top of the slide downwards.
    func applyFade(toTopToBottom slides: [Slide]) {
        for slide in slides {
            let targets = slide.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            guard !targets.isEmpty else { continue }
            slide.items.forEach { $0.order = 0 }
            targets.forEach { slide.removeFade(from: $0) }
            targets.forEach { slide.applyFade(to: [$0]) }
        }
    }
    /// Top-right button: slides that have no effect yet get a Fade on every object, top to bottom.
    /// Slides that already have effects (the ones you set up by hand) are skipped and stay exactly as they are.
    @objc func fadeAllSlides() {
        guard let presentation, !busy, showWindow == nil, window.attachedSheet == nil else { return }
        canvas.finishEditing(commit: true)
        let plain = slidesWithoutEffects(in: presentation)
        let alert = NSAlert()
        if plain.isEmpty {
            alert.messageText = "All slides already have effects"
            alert.informativeText = "Nothing to apply. Slides with effects are left as they are."
            alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        let skipped = presentation.slides.count - plain.count
        alert.messageText = "Apply Fade to \(plain.count) slides without effects?"
        alert.informativeText = "Every object on those slides gets a Fade, top to bottom. The other \(skipped) slides already have effects (or no objects) and stay as they are. ⌘Z undoes it."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        checkpointAll()
        applyFade(toTopToBottom: plain)
        refreshAllSlides()
    }
    /// ⌘G: groups the selected objects' Fade effects so they play together (one number, one icon), or ungroups them.
    @objc func toggleFadeGroup() {
        guard !busy, canvas.editor == nil, let slide = canvas.slide else { return }
        let selection = canvas.selection.filter(\.canMove)
        let ungroup = !selection.isEmpty && selection.allSatisfy { $0.hasFade && $0.fadeGroup != nil }
        guard ungroup || selection.count >= 2, permitTimingEdit() else { NSSound.beep(); return }
        checkpoint()
        if ungroup {
            selection.forEach { $0.fadeGroup = nil }
        } else {
            let key = UUID().uuidString
            let order = selection.filter(\.hasFade).map(\.order).min() ?? ((slide.items.map(\.order).max() ?? 0) + 1)
            for item in selection {
                if !item.hasFade { item.enableFade(); item.duration = defaultFadeDuration; item.paragraphDurations.removeAll() }
                item.fadeGroup = key; item.order = order
            }
        }
        slide.normalizeFadeOrder(); slide.timingDirty = true
        didChange()
    }
    /// ⌥⌘↑ / ⌥⌘↓ on the slide: move the selected objects' Fade effects one step earlier / later.
    func reorderFade(by delta: Int) {
        guard !busy, let slide = canvas.slide else { return }
        let groups = slide.fadeGroups
        let selectedIDs = Set(canvas.selection.map { ObjectIdentifier($0) })
        let rows = groups.indices.filter { row in groups[row].contains { selectedIDs.contains(ObjectIdentifier($0)) } }
        guard let first = rows.first, let last = rows.last, delta < 0 ? first > 0 : last < groups.count - 1,
              permitTimingEdit() else { return }
        checkpoint()
        for row in (delta < 0 ? rows : rows.reversed()) { slide.moveFadeGroup(from: row, to: delta < 0 ? row - 1 : row + 2) }
        didChange()
    }
    func permitTimingEdit() -> Bool {
        guard let slide = canvas.slide else { return false }
        if slide.originalTiming && !slide.timingDirty && !slide.warnings.isEmpty {
            let alert = NSAlert(); alert.messageText = "Replace this slide’s effects with Fade?"; alert.informativeText = "This slide has effects other than Fade. Slidy’s Fade order will replace them."
            alert.addButton(withTitle: "Use Fade"); alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
    @objc func bringForward() { reorder(forward: true) }
    @objc func sendBackward() { reorder(forward: false) }
    func reorder(forward: Bool) {
        guard let item = canvas.selected, let slide = canvas.slide, item.canMove, let position = slide.items.firstIndex(where: { $0 === item }) else { return }
        let next = position + (forward ? 1 : -1)
        guard slide.items.indices.contains(next), slide.items[next].canMove else { return }
        checkpoint(); let other = slide.items[next].node; let nodeIndex = other.index
        item.node.detach(); slide.tree.insertChild(item.node, at: forward ? nodeIndex : nodeIndex)
        slide.items.swapAt(position, next); canvas.rebuild(); didChange()
    }
    /// Delete: removes every selected object. A selected table (any of its cells) goes as a whole.
    @objc func deleteObject() {
        guard let slide = canvas.slide, !canvas.selection.isEmpty else { return }
        canvas.finishEditing(commit: true)
        var doomed: [SlideItem] = []
        for item in canvas.selection {
            if item.isTableCell { doomed += slide.items.filter { $0.tableID == item.tableID } }
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
    /// ⌘↓ / ⌘↑: with the slide list focused, moves the selected slide in the deck; otherwise goes to the next / previous slide.
    func moveSlide(by delta: Int) {
        guard let presentation, !busy, !showingRecents else { return }
        let next = index + delta
        guard presentation.slides.indices.contains(next) else { return }
        if window.firstResponder === table { moveSlideInDeck(from: index, to: next); return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
    /// Reorders the deck (saved into presentation.xml by autosave) and keeps the moved slide selected. ⌘Z moves it back.
    func moveSlideInDeck(from source: Int, to destination: Int) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.moveSlide(from: source, to: destination) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { target in target.moveSlideInDeck(from: destination, to: source) }
        undo.setActionName("Move Slide")
        index = destination
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        table.scrollRowToVisible(destination)
        window.makeFirstResponder(table)
        didChange()
    }
}

extension AppDelegate {
    /// Return in the slide list: a new slide after the selected one, styled like the deck's content slides. ⌘Z removes it.
    func insertSlideInDeck(after position: Int) {
        guard let presentation, !busy, !showingRecents else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.insertSlide(after: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.removeSlideInDeck(at: position + 1) }
        undo.setActionName("Add Slide")
        showSlideRow(position + 1)
    }
    func removeSlideInDeck(at position: Int) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.removeInsertedSlide(at: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.insertSlideInDeck(after: position - 1) }
        undo.setActionName("Add Slide")
        showSlideRow(max(0, min(position - 1, presentation.slides.count - 1)))
    }
    /// Delete in the slide list removes the selected slide (no confirmation: ⌘Z brings it back with its Fade).
    func deleteSlideInDeck(at position: Int) {
        guard let presentation, !busy, !showingRecents, presentation.slides.count > 1 else { NSSound.beep(); return }
        canvas.finishEditing(commit: true)
        let removed: RemovedSlide
        do { removed = try presentation.removeSlide(at: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.restoreSlideInDeck(removed) }
        undo.setActionName("Delete Slide")
        showSlideRow(min(position, presentation.slides.count - 1))
    }
    func restoreSlideInDeck(_ removed: RemovedSlide) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.restoreSlide(removed) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.deleteSlideInDeck(at: removed.index) }
        undo.setActionName("Delete Slide")
        showSlideRow(removed.index)
    }
    private func showSlideRow(_ row: Int) {
        index = row
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window.makeFirstResponder(table)
        didChange()
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
        } catch { showError(error) }
    }
}

extension AppDelegate {
    /// Your choice for lists already in the deck: spread the items a little, or put them back as they were.
    @objc func toggleListSpacing() {
        guard !busy, canvas.editor == nil, let slide = canvas.slide, let presentation else { return }
        let lists = canvas.selection.filter { $0.canMove && $0.hasList && $0.textBody != nil }
        guard !lists.isEmpty else { NSSound.beep(); return }
        let spread = lists.allSatisfy { $0.paragraphs.filter { $0.bullet != nil }.allSatisfy { $0.after > 0 } }
        checkpoint()
        lists.forEach { presentation.setListSpacing($0, on: !spread) }
        canvas.rebuild(); didChange()
    }
}
