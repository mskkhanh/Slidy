import AppKit

/// Single source for the shortcut list shown by ⌘/. Update it when a shortcut is added or changed.
enum Shortcuts {
    static let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("File", [
            ("⌘O", "Open a presentation"),
            ("⌘E", "Show recent files in the left column (Esc or ⌘E to return to the slides)"),
            ("⌘S", "Save a copy (changes are always autosaved to the original file)"),
            ("⌘Q", "Quit")
        ]),
        ("Edit", [
            ("⌘Z / ⇧⌘Z", "Undo / Redo"),
            ("⌘X  ⌘C  ⌘V", "Cut / Copy / Paste (images too)"),
            ("⌘A", "Select all objects on the slide"),
            ("⌘↑ / ⌘↓", "Go to the previous / next slide while editing")
        ]),
        ("Insert and effects", [
            ("T", "Add a text box"),
            ("H", "Add a heading"),
            ("F", "Toggle Fade: remove it if every selected object has it (e.g. ⌘A then F clears the slide), otherwise add it"),
            ("wand button", "Top right: apply Fade to every object on every slide, top to bottom (⌘Z undoes it)"),
            ("⌘G", "Group / ungroup the Fade of the selected objects: they play together and show one number with a link icon"),
            ("⌥⌘↑ / ⌥⌘↓", "Move the selected objects' Fade effect earlier / later (the order badges update)"),
        ]),
        ("Objects on the slide", [
            ("Click / ⇧-click", "Select an object / add or remove it from the selection (a marquee selects objects it fully encloses)"),
            ("Drag / resize", "Moving or resizing (corner handle) shows alignment guides that snap to other objects and the slide (hold ⌘ to move or resize freely)"),
            ("⌥-click", "Select the object underneath (e.g. a card behind its text); repeat to go deeper"),
            ("Enter", "Edit the text of the selected object"),
            ("⇧Enter", "New line inside a text box"),
            ("Esc", "Stop editing text"),
            ("← ↑ ↓ →", "Nudge the object 1 px (hold ⇧ for 10 px)"),
            ("⌫", "Delete the object")
        ]),
        ("Presenting", [
            ("⌘F hoặc ⌘Enter", "Present from the current slide (also the Play button, top right)"),
            ("→ ↓ Space Enter", "Next step"),
            ("← ↑", "Previous step (or the previous slide, shown complete)"),
            ("delete ⌫", "Back to the previous slide, shown complete with all its elements"),
            ("⌘↓ / ⌘↑", "Jump to the next / previous slide, shown complete with all its elements"),
            ("Esc", "Exit the presentation")
        ]),
        ("View", [
            ("⌘B", "Hide / show the left sidebar"),
            ("Pinch", "Zoom in / out around the pointer (trackpad); two-finger scroll moves the slide while zoomed in"),
            ("⌘0", "Fit the slide to the window (reset zoom)"),
            ("⌘L", "Switch night / light mode (also the moon / sun button, top right; display only, never changes the file)")
        ]),
        ("Help", [
            ("⌘/", "Show / hide this shortcut sheet")
        ])
    ]
}

final class ShortcutsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        for section in Shortcuts.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold); header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(10, after: stack.views.last ?? header)
            for item in section.items {
                let keys = NSTextField(labelWithString: item.keys)
                keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                keys.widthAnchor.constraint(equalToConstant: 140).isActive = true
                let action = NSTextField(wrappingLabelWithString: item.action)
                action.font = .systemFont(ofSize: 12)
                let row = NSStackView(views: [keys, action]); row.alignment = .firstBaseline; row.spacing = 12
                stack.addArrangedSubview(row)
            }
            stack.setCustomSpacing(16, after: stack.views.last ?? header)
        }
        let flipped = FlippedView(); flipped.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -12),
            flipped.widthAnchor.constraint(equalToConstant: 500)
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
