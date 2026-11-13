import AppKit
import UniformTypeIdentifiers

// Menu bar, toolbar buttons and the shortcut sheet.
extension AppDelegate {
    func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    func makeMenus() {
        let menu = NSMenu()
        let app = NSMenu(); app.addItem(withTitle: "Quit Slidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let file = NSMenu(title: "File")
        file.addItem(menuItem("Open…", #selector(openFile), key: "o")); file.addItem(menuItem("Recent Files", #selector(toggleRecents), key: "e")); file.addItem(menuItem("Save a Copy…", #selector(saveCopy)))
        let fileItem = NSMenuItem(); fileItem.submenu = file; menu.addItem(fileItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        edit.addItem(menuItem("Paste", #selector(pasteIntoSlide), key: "v"))
        let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(.separator())
        edit.addItem(menuItem("Group / Ungroup Fade", #selector(toggleFadeGroup), key: "g"))
        edit.addItem(menuItem("Bold", #selector(toggleBold), key: "b"))
        let insert = NSMenu(title: "Insert")
        insert.addItem(menuItem("Text · T", #selector(addText))); insert.addItem(menuItem("Heading · H", #selector(addHeading))); insert.addItem(menuItem("Bullet List", #selector(addList))); insert.addItem(menuItem("Picture…", #selector(addImage))); insert.addItem(menuItem("Link…", #selector(linkOrFilter), key: "k"))
        let insertItem = NSMenuItem(); insertItem.submenu = insert; menu.addItem(insertItem)
        let play = NSMenu(title: "Present"); play.addItem(menuItem("From Current Slide", #selector(presentSlides), key: "f"))
        play.addItem(menuItem("Auto Fade and Trim Text Boxes", #selector(fadeAllSlides)))
        let playItem = NSMenuItem(); playItem.submenu = play; menu.addItem(playItem)
        let view = NSMenu(title: "View")
        view.addItem(menuItem("Recent Files", #selector(showRecentFiles), key: "1"))
        view.addItem(menuItem("Slides", #selector(showSlides), key: "2"))
        view.addItem(menuItem("Filter Files", #selector(focusFilter)))
        view.addItem(menuItem("Collapse All Headings", #selector(collapseAllHeadings)))
        view.addItem(menuItem("Expand All Headings", #selector(expandAllHeadings)))
        view.addItem(.separator())
        view.addItem(menuItem("Night / Light Mode", #selector(toggleNight), key: "l"))
        view.addItem(menuItem("Hide / Show Sidebar", #selector(toggleSidebar), key: "s"))
        view.addItem(menuItem("Fit to Window", #selector(fitZoom), key: "0"))
        let viewItem = NSMenuItem(); viewItem.submenu = view; menu.addItem(viewItem)
        let help = NSMenu(title: "Help")
        help.addItem(menuItem("Keyboard Shortcuts", #selector(toggleShortcuts), key: "/"))
        let helpItem = NSMenuItem(); helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }
    func updateNightButton() {
        let night = NightMode.isOn
        nightButton.image = NSImage(systemSymbolName: night ? "sun.max" : "moon", accessibilityDescription: nil)
        nightButton.contentTintColor = .secondaryLabelColor
        nightButton.toolTip = (night ? "Light mode" : "Night mode") + " (⌘L)"
    }
    /// Display only: slide backgrounds and text colors are remapped while drawing, never saved.
    @objc func toggleNight() {
        canvas.finishEditing(commit: true)
        NightMode.isOn.toggle()
        updateNightButton()
        thumbnailCache.removeAllObjects()
        canvas.rebuild(); canvas.needsDisplay = true
        if presentation != nil, !showingRecents { table.reloadData() }
    }
    @objc func fitZoom() { canvas.resetZoom() }
    @objc func toggleSidebar() { setSidebarHidden(!sidebarHidden) }
    @objc func showRecentFiles() { if presentation != nil, !showingRecents { toggleRecents() } }
    @objc func showSlides() { if presentation != nil, showingRecents { toggleRecents() } }
    /// The small sidebar buttons: the list that is showing is brighter.
    func updateSidebarButtons() {
        recentsButton.contentTintColor = recentsMode ? .labelColor : .tertiaryLabelColor
        slidesButton.contentTintColor = recentsMode ? .tertiaryLabelColor : .labelColor
        headingButton.isHidden = sidebarHidden || !recentsMode   // headings are for the recent files list
        searchField.isHidden = sidebarHidden || !recentsMode      // so is the filter box
        let count = presentation?.slides.count ?? 0
        slideCountLabel.stringValue = count == 1 ? "1 slide" : "\(count) slides"
        slideCountLabel.isHidden = sidebarHidden || recentsMode || count == 0
        slidePositionLabel.stringValue = "\(index + 1)/\(count)"
        slidePositionLabel.isHidden = !sidebarHidden || count == 0
        scrollTop.constant = recentsMode ? 54 : 28
        headingButton.contentTintColor = .tertiaryLabelColor
        sidebarButton.contentTintColor = sidebarHidden ? .secondaryLabelColor : .tertiaryLabelColor
    }
    /// ⌘B: bold on / off for the selected text while editing, or for the whole text of the selected objects.
    @objc func toggleBold() {
        if let editor = canvas.editor { editor.toggleBold(); return }
        guard let presentation, !busy else { return }
        let items = canvas.selection.filter { $0.textBody != nil && !$0.text.isEmpty && !$0.inherited }
        guard !items.isEmpty else { NSSound.beep(); return }
        func bold(_ paragraph: Paragraph) -> [Bool] {
            (0..<paragraph.text.length).map { ((paragraph.text.attribute(.font, at: $0, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) }) ?? false }
        }
        let allBold = items.allSatisfy { $0.paragraphs.allSatisfy { bold($0).allSatisfy { $0 } } }
        checkpoint()
        for item in items { presentation.applyBold(item, flags: item.paragraphs.map { Array(repeating: !allBold, count: $0.text.length) }) }
        canvas.rebuild(); didChange()
    }
    /// ⌘B: the left column slides out to the left (and back in) while the slide area grows and shrinks with it.
    func setSidebarHidden(_ hidden: Bool, remember: Bool = true, animated: Bool = true) {
        sidebarHidden = hidden
        updateSidebarButtons()
        emptyRecents.isHidden = hidden || !(recentsMode && sidebarIsEmpty)
        if remember { UserDefaults.standard.set(hidden, forKey: "sidebarHidden") }
        let target: CGFloat = hidden ? -(sidebarWidth + 1) : 0
        guard animated, window?.isVisible == true else {
            sidebarLeading.constant = target
            sidebarViews.forEach { $0.isHidden = hidden }
            return
        }
        if !hidden { sidebarViews.forEach { $0.isHidden = false } }   // visible before it slides in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebarLeading.animator().constant = target
        }, completionHandler: { [weak self] in
            guard let self, self.sidebarHidden == hidden else { return }
            self.sidebarViews.forEach { $0.isHidden = hidden }   // out of the way (and of focus) once it is off screen
        })
    }
    @objc func toggleShortcuts() {
        if let sheet = window.attachedSheet {
            if sheet is ShortcutsPanel { window.endSheet(sheet) }
            return
        }
        guard showWindow == nil else { return }
        window.beginSheet(ShortcutsPanel()) { _ in }
    }
}
