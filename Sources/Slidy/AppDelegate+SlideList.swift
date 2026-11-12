import AppKit
import UniformTypeIdentifiers

// Left column: slide thumbnails, and the recent files list (⌘E).
struct RecentPresentation: Codable {
    let path: String
    let slide: Int

    var url: URL { URL(fileURLWithPath: path) }
    /// File names with accents can arrive composed or decomposed; compare them in one form so a file never appears twice.
    var key: String { Self.key(path) }
    /// One spelling per file: composed accents, and no "/private" in front of /tmp, /var and /etc (macOS reports both).
    static func key(_ path: String) -> String {
        let composed = path.precomposedStringWithCanonicalMapping
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where composed.hasPrefix(prefix) { return String(composed.dropFirst(8)) }
        return composed
    }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

extension AppDelegate {
    var recentsMode: Bool { presentation == nil || showingRecents }
    static let recentKey = "recentPresentations"
    var recentPresentations: [RecentPresentation] {
        get {
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: Self.recentKey),
               let entries = try? JSONDecoder().decode([RecentPresentation].self, from: data) { return entries }
            if let previous = defaults.dictionary(forKey: "lastPresentation"),
               let path = previous["path"] as? String {
                return [RecentPresentation(path: path, slide: previous["slide"] as? Int ?? 0)]
            }
            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.recentKey) }
        }
    }
    func updateRecentSidebar() {
        sidebarRows = buildSidebarRows()
        updateSidebarButtons()
        table.setAccessibilityLabel("Recent files")
        table.rowHeight = 28; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.reloadData()
        // The open file is highlighted without being "clicked" (which would reopen it).
        suppressSelectionOpen = true
        table.deselectAll(nil)
        if let current = presentation?.source, let row = sidebarRows.firstIndex(where: { if case .file(let file, _) = $0 { return file.key == RecentPresentation.key(current.standardizedFileURL.path) } else { return false } }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelectionOpen = false
        emptyRecents.stringValue = isFiltering ? "No matching files." : "No recent files.\nPress ⌘O to open a .pptx."
        emptyRecents.isHidden = sidebarHidden || !(recentsMode && sidebarIsEmpty)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if let presentation, !showingRecents { return presentation.slides.count }
        return sidebarRows.count
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GrayRowView() }
    /// One line per file; the full name is in the tooltip.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if presentation != nil, !showingRecents { return 106 }
        return 26
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let presentation, !showingRecents else {
            if let group = recentGroup(at: row) { return headingCell(for: group, row: row) }
            if case .add = sidebarRows[row] { return addRowCell() }
            guard let entry = recentFile(at: row), case .file(_, let indented) = sidebarRows[row] else { return nil }
            return fileCell(for: entry, row: row, indented: indented)
        }
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 154, height: 106))
        let image = NSImageView(frame: NSRect(x: 8, y: 17, width: 146, height: 82)); image.imageScaling = .scaleProportionallyUpOrDown
        image.image = thumbnail(row); cell.addSubview(image)
        let label = NSTextField(labelWithString: "\(row + 1)/\(presentation.slides.count)"); label.frame = NSRect(x: 8, y: 0, width: 146, height: 15); label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
        cell.addSubview(label); cell.textField = label
        cell.setAccessibilityLabel("Slide \(row + 1). \(presentation.slides[row].title)")
        return cell
    }
    func thumbnail(_ row: Int) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: NSNumber(value: row)) { return cached }
        guard let presentation else { return nil }
        let slide = presentation.slides[row]
        let preview = CanvasView(frame: NSRect(x: 0, y: 0, width: 292, height: 164))
        preview.usesNightMode = true
        preview.display(slide, in: presentation); preview.layoutSubtreeIfNeeded()
        // Render without editor margins and without enabling presentation animation.
        preview.surface.frame = preview.bounds; preview.surface.bounds = CGRect(origin: .zero, size: presentation.size)
        guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return nil }
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        let result = NSImage(size: NSSize(width: 146, height: 82)); result.addRepresentation(bitmap)
        thumbnailCache.setObject(result, forKey: NSNumber(value: row)); return result
    }
    // Drag and drop: reorder slides by dragging a thumbnail; a line shows where it will land.
    static let slideRowType = NSPasteboard.PasteboardType("com.khanh.slidy.slide-row")
    /// Dropping before row `row` puts the slide at this index, or nil when it would not move.
    static func slideDropTarget(source: Int, row: Int) -> Int? {
        let target = row > source ? row - 1 : row
        return target == source ? nil : target
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if recentsMode { return busy ? nil : recentPasteboardWriter(row: row) }
        guard presentation != nil, !showingRecents, !busy else { return nil }
        let item = NSPasteboardItem(); item.setString(String(row), forType: Self.slideRowType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if recentsMode { return recentValidateDrop(info, row: row, operation: operation) }
        guard let presentation, !showingRecents, info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: Self.slideRowType), let source = Int(value),
              Self.slideDropTarget(source: source, row: row) != nil, row <= presentation.slides.count else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if recentsMode { return recentAcceptDrop(info, row: row, operation: dropOperation) }
        guard let value = info.draggingPasteboard.string(forType: Self.slideRowType), let source = Int(value),
              let target = Self.slideDropTarget(source: source, row: row) else { return false }
        DispatchQueue.main.async { [weak self] in self?.moveSlideInDeck(from: source, to: target) }   // after the drop finishes
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, !busy, !suppressSelectionOpen else { return }
        guard let presentation, !showingRecents else { return }   // recent files open from a click (see recentClicked)
        canvas.finishEditing(commit: true); index = table.selectedRow
        canvas.display(presentation.slides[index], in: presentation)
        updateStatus()
        enforceStandardListSpacing([presentation.slides[index]])
    }
    // MARK: Recent files: click opens, double-click renames
    /// Opens the recent file in `row` (or closes the list when it is the file already open).
    func openRecent(row: Int) {
        guard recentsMode, let file = recentFile(at: row), !busy else { return }
        let url = file.url
        if let open = presentation?.source, RecentPresentation.key(url.standardizedFileURL.path) == RecentPresentation.key(open.standardizedFileURL.path) { toggleRecents() }
        else { openURL(url) }
    }
    /// A single click opens the file, but only after the double-click interval, so a double-click can rename instead.
    @objc func recentClicked() {
        guard recentsMode, renameField == nil else { return }
        let row = table.clickedRow
        guard row >= 0 else { return }
        if case .add = sidebarRows[row] { addSidebarHeading(nil); return }
        guard recentFile(at: row) != nil else { return }   // a heading does nothing on a single click
        pendingRecentOpen?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.openRecent(row: row) }
        pendingRecentOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    @objc func recentDoubleClicked() {
        pendingRecentOpen?.cancel(); pendingRecentOpen = nil
        guard recentsMode else { return }
        if recentGroup(at: table.clickedRow) != nil { beginRenameGroup(row: table.clickedRow) } else { beginRename(row: table.clickedRow) }
    }
    /// The name is edited in place; only the part before ".pptx" can change.
    func beginRename(row: Int) {
        guard let file = recentFile(at: row), renameField == nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        let url = file.url
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        renamingURL = url; renameField = field
        field.stringValue = url.deletingPathExtension().lastPathComponent
        field.isEditable = true; field.isSelectable = true
        field.drawsBackground = true; field.backgroundColor = NSColor(white: 0.16, alpha: 1)
        field.maximumNumberOfLines = 3
        field.delegate = self
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { finishRename(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finishRename(commit: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === renameField { finishRename(commit: true) }   // clicking elsewhere keeps the new name
    }
    func finishRename(commit: Bool) {
        guard let field = renameField else { return }
        let text = field.stringValue, url = renamingURL, group = renamingGroup
        renameField = nil; renamingURL = nil; renamingGroup = nil
        field.delegate = nil; field.isEditable = false; field.drawsBackground = false
        if commit {
            if let group { commitGroupTitle(id: group, text: text) }
            else if let url { do { try renameFile(at: url, to: text) } catch { showError(error) } }
        }
        updateRecentSidebar()
        window.makeFirstResponder(table)
    }
    /// ⌘E: swaps the thumbnail column for the list of recent files, and back.
    @objc func toggleRecents() {
        guard presentation != nil, !busy, window.attachedSheet == nil, showWindow == nil else { return }
        canvas.finishEditing(commit: true)
        if sidebarHidden { setSidebarHidden(false) }
        showingRecents.toggle()
        if showingRecents { updateRecentSidebar() }
        else { showSlideList() }
        updateSidebarButtons()
    }
    /// Removes a file from the recent list only. The file itself is never touched.
    @objc func removeRecent(_ sender: NSButton) {
        guard let file = recentFile(at: sender.tag) else { return }
        let key = file.key
        recentPresentations = recentPresentations.filter { $0.key != key }
        replaceGroupKey(key, with: nil)
        updateRecentSidebar()
    }
    func showSlideList() {
        guard let presentation else { return }
        table.setAccessibilityLabel("Slides")
        updateSidebarButtons()
        table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        _ = presentation
    }
}
