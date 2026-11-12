import AppKit

// Headings in the recent files list: a heading works like a folder in the sidebar. Files are dragged under it,
// a chevron collapses it. Headings and their files live only in the app's settings; no .pptx is ever touched.

struct RecentGroup: Codable {
    var id: String
    var title: String
    var collapsed: Bool
    /// `RecentPresentation.key` of each file under the heading, in the order shown.
    var keys: [String]
}

/// One row of the recent files list.
enum SidebarRow {
    case file(RecentPresentation, indented: Bool)
    case heading(RecentGroup)
    /// The quiet "+ New heading" row at the end of the list.
    case add
}

extension AppDelegate {
    static let groupsKey = "recentGroups"
    static let recentRowType = NSPasteboard.PasteboardType("com.khanh.slidy.recent-row")
    static let defaultHeadingTitle = "New heading"

    var recentGroups: [RecentGroup] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.groupsKey) else { return [] }
            return (try? JSONDecoder().decode([RecentGroup].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.groupsKey) }
        }
    }
    static let pinnedKey = "recentPinned"
    /// Pinned files stay at the top of the plain list, in the order they were pinned.
    var pinnedKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey) }
    }
    /// Typing in the filter box shows the matching files as one flat list (no headings).
    func fileMatchesFilter(_ file: RecentPresentation) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return file.url.deletingPathExtension().lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    var isFiltering: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Pinned files first, then the rest, each group in its own order; with a filter, only the matches.
    func buildSidebarRows() -> [SidebarRow] {
        let recents = recentPresentations, groups = recentGroups, pinned = pinnedKeys
        if isFiltering {
            let matches = recents.filter(fileMatchesFilter)
            let ordered = matches.filter { pinned.contains($0.key) } + matches.filter { !pinned.contains($0.key) }
            return ordered.map { .file($0, indented: false) }
        }
        let grouped = Set(groups.flatMap(\.keys))
        let plain = recents.filter { !grouped.contains($0.key) }
        var rows: [SidebarRow] = pinned.compactMap { key in plain.first { $0.key == key } }.map { .file($0, indented: false) }
        rows += plain.filter { !pinned.contains($0.key) }.map { .file($0, indented: false) }
        for group in groups {
            rows.append(.heading(group))
            guard !group.collapsed else { continue }
            for key in group.keys { if let file = recents.first(where: { $0.key == key }) { rows.append(.file(file, indented: true)) } }
        }
        rows.append(.add)
        return rows
    }
    /// True when there is nothing to show (no files, no headings).
    var sidebarIsEmpty: Bool {
        !sidebarRows.contains { if case .add = $0 { return false } else { return true } }
    }
    func recentFile(at row: Int) -> RecentPresentation? {
        guard sidebarRows.indices.contains(row), case .file(let file, _) = sidebarRows[row] else { return nil }
        return file
    }
    func recentGroup(at row: Int) -> RecentGroup? {
        guard sidebarRows.indices.contains(row), case .heading(let group) = sidebarRows[row] else { return nil }
        return group
    }
    /// The recent list keeps 20 files, plus every file that sits under a heading.
    func trimmedRecents(_ list: [RecentPresentation]) -> [RecentPresentation] {
        let grouped = Set(recentGroups.flatMap(\.keys))
        var kept = 0
        return list.filter { entry in
            if grouped.contains(entry.key) { return true }
            kept += 1; return kept <= 20
        }
    }
    /// A file that was renamed or removed: its place under a heading follows (or goes).
    func replaceGroupKey(_ old: String, with new: String?) {
        var pinned = pinnedKeys
        if let at = pinned.firstIndex(of: old) { if let new, !pinned.contains(new) { pinned[at] = new } else { pinned.remove(at: at) }; pinnedKeys = pinned }
        var groups = recentGroups
        for index in groups.indices {
            guard let at = groups[index].keys.firstIndex(of: old) else { continue }
            if let new, !groups[index].keys.contains(new) { groups[index].keys[at] = new } else { groups[index].keys.remove(at: at) }
        }
        recentGroups = groups
    }

    // MARK: Heading actions
    @objc func addSidebarHeading(_ sender: Any?) {
        guard recentsMode, !busy else { return }
        var groups = recentGroups
        let group = RecentGroup(id: UUID().uuidString, title: Self.defaultHeadingTitle, collapsed: false, keys: [])
        groups.append(group)
        recentGroups = groups
        updateRecentSidebar()
        if let row = sidebarRows.firstIndex(where: { if case .heading(let g) = $0 { return g.id == group.id } else { return false } }) {
            table.scrollRowToVisible(row)
            beginRenameGroup(row: row)
        }
    }
    @objc func toggleGroup(_ sender: NSButton) {
        guard let group = recentGroup(at: sender.tag) else { return }
        var groups = recentGroups
        guard let at = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[at].collapsed.toggle()
        recentGroups = groups
        updateRecentSidebar()
    }
    /// Removes a heading only: its files go back to the plain list. Nothing on disk is touched.
    @objc func removeGroup(_ sender: NSButton) {
        guard let group = recentGroup(at: sender.tag) else { return }
        recentGroups = recentGroups.filter { $0.id != group.id }
        updateRecentSidebar()
    }
    func beginRenameGroup(row: Int) {
        guard let group = recentGroup(at: row), renameField == nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        renamingGroup = group.id; renameField = field
        field.stringValue = group.title
        field.isEditable = true; field.isSelectable = true
        field.drawsBackground = true; field.backgroundColor = NSColor(white: 0.16, alpha: 1)
        field.delegate = self
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    func commitGroupTitle(id: String, text: String) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var groups = recentGroups
        guard let at = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[at].title = String(title.prefix(80))
        recentGroups = groups
    }

    // MARK: Drag and drop in the recent list
    func recentPasteboardWriter(row: Int) -> NSPasteboardWriting? {
        guard !isFiltering else { return nil }
        let item = NSPasteboardItem()
        if let file = recentFile(at: row) { item.setString("file:" + file.key, forType: Self.recentRowType) }
        else if let group = recentGroup(at: row) { item.setString("group:" + group.id, forType: Self.recentRowType) }
        else { return nil }
        return item
    }
    /// Where a file dropped before row `row` lands: the heading that row sits under (nil = the plain list) and its place there.
    func fileDropTarget(row: Int) -> (group: String?, index: Int) {
        var files = 0
        var at = min(row, sidebarRows.count) - 1
        while at >= 0 {
            if case .heading(let group) = sidebarRows[at] { return (group.id, files) }
            files += 1; at -= 1
        }
        return (nil, 0)
    }
    func recentValidateDrop(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isFiltering, info.draggingSource as? NSTableView === table, let value = info.draggingPasteboard.string(forType: Self.recentRowType) else { return [] }
        if value.hasPrefix("file:") {
            if operation == .on, recentGroup(at: row) != nil { return .move }   // dropped on a heading: goes in at the end
            table.setDropRow(min(row, sidebarRows.count), dropOperation: .above)
            return .move
        }
        // A heading moves between headings, or to the end.
        let id = String(value.dropFirst(6))
        let groups = recentGroups
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return [] }
        var to = groups.count
        if let heading = recentGroup(at: row), let index = groups.firstIndex(where: { $0.id == heading.id }) { to = index }
        else if row < sidebarRows.count - 1 { return [] }   // only between headings, or at the end (before the "+" row)
        guard to != from, to != from + 1 else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }
    func recentAcceptDrop(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> Bool {
        guard let value = info.draggingPasteboard.string(forType: Self.recentRowType) else { return false }
        return applyRecentDrop(value, row: row, operation: operation)
    }
    /// The drop itself: `value` is "file:<key>" or "group:<id>", `row` the row it was dropped before (or on).
    func applyRecentDrop(_ value: String, row: Int, operation: NSTableView.DropOperation) -> Bool {
        var groups = recentGroups
        if value.hasPrefix("file:") {
            let key = String(value.dropFirst(5))
            var target: (group: String?, index: Int)
            if operation == .on, let heading = recentGroup(at: row) { target = (heading.id, Int.max) } else { target = fileDropTarget(row: row) }
            // Taking the file out first can shift the place it lands in.
            if let id = target.group, let into = groups.firstIndex(where: { $0.id == id }), let old = groups[into].keys.firstIndex(of: key), old < target.index { target.index -= 1 }
            for index in groups.indices { groups[index].keys.removeAll { $0 == key } }
            if let id = target.group, let into = groups.firstIndex(where: { $0.id == id }) {
                groups[into].keys.insert(key, at: min(max(0, target.index), groups[into].keys.count))
                groups[into].collapsed = false
            }
        } else {
            let id = String(value.dropFirst(6))
            guard let from = groups.firstIndex(where: { $0.id == id }) else { return false }
            var to = groups.count
            if let heading = recentGroup(at: row), let index = groups.firstIndex(where: { $0.id == heading.id }) { to = index }
            let moved = groups.remove(at: from)
            groups.insert(moved, at: to > from ? to - 1 : to)
        }
        recentGroups = groups
        DispatchQueue.main.async { [weak self] in self?.updateRecentSidebar() }   // after the drop finishes
        return true
    }
}
