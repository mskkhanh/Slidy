import AppKit

/// Single source for the shortcut list shown by ⌘/. Update it when a shortcut is added or changed.
enum Shortcuts {
    /// Only what is special to Slidy: the shortcuts every Mac app has (⌘C, ⌘Z, ⌘A, ⌘S, Delete, Esc...) are left out.
    static let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("Objects", [
            ("T · H", "Add text · heading"),
            ("F", "Toggle Fade"),
            ("⇧↑ / ⇧↓", "Reorder Fade"),
            ("⌥-click", "Select underneath"),
            ("Wand button", "Auto Fade")
        ]),
        ("Slides", [
            ("⌘↑ / ⌘↓", "Previous / next slide"),
            ("⌘↑ / ⌘↓", "Move slide (list)"),
            ("⌘E", "Recent files")
        ]),
        ("View", [
            ("⌘B", "Hide sidebar"),
            ("⌘0", "Fit slide"),
            ("⌘L", "Night mode")
        ]),
        ("Presenting", [
            ("⌘F · ⌘Enter", "Present"),
            ("⌫ · ⌘↑", "Previous slide"),
            ("⌘↓", "Next slide")
        ])
    ]
}

final class ShortcutsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        // Two columns so the whole list is visible at once.
        func column(_ sections: ArraySlice<(title: String, items: [(keys: String, action: String)])>) -> NSStackView {
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
            for section in sections {
                let header = NSTextField(labelWithString: section.title.uppercased())
                header.font = .systemFont(ofSize: 11, weight: .semibold); header.textColor = .secondaryLabelColor
                if !stack.views.isEmpty { stack.setCustomSpacing(14, after: stack.views.last!) }
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(7, after: header)
                for item in section.items {
                    let keys = NSTextField(labelWithString: item.keys)
                    keys.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
                    keys.widthAnchor.constraint(equalToConstant: 112).isActive = true
                    let action = NSTextField(wrappingLabelWithString: item.action)
                    action.font = .systemFont(ofSize: 12)
                    action.preferredMaxLayoutWidth = 285
                    action.widthAnchor.constraint(lessThanOrEqualToConstant: 285).isActive = true
                    let row = NSStackView(views: [keys, action]); row.alignment = .firstBaseline; row.spacing = 10
                    stack.addArrangedSubview(row)
                }
            }
            return stack
        }
        // Balance the two columns: pick the split whose columns have the most similar number of rows.
        let rows = Shortcuts.sections.map { $0.items.count + 1 }
        var split = 1, bestGap = Int.max
        for candidate in 1..<Shortcuts.sections.count {
            let gap = abs(rows[..<candidate].reduce(0, +) - rows[candidate...].reduce(0, +))
            if gap < bestGap { bestGap = gap; split = candidate }
        }
        let columns = NSStackView(views: [column(Shortcuts.sections[..<split]), column(Shortcuts.sections[split...])])
        columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 36
        let flipped = FlippedView(); flipped.translatesAutoresizingMaskIntoConstraints = false
        columns.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 20),
            columns.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            columns.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -12),
            flipped.widthAnchor.constraint(equalToConstant: 840)
        ])
        let scroll = NSScrollView(); scroll.documentView = flipped; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        let root = NSView()
        for view in [heading, scroll, close] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -10),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        contentView = root
    }
    @objc private func closeSheet() { sheetParent?.endSheet(self) }
    override func cancelOperation(_ sender: Any?) { closeSheet() }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
