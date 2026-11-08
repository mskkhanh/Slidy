import AppKit
import UniformTypeIdentifiers

final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SlideEditorWindow: NSWindow {
    var onShortcut: ((String) -> Void)?
    var onEscape: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, let onShortcut {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, event.keyCode == 53, !(firstResponder is NSTextView), onEscape?() == true { return }
            if modifiers == .command, [36, 76].contains(event.keyCode) {
                if !event.isARepeat { onShortcut("present") }
                return
            }
            if !(firstResponder is NSTextView), modifiers.isSubset(of: .shift),
               let key = event.charactersIgnoringModifiers?.lowercased(), ["f", "t", "h"].contains(key) {
                if !event.isARepeat { onShortcut(key) }
                return
            }
        }
        super.sendEvent(event)
    }
}

private struct RecentPresentation: Codable {
    let path: String
    let slide: Int

    var url: URL { URL(fileURLWithPath: path) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    let canvas = CanvasView()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    private let nightButton = NSButton()
    private let playButton = NSButton()
    private let fadeAllButton = NSButton()
    private var toolbarView: NSView?
    private var recentSidebarEntries: [RecentPresentation] = []
    /// The left column shows recent files instead of slide thumbnails (⌘E, or when no file is open).
    private var showingRecents = false
    private var recentsMode: Bool { presentation == nil || showingRecents }
    let detail = NSTextField(labelWithString: "")
    let undo = UndoManager()
    var presentation: Presentation?
    var index = 0
    var modified = false
    var busy = false
    private var openRequest = 0
    private let recentKey = "recentPresentations"
    private var recentPresentations: [RecentPresentation] {
        get {
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: recentKey),
               let entries = try? JSONDecoder().decode([RecentPresentation].self, from: data) { return entries }
            if let previous = defaults.dictionary(forKey: "lastPresentation"),
               let path = previous["path"] as? String {
                return [RecentPresentation(path: path, slide: previous["slide"] as? Int ?? 0)]
            }
            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: recentKey) }
        }
    }
    private let windowFrameName = "SlideEditor"
    var savedURL: URL?
    var showWindow: NSWindow?
    var showCanvas: CanvasView?
    var showNumber: SlideNumberLabel?
    var showIndex = 0
    var thumbnailCache = NSCache<NSNumber, NSImage>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }
        thumbnailCache.countLimit = 80
        makeMenus()
        let editorWindow = SlideEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window = editorWindow
        editorWindow.onEscape = { [weak self] in
            guard let self, self.presentation != nil, self.showingRecents else { return false }
            self.toggleRecents(); return true
        }
        editorWindow.onShortcut = { [weak self] key in
            switch key {
            case "f": self?.toggleSelectedFade()
            case "t": self?.addText()
            case "h": self?.addHeading()
            case "present": self?.presentSlides()
            default: break
            }
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.title = "Slidy"; window.minSize = NSSize(width: 890, height: 520)
        window.delegate = self; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed; window.center()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = root
        let scroll = NSScrollView()
        let column = NSTableColumn(identifier: .init("slides")); column.width = 174; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.delegate = self; table.dataSource = self; table.backgroundColor = .black
        table.style = .plain
        scroll.drawsBackground = true; scroll.backgroundColor = .black
        scroll.documentView = table
        func divider() -> NSBox {
            let line = NSBox(); line.boxType = .custom; line.borderWidth = 0; line.fillColor = NSColor(white: 0.2, alpha: 1); return line
        }
        let separator = divider()
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.isHidden = true
        nightButton.isBordered = false; nightButton.target = self; nightButton.action = #selector(toggleNight)
        nightButton.setAccessibilityLabel("Chế độ tối / sáng")
        updateNightButton()
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Trình chiếu")
        playButton.isBordered = false; playButton.target = self; playButton.action = #selector(presentSlides)
        playButton.contentTintColor = .secondaryLabelColor
        playButton.toolTip = "Trình chiếu từ slide hiện tại (⌘F)"
        playButton.setAccessibilityLabel("Trình chiếu")
        fadeAllButton.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Fade cho mọi slide")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Fade cho mọi slide")
        fadeAllButton.isBordered = false; fadeAllButton.target = self; fadeAllButton.action = #selector(fadeAllSlides)
        fadeAllButton.contentTintColor = .secondaryLabelColor
        fadeAllButton.toolTip = "Áp dụng Fade cho mọi đối tượng ở tất cả slide, từ trên xuống dưới (⌘Z để hoàn tác)"
        fadeAllButton.setAccessibilityLabel("Fade cho mọi slide")
        let toolbar = NSStackView(views: [fadeAllButton, nightButton, playButton])
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarView = toolbar
        for view in [scroll, separator, canvas] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        root.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)
        ])
        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor), scroll.widthAnchor.constraint(equalToConstant: 174),
            separator.leadingAnchor.constraint(equalTo: scroll.trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1), separator.topAnchor.constraint(equalTo: root.topAnchor), separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: separator.trailingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        canvas.showsOrderBadges = true
        canvas.usesNightMode = true
        canvas.onReorderFade = { [weak self] delta in self?.reorderFade(by: delta) }
        canvas.onOpenFile = { [weak self] in self?.openFile() }
        canvas.onWillEdit = { [weak self] in self?.checkpoint() }
        canvas.onChanged = { [weak self] in self?.didChange() }
        canvas.onDelete = { [weak self] in self?.deleteObject() }
        let context = NSMenu()
        context.addItem(menuItem("Đưa lên trước", #selector(bringForward)))
        context.addItem(menuItem("Đưa ra sau", #selector(sendBackward)))
        context.addItem(.separator()); context.addItem(menuItem("Xóa đối tượng", #selector(deleteObject)))
        canvas.objectMenu = context
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setFrameUsingName(windowFrameName)
        window.setFrameAutosaveName(windowFrameName)
        updateRecentSidebar()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.busy, self.presentation == nil,
                  let previous = self.recentPresentations.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else { return }
            self.openURL(previous.url, restoring: true)
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let filename = filenames.first else { return }
        if window == nil { applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
        openURL(URL(fileURLWithPath: filename)); sender.reply(toOpenOrPrint: .success)
    }
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
        let insert = NSMenu(title: "Chèn")
        insert.addItem(menuItem("Văn bản · T", #selector(addText))); insert.addItem(menuItem("Tiêu đề · H", #selector(addHeading))); insert.addItem(menuItem("Danh sách bullet", #selector(addList))); insert.addItem(menuItem("Ảnh…", #selector(addImage)))
        let insertItem = NSMenuItem(); insertItem.submenu = insert; menu.addItem(insertItem)
        let play = NSMenu(title: "Trình chiếu"); play.addItem(menuItem("Từ slide hiện tại", #selector(presentSlides), key: "f"))
        play.addItem(menuItem("Áp dụng Fade cho mọi slide…", #selector(fadeAllSlides)))
        let playItem = NSMenuItem(); playItem.submenu = play; menu.addItem(playItem)
        let view = NSMenu(title: "Xem")
        view.addItem(menuItem("Chế độ tối / sáng", #selector(toggleNight), key: "l"))
        let viewItem = NSMenuItem(); viewItem.submenu = view; menu.addItem(viewItem)
        let help = NSMenu(title: "Trợ giúp")
        help.addItem(menuItem("Phím tắt", #selector(toggleShortcuts), key: "/"))
        let helpItem = NSMenuItem(); helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }
    private func updateNightButton() {
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
    @objc func toggleShortcuts() {
        if let sheet = window.attachedSheet {
            if sheet is ShortcutsPanel { window.endSheet(sheet) }
            return
        }
        guard showWindow == nil else { return }
        window.beginSheet(ShortcutsPanel()) { _ in }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    private func updateRecentSidebar() {
        recentSidebarEntries = recentPresentations
        table.setAccessibilityLabel("Bài trình chiếu gần đây")
        table.rowHeight = 28; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.reloadData()
        table.deselectAll(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if let presentation, !showingRecents { return presentation.slides.count }
        return recentSidebarEntries.count
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GrayRowView() }
    private static let recentFont = NSFont.systemFont(ofSize: 12)
    private static let recentLabelWidth: CGFloat = 112
    /// Recent files sit close together; a long name takes a second line before it is truncated.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if presentation != nil, !showingRecents { return 106 }
        guard recentSidebarEntries.indices.contains(row) else { return 28 }
        let name = recentSidebarEntries[row].url.deletingPathExtension().lastPathComponent
        let box = (name as NSString).boundingRect(with: NSSize(width: Self.recentLabelWidth, height: 1000),
                                                  options: [.usesLineFragmentOrigin], attributes: [.font: Self.recentFont])
        return box.height > 20 ? 40 : 26
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let presentation, !showingRecents else {
            guard recentSidebarEntries.indices.contains(row) else { return nil }
            let entry = recentSidebarEntries[row]
            let cell = NSTableCellView()
            cell.toolTip = entry.path
            let symbol = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil) ?? NSImage()
            let icon = NSImageView(image: symbol)
            icon.contentTintColor = NSColor(red: 0.50, green: 0.68, blue: 0.96, alpha: 1)
            let label = NSTextField(wrappingLabelWithString: entry.url.deletingPathExtension().lastPathComponent)
            label.font = Self.recentFont
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.preferredMaxLayoutWidth = Self.recentLabelWidth
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Xóa khỏi danh sách") ?? NSImage(), target: self, action: #selector(removeRecent(_:)))
            remove.isBordered = false; remove.contentTintColor = .tertiaryLabelColor; remove.tag = row
            remove.toolTip = "Xóa khỏi danh sách (không xóa file)"
            remove.imageScaling = .scaleProportionallyDown
            for view in [icon, label, remove] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                remove.widthAnchor.constraint(equalToConstant: 18), remove.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 154, height: 106))
        let image = NSImageView(frame: NSRect(x: 8, y: 17, width: 146, height: 82)); image.imageScaling = .scaleProportionallyUpOrDown
        image.image = thumbnail(row); cell.addSubview(image)
        let label = NSTextField(labelWithString: "\(row + 1)/\(presentation.slides.count)"); label.frame = NSRect(x: 8, y: 0, width: 146, height: 15); label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
        cell.addSubview(label); cell.textField = label
        cell.setAccessibilityLabel("Slide \(row + 1). \(presentation.slides[row].title)")
        return cell
    }
    func thumbnail(_ row: Int) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: NSNumber(value: row)) { return cached }
        guard let presentation else { return nil }
        let slide = presentation.slides[row]
        let preview = CanvasView(frame: NSRect(x: 0, y: 0, width: 292, height: 164))
        preview.usesNightMode = true
        preview.display(slide, in: presentation); preview.layoutSubtreeIfNeeded()
        // Render without editor margins and without enabling presentation animation.
        preview.surface.frame = preview.bounds; preview.surface.bounds = CGRect(origin: .zero, size: presentation.size)
        guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return nil }
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        let result = NSImage(size: NSSize(width: 146, height: 82)); result.addRepresentation(bitmap)
        thumbnailCache.setObject(result, forKey: NSNumber(value: row)); return result
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, !busy else { return }
        guard let presentation, !showingRecents else {
            if recentSidebarEntries.indices.contains(table.selectedRow) {
                let url = recentSidebarEntries[table.selectedRow].url
                if presentation != nil, url.standardizedFileURL == (savedURL ?? presentation?.source)?.standardizedFileURL { toggleRecents() }
                else { openURL(url) }
            }
            return
        }
        canvas.finishEditing(commit: true); index = table.selectedRow
        canvas.display(presentation.slides[index], in: presentation)
        updateStatus()
    }
    func updateStatus() {
        guard let presentation else { return }
        let url = savedURL ?? presentation.source
        let path = url.standardizedFileURL.path
        let previous = recentPresentations
        if previous.first?.path != path || previous.first?.slide != index {
            recentPresentations = [RecentPresentation(path: path, slide: index)] +
                Array(previous.filter { $0.path != path }.prefix(19))
        }
        status.stringValue = ""
        status.isHidden = true
        canvas.updateOrderBadges()
        let warnings = presentation.slides[index].warnings
        detail.stringValue = warnings.first ?? (presentation.missingFonts.isEmpty ? "" : "Font thay thế: " + presentation.missingFonts.sorted().joined(separator: ", "))
        detail.toolTip = (warnings + presentation.missingFonts.map { "Thiếu font \($0)" }).joined(separator: "\n")
        window.title = (savedURL ?? presentation.source).deletingPathExtension().lastPathComponent
        window.isDocumentEdited = modified
    }
    /// ⌘E: swaps the thumbnail column for the list of recent files, and back.
    @objc func toggleRecents() {
        guard presentation != nil, !busy, window.attachedSheet == nil, showWindow == nil else { return }
        canvas.finishEditing(commit: true)
        showingRecents.toggle()
        if showingRecents { updateRecentSidebar() }
        else { showSlideList() }
    }
    /// Removes a file from the recent list only. The file itself is never touched.
    @objc private func removeRecent(_ sender: NSButton) {
        guard recentSidebarEntries.indices.contains(sender.tag) else { return }
        let path = recentSidebarEntries[sender.tag].path
        recentPresentations = recentPresentations.filter { $0.path != path }
        updateRecentSidebar()
    }
    private func showSlideList() {
        guard let presentation else { return }
        table.setAccessibilityLabel("Slides")
        table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        _ = presentation
    }
    @objc func openFile() {
        guard !busy, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pptx")!]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.openURL(url) } }
    }
    func allowDiscard() -> Bool { flushSave(); return true }
    func openURL(_ url: URL, restoring: Bool = false) {
        guard allowDiscard() else { return }
        let lastIndex = recentPresentations.first { $0.path == url.standardizedFileURL.path }?.slide ?? 0
        openRequest += 1
        let request = openRequest
        busy = true; status.stringValue = "Đang mở…"; status.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Presentation(url: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openRequest == request else { return }; self.busy = false
                switch result {
                case .success(let document):
                    let position = min(max(0, lastIndex), document.slides.count - 1)
                    self.table.deselectAll(nil)
                    self.table.setAccessibilityLabel("Slides")
                    self.table.rowHeight = 106; self.table.intercellSpacing = NSSize(width: 0, height: 4)
                    self.showingRecents = false
                    self.presentation = document; self.savedURL = nil; self.modified = false; self.index = position
                    self.undo.removeAllActions(); self.thumbnailCache.removeAllObjects()
                    self.table.reloadData()
                    self.table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
                    self.table.scrollRowToVisible(position)
                    self.canvas.display(document.slides[position], in: document)
                    self.updateStatus()
                case .failure(let error):
                    if restoring { self.recentPresentations = self.recentPresentations.filter { $0.path != url.standardizedFileURL.path } }
                    self.showError(error)
                    self.status.isHidden = true
                    if self.presentation == nil { self.updateRecentSidebar() }
                    self.updateStatus()
                }
            }
        }
    }
    func checkpoint() {
        guard let presentation else { return }
        let slideIndex = index, slide = presentation.slides[index]
        let snapshot = slide.document.xmlString
        let timingDirty = slide.timingDirty
        let settings = slide.items.map { ($0.id, $0.fade, $0.duration, $0.order, $0.paragraphDurations, $0.fadeGroup) }
        undo.registerUndo(withTarget: self) { target in
            guard target.presentation === presentation else { return }
            target.canvas.finishEditing(commit: false)
            target.index = slideIndex; target.checkpoint()
            do {
                slide.document = try xml(snapshot); slide.timingDirty = timingDirty
                try presentation.parse(slide)
                for (id, fade, duration, order, paragraphDurations, group) in settings { if let item = slide.items.first(where: { $0.id == id }) { item.fade = fade; item.duration = duration; item.order = order; item.paragraphDurations = paragraphDurations; item.fadeGroup = group } }
                target.table.selectRowIndexes(IndexSet(integer: slideIndex), byExtendingSelection: false)
                target.canvas.display(slide, in: presentation); target.didChange()
            } catch { target.showError(error) }
        }
        undo.setActionName("Sửa slide")
    }
    private var autosaveTimer: Timer?
    /// Saves pending edits into the original file. Called after a short pause, and before opening another file, closing or quitting.
    func flushSave(whileEditing keepEditing: Bool = false) {
        autosaveTimer?.invalidate(); autosaveTimer = nil
        // The timer must never end a text edit the person is typing in; it waits for the edit to finish.
        if keepEditing, canvas.editor != nil {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flushSave(whileEditing: true) }
            return
        }
        canvas.finishEditing(commit: true)
        guard modified, let presentation else { return }
        do { try presentation.saveInPlace(); modified = false; window.isDocumentEdited = false }
        catch { if window.attachedSheet == nil { showError(error) } }
    }
    func didChange() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flushSave(whileEditing: true) }
        modified = true; thumbnailCache.removeObject(forKey: NSNumber(value: index))
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)); updateStatus()
    }
    @objc func addText() { insertText(list: false) }
    @objc func addList() { insertText(list: true) }
    @objc func addHeading() { insertText(list: false, heading: true) }
    func insertText(list: Bool, heading: Bool = false) {
        guard let presentation, !busy else { return }
        canvas.finishEditing(commit: true); checkpoint()
        let item = presentation.addText(to: presentation.slides[index], list: list, heading: heading)
        canvas.selected = item; canvas.rebuild(); didChange(); canvas.startEditing(selectContents: true)
    }
    @objc func addImage() {
        guard let presentation, !busy else { return }; canvas.finishEditing(commit: true)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.insertImage(url, into: presentation) }
            catch { self.showError(error) }
        }
    }
    private func insertImage(_ url: URL, into presentation: Presentation, pasted: Bool = false) throws {
        guard !pasted || permitTimingEdit() else { return }
        checkpoint()
        let item = try presentation.addImage(to: presentation.slides[index], url: url, pasted: pasted)
        canvas.selected = item
        canvas.rebuild()
        window.makeFirstResponder(canvas)
        didChange()
    }
    @objc func pasteIntoSlide() {
        if let editor = canvas.editor, window.firstResponder === editor {
            editor.pasteAsPlainText(nil)
            return
        }
        guard let presentation, !busy, showWindow == nil else { return }
        let clipboard = NSPasteboard.general
        do {
            let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if let url = urls.first(where: { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }) {
                try insertImage(url, into: presentation, pasted: true)
                return
            }
            guard let image = NSImage(pasteboard: clipboard),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url, options: .atomic)
            try insertImage(url, into: presentation, pasted: true)
        } catch { showError(error) }
    }
    func toggleSelectedFade() {
        let selection = canvas.selection.filter(\.canMove)
        guard !busy, !selection.isEmpty else { return }
        setFade(for: selection, enabled: !(selection.count == 1 && selection[0].hasFade))
    }
    private func setFade(for selection: [SlideItem], enabled: Bool) {
        guard !busy, !selection.isEmpty, let slide = canvas.slide, permitTimingEdit() else { return }
        checkpoint()
        if enabled { slide.applyFade(to: selection) }
        else { selection.forEach { slide.removeFade(from: $0) } }
        didChange()
    }
    /// One undo step for a change that touches every slide.
    private func checkpointAll() {
        guard let presentation else { return }
        let saved = presentation.slides.map { slide in
            (slide, slide.document.xmlString, slide.timingDirty, slide.items.map { ($0.id, $0.fade, $0.duration, $0.order, $0.paragraphDurations, $0.fadeGroup) })
        }
        undo.registerUndo(withTarget: self) { target in
            guard target.presentation === presentation else { return }
            target.canvas.finishEditing(commit: false)
            target.checkpointAll()
            do {
                for (slide, snapshot, timingDirty, settings) in saved {
                    slide.document = try xml(snapshot); slide.timingDirty = timingDirty
                    try presentation.parse(slide)
                    for (id, fade, duration, order, paragraphDurations, group) in settings {
                        if let item = slide.items.first(where: { $0.id == id }) { item.fade = fade; item.duration = duration; item.order = order; item.paragraphDurations = paragraphDurations; item.fadeGroup = group }
                    }
                }
                target.refreshAllSlides()
            } catch { target.showError(error) }
        }
        undo.setActionName("Fade cho mọi slide")
    }
    private func refreshAllSlides() {
        guard let presentation else { return }
        thumbnailCache.removeAllObjects()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        canvas.display(presentation.slides[index], in: presentation)
        didChange()
    }
    /// Top-right button: every movable object on every slide gets a Fade, numbered from the top of the slide downwards.
    @objc func fadeAllSlides() {
        guard let presentation, !busy, showWindow == nil, window.attachedSheet == nil else { return }
        canvas.finishEditing(commit: true)
        let alert = NSAlert()
        alert.messageText = "Áp dụng Fade cho tất cả slide?"
        alert.informativeText = "Mọi đối tượng trên \(presentation.slides.count) slide sẽ có hiệu ứng Fade, theo thứ tự từ trên xuống dưới. Thứ tự hiệu ứng hiện có sẽ được thay. Có thể hoàn tác bằng ⌘Z."
        alert.addButton(withTitle: "Áp dụng"); alert.addButton(withTitle: "Hủy")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        checkpointAll()
        for slide in presentation.slides {
            let targets = slide.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            guard !targets.isEmpty else { continue }
            slide.items.forEach { $0.order = 0 }
            targets.forEach { slide.removeFade(from: $0) }
            targets.forEach { slide.applyFade(to: [$0]) }
        }
        refreshAllSlides()
    }
    /// ⌘↑ / ⌘↓ on the slide: move the selected objects' Fade effects one step earlier / later.
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
            let alert = NSAlert(); alert.messageText = "Thay hiệu ứng của slide này bằng Fade?"; alert.informativeText = "Slide có hiệu ứng gốc ngoài phạm vi Fade. Bản sao sẽ dùng thứ tự Fade trong ứng dụng."
            alert.addButton(withTitle: "Dùng Fade"); alert.addButton(withTitle: "Hủy")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
    @objc func bringForward() { reorder(forward: true) }
    @objc func sendBackward() { reorder(forward: false) }
    func reorder(forward: Bool) {
        guard let item = canvas.selected, let slide = canvas.slide, item.canMove, let position = slide.items.firstIndex(where: { $0 === item }) else { return }
        let next = position + (forward ? 1 : -1)
        guard slide.items.indices.contains(next), slide.items[next].canMove else { return }
        checkpoint(); let other = slide.items[next].node; let nodeIndex = other.index
        item.node.detach(); slide.tree.insertChild(item.node, at: forward ? nodeIndex : nodeIndex)
        slide.items.swapAt(position, next); canvas.rebuild(); didChange()
    }
    @objc func deleteObject() {
        guard let item = canvas.selected, let slide = canvas.slide, item.canMove else { return }
        canvas.finishEditing(commit: true); checkpoint(); item.node.detach(); slide.items.removeAll { $0 === item }; slide.timingDirty = true
        canvas.selected = nil; canvas.rebuild(); didChange()
    }
    @objc func saveCopy() {
        guard let presentation, !busy else { return }; canvas.finishEditing(commit: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pptx")!]
        panel.nameFieldStringValue = savedURL?.lastPathComponent ?? presentation.source.deletingPathExtension().lastPathComponent + " — edited.pptx"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try presentation.save(to: url) }
            catch { self.showError(error) }
        }
    }
    @objc func presentSlides() {
        guard let presentation, !busy else { return }; canvas.finishEditing(commit: true)
        if showWindow != nil { return }
        let screen = window.screen ?? NSScreen.main!
        let player = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        player.isReleasedWhenClosed = false; player.backgroundColor = .black
        let playerCanvas = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size)); player.contentView = playerCanvas
        showIndex = index; playerCanvas.display(presentation.slides[index], in: presentation, presenting: true)
        let number = SlideNumberLabel(); number.translatesAutoresizingMaskIntoConstraints = false
        playerCanvas.addSubview(number)
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: playerCanvas.leadingAnchor, constant: 16), number.bottomAnchor.constraint(equalTo: playerCanvas.bottomAnchor, constant: -12)])
        showNumber = number; updateShowNumber()
        playerCanvas.onNavigate = { [weak self] direction in self?.navigateShow(direction) }
        playerCanvas.onExit = { [weak self] in self?.endShow() }
        player.level = .mainMenu + 1; player.collectionBehavior = [.fullScreenAuxiliary]
        showWindow = player; showCanvas = playerCanvas
        player.makeKeyAndOrderFront(nil); player.makeFirstResponder(playerCanvas)
    }
    func navigateShow(_ direction: Int) {
        guard let presentation, presentation.slides.indices.contains(showIndex + direction) else { return }
        showIndex += direction; showCanvas?.display(presentation.slides[showIndex], in: presentation, presenting: true)
        // Coming back to an earlier slide shows it complete, with every effect already revealed.
        if direction < 0 { showCanvas?.revealAll() }
        updateShowNumber()
    }
    private func updateShowNumber() {
        guard let presentation else { return }
        showNumber?.stringValue = "\(showIndex + 1)/\(presentation.slides.count)"
    }
    func endShow() { showWindow?.close(); showWindow = nil; showCanvas = nil; showNumber = nil; window.makeKeyAndOrderFront(nil) }
    func showError(_ error: Error) { let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowDiscard() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { flushSave(); return .terminateNow }
}

@main struct SlidyApp {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--verify") { Verification.run(); return }
        #endif
        let application = NSApplication.shared
        let delegate = AppDelegate(); application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
