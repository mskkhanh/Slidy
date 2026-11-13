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
        if canvas.linkField != nil { canvas.hideLinkField(restoreFocus: true); return }   // ⌘K again closes it
        if canvas.editor == nil {   // an object is selected: link all of its text
            guard let item = canvas.selected, item.textBody != nil, !item.text.isEmpty else { NSSound.beep(); return }
            canvas.startEditing(selectContents: true)
        }
        guard let editor = canvas.editor else { return }
        let range = editor.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let current = editor.linkAddress(at: range.location)
        canvas.showLinkField(for: editor, range: range, current: current, onApply: { [weak self] text in
            guard let url = Self.linkURL(from: text) else { return false }
            self?.applyLink(url, to: editor, range: range); return true
        }, onRemove: { [weak self] in self?.applyLink(nil, to: editor, range: range) })
    }
    func applyLink(_ url: URL?, to editor: InlineTextView, range: NSRange) {
        editor.setLink(url, in: range)
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }
}
