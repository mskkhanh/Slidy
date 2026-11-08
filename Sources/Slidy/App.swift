import AppKit
import UniformTypeIdentifiers

final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SlideEditorWindow: NSWindow {
    var onShortcut: ((String) -> Void)?
    weak var fadeSidebar: FadeSidebar?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, let onShortcut {
            if fadeSidebar?.handleRemovalShortcut(event) == true { return }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
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
    let fadeSidebar = FadeSidebar()
    let status = NSTextField(labelWithString: "")
    private let recentButton = NSButton()
    private var recentSidebarEntries: [RecentPresentation] = []
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
    var showIndex = 0
    var thumbnailCache = NSCache<NSNumber, NSImage>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }
        thumbnailCache.countLimit = 80
        makeMenus()
        let editorWindow = SlideEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window = editorWindow
        editorWindow.fadeSidebar = fadeSidebar
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
        window.title = "Slidy"; window.minSize = NSSize(width: 890, height: 520)
        window.delegate = self; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed; window.center()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = root
        let scroll = NSScrollView()
        let column = NSTableColumn(identifier: .init("slides")); column.width = 154
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.delegate = self; table.dataSource = self; table.backgroundColor = .controlBackgroundColor
        table.style = .sourceList
        scroll.documentView = table
        let separator = NSBox(); separator.boxType = .separator
        let rightSeparator = NSBox(); rightSeparator.boxType = .separator
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 10; footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recentButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Bài trình chiếu đã mở")
        recentButton.target = self
        recentButton.action = #selector(showRecentPresentations)
        recentButton.isBordered = false
        recentButton.toolTip = "Bài trình chiếu đã mở (⌘E)"
        recentButton.setAccessibilityLabel("Bài trình chiếu đã mở")
        footer.addArrangedSubview(recentButton)
        status.isHidden = true
        footer.addArrangedSubview(status)
        footer.addArrangedSubview(detail)
        for view in [scroll, separator, canvas, rightSeparator, fadeSidebar, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor), scroll.widthAnchor.constraint(equalToConstant: 174),
            separator.leadingAnchor.constraint(equalTo: scroll.trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1), separator.topAnchor.constraint(equalTo: root.topAnchor), separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: separator.trailingAnchor), canvas.trailingAnchor.constraint(equalTo: rightSeparator.leadingAnchor), canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: footer.topAnchor),
            rightSeparator.widthAnchor.constraint(equalToConstant: 1), rightSeparator.trailingAnchor.constraint(equalTo: fadeSidebar.leadingAnchor),
            rightSeparator.topAnchor.constraint(equalTo: root.topAnchor), rightSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            fadeSidebar.widthAnchor.constraint(equalToConstant: 180), fadeSidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fadeSidebar.topAnchor.constraint(equalTo: root.topAnchor), fadeSidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        canvas.onOpenFile = { [weak self] in self?.openFile() }
        canvas.onWillEdit = { [weak self] in self?.checkpoint() }
        canvas.onChanged = { [weak self] in self?.didChange() }
        canvas.onDelete = { [weak self] in self?.deleteObject() }
        fadeSidebar.onMove = { [weak self] source, destination in self?.moveFadeGroup(from: source, to: destination) }
        fadeSidebar.onRemove = { [weak self] items in self?.setFade(for: items, enabled: false) }
        fadeSidebar.onSelect = { [weak self] items in
            guard let self else { return }
            self.canvas.finishEditing(commit: true)
            self.canvas.select(items)
        }
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
        file.addItem(menuItem("Mở…", #selector(openFile), key: "o")); file.addItem(menuItem("Bài trình chiếu đã mở", #selector(showRecentPresentations), key: "e")); file.addItem(menuItem("Lưu bản sao…", #selector(saveCopy), key: "s"))
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
        let playItem = NSMenuItem(); playItem.submenu = play; menu.addItem(playItem)
        NSApp.mainMenu = menu
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    private func updateRecentSidebar() {
        recentSidebarEntries = recentPresentations
        table.setAccessibilityLabel("Bài trình chiếu gần đây")
        table.rowHeight = 36
        table.reloadData()
        table.deselectAll(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { presentation?.slides.count ?? recentSidebarEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let presentation else {
            let entry = recentSidebarEntries[row]
            let cell = NSTableCellView()
            cell.toolTip = entry.path
            let icon = NSImageView(image: NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage())
            let label = NSTextField(labelWithString: entry.url.deletingPathExtension().lastPathComponent)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            let rowContent = NSStackView(views: [icon, label])
            rowContent.spacing = 7
            rowContent.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(rowContent)
            NSLayoutConstraint.activate([
                rowContent.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                rowContent.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                rowContent.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 13)
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
        guard let presentation else {
            if recentSidebarEntries.indices.contains(table.selectedRow) {
                openURL(recentSidebarEntries[table.selectedRow].url)
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
        fadeSidebar.display(presentation.slides[index].fadeGroups)
        let warnings = presentation.slides[index].warnings
        detail.stringValue = warnings.first ?? (presentation.missingFonts.isEmpty ? "" : "Font thay thế: " + presentation.missingFonts.sorted().joined(separator: ", "))
        detail.toolTip = (warnings + presentation.missingFonts.map { "Thiếu font \($0)" }).joined(separator: "\n")
        window.title = (savedURL ?? presentation.source).deletingPathExtension().lastPathComponent
        window.isDocumentEdited = modified
    }
    @objc private func showRecentPresentations() {
        guard window.attachedSheet == nil, showWindow == nil else { return }
        let menu = NSMenu()
        let entries = recentPresentations
        var shownFolders = Set<URL>()
        for entry in entries {
            let folder = entry.url.deletingLastPathComponent()
            guard shownFolders.insert(folder).inserted else { continue }
            if menu.items.count > 0 { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: folder.lastPathComponent, action: nil, keyEquivalent: "")
            heading.toolTip = folder.path
            menu.addItem(heading)
            for file in entries where file.url.deletingLastPathComponent() == folder {
                let item = menuItem(file.url.deletingPathExtension().lastPathComponent, #selector(openRecentPresentation(_:)))
                item.representedObject = file.url
                item.toolTip = "Slide \(file.slide + 1)"
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(menuItem("Mở bài trình chiếu…", #selector(openFile)))
        menu.popUp(positioning: nil, at: NSPoint(x: recentButton.bounds.minX, y: recentButton.bounds.maxY), in: recentButton)
    }
    @objc private func openRecentPresentation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !busy, url.standardizedFileURL == (savedURL ?? presentation?.source)?.standardizedFileURL { return }
        openURL(url)
    }
    @objc func openFile() {
        guard !busy, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "pptx")!]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.openURL(url) } }
    }
    func allowDiscard() -> Bool {
        canvas.finishEditing(commit: true)
        guard modified else { return true }
        let alert = NSAlert(); alert.messageText = "Bài trình chiếu có thay đổi chưa lưu."; alert.informativeText = "Lưu bản sao trước khi mở file khác hoặc đóng cửa sổ."
        alert.addButton(withTitle: "Quay lại"); alert.addButton(withTitle: "Bỏ thay đổi")
        return alert.runModal() == .alertSecondButtonReturn
    }
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
                    self.table.rowHeight = 106
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
    func didChange() {
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
            editor.paste(nil)
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
    func moveFadeGroup(from source: Int, to destination: Int) {
        guard !busy, let slide = canvas.slide, permitTimingEdit() else { return }
        checkpoint()
        slide.moveFadeGroup(from: source, to: destination)
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
            do { try presentation.save(to: url); self.savedURL = url; self.modified = false; self.updateStatus() }
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
        playerCanvas.onNavigate = { [weak self] direction in self?.navigateShow(direction) }
        playerCanvas.onExit = { [weak self] in self?.endShow() }
        player.level = .mainMenu + 1; player.collectionBehavior = [.fullScreenAuxiliary]
        showWindow = player; showCanvas = playerCanvas
        player.makeKeyAndOrderFront(nil); player.makeFirstResponder(playerCanvas)
    }
    func navigateShow(_ direction: Int) {
        guard let presentation, presentation.slides.indices.contains(showIndex + direction) else { return }
        showIndex += direction; showCanvas?.display(presentation.slides[showIndex], in: presentation, presenting: true)
    }
    func endShow() { showWindow?.close(); showWindow = nil; showCanvas = nil; window.makeKeyAndOrderFront(nil) }
    func showError(_ error: Error) { let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowDiscard() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { allowDiscard() ? .terminateNow : .terminateCancel }
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
