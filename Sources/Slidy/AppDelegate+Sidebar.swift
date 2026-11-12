import AppKit

// The left column's own controls: width, filter box, right-click menu, keyboard, pins.

/// The table of the left column. It passes plain arrow keys to the delegate first, so ← → fold headings.
final class SidebarTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A thin strip over the divider: drag it to make the left column wider or narrower.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - startX); startX = event.locationInWindow.x }
    override func mouseUp(with event: NSEvent) { onEnd?() }
    override var mouseDownCanMoveWindow: Bool { false }
}

extension AppDelegate {
    func installSidebarExtras(in root: NSView, scroll: NSScrollView, separator: NSView) {
        // Filter box at the top of the recent files list.
        searchField.placeholderString = "Filter"
        searchField.font = .systemFont(ofSize: 11)
        searchField.controlSize = .small
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none
        // The slide count, once, at the bottom of the slide list.
        slideCountLabel.font = .systemFont(ofSize: 10); slideCountLabel.textColor = NSColor(white: 0.5, alpha: 0.9)
        slideCountLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(slideCountLabel)
        NSLayoutConstraint.activate([slideCountLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 12), slideCountLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)])
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        searchField.target = self; searchField.action = #selector(filterChanged(_:))
        searchField.setAccessibilityLabel("Filter files")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8), searchField.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 29), searchField.heightAnchor.constraint(equalToConstant: 20)
        ])
        // Drag handle over the divider.
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarResizeHandle)
        NSLayoutConstraint.activate([
            sidebarResizeHandle.centerXAnchor.constraint(equalTo: separator.centerXAnchor), sidebarResizeHandle.widthAnchor.constraint(equalToConstant: 7),
            sidebarResizeHandle.topAnchor.constraint(equalTo: root.topAnchor), sidebarResizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebarResizeHandle.onDrag = { [weak self] delta in self?.setSidebarWidth((self?.sidebarWidth ?? 174) + delta, remember: false) }
        sidebarResizeHandle.onEnd = { [weak self] in UserDefaults.standard.set(Double(self?.sidebarWidth ?? 174), forKey: "sidebarWidth") }
        // Keyboard and right-click menu of the list.
        table.onKey = { [weak self] event in self?.sidebarKey(event) ?? false }
        let menu = NSMenu(); menu.delegate = self
        table.menu = menu
    }
    func setSidebarWidth(_ width: CGFloat, remember: Bool = true) {
        let clamped = min(max(width, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        sidebarWidthConstraint.constant = clamped
        if !recentsMode, presentation != nil { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows)) }   // thumbnails follow the width
        if remember { UserDefaults.standard.set(Double(clamped), forKey: "sidebarWidth") }
    }

    // MARK: Filter
    @objc func filterChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        guard recentsMode else { return }
        updateRecentSidebar()
    }
    /// ⌘K: shows the recent files and puts the cursor in the filter box.
    @objc func focusFilter() {
        guard !busy, window.attachedSheet == nil else { return }
        if presentation != nil, !showingRecents { toggleRecents() }
        if sidebarHidden { setSidebarHidden(false) }
        window.makeFirstResponder(searchField)
    }

    // MARK: Keyboard
    func sidebarKey(_ event: NSEvent) -> Bool {
        guard recentsMode, renameField == nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let row = table.selectedRow
        switch event.keyCode {
        case 123:   // ←: fold the heading, or step from a file to its heading
            if let group = recentGroup(at: row), !group.collapsed { setGroup(group.id, collapsed: true); return true }
            if case .file(_, true)? = sidebarRows.indices.contains(row) ? sidebarRows[row] : nil, let heading = (0..<row).reversed().first(where: { recentGroup(at: $0) != nil }) {
                table.selectRowIndexes(IndexSet(integer: heading), byExtendingSelection: false); return true
            }
            return true
        case 124:   // →: open the heading
            if let group = recentGroup(at: row), group.collapsed { setGroup(group.id, collapsed: false) }
            return true
        default: return false
        }
    }
    /// Return in the list: opens the selected file, or folds / opens the selected heading.
    func activateSelectedSidebarRow() {
        let row = table.selectedRow
        guard row >= 0, sidebarRows.indices.contains(row) else { return }
        switch sidebarRows[row] {
        case .file: openRecent(row: row)
        case .heading(let group): setGroup(group.id, collapsed: !group.collapsed)
        case .add: addSidebarHeading(nil)
        }
    }
    func setGroup(_ id: String, collapsed: Bool) {
        var groups = recentGroups
        guard let at = groups.firstIndex(where: { $0.id == id }), groups[at].collapsed != collapsed else { return }
        groups[at].collapsed = collapsed
        recentGroups = groups
        updateRecentSidebar()
        if let row = sidebarRows.firstIndex(where: { if case .heading(let g) = $0 { return g.id == id } else { return false } }) {
            suppressSelectionOpen = true; table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); suppressSelectionOpen = false
        }
    }
    @objc func collapseAllHeadings() { setAllGroups(collapsed: true) }
    @objc func expandAllHeadings() { setAllGroups(collapsed: false) }
    func setAllGroups(collapsed: Bool) {
        guard recentsMode else { return }
        recentGroups = recentGroups.map { var group = $0; group.collapsed = collapsed; return group }
        updateRecentSidebar()
    }

    // MARK: Pins and moves
    func togglePin(_ key: String) {
        var pinned = pinnedKeys
        if let at = pinned.firstIndex(of: key) { pinned.remove(at: at) }
        else {
            pinned.append(key)
            recentGroups = recentGroups.map { var group = $0; group.keys.removeAll { $0 == key }; return group }   // pinned files sit at the top of the plain list
        }
        pinnedKeys = pinned
        updateRecentSidebar()
    }
    /// Puts a file under a heading (or back in the plain list when `group` is nil), at the end.
    func moveRecent(_ key: String, toGroup group: String?) {
        var groups = recentGroups
        for index in groups.indices { groups[index].keys.removeAll { $0 == key } }
        if let group, let at = groups.firstIndex(where: { $0.id == group }) {
            groups[at].keys.append(key); groups[at].collapsed = false
            pinnedKeys = pinnedKeys.filter { $0 != key }
        }
        recentGroups = groups
        updateRecentSidebar()
    }

    // MARK: Right-click menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        fillSidebarMenu(menu, row: table.clickedRow)
    }
    /// The menu for the row that was right-clicked (empty for the slide list, which has no menu).
    func fillSidebarMenu(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard recentsMode else { fillSlideMenu(menu, row: row); return }
        func item(_ title: String, _ action: Selector, _ represented: Any? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; entry.representedObject = represented; return entry
        }
        if let file = recentFile(at: row) {
            menu.addItem(item("Open", #selector(menuOpen(_:)), file.key))
            menu.addItem(item("Rename…", #selector(menuRename(_:)), file.key))
            menu.addItem(item(pinnedKeys.contains(file.key) ? "Unpin" : "Pin to Top", #selector(menuPin(_:)), file.key))
            let move = NSMenuItem(title: "Move to Heading", action: nil, keyEquivalent: ""); let submenu = NSMenu()
            for group in recentGroups { submenu.addItem(item(group.title, #selector(menuMove(_:)), [file.key, group.id])) }
            if !recentGroups.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(item("No Heading", #selector(menuMove(_:)), [file.key, ""]))
            move.submenu = submenu; menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(item("Show in Finder", #selector(menuReveal(_:)), file.key))
            menu.addItem(item("Remove from List", #selector(menuRemove(_:)), file.key))
        } else if let group = recentGroup(at: row) {
            menu.addItem(item("Rename…", #selector(menuRenameGroup(_:)), group.id))
            menu.addItem(item(group.collapsed ? "Expand" : "Collapse", #selector(menuToggleGroup(_:)), group.id))
            menu.addItem(.separator())
            menu.addItem(item("Collapse All", #selector(collapseAllHeadings)))
            menu.addItem(item("Expand All", #selector(expandAllHeadings)))
            menu.addItem(.separator())
            menu.addItem(item("Remove Heading", #selector(menuRemoveGroup(_:)), group.id))
        }
    }
    private func file(for key: Any?) -> RecentPresentation? { recentPresentations.first { $0.key == (key as? String) } }
    private func row(forKey key: Any?) -> Int? { sidebarRows.firstIndex { if case .file(let f, _) = $0 { return f.key == (key as? String) } else { return false } } }
    private func row(forGroup id: Any?) -> Int? { sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.id == (id as? String) } else { return false } } }
    @objc func menuOpen(_ item: NSMenuItem) { if let row = row(forKey: item.representedObject) { openRecent(row: row) } }
    @objc func menuRename(_ item: NSMenuItem) { if let row = row(forKey: item.representedObject) { beginRename(row: row) } }
    @objc func menuPin(_ item: NSMenuItem) { if let key = item.representedObject as? String { togglePin(key) } }
    @objc func menuMove(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String], pair.count == 2 else { return }
        moveRecent(pair[0], toGroup: pair[1].isEmpty ? nil : pair[1])
    }
    @objc func menuReveal(_ item: NSMenuItem) { if let file = file(for: item.representedObject) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } }
    @objc func menuRemove(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        recentPresentations = recentPresentations.filter { $0.key != key }
        replaceGroupKey(key, with: nil)
        updateRecentSidebar()
    }
    @objc func menuRenameGroup(_ item: NSMenuItem) { if let row = row(forGroup: item.representedObject) { beginRenameGroup(row: row) } }
    @objc func menuToggleGroup(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let group = recentGroups.first(where: { $0.id == id }) else { return }
        setGroup(id, collapsed: !group.collapsed)
    }
    @objc func menuRemoveGroup(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        recentGroups = recentGroups.filter { $0.id != id }
        updateRecentSidebar()
    }
}
