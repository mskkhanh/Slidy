import AppKit
import UniformTypeIdentifiers

// Menu bar, toolbar buttons and the shortcut sheet.
extension AppDelegate {
    func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    func makeMenus() {
        let menu = NSMenu()
        let app = NSMenu(); app.addItem(withTitle: "Thoát Slidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let file = NSMenu(title: "Tệp")
        file.addItem(menuItem("Mở…", #selector(openFile), key: "o")); file.addItem(menuItem("Bài trình chiếu đã mở", #selector(toggleRecents), key: "e")); file.addItem(menuItem("Lưu bản sao…", #selector(saveCopy), key: "s"))
        let fileItem = NSMenuItem(); fileItem.submenu = file; menu.addItem(fileItem)
        let edit = NSMenu(title: "Sửa")
        edit.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, selector, key) in [("Cắt", "cut:", "x"), ("Sao chép", "copy:", "c"), ("Chọn tất cả", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        edit.addItem(menuItem("Dán", #selector(pasteIntoSlide), key: "v"))
        let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(.separator())
        edit.addItem(menuItem("Nhóm / Tách nhóm Fade", #selector(toggleFadeGroup), key: "g"))
        let insert = NSMenu(title: "Chèn")
        insert.addItem(menuItem("Văn bản · T", #selector(addText))); insert.addItem(menuItem("Tiêu đề · H", #selector(addHeading))); insert.addItem(menuItem("Danh sách bullet", #selector(addList))); insert.addItem(menuItem("Ảnh…", #selector(addImage)))
        let insertItem = NSMenuItem(); insertItem.submenu = insert; menu.addItem(insertItem)
        let play = NSMenu(title: "Trình chiếu"); play.addItem(menuItem("Từ slide hiện tại", #selector(presentSlides), key: "f"))
        play.addItem(menuItem("Áp dụng Fade cho mọi slide…", #selector(fadeAllSlides)))
        let playItem = NSMenuItem(); playItem.submenu = play; menu.addItem(playItem)
        let view = NSMenu(title: "Xem")
        view.addItem(menuItem("Chế độ tối / sáng", #selector(toggleNight), key: "l"))
        view.addItem(menuItem("Ẩn / hiện thanh bên trái", #selector(toggleSidebar), key: "b"))
        view.addItem(menuItem("Vừa khung (bỏ zoom)", #selector(fitZoom), key: "0"))
        let viewItem = NSMenuItem(); viewItem.submenu = view; menu.addItem(viewItem)
        let help = NSMenu(title: "Trợ giúp")
        help.addItem(menuItem("Phím tắt", #selector(toggleShortcuts), key: "/"))
        let helpItem = NSMenuItem(); helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }
    func updateNightButton() {
        let night = NightMode.isOn
        nightButton.image = NSImage(systemSymbolName: night ? "sun.max" : "moon", accessibilityDescription: nil)
        nightButton.contentTintColor = .secondaryLabelColor
        nightButton.toolTip = (night ? "Chế độ sáng" : "Chế độ tối") + " (⌘L): chỉ đổi cách hiển thị, không đổi file"
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
    func setSidebarHidden(_ hidden: Bool, remember: Bool = true) {
        sidebarHidden = hidden
        sidebarViews.forEach { $0.isHidden = hidden }
        canvasLeadingOpen.isActive = !hidden; canvasLeadingClosed.isActive = hidden
        emptyRecents.isHidden = hidden || !(recentsMode && recentSidebarEntries.isEmpty)
        if remember { UserDefaults.standard.set(hidden, forKey: "sidebarHidden") }
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
