import AppKit
import CoreText
import QuartzCore

/// The inline text editor used on the slide: list markers, numbering, bold, and drawing that keeps accents whole.
final class InlineTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    var onTextChange: (() -> Void)?
    private var renumbering = false
    /// Set once ⌘B changed something, so the run styles are written back when editing ends.
    private(set) var boldEdited = false
    private static let boldKey = NSAttributedString.Key("slidyBold")
    private static func isBold(_ font: NSFont?) -> Bool { font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false }
    /// ⌘B: bold on / off for the selected text.
    func toggleBold() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { NSSound.beep(); return }
        var allBold = true
        for index in range.location..<NSMaxRange(range) where !bold(at: index) { allBold = false; break }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont else { return }
            let manager = NSFontManager.shared
            storage.addAttribute(.font, value: allBold ? manager.convert(font, toNotHaveTrait: .boldFontMask) : manager.convert(font, toHaveTrait: .boldFontMask), range: part)
        }
        storage.addAttribute(Self.boldKey, value: !allBold, range: range)
        storage.endEditing()
        boldEdited = true
        needsDisplay = true; onTextChange?()
    }
    private func bold(at index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length else { return false }
        return (storage.attribute(Self.boldKey, at: index, effectiveRange: nil) as? Bool) ?? Self.isBold(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }
    /// A value for every character of every line, list markers left out (same lines as `plainText`).
    private func perCharacter<T>(_ value: (Int) -> T) -> [[T]] {
        var location = 0
        return lines.map { line in
            let length = (line as NSString).length, skip = Self.marker(in: line)?.length ?? 0
            defer { location += length + 1 }
            return (skip..<length).map { value(location + $0) }
        }
    }
    /// Bold on / off for every character of every line.
    var boldFlags: [[Bool]] { perCharacter { bold(at: $0) } }

    // MARK: Links
    /// Set once a link was added or removed, so the links are written back when editing ends.
    private(set) var linkEdited = false
    /// The address linked to the character at `index`, if any.
    func linkAddress(at index: Int) -> String? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.link, at: index, effectiveRange: nil) as? URL)?.absoluteString
    }
    /// Links `range` to `url` (or removes the link when `url` is nil). The text keeps its other formatting.
    func setLink(_ url: URL?, in range: NSRange) {
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, part, _ in
            if let url {   // underlined; the color stays the text's own
                storage.addAttribute(.link, value: url, range: part)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: part)
            } else if attributes[.link] != nil {
                storage.removeAttribute(.link, range: part)
                storage.removeAttribute(.underlineStyle, range: part)
            }
        }
        storage.endEditing()
        linkEdited = true
        needsDisplay = true; onTextChange?()
    }
    /// The address of every character of every line (nil where there is no link).
    var linkAddresses: [[String?]] { perCharacter { linkAddress(at: $0) } }
    /// ⌘V with text selected and a web address on the clipboard links the selection instead of pasting the address.
    /// Only a clear link counts (http(s)://, mailto: or www.); anything else pastes as plain text.
    static func clipboardLink() -> URL? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 2000, !text.contains(where: \.isWhitespace) else { return nil }
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("www.") else { return nil }
        return AppDelegate.linkURL(from: text)
    }
    private func pasteOrLink() {
        let range = selectedRange()
        if range.length > 0, let url = Self.clipboardLink() {
            setLink(url, in: range)
            setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))   // the caret goes after the linked words
        } else { super.pasteAsPlainText(nil) }
    }
    override func paste(_ sender: Any?) { pasteOrLink() }
    override func pasteAsPlainText(_ sender: Any?) { pasteOrLink() }
    /// ⌘-click on a link opens it (a plain click places the caret, as in any editor).
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let address = linkAddress(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))), let url = URL(string: address) {
            NSWorkspace.shared.open(url); return
        }
        super.mouseDown(with: event)
    }
    /// Slidy draws the text itself: NSTextView cuts glyphs at the top of a tight line box, which removed
    /// stacked Vietnamese accents (Ế, Ẫ) in headings. The layout manager draws them whole.
    override func draw(_ dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer else { super.draw(dirtyRect); return }
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: textContainerOrigin)
        manager.drawGlyphs(forGlyphRange: range, at: textContainerOrigin)
    }
    // Accents sit outside their line box, so a partial redraw would leave them stale: always redraw the whole editor.
    override func setNeedsDisplay(_ invalidRect: NSRect) { super.setNeedsDisplay(bounds) }
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) { super.setNeedsDisplay(bounds, avoidAdditionalLayout: flag) }

    /// A paragraph that is a list item starts with its marker and a tab: "•<tab>" or "2.<tab>".
    static func marker(in line: String) -> (length: Int, numbered: Bool)? {
        if line.hasPrefix("•\t") { return (2, false) }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < 4, line.dropFirst(digits.count).hasPrefix(".\t") else { return nil }
        return (digits.count + 2, true)
    }
    private var lines: [String] { string.components(separatedBy: "\n") }
    var bulletRows: Set<Int> { Set(lines.enumerated().compactMap { Self.marker(in: $0.element) != nil ? $0.offset : nil }) }
    var numberedRows: Set<Int> { Set(lines.enumerated().compactMap { Self.marker(in: $0.element)?.numbered == true ? $0.offset : nil }) }
    var plainText: String {
        lines.map { line in Self.marker(in: line).map { String(line.dropFirst($0.length)) } ?? line }.joined(separator: "\n")
    }
    /// The text of the current line before the caret.
    private var linePrefixRange: NSRange {
        let text = string as NSString
        let end = selectedRange().location
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end))
        let start = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        return NSRange(location: start, length: end - start)
    }
    private var currentLineRange: NSRange { (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)) }

    /// Numbered items count 1, 2, 3... within each run of consecutive numbered lines (the first one keeps its number).
    func renumber() {
        guard !renumbering, let storage = textStorage else { return }
        renumbering = true; defer { renumbering = false }
        let selection = selectedRange()
        var expected: Int?
        var shift = 0
        var location = 0
        var edits: [(NSRange, String)] = []
        for line in lines {
            if let marker = Self.marker(in: line), marker.numbered {
                let current = Int(line.prefix(marker.length - 2)) ?? 1
                let number = expected ?? current
                if number != current { edits.append((NSRange(location: location, length: marker.length - 2), String(number))) }
                expected = number + 1
            } else { expected = nil }
            location += (line as NSString).length + 1
        }
        guard !edits.isEmpty else { return }
        for (range, text) in edits.reversed() { storage.replaceCharacters(in: range, with: text) }
        for (range, text) in edits where range.location < selection.location { shift += text.count - range.length }
        setSelectedRange(NSRange(location: max(0, selection.location + shift), length: selection.length))
    }
    override func didChangeText() { super.didChangeText(); renumber(); onTextChange?() }

    override func keyDown(with event: NSEvent) {
        let prefix = (string as NSString).substring(with: linePrefixRange)
        let line = (string as NSString).substring(with: currentLineRange).trimmingCharacters(in: .newlines)
        if event.keyCode == 53 { finish?(false) }
        else if event.keyCode == 36 && event.modifierFlags.contains(.shift) { insertText("\u{2028}", replacementRange: selectedRange()) }
        else if event.keyCode == 36, let marker = Self.marker(in: prefix) {
            if line.count == marker.length && selectedRange().length == 0 {
                // Return on an empty list item leaves the list.
                insertText("", replacementRange: linePrefixRange)
            } else {
                let next = marker.numbered ? "\((Int(prefix.prefix(marker.length - 2)) ?? 0) + 1).\t" : "•\t"
                insertText("\n" + next, replacementRange: selectedRange())
            }
        } else if event.characters == " ", selectedRange().length == 0, prefix == "-" {
            insertText("•\t", replacementRange: linePrefixRange)
        } else if event.characters == " ", selectedRange().length == 0, let number = Self.typedNumber(prefix) {
            // "1" or "1." followed by a space starts a numbered list.
            insertText("\(number).\t", replacementRange: linePrefixRange)
        } else { super.keyDown(with: event) }
    }
    /// "1" or "12." typed alone at the start of a line.
    static func typedNumber(_ prefix: String) -> Int? {
        let digits = prefix.hasSuffix(".") ? String(prefix.dropLast()) : prefix
        guard !digits.isEmpty, digits.count < 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
