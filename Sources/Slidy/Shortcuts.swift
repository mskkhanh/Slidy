import AppKit

/// Single source for the shortcut list shown by ⌘/. Update it when a shortcut is added or changed.
enum Shortcuts {
    static let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("File", [
            ("⌘O", "Open a presentation"),
            ("⌘E", "Recent files in the left column (Esc or ⌘E to go back)"),
            ("⌘S", "Save a copy (changes autosave to the original file)"),
            ("⌘Q", "Quit")
        ]),
        ("Edit", [
            ("⌘Z / ⇧⌘Z", "Undo / redo"),
            ("⌘C ⌘X ⌘V", "Copy / cut / paste objects, tables, pictures (also onto another slide)"),
            ("⌘A", "Select all objects on the slide"),
            ("⌘G", "Group / ungroup the Fade of the selected objects"),
            ("Delete", "Delete the selected objects (a table goes whole)")
        ]),
        ("Objects", [
            ("Click · ⇧-click", "Select · add or remove from the selection"),
            ("⌥-click", "Select the object underneath (repeat to go deeper)"),
            ("Drag · handle", "Move · resize, with snapping guides (hold ⌘ for none)"),
            ("Double-click picture", "Crop: drag the handles, Return applies, Esc cancels"),
            ("← ↑ ↓ →", "Nudge 1 pt (⇧ for 10 pt)"),
            ("T · H", "Add a text box · a heading"),
            ("F", "Toggle Fade (⌘A then F clears a slide)"),
            ("⇧↑ / ⇧↓", "Move the Fade earlier / later (⌥⌘↑/↓ also work)"),
            ("Wand button", "Fade for slides that have no effect yet (top right)")
        ]),
        ("Text", [
            ("Enter · Esc", "Edit the selected object's text · stop editing"),
            ("⇧Enter", "New line inside a paragraph"),
            ("- + Space", "Start a bullet list"),
            ("1 + Space", "Start a numbered list (Return continues, Return on an empty item ends it)"),
            ("Edit menu", "Spread list items · loosen / tighten line spacing")
        ]),
        ("Slides", [
            ("⌘↑ / ⌘↓", "Previous / next slide while editing"),
            ("Return", "Slide list focused: add a slide after the selected one"),
            ("Delete", "Slide list focused: delete the selected slide"),
            ("⌘↑ / ⌘↓", "Slide list focused: move the selected slide up / down"),
            ("Drag a slide", "Reorder slides in the left column")
        ]),
        ("View", [
            ("⌘B", "Hide / show the left column"),
            ("Pinch", "Zoom around the pointer (two-finger scroll pans)"),
            ("⌘0", "Fit the slide to the window"),
            ("⌘L", "Night / light mode (display only)"),
            ("⌘/", "This list")
        ]),
        ("Presenting", [
            ("⌘F · ⌘Enter", "Present from this slide (Play button, top right)"),
            ("→ ↓ Space Enter", "Next step"),
            ("← ↑", "Previous step"),
            ("⌫ · ⌘↑", "Previous slide, shown complete"),
            ("⌘↓", "Next slide, shown complete"),
            ("Esc", "Exit")
        ])
    ]
}

final class ShortcutsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
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
        let split = 3
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
