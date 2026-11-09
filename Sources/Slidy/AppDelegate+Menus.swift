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
        file.addItem(menuItem("Open…", #selector(openFile), key: "o")); file.addItem(menuItem("Recent Files", #selector(toggleRecents), key: "e")); file.addItem(menuItem("Save a Copy…", #selector(saveCopy), key: "s"))
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
        edit.addItem(menuItem("Spread / Tighten List Items", #selector(toggleListSpacing)))
        edit.addItem(menuItem("Loosen Line Spacing", #selector(loosenLineSpacing)))
        edit.addItem(menuItem("Tighten Line Spacing", #selector(tightenLineSpacing)))
        let insert = NSMenu(title: "Insert")
        insert.addItem(menuItem("Text · T", #selector(addText))); insert.addItem(menuItem("Heading · H", #selector(addHeading))); insert.addItem(menuItem("Bullet List", #selector(addList))); insert.addItem(menuItem("Picture…", #selector(addImage)))
        let insertItem = NSMenuItem(); insertItem.submenu = insert; menu.addItem(insertItem)
        let play = NSMenu(title: "Present"); play.addItem(menuItem("From Current Slide", #selector(presentSlides), key: "f"))
        play.addItem(menuItem("Fade Slides Without Effects…", #selector(fadeAllSlides)))
        let playItem = NSMenuItem(); playItem.submenu = play; menu.addItem(playItem)
        let view = NSMenu(title: "Xem")
        view.addItem(menuItem("Night / Light Mode", #selector(toggleNight), key: "l"))
        view.addItem(menuItem("Hide / Show Left Column", #selector(toggleSidebar), key: "b"))
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
    /// ⌘B: the left column slides out to the left (and back in) while the slide area grows and shrinks with it.
    func setSidebarHidden(_ hidden: Bool, remember: Bool = true, animated: Bool = true) {
        sidebarHidden = hidden
        emptyRecents.isHidden = hidden || !(recentsMode && recentSidebarEntries.isEmpty)
        if remember { UserDefaults.standard.set(hidden, forKey: "sidebarHidden") }
        let target: CGFloat = hidden ? -Self.sidebarOffset : 0
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
