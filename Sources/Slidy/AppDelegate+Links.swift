import AppKit

// Adding and removing a link on the selected text.
extension AppDelegate {
    /// A typed address as a URL: "plancub.com" becomes https://plancub.com, "a@b.com" a mailto link; only web and mail links are accepted.
    static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        var address = trimmed
        if !address.contains("://") && !address.lowercased().hasPrefix("mailto:") { address = address.contains("@") ? "mailto:" + address : "https://" + address }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "mailto" { return address.count > 7 ? url : nil }
        guard ["http", "https"].contains(scheme), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }
    /// ⌘K: with text being edited it links the selection; otherwise it jumps to the file filter.
    @objc func linkOrFilter() {
        if canvas.editor != nil || (canvas.selected?.textBody != nil && !recentsMode && !(canvas.selected?.text.isEmpty ?? true) && window.firstResponder === canvas) { addLink() }
        else { focusFilter() }
    }
    @objc func addLink() {
        guard presentation != nil, !busy, window.attachedSheet == nil else { return }
        if canvas.editor == nil {   // an object is selected: link all of its text
            guard let item = canvas.selected, item.textBody != nil, !item.text.isEmpty else { NSSound.beep(); return }
            canvas.startEditing(selectContents: true)
        }
        guard let editor = canvas.editor else { return }
        let range = editor.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let current = editor.linkAddress(at: range.location)
        let alert = NSAlert()
        alert.messageText = current == nil ? "Add Link" : "Edit Link"
        alert.informativeText = "Web address for the selected text."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = "https://"; field.stringValue = current ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: current == nil ? "Add" : "Update")
        alert.addButton(withTitle: "Cancel")
        if current != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        window.makeFirstResponder(editor); editor.setSelectedRange(range)
        switch response {
        case .alertFirstButtonReturn:
            guard let url = Self.linkURL(from: field.stringValue) else {
                let bad = NSAlert(); bad.messageText = "That is not a web address."; bad.informativeText = "Use something like https://plancub.com."
                bad.addButton(withTitle: "OK"); bad.runModal()
                window.makeFirstResponder(editor); editor.setSelectedRange(range); return
            }
            applyLink(url, to: editor, range: range)
        case .alertThirdButtonReturn: applyLink(nil, to: editor, range: range)
        default: break
        }
    }
    func applyLink(_ url: URL?, to editor: InlineTextView, range: NSRange) {
        editor.setLink(url, in: range)
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }
}
