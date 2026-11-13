import AppKit

// A small field for a link's address, shown right at the selected text (no dialog).

/// A text field that handles the editing shortcuts itself, so ⌘V ⌘C ⌘X ⌘A ⌘Z work whatever the app's menus do.
final class LinkTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(), let editor = currentEditor() as? NSTextView else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "v": editor.pasteAsPlainText(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        case "z": editor.undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class LinkField: NSView, NSTextFieldDelegate {
    let field = LinkTextField()
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    /// Enter: the text typed (the owner checks it and closes the field when it is a good address).
    var onSubmit: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }

    init(current: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7; layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.97).cgColor
        layer?.borderWidth = 1; layer?.borderColor = NSColor(white: 0.5, alpha: 0.55).cgColor
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 12); field.textColor = .white
        field.placeholderString = "https://…"; field.stringValue = current ?? ""
        field.lineBreakMode = .byTruncatingHead; field.cell?.isScrollable = true; field.maximumNumberOfLines = 1
        field.delegate = self
        addSubview(field)
        remove.isBordered = false; remove.font = .systemFont(ofSize: 11); remove.contentTintColor = NSColor(white: 0.65, alpha: 1)
        remove.target = self; remove.action = #selector(removeClicked)
        remove.toolTip = "Remove the link"
        remove.isHidden = current == nil
        addSubview(remove)
        let removeWidth: CGFloat = current == nil ? 0 : 56
        frame.size = NSSize(width: 250 + removeWidth, height: 26)
        field.frame = NSRect(x: 10, y: 4, width: 250 - 20 + (current == nil ? 0 : 0), height: 18)
        remove.frame = NSRect(x: 250 - 4, y: 3, width: removeWidth, height: 20)
        toolTip = "Enter adds the link, Esc closes"
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked() { onRemove?() }
    /// Marks a bad address: a red outline until the next key.
    func flagInvalid() {
        layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        toolTip = "That is not a web address (try https://plancub.com)"
    }
    func controlTextDidChange(_ notification: Notification) {
        layer?.borderColor = NSColor(white: 0.5, alpha: 0.55).cgColor
        toolTip = "Enter adds the link, Esc closes"
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(field.stringValue); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
}

extension CanvasView {
    /// Shows the field above the right end of the selected text (below it when there is no room above) and focuses it.
    func showLinkField(for editor: InlineTextView, range: NSRange, current: String?, onApply: @escaping (String) -> Bool, onRemove: @escaping () -> Void) {
        hideLinkField(restoreFocus: false)
        let linkField = LinkField(current: current)
        linkField.onSubmit = { [weak self, weak linkField] text in
            if onApply(text) { self?.hideLinkField(restoreFocus: true) } else { linkField?.flagInvalid() }
        }
        linkField.onRemove = { [weak self] in onRemove(); self?.hideLinkField(restoreFocus: true) }
        linkField.onCancel = { [weak self] in self?.hideLinkField(restoreFocus: true) }
        addSubview(linkField)
        self.linkField = linkField; linkFieldRange = range
        // Right end of the selected text, in this view's coordinates.
        var selection = CGRect.zero
        if let manager = editor.layoutManager, let container = editor.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            selection = manager.boundingRect(forGlyphRange: glyphs, in: container)
            selection.origin.x += editor.textContainerOrigin.x; selection.origin.y += editor.textContainerOrigin.y
        }
        let rect = editor.convert(selection, to: self)
        var origin = CGPoint(x: rect.maxX - linkField.frame.width, y: rect.minY - linkField.frame.height - 4)
        origin.x = min(max(4, origin.x), max(4, bounds.width - linkField.frame.width - 4))
        if origin.y < 4 { origin.y = rect.maxY + 4 }
        linkField.setFrameOrigin(origin)
        window?.makeFirstResponder(linkField.field)
        linkField.field.currentEditor()?.selectAll(nil)
    }
    func hideLinkField(restoreFocus: Bool) {
        guard let linkField else { return }
        let range = linkFieldRange
        linkField.removeFromSuperview(); self.linkField = nil
        if restoreFocus, let editor { window?.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0)) }
    }
}
