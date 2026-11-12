import AppKit

// The rows of the recent files list: a quiet dot, one line per file with the full name in the tooltip, a small gray
// date on the right (replaced by ✕ while the pointer is over the row), a thin bar on the open file, a guide line for
// files under a heading.

extension AppDelegate {
    static let accent = NSColor(red: 0.50, green: 0.68, blue: 0.96, alpha: 1)
    static let rowFont = NSFont.systemFont(ofSize: 12)
    static let faint = NSColor(white: 0.5, alpha: 0.55)

    /// "14:05" today, a weekday within the last week, otherwise "Nov 9" (with the year when it is not this one).
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // 24-hour time, English day and month names
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "HH:mm" }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days > 0, days < 7 { formatter.dateFormat = "EEE" }
        else if calendar.component(.year, from: date) == calendar.component(.year, from: now) { formatter.dateFormat = "MMM d" }
        else { formatter.dateFormat = "MMM d, yyyy" }
        return formatter.string(from: date)
    }
    private func metaLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10); label.textColor = NSColor(white: 0.5, alpha: 0.9)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.identifier = HoverReveal.hideIdentifier   // goes away while the ✕ shows
        return label
    }
    private func removeButton(row: Int, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        button.isBordered = false; button.contentTintColor = .tertiaryLabelColor; button.tag = row
        button.toolTip = tip; button.imageScaling = .scaleProportionallyDown
        button.identifier = HoverReveal.identifier; button.alphaValue = 0   // shown while the pointer is over the row
        return button
    }
    func fileCell(for entry: RecentPresentation, row: Int, indented: Bool) -> NSView {
        let cell = NSTableCellView()
        let name = entry.url.deletingPathExtension().lastPathComponent
        let exists = entry.exists
        cell.toolTip = name + "\n" + entry.path + (exists ? "" : "\nFile not found")
        let pinned = pinnedKeys.contains(entry.key)
        let open = presentation.map { RecentPresentation.key($0.source.standardizedFileURL.path) == entry.key } ?? false
        // A small faint dot (a pin when pinned) instead of an icon on every row.
        let icon = NSImageView(image: NSImage(systemSymbolName: pinned ? "pin.fill" : "circle.fill", accessibilityDescription: pinned ? "Pinned" : nil)?
            .withSymbolConfiguration(.init(pointSize: pinned ? 8 : 5, weight: .regular)) ?? NSImage())
        icon.contentTintColor = pinned ? NSColor(white: 0.65, alpha: 1) : Self.faint
        let label = NSTextField(labelWithString: name)
        label.font = Self.rowFont; label.lineBreakMode = .byTruncatingTail; label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = exists ? .labelColor : .tertiaryLabelColor
        let date = (try? FileManager.default.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date
        let meta = metaLabel(date.map { Self.shortDate($0) } ?? "")
        let remove = removeButton(row: row, tip: "Remove from list", action: #selector(removeRecent(_:)))
        for view in [icon, label, meta, remove] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        let left: CGFloat = indented ? 26 : 12
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: left), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -6),
            meta.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), meta.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 18), remove.heightAnchor.constraint(equalToConstant: 18)
        ])
        if indented { addBar(to: cell, x: 16, width: 1, color: NSColor(white: 0.5, alpha: 0.28), inset: 0) }   // the guide line of the heading's files
        if open { addBar(to: cell, x: 1, width: 2, color: Self.accent, inset: 5) }                            // the open file
        return cell
    }
    private func addBar(to cell: NSView, x: CGFloat, width: CGFloat, color: NSColor, inset: CGFloat) {
        let bar = NSBox(); bar.boxType = .custom; bar.borderWidth = 0; bar.fillColor = color; bar.cornerRadius = width / 2
        bar.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: x), bar.widthAnchor.constraint(equalToConstant: width),
                                     bar.topAnchor.constraint(equalTo: cell.topAnchor, constant: inset), bar.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -inset)])
    }
    func headingCell(for group: RecentGroup, row: Int) -> NSView {
        let cell = NSTableCellView()
        let chevron = NSButton(image: NSImage(systemSymbolName: group.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: group.collapsed ? "Expand" : "Collapse")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) ?? NSImage(), target: self, action: #selector(toggleGroup(_:)))
        chevron.isBordered = false; chevron.contentTintColor = .secondaryLabelColor; chevron.tag = row
        chevron.toolTip = group.collapsed ? "Expand" : "Collapse"; chevron.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: group.title)
        label.font = .systemFont(ofSize: 12, weight: .bold); label.textColor = NSColor(white: 0.88, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = metaLabel(String(group.keys.count))   // how many files it holds
        let remove = removeButton(row: row, tip: "Remove heading (files stay in the list)", action: #selector(removeGroup(_:)))
        for view in [chevron, label, count, remove] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14), chevron.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 18), remove.heightAnchor.constraint(equalToConstant: 18)
        ])
        cell.toolTip = group.title + "\nDouble-click to rename. Drag files under it."
        return cell
    }
    /// The last row: a quiet way to add a heading.
    func addRowCell() -> NSView {
        let cell = NSTableCellView()
        let plus = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New heading")?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) ?? NSImage())
        plus.contentTintColor = Self.faint
        let label = NSTextField(labelWithString: "New heading")
        label.font = .systemFont(ofSize: 11); label.textColor = NSColor(white: 0.5, alpha: 0.7)
        for view in [plus, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), plus.centerYAnchor.constraint(equalTo: cell.centerYAnchor), plus.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = "Add a heading to group files"
        return cell
    }
}
