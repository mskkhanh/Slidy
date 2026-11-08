import AppKit

private final class FadeRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let fill = isEmphasized ? NSColor.controlAccentColor.withAlphaComponent(0.22) :
            NSColor.unemphasizedSelectedContentBackgroundColor
        fill.setFill()
        let area = bounds.insetBy(dx: 5, dy: 1)
        NSBezierPath(roundedRect: area, xRadius: 5, yRadius: 5).fill()
    }
}

final class FadeSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var reloading = false
    private let empty = NSTextField(wrappingLabelWithString: "Bấm hoặc kéo khung để chọn, rồi nhấn F. Giữ Shift để chọn thêm.")
    private let rowType = NSPasteboard.PasteboardType("com.khanh.slidy.fade-row")
    private var groups: [[SlideItem]] = []
    var onMove: ((Int, Int) -> Void)?
    var onSelect: (([SlideItem]) -> Void)?
    var onRemove: (([SlideItem]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("fade"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.draggingDestinationFeedbackStyle = .gap
        table.rowHeight = 24
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self
        table.registerForDraggedTypes([rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        table.setAccessibilityLabel("Thứ tự Fade")
        for view in [scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func display(_ groups: [[SlideItem]]) {
        let selected = self.groups.indices.contains(table.selectedRow) ? self.groups[table.selectedRow].first : nil
        reloading = true
        self.groups = groups
        table.reloadData()
        if let selected, let row = groups.firstIndex(where: { $0.contains { $0 === selected } }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        reloading = false
        empty.isHidden = !groups.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { groups.count }

    func handleRemovalShortcut(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === table,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [51, 117].contains(event.keyCode) || event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return false
        }
        if !event.isARepeat, groups.indices.contains(table.selectedRow) {
            onRemove?(groups[table.selectedRow])
        }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FadeRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let group = groups[row]
        let item = group[0]
        let name = group.count > 1 ? "Nhóm · \(group.count) đối tượng" :
            (item.imageURL != nil ? "Ảnh" : (item.text.split(separator: "\n").first.map(String.init) ?? "Đối tượng"))
        let label = NSTextField(labelWithString: "\(row + 1).  \(name)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = group.map { $0.imageURL != nil ? "Ảnh" : $0.text }.joined(separator: "\n")
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        guard groups.indices.contains(table.selectedRow) else { return }
        onSelect?(groups[table.selectedRow])
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, (0...groups.count).contains(row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: rowType), let source = Int(value),
              groups.indices.contains(source), (0...groups.count).contains(row),
              row != source, row != source + 1 else { return false }
        onMove?(source, row)
        return true
    }
}
