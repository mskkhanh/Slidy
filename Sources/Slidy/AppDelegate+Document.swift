import AppKit
import UniformTypeIdentifiers

// Opening, autosaving, undo and status of the current presentation.
extension AppDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    func updateStatus() {
        guard let presentation else { return }
        let url = savedURL ?? presentation.source
        let path = url.standardizedFileURL.path
        let previous = recentPresentations
        let key = RecentPresentation.key(path)
        if previous.first?.key != key || previous.first?.slide != index {
            recentPresentations = [RecentPresentation(path: path, slide: index)] +
                Array(previous.filter { $0.key != key }.prefix(19))
        }
        status.stringValue = ""
        status.isHidden = true
        canvas.updateOrderBadges()
        let warnings = presentation.slides[index].warnings
        detail.stringValue = warnings.first ?? (presentation.missingFonts.isEmpty ? "" : "Font thay thế: " + presentation.missingFonts.sorted().joined(separator: ", "))
        detail.toolTip = (warnings + presentation.missingFonts.map { "Thiếu font \($0)" }).joined(separator: "\n")
        window.title = (savedURL ?? presentation.source).deletingPathExtension().lastPathComponent
        window.isDocumentEdited = modified
    }
    @objc func openFile() {
        guard !busy, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pptx")!]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.openURL(url) } }
    }
    func allowDiscard() -> Bool { flushSave(); return true }
    func openURL(_ url: URL, restoring: Bool = false) {
        guard allowDiscard() else { return }
        let wanted = RecentPresentation.key(url.standardizedFileURL.path)
        let lastIndex = recentPresentations.first { $0.key == wanted }?.slide ?? 0
        openRequest += 1
        let request = openRequest
        busy = true; status.stringValue = "Đang mở…"; status.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Presentation(url: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openRequest == request else { return }; self.busy = false
                switch result {
                case .success(let document):
                    let position = min(max(0, lastIndex), document.slides.count - 1)
                    self.table.deselectAll(nil)
                    self.table.setAccessibilityLabel("Slides")
                    self.table.rowHeight = 106; self.table.intercellSpacing = NSSize(width: 0, height: 4)
                    self.showingRecents = false; self.emptyRecents.isHidden = true; self.canvas.resetZoom()
                    self.presentation = document; self.savedURL = nil; self.modified = false; self.index = position
                    self.undo.removeAllActions(); self.thumbnailCache.removeAllObjects()
                    self.table.reloadData()
                    self.table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
                    self.table.scrollRowToVisible(position)
                    self.canvas.display(document.slides[position], in: document)
                    self.updateStatus()
                case .failure(let error):
                    // A file that is gone is dropped from the list; one that merely failed to open stays.
                    if restoring || !FileManager.default.fileExists(atPath: url.path) {
                        self.recentPresentations = self.recentPresentations.filter { $0.key != wanted }
                    }
                    self.showError(error)
                    self.status.isHidden = true
                    if self.recentsMode { self.updateRecentSidebar() }
                    self.updateStatus()
                }
            }
        }
    }
    func checkpoint() {
        guard let presentation else { return }
        let slideIndex = index, slide = presentation.slides[index]
        let snapshot = slide.document.xmlString
        let timingDirty = slide.timingDirty
        let settings = slide.items.map { ($0.id, $0.fade, $0.duration, $0.order, $0.paragraphDurations, $0.fadeGroup) }
        undo.registerUndo(withTarget: self) { target in
            guard target.presentation === presentation else { return }
            target.canvas.finishEditing(commit: false)
            target.index = slideIndex; target.checkpoint()
            do {
                slide.document = try xml(snapshot); slide.timingDirty = timingDirty
                try presentation.parse(slide)
                for (id, fade, duration, order, paragraphDurations, group) in settings { if let item = slide.items.first(where: { $0.id == id }) { item.fade = fade; item.duration = duration; item.order = order; item.paragraphDurations = paragraphDurations; item.fadeGroup = group } }
                target.table.selectRowIndexes(IndexSet(integer: slideIndex), byExtendingSelection: false)
                target.canvas.display(slide, in: presentation); target.didChange()
            } catch { target.showError(error) }
        }
        undo.setActionName("Sửa slide")
    }
    /// Saves pending edits into the original file. Called after a short pause, and before opening another file, closing or quitting.
    /// Returns false only when there were changes that could not be written to the file.
    @discardableResult
    func flushSave(whileEditing keepEditing: Bool = false, silent: Bool = false) -> Bool {
        autosaveTimer?.invalidate(); autosaveTimer = nil
        // The timer must never end a text edit the person is typing in; it waits for the edit to finish.
        if keepEditing, canvas.editor != nil {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flushSave(whileEditing: true) }
            return true
        }
        canvas.finishEditing(commit: true)
        guard modified, let presentation else { return true }
        do { try presentation.saveInPlace(); modified = false; window.isDocumentEdited = false; return true }
        catch {
            if !silent, window.attachedSheet == nil { showError(error) }
            return false
        }
    }
    func didChange() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flushSave(whileEditing: true) }
        modified = true; thumbnailCache.removeObject(forKey: NSNumber(value: index))
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)); updateStatus()
    }
    /// One undo step for a change that touches every slide.
    func checkpointAll() {
        guard let presentation else { return }
        let saved = presentation.slides.map { slide in
            (slide, slide.document.xmlString, slide.timingDirty, slide.items.map { ($0.id, $0.fade, $0.duration, $0.order, $0.paragraphDurations, $0.fadeGroup) })
        }
        undo.registerUndo(withTarget: self) { target in
            guard target.presentation === presentation else { return }
            target.canvas.finishEditing(commit: false)
            target.checkpointAll()
            do {
                for (slide, snapshot, timingDirty, settings) in saved {
                    slide.document = try xml(snapshot); slide.timingDirty = timingDirty
                    try presentation.parse(slide)
                    for (id, fade, duration, order, paragraphDurations, group) in settings {
                        if let item = slide.items.first(where: { $0.id == id }) { item.fade = fade; item.duration = duration; item.order = order; item.paragraphDurations = paragraphDurations; item.fadeGroup = group }
                    }
                }
                target.refreshAllSlides()
            } catch { target.showError(error) }
        }
        undo.setActionName("Fade cho mọi slide")
    }
    func refreshAllSlides() {
        guard let presentation else { return }
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        canvas.display(presentation.slides[index], in: presentation)
        didChange()
    }
    @objc func saveCopy() {
        guard let presentation, !busy else { return }; canvas.finishEditing(commit: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pptx")!]
        panel.nameFieldStringValue = savedURL?.lastPathComponent ?? presentation.source.deletingPathExtension().lastPathComponent + " — edited.pptx"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try presentation.save(to: url) }
            catch { self.showError(error) }
        }
    }
    func showError(_ error: Error) { let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
}
