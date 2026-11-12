import AppKit

// Actions on the selected slides: delete, duplicate, hide, and the right-click menu of the slide list.
extension AppDelegate {
    var selectedSlideRows: [Int] { table.selectedRowIndexes.sorted() }

    /// Delete in the slide list removes every selected slide (never all of them). One ⌘Z brings them all back.
    @objc func deleteSelectedSlides() {
        guard let presentation, !busy, !showingRecents else { return }
        let rows = selectedSlideRows.isEmpty ? [index] : selectedSlideRows
        guard rows.count < presentation.slides.count else { NSSound.beep(); return }
        for (step, row) in rows.sorted(by: >).enumerated() { deleteSlideInDeck(at: row, refresh: step == rows.count - 1) }
    }
    @objc func duplicateSelectedSlides() {
        guard let presentation, !busy, !showingRecents else { return }
        let rows = selectedSlideRows.isEmpty ? [index] : selectedSlideRows
        for (step, row) in rows.sorted(by: >).enumerated() { duplicateSlideInDeck(at: row, refresh: step == rows.count - 1) }
        // The copies are selected, each right after its original.
        let copies = IndexSet(rows.sorted().enumerated().map { $0.element + $0.offset + 1 })
        table.selectRowIndexes(copies, byExtendingSelection: false)
        _ = presentation
    }
    func duplicateSlideInDeck(at position: Int, refresh: Bool = true) {
        guard let presentation, !busy else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.duplicateSlide(at: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.undoDuplicate(at: position + 1) }
        undo.setActionName("Duplicate Slide")
        showSlideRow(position + 1, refresh: refresh)
    }
    func undoDuplicate(at position: Int) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.removeInsertedSlide(at: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.duplicateSlideInDeck(at: position - 1) }
        undo.setActionName("Duplicate Slide")
        showSlideRow(max(0, min(position - 1, presentation.slides.count - 1)))
    }
    /// Hide / show the selected slides while presenting (the slide stays in the file, marked show="0").
    @objc func toggleHideSelectedSlides() {
        guard let presentation, !busy, !showingRecents else { return }
        let rows = selectedSlideRows.isEmpty ? [index] : selectedSlideRows
        let allHidden = rows.allSatisfy { presentation.slides[$0].isHidden }
        canvas.finishEditing(commit: true)
        checkpointAll()
        undo.setActionName(allHidden ? "Show Slide" : "Hide Slide")
        rows.forEach { presentation.slides[$0].setHidden(!allHidden) }
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        didChange()
    }
    /// The slide list's right-click menu (the clicked slide joins the selection when it is not in it).
    func fillSlideMenu(_ menu: NSMenu, row: Int) {
        guard let presentation, row >= 0, row < presentation.slides.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let rows = selectedSlideRows
        func entry(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; return item
        }
        let many = rows.count > 1
        menu.addItem(entry(many ? "Duplicate \(rows.count) Slides" : "Duplicate", #selector(duplicateSelectedSlides)))
        menu.addItem(entry(rows.allSatisfy { presentation.slides[$0].isHidden } ? "Show" : "Hide", #selector(toggleHideSelectedSlides)))
        menu.addItem(.separator())
        menu.addItem(entry(many ? "Delete \(rows.count) Slides" : "Delete", #selector(deleteSelectedSlides), enabled: rows.count < presentation.slides.count))
    }
}
