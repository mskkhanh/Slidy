import AppKit

/// Fade effects: toggle, tables, grouping, order, and the wand button.
extension AppDelegate {
    func toggleSelectedFade() {
        var tables: [String] = []
        for item in canvas.selection { if let id = item.tableID, !tables.contains(id) { tables.append(id) } }
        if !tables.isEmpty { toggleTableFade(tables); return }
        let selection = canvas.selection.filter(\.canMove)
        guard !busy, !selection.isEmpty else { return }
        // F toggles: if every selected object already has Fade, remove it from all of them; otherwise add Fade.
        setFade(for: selection, enabled: !selection.allSatisfy(\.hasFade))
    }
    /// F on a table: the table (grid and fills) fades in first, then the text of each cell, left to right and top to bottom.
    /// A .pptx table can only be animated as a whole, so each cell's text moves into its own text box over the cell.
    /// F again removes those effects (the text boxes stay).
    func toggleTableFade(_ tables: [String]) {
        guard !busy, let presentation, let slide = canvas.slide, permitTimingEdit() else { return }
        canvas.finishEditing(commit: true)
        checkpoint()
        var reselect: [SlideItem] = []
        for id in tables {
            guard let whole = slide.items.first(where: { $0.isTableFrame && $0.tableID == id }) else { continue }
            if whole.hasFade {
                slide.removeFade(from: whole)
                slide.items.filter { $0.cellTextOf == id }.forEach { slide.removeFade(from: $0) }
            } else {
                presentation.splitCellText(ofTable: id, in: slide)
                let texts = slide.items.filter { $0.cellTextOf == id }.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
                texts.forEach { slide.removeFade(from: $0) }
                slide.applyFade(to: [whole])
                texts.forEach { slide.applyFade(to: [$0]); $0.fadeGroup = UUID().uuidString }   // one step per cell, even for a list
            }
            reselect += slide.items.filter { $0.tableID == id || $0.cellTextOf == id }
        }
        slide.normalizeFadeOrder()
        canvas.rebuild(); canvas.select(reselect)
        didChange()
    }
    func setFade(for selection: [SlideItem], enabled: Bool) {
        guard !busy, !selection.isEmpty, let slide = canvas.slide, permitTimingEdit() else { return }
        checkpoint()
        if enabled { slide.applyFade(to: selection) }
        else { selection.forEach { slide.removeFade(from: $0) } }
        didChange()
    }
    /// Slides the wand button will touch: those where nothing was animated by hand. A list fades by itself as soon as it
    /// exists, so a slide whose only effects are on lists still counts as untouched (otherwise its heading and text
    /// would be left without a Fade). Slides where you gave any other object a Fade are left alone.
    func slidesWithoutEffects(in presentation: Presentation) -> [Slide] {
        presentation.slides.filter { slide in
            let movable = slide.items.filter(\.canMove)
            return !movable.isEmpty && !slide.items.contains { $0.canFade && $0.hasFade && !$0.hasList } && movable.contains { !$0.hasFade }
        }
    }
    /// Gives every movable object of `slides` a Fade, numbered from the top of the slide downwards.
    func applyFade(toTopToBottom slides: [Slide]) {
        for slide in slides {
            let targets = slide.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            guard !targets.isEmpty else { continue }
            slide.items.forEach { $0.order = 0 }
            targets.forEach { slide.removeFade(from: $0) }
            targets.forEach { slide.applyFade(to: [$0]) }
        }
    }
    /// Top-right button. Slides that have no effect yet get a Fade on every object, top to bottom (slides you animated
    /// yourself keep their effects). On every slide, plain text boxes shrink to their text, so each order badge sits
    /// right above its text. A short report says what changed; one ⌘Z undoes all of it.
    @objc func fadeAllSlides() {
        guard let presentation, !busy, showWindow == nil, window.attachedSheet == nil else { return }
        canvas.finishEditing(commit: true)
        let alert = NSAlert()
        // Look first, so a click that changes nothing leaves no undo step behind.
        let needed = !slidesWithoutEffects(in: presentation).isEmpty
            || presentation.slides.contains { slide in slide.items.contains { presentation.trimTextBox($0, dryRun: true) } }
        guard needed else {
            alert.messageText = "Nothing to change"
            alert.informativeText = "Every slide already has effects and every text box already fits its text."
            alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        checkpointAll()
        let result = tidyDeck(presentation)
        refreshAllSlides()
        alert.messageText = "Done"
        alert.informativeText = Self.tidyReport(result)
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Undo")
        if alert.runModal() == .alertSecondButtonReturn { undo.undo() }
    }
    /// The work behind the wand button. Returns what changed.
    func tidyDeck(_ presentation: Presentation) -> (faded: Int, trimmed: Int, trimmedSlides: Int) {
        var trimmed = 0, trimmedSlides = 0
        for slide in presentation.slides {
            let count = slide.items.filter { presentation.trimTextBox($0) }.count
            if count > 0 { trimmed += count; trimmedSlides += 1 }
        }
        let plain = slidesWithoutEffects(in: presentation)
        applyFade(toTopToBottom: plain)
        return (plain.count, trimmed, trimmedSlides)
    }
    static func tidyReport(_ result: (faded: Int, trimmed: Int, trimmedSlides: Int)) -> String {
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : (noun.hasSuffix("x") ? "es" : "s"))" }
        var lines: [String] = []
        lines.append(result.faded > 0 ? "Fade added to \(count(result.faded, "slide"))." : "Fade: no slide without effects.")
        lines.append(result.trimmed > 0 ? "\(count(result.trimmed, "text box")) fitted to their text on \(count(result.trimmedSlides, "slide"))." : "Text boxes: all already fit.")
        lines.append("⌘Z undoes it.")
        return lines.joined(separator: "\n")
    }
    /// ⌘G: groups the selected objects' Fade effects so they play together (one number, one icon), or ungroups them.
    @objc func toggleFadeGroup() {
        guard !busy, canvas.editor == nil, let slide = canvas.slide else { return }
        let selection = canvas.selection.filter(\.canMove)
        let ungroup = !selection.isEmpty && selection.allSatisfy { $0.hasFade && $0.fadeGroup != nil }
        guard ungroup || selection.count >= 2, permitTimingEdit() else { NSSound.beep(); return }
        checkpoint()
        if ungroup {
            selection.forEach { $0.fadeGroup = nil }
        } else {
            let key = UUID().uuidString
            let order = selection.filter(\.hasFade).map(\.order).min() ?? ((slide.items.map(\.order).max() ?? 0) + 1)
            for item in selection {
                if !item.hasFade { item.enableFade(); item.duration = defaultFadeDuration; item.paragraphDurations.removeAll() }
                item.fadeGroup = key; item.order = order
            }
        }
        slide.normalizeFadeOrder(); slide.timingDirty = true
        didChange()
    }
    /// ⇧↑ / ⇧↓ on the slide: move the selected objects' Fade effects one step earlier / later.
    func reorderFade(by delta: Int) {
        guard !busy, let slide = canvas.slide else { return }
        let groups = slide.fadeGroups
        let selectedIDs = Set(canvas.selection.map { ObjectIdentifier($0) })
        let rows = groups.indices.filter { row in groups[row].contains { selectedIDs.contains(ObjectIdentifier($0)) } }
        guard let first = rows.first, let last = rows.last, delta < 0 ? first > 0 : last < groups.count - 1,
              permitTimingEdit() else { return }
        checkpoint()
        for row in (delta < 0 ? rows : rows.reversed()) { slide.moveFadeGroup(from: row, to: delta < 0 ? row - 1 : row + 2) }
        didChange()
    }
    func permitTimingEdit() -> Bool {
        guard let slide = canvas.slide else { return false }
        if slide.originalTiming && !slide.timingDirty && !slide.warnings.isEmpty {
            let alert = NSAlert(); alert.messageText = "Replace this slide’s effects with Fade?"; alert.informativeText = "This slide has effects other than Fade. Slidy’s Fade order will replace them."
            alert.addButton(withTitle: "Use Fade"); alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
}
