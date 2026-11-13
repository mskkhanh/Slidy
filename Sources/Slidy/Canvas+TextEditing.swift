import AppKit
import CoreText
import QuartzCore

/// The inline text editor: building it, its caret, starting and finishing an edit.
extension CanvasView {
    /// Builds the inline editor so its text sits exactly where the rendered text is: same insets, indents,
    /// line height, alignment, vertical anchor and run styles. Bullets are shown as "•<tab>" lines.
    static let editorPad: CGFloat = 16
    func makeEditor(for item: SlideItem) -> InlineTextView {
        let night = nightActive
        // The editor starts `editorPad` above the object: stacked accents (Ế, Ẫ) rise above a tight line box and would be cut off.
        let view = InlineTextView(frame: CGRect(x: item.frame.minX, y: item.frame.minY - Self.editorPad, width: item.frame.width, height: item.frame.height + Self.editorPad))
        view.isRichText = true; view.importsGraphics = false; view.usesFontPanel = false; view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.allowsUndo = true
        var fallbackColor = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil } ?? .labelColor
        var editorBackground = item.fill ?? slide?.background ?? .white
        if night { fallbackColor = NightMode.ink(fallbackColor); editorBackground = NightMode.surface(editorBackground) }
        if usesNightMode, !presenting { editorBackground = NightMode.separated(editorBackground) }
        let fallbackFont = item.paragraphs.first.flatMap { $0.text.length > 0 ? $0.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil } ?? .systemFont(ofSize: 24)
        let content = NSMutableAttributedString()
        var firstAttributes: [NSAttributedString.Key: Any] = [.font: fallbackFont, .foregroundColor: fallbackColor]
        for (index, paragraph) in item.paragraphs.enumerated() {
            let text = night ? NightMode.text(paragraph.text) : paragraph.text
            var attributes: [NSAttributedString.Key: Any] = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [.font: fallbackFont, .foregroundColor: fallbackColor]
            // The first character may be linked; the list marker and the typing style must not inherit the link.
            if attributes[.slidyLink] != nil {
                attributes[.slidyLink] = nil; attributes[.underlineStyle] = nil
            }
            let style = NSMutableParagraphStyle()
            style.alignment = paragraph.alignment
            style.minimumLineHeight = paragraph.spacing; style.maximumLineHeight = paragraph.spacing
            style.paragraphSpacingBefore = index == 0 ? 0 : paragraph.before
            style.paragraphSpacing = paragraph.after
            style.lineBreakMode = .byWordWrapping
            style.headIndent = paragraph.left
            style.firstLineHeadIndent = paragraph.bullet == nil ? paragraph.left : max(0, paragraph.left + paragraph.indent)
            if paragraph.bullet != nil { style.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.left)]; style.defaultTabInterval = 36 }
            attributes[.paragraphStyle] = style
            if index == 0 { firstAttributes = attributes }
            let line = NSMutableAttributedString()
            if let marker = paragraph.bullet { line.append(NSAttributedString(string: marker + "\t", attributes: attributes)) }
            line.append(text)
            if index < item.paragraphs.count - 1 { line.append(NSAttributedString(string: "\n", attributes: attributes)) }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            content.append(line)
        }
        view.textStorage?.setAttributedString(content)
        view.typingAttributes = firstAttributes
        view.drawsBackground = false
        view.backgroundColor = editorBackground
        view.insertionPointColor = (firstAttributes[.foregroundColor] as? NSColor) ?? fallbackColor
        let top = layoutParagraphs(item, night: night).first?.origin.y ?? item.insets.top
        view.textContainerInset = CGSize(width: item.insets.left, height: top + Self.editorPad)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: max(1, item.frame.width - item.insets.left - item.insets.right), height: 100000)
        view.isVerticallyResizable = true; view.maxSize = CGSize(width: item.frame.width, height: 100000)
        return view
    }
    /// While typing in an auto-fit box the editor grows and shrinks with its text (width up to the margin, then more lines).
    func fitEditor() {
        guard let editor, let item = selected, item.autoFit, let presentation, let storage = editor.textStorage,
              let container = editor.textContainer, let manager = editor.layoutManager else { return }
        let maxWidth = presentation.maxAutoFitWidth(for: item)
        let natural = storage.boundingRect(with: CGSize(width: 100000, height: 1000), options: [.usesLineFragmentOrigin]).width
        let width = min(maxWidth, max(60, ceil(natural) + item.insets.left + item.insets.right + 2))
        container.containerSize = CGSize(width: max(1, width - item.insets.left - item.insets.right), height: 100000)
        editor.maxSize = CGSize(width: maxWidth, height: 100000)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + editor.textContainerInset.height + item.insets.bottom
        editor.setFrameSize(NSSize(width: width, height: max(24, ceil(used))))
        updateCaret(restartBlink: false)
    }
    // The text caret is drawn by Slidy (in the overlay above everything) and blinks on its own timer.
    // The system caret did not blink inside the scaled, layered slide view.
    func startCaret(for editor: InlineTextView) {
        overlay.caretColor = editor.insertionPointColor
        editor.insertionPointColor = .clear
        caretObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in
            self?.updateCaret(restartBlink: true)
        }
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.overlay.caret != nil else { return }
            self.hideSystemCaret()
            self.overlay.caretOn.toggle(); self.overlay.needsDisplay = true
        }
        updateCaret(restartBlink: true)
    }
    /// macOS 14+ draws its own insertion indicator inside the text view; keep it hidden so only Slidy's caret shows.
    func hideSystemCaret() {
        func walk(_ view: NSView) {
            for case let indicator as NSTextInsertionIndicator in view.subviews { indicator.displayMode = .hidden }
            view.subviews.forEach(walk)
        }
        if let editor { walk(editor) }
    }
    func stopCaret() {
        caretTimer?.invalidate(); caretTimer = nil
        if let caretObserver { NotificationCenter.default.removeObserver(caretObserver) }
        caretObserver = nil
        overlay.caret = nil; overlay.needsDisplay = true
    }
    /// Where the caret is, in slide coordinates (nil while text is selected).
    var caretRect: CGRect? { overlay.caret }
    func updateCaret(restartBlink: Bool) {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer, let storage = editor.textStorage else { overlay.caret = nil; return }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { overlay.caret = nil; overlay.needsDisplay = true; return }
        manager.ensureLayout(for: container)
        var line = CGRect.zero, x: CGFloat = 0
        let length = storage.length
        if length == 0 || (selection.location >= length && storage.string.hasSuffix("\n")) {
            line = manager.extraLineFragmentRect
            if line == .zero { line = CGRect(x: 0, y: 0, width: 1, height: 24) }
            x = manager.extraLineFragmentUsedRect.minX
        } else if selection.location >= length {
            let glyph = manager.glyphIndexForCharacter(at: length - 1)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
        } else {
            let glyph = manager.glyphIndexForCharacter(at: selection.location)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + manager.location(forGlyphAt: glyph).x
        }
        // The caret hugs the text: it runs from the font's ascent above the baseline to its descent below it,
        // wherever the (taller) line box leaves the extra space.
        let font = (editor.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 24)
        var baseline = line.minY + line.height - font.descender * -1 - (line.height - font.ascender + font.descender) / 2
        if length > 0 {
            let glyph = manager.glyphIndexForCharacter(at: min(max(0, selection.location), length - 1))
            if manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil) == line { baseline = line.minY + manager.location(forGlyphAt: glyph).y }
        } else { baseline = line.minY + line.height + font.descender }
        let height = font.ascender - font.descender
        let origin = editor.textContainerOrigin
        let local = CGRect(x: origin.x + x, y: origin.y + baseline - font.ascender, width: 1.5, height: height)
        overlay.caret = surface.convert(local, from: editor)
        hideSystemCaret()
        if restartBlink { overlay.caretOn = true }
        overlay.needsDisplay = true
    }
    /// `point` (slide coordinates) puts the caret where the person double-clicked instead of at the end.
    func startEditing(selectContents: Bool = false, at point: CGPoint? = nil) {
        guard let item = selected, item.textBody != nil, editor == nil else { return }
        let view = makeEditor(for: item)
        view.finish = { [weak self] commit in self?.finishEditing(commit: commit) }
        if item.autoFit { view.onTextChange = { [weak self] in self?.fitEditor() } }
        surface.addSubview(view); editor = view
        startCaret(for: view)
        updateOrderBadges()   // keep the order badges above the editor
        // The editor is transparent: the object keeps drawing its own fill and outline, only its (replaced) text is hidden,
        // so nothing underneath the box is ever covered.
        objectViews.first { $0.item === item }?.paragraphViews.forEach { $0.isHidden = true }
        updateSelection(); window?.makeFirstResponder(view)
        if !selectContents, let point {
            let inEditor = surface.convert(point, to: view)
            var location = view.characterIndexForInsertion(at: inEditor)
            // Never land inside a list marker ("•<tab>" or "2.<tab>"): put the caret after it.
            let text = view.string as NSString
            let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
            let line = text.substring(with: text.lineRange(for: NSRange(location: lineStart, length: 0))).trimmingCharacters(in: .newlines)
            if let marker = InlineTextView.marker(in: line), location < lineStart + marker.length { location = lineStart + marker.length }
            view.setSelectedRange(NSRange(location: max(0, min(location, text.length)), length: 0))
        }
        if selectContents {
            let start = InlineTextView.marker(in: view.string.components(separatedBy: "\n").first ?? "")?.length ?? 0
            view.setSelectedRange(NSRange(location: start, length: (view.string as NSString).length - start))
        }
    }
    func finishEditing(commit: Bool) {
        guard let editor else { return }
        hideLinkField(restoreFocus: false)
        if commit, let item = selected {
            let existingBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
            let existingNumbered = Set(item.paragraphs.indices.filter { item.paragraphs[$0].isNumbered })
            let bullets = editor.bulletRows, numbered = editor.numberedRows
            let text = editor.plainText
            if text != item.text || bullets != existingBullets || numbered != existingNumbered || editor.boldEdited || editor.linkEdited {
                onWillEdit?()
                presentation?.updateText(item, text: text, bulletRows: bullets, numberedRows: numbered)
                if editor.boldEdited { presentation?.applyBold(item, flags: editor.boldFlags) }
                if editor.linkEdited { presentation?.applyLinks(item, addresses: editor.linkAddresses) }
                if !existingBullets.isEmpty || !bullets.isEmpty { slide?.timingDirty = true }
                onChanged?()
            }
        }
        stopCaret()
        let editedCell = selected?.isTableCell == true ? selected : nil
        editor.removeFromSuperview(); self.editor = nil
        rebuild(); window?.makeFirstResponder(self)
        if let editedCell { select(members(of: editedCell)) }
    }
}
