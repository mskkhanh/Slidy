import AppKit

/// Single source for the shortcut list shown by ⌘/. Update it when a shortcut is added or changed.
enum Shortcuts {
    /// Only what is special to Slidy: the shortcuts every Mac app has (⌘C, ⌘Z, ⌘A, ⌘S, Delete, Esc...) are left out.
    static let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("Objects", [
            ("T · H", "Add text · heading"),
            ("⌥⌘↑ / ⌥⌘↓", "Move layer"),
            ("⌥-click", "Select underneath")
        ]),
        ("Fade", [
            ("F", "Toggle Fade"),
            ("⇧↑ / ⇧↓", "Reorder Fade"),
            ("⇧⌘F", "Wand: Fade all, fit boxes"),
            ("⌘H", "Show / hide Fade numbers")
        ]),
        ("Text", [
            ("⌘B", "Bold"),
            ("⌘V", "Paste a link onto text"),
            ("⌘K", "Link · Filter files")
        ]),
        ("Slides", [
            ("⌘↑ / ⌘↓", "Previous / next slide"),
            ("⌘↑ / ⌘↓", "Move slide (list)"),
            ("⌘1 · ⌘E", "Recent files"),
            ("⌘2", "Slides")
        ]),
        ("View", [
            ("⌘S", "Hide / show sidebar"),
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

/// A key combination drawn as a small gray keycap, so it stands apart from the description.
private final class KeyCap: NSView {
    private let label: NSTextField
    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.28).cgColor
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([   // the text is centered, so every keycap can have the same width
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ShortcutsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        func column(_ sections: ArraySlice<(title: String, items: [(keys: String, action: String)])>) -> NSStackView {
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
            for section in sections {
                let header = NSTextField(labelWithString: section.title.uppercased())
                header.font = .systemFont(ofSize: 10.5, weight: .semibold); header.textColor = .secondaryLabelColor
                if !stack.views.isEmpty { stack.setCustomSpacing(14, after: stack.views.last!) }
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(8, after: header)
                for item in section.items {
                    let cap = KeyCap(item.keys)
                    let capSlot = NSView(); capSlot.translatesAutoresizingMaskIntoConstraints = false
                    cap.translatesAutoresizingMaskIntoConstraints = false
                    capSlot.addSubview(cap)
                    NSLayoutConstraint.activate([
                        capSlot.widthAnchor.constraint(equalToConstant: 112),
                        cap.leadingAnchor.constraint(equalTo: capSlot.leadingAnchor), cap.trailingAnchor.constraint(equalTo: capSlot.trailingAnchor), cap.topAnchor.constraint(equalTo: capSlot.topAnchor), cap.bottomAnchor.constraint(equalTo: capSlot.bottomAnchor)
                    ])
                    let action = NSTextField(labelWithString: item.action)
                    action.font = .systemFont(ofSize: 12.5)
                    let row = NSStackView(views: [capSlot, action]); row.alignment = .centerY; row.spacing = 8
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
        columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 32
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        let root = NSView()
        for view in [columns, close] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), columns.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            close.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22)
        ])
        contentView = root
        root.layoutSubtreeIfNeeded()
        // Fit the window to its content: no empty space on the right or below.
        let fit = root.fittingSize
        setContentSize(NSSize(width: fit.width + 4, height: fit.height))
    }
    @objc private func closeSheet() { sheetParent?.endSheet(self) }
    override func cancelOperation(_ sender: Any?) { closeSheet() }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
