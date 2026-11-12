import AppKit

// Slides in the deck: move, add, delete, restore.
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
    func moveSlideInDeck(from source: Int, to destination: Int, refresh: Bool = true) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.moveSlide(from: source, to: destination) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { target in target.moveSlideInDeck(from: destination, to: source) }
        undo.setActionName("Move Slide")
        index = destination
        guard refresh else { return }
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        table.scrollRowToVisible(destination)
        window.makeFirstResponder(table)
        didChange()
    }
    /// Where each slide ends up when `sources` are dropped before row `row`; nil when nothing would move.
    static func slideMoveOrder(sources: [Int], row: Int, count: Int) -> [Int]? {
        let sources = Array(Set(sources)).sorted().filter { $0 >= 0 && $0 < count }
        guard !sources.isEmpty, row >= 0, row <= count else { return nil }
        let remaining = (0..<count).filter { !sources.contains($0) }
        let position = remaining.filter { $0 < row }.count
        let order = Array(remaining[..<position]) + sources + Array(remaining[position...])
        return order == Array(0..<count) ? nil : order
    }
    /// Drag and drop of one or several slides: they keep their order and land together before `row`. One ⌘Z puts them back.
    func moveSlides(_ sources: [Int], before row: Int) {
        guard let presentation, let order = Self.slideMoveOrder(sources: sources, row: row, count: presentation.slides.count) else { return }
        var current = Array(0..<presentation.slides.count)   // original number of the slide now at each position
        for (target, wanted) in order.enumerated() {
            guard let at = current.firstIndex(of: wanted), at != target else { continue }
            moveSlideInDeck(from: at, to: target, refresh: false)
            current.insert(current.remove(at: at), at: target)
        }
        let moved = IndexSet(order.enumerated().filter { sources.contains($0.element) }.map(\.offset))
        index = moved.first ?? 0
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(moved, byExtendingSelection: false)
        table.scrollRowToVisible(index)
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
    func deleteSlideInDeck(at position: Int, refresh: Bool = true) {
        guard let presentation, !busy, !showingRecents, presentation.slides.count > 1 else { NSSound.beep(); return }
        canvas.finishEditing(commit: true)
        let removed: RemovedSlide
        do { removed = try presentation.removeSlide(at: position) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.restoreSlideInDeck(removed) }
        undo.setActionName("Delete Slide")
        showSlideRow(min(position, presentation.slides.count - 1), refresh: refresh)
    }
    func restoreSlideInDeck(_ removed: RemovedSlide) {
        guard let presentation else { return }
        canvas.finishEditing(commit: true)
        do { try presentation.restoreSlide(removed) } catch { showError(error); return }
        undo.registerUndo(withTarget: self) { $0.deleteSlideInDeck(at: removed.index) }
        undo.setActionName("Delete Slide")
        showSlideRow(removed.index)
    }
    func showSlideRow(_ row: Int, refresh: Bool = true) {
        index = row
        guard refresh else { return }
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window.makeFirstResponder(table)
        didChange()
    }
}
