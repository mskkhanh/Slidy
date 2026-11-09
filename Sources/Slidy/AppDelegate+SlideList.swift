import AppKit
import UniformTypeIdentifiers

// Left column: slide thumbnails, and the recent files list (⌘E).
struct RecentPresentation: Codable {
    let path: String
    let slide: Int

    var url: URL { URL(fileURLWithPath: path) }
    /// File names with accents can arrive composed or decomposed; compare them in one form so a file never appears twice.
    var key: String { Self.key(path) }
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }
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
        recentSidebarEntries = recentPresentations
        table.setAccessibilityLabel("Bài trình chiếu gần đây")
        table.rowHeight = 28; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.reloadData()
        // The open file is highlighted without being "clicked" (which would reopen it).
        suppressSelectionOpen = true
        table.deselectAll(nil)
        if let current = presentation?.source, let row = recentSidebarEntries.firstIndex(where: { $0.key == RecentPresentation.key(current.standardizedFileURL.path) }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelectionOpen = false
        emptyRecents.isHidden = sidebarHidden || !(recentsMode && recentSidebarEntries.isEmpty)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if let presentation, !showingRecents { return presentation.slides.count }
        return recentSidebarEntries.count
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GrayRowView() }
    private static let recentFont = NSFont.systemFont(ofSize: 12)
    private static let recentLabelWidth: CGFloat = 112
    /// Recent files sit close together; a long name takes a second line before it is truncated.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if presentation != nil, !showingRecents { return 106 }
        guard recentSidebarEntries.indices.contains(row) else { return 28 }
        let name = recentSidebarEntries[row].url.deletingPathExtension().lastPathComponent
        let box = (name as NSString).boundingRect(with: NSSize(width: Self.recentLabelWidth, height: 1000),
                                                  options: [.usesLineFragmentOrigin], attributes: [.font: Self.recentFont])
        return box.height > 20 ? 40 : 26
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let presentation, !showingRecents else {
            guard recentSidebarEntries.indices.contains(row) else { return nil }
            let entry = recentSidebarEntries[row]
            let cell = NSTableCellView()
            cell.toolTip = entry.path
            let symbol = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil) ?? NSImage()
            let icon = NSImageView(image: symbol)
            icon.contentTintColor = NSColor(red: 0.50, green: 0.68, blue: 0.96, alpha: 1)
            let label = NSTextField(wrappingLabelWithString: entry.url.deletingPathExtension().lastPathComponent)
            label.font = Self.recentFont
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            if !entry.exists { label.textColor = .tertiaryLabelColor; cell.toolTip = entry.path + "\nKhông tìm thấy file" }
            label.preferredMaxLayoutWidth = Self.recentLabelWidth
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Xóa khỏi danh sách") ?? NSImage(), target: self, action: #selector(removeRecent(_:)))
            remove.isBordered = false; remove.contentTintColor = .tertiaryLabelColor; remove.tag = row
            remove.toolTip = "Xóa khỏi danh sách (không xóa file)"
            remove.imageScaling = .scaleProportionallyDown
            for view in [icon, label, remove] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                remove.widthAnchor.constraint(equalToConstant: 18), remove.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
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
        guard presentation != nil, !showingRecents, !busy else { return nil }
        let item = NSPasteboardItem(); item.setString(String(row), forType: Self.slideRowType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let presentation, !showingRecents, info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: Self.slideRowType), let source = Int(value),
              Self.slideDropTarget(source: source, row: row) != nil, row <= presentation.slides.count else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = info.draggingPasteboard.string(forType: Self.slideRowType), let source = Int(value),
              let target = Self.slideDropTarget(source: source, row: row) else { return false }
        DispatchQueue.main.async { [weak self] in self?.moveSlideInDeck(from: source, to: target) }   // after the drop finishes
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, !busy, !suppressSelectionOpen else { return }
        guard let presentation, !showingRecents else {
            if recentSidebarEntries.indices.contains(table.selectedRow) {
                let url = recentSidebarEntries[table.selectedRow].url
                if let open = presentation?.source, RecentPresentation.key(url.standardizedFileURL.path) == RecentPresentation.key(open.standardizedFileURL.path) { toggleRecents() }
                else { openURL(url) }
            }
            return
        }
        canvas.finishEditing(commit: true); index = table.selectedRow
        canvas.display(presentation.slides[index], in: presentation)
        updateStatus()
    }
    /// ⌘E: swaps the thumbnail column for the list of recent files, and back.
    @objc func toggleRecents() {
        guard presentation != nil, !busy, window.attachedSheet == nil, showWindow == nil else { return }
        canvas.finishEditing(commit: true)
        if sidebarHidden { setSidebarHidden(false) }
        showingRecents.toggle()
        if showingRecents { updateRecentSidebar() }
        else { showSlideList() }
    }
    /// Removes a file from the recent list only. The file itself is never touched.
    @objc func removeRecent(_ sender: NSButton) {
        guard recentSidebarEntries.indices.contains(sender.tag) else { return }
        let key = recentSidebarEntries[sender.tag].key
        recentPresentations = recentPresentations.filter { $0.key != key }
        updateRecentSidebar()
    }
    func showSlideList() {
        guard let presentation else { return }
        table.setAccessibilityLabel("Slides")
        table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        _ = presentation
    }
}
