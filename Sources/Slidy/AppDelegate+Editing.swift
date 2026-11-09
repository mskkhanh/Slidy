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
    /// Top-right button: every movable object on every slide gets a Fade, numbered from the top of the slide downwards.
    @objc func fadeAllSlides() {
        guard let presentation, !busy, showWindow == nil, window.attachedSheet == nil else { return }
        canvas.finishEditing(commit: true)
        let alert = NSAlert()
        alert.messageText = "Áp dụng Fade cho tất cả slide?"
        alert.informativeText = "Mọi đối tượng trên \(presentation.slides.count) slide sẽ có hiệu ứng Fade, theo thứ tự từ trên xuống dưới. Thứ tự hiệu ứng hiện có sẽ được thay. Có thể hoàn tác bằng ⌘Z."
        alert.addButton(withTitle: "Áp dụng"); alert.addButton(withTitle: "Hủy")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        checkpointAll()
        for slide in presentation.slides {
            let targets = slide.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            guard !targets.isEmpty else { continue }
            slide.items.forEach { $0.order = 0 }
            targets.forEach { slide.removeFade(from: $0) }
            targets.forEach { slide.applyFade(to: [$0]) }
        }
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
            let alert = NSAlert(); alert.messageText = "Thay hiệu ứng của slide này bằng Fade?"; alert.informativeText = "Slide có hiệu ứng gốc ngoài phạm vi Fade. Bản sao sẽ dùng thứ tự Fade trong ứng dụng."
            alert.addButton(withTitle: "Dùng Fade"); alert.addButton(withTitle: "Hủy")
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
    @objc func deleteObject() {
        guard let item = canvas.selected, let slide = canvas.slide, item.canMove else { return }
        canvas.finishEditing(commit: true); checkpoint(); item.node.detach(); slide.items.removeAll { $0 === item }; slide.timingDirty = true
        canvas.selected = nil; canvas.rebuild(); didChange()
    }
}

extension AppDelegate {
    /// ⌘↓ / ⌘↑ while editing: go to the next / previous slide.
    func moveSlide(by delta: Int) {
        guard let presentation, !busy, !showingRecents else { return }
        let next = index + delta
        guard presentation.slides.indices.contains(next) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
}
