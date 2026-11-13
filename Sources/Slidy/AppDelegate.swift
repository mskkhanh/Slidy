import AppKit

/// App entry: owns the window, the open presentation and its state. Behaviour lives in the AppDelegate+*.swift extensions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var window: NSWindow!
    let canvas = CanvasView()
    let table = SidebarTableView()
    let status = NSTextField(labelWithString: "")
    let nightButton = NSButton()
    let playButton = NSButton()
    let fadeAllButton = NSButton()
    let recentsButton = NSButton(), slidesButton = NSButton(), sidebarButton = NSButton(), headingButton = NSButton()
    var toolbarView: NSView?
    let sidebarResizeHandle = SidebarResizeHandle()
    var sidebarRows: [SidebarRow] = []
    /// The left column shows recent files instead of slide thumbnails (⌘E, or when no file is open).
    var showingRecents = false
    /// Left column (thumbnails / recent files) can be hidden with ⌘B; the choice is remembered.
    /// Pasting the same copy again on the same slide shifts each paste a little.
    var lastPasteKey = ""
    var pasteRepeats = 0
    var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebarHidden")
    var sidebarViews: [NSView] = []
    /// Slides the left column in and out: 0 shows it, -(width + divider) parks it just off the left edge.
    var sidebarLeading: NSLayoutConstraint!
    /// The width of the left column; drag its right edge to change it (remembered).
    var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        return saved > 0 ? min(max(CGFloat(saved), AppDelegate.sidebarWidthRange.lowerBound), AppDelegate.sidebarWidthRange.upperBound) : 174
    }()
    static let sidebarWidthRange: ClosedRange<CGFloat> = 150...380
    var sidebarWidthConstraint: NSLayoutConstraint!
    var scrollTop: NSLayoutConstraint!
    let searchField = NSSearchField()
    let slideCountLabel = NSTextField(labelWithString: "")
    /// "3/15" at the bottom left while the sidebar is hidden (full-width editing).
    let slidePositionLabel = NSTextField(labelWithString: "")
    var fadeNumbersItem: NSMenuItem?
    var searchQuery = ""
    /// Set while the list highlights the open file, so highlighting is not mistaken for a click.
    var suppressSelectionOpen = false
    let emptyRecents = NSTextField(wrappingLabelWithString: "No recent files.\nPress ⌘O to open a .pptx.")
    let detail = NSTextField(labelWithString: "")
    let undo = UndoManager()
    var presentation: Presentation?
    var index = 0
    /// True after an autosave failed (for example the file changed outside Slidy); automatic changes pause until a save works.
    var saveFailing = false
    /// A click on a recent file opens it after the double-click interval, unless a double-click (rename) follows.
    var pendingRecentOpen: DispatchWorkItem?
    /// The text field currently renaming a file in the recent list.
    weak var renameField: NSTextField?
    var renamingURL: URL?
    var renamingGroup: String?
    var modified = false {
        didSet { if modified && !oldValue, ProcessInfo.processInfo.environment["SLIDY_TRACE_MODIFIED"] != nil { fputs("MODIFIED set by:\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n", stderr) } }
    }
    var busy = false
    var openRequest = 0
    let windowFrameName = "SlideEditor"
    var savedURL: URL?
    var showWindow: NSWindow?
    var showCanvas: CanvasView?
    var showNumber: SlideNumberLabel?
    var showIndex = 0
    var thumbnailCache = NSCache<NSNumber, NSImage>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }
        thumbnailCache.countLimit = 80
        undo.levelsOfUndo = 100   // each step keeps slide XML: bound it so long sessions do not grow
        Presentation.removeStaleWorkFolders()
        makeMenus()
        let editorWindow = SlideEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window = editorWindow
        editorWindow.slideList = table
        editorWindow.onEscape = { [weak self] in
            guard let self, self.presentation != nil, self.showingRecents else { return false }
            self.toggleRecents(); return true
        }
        editorWindow.onShortcut = { [weak self] key in
            if self?.canvas.isCropping == true { return }   // crop mode owns the keyboard
            switch key {
            case "f": self?.toggleSelectedFade()
            case "t": self?.addText()
            case "h": self?.addHeading()
            case "present": self?.presentSlides()
            case "deleteSlide": if self?.recentsMode == true { NSSound.beep() } else { self?.deleteSelectedSlides() }
            case "newSlide": if self?.recentsMode == true { self?.activateSelectedSidebarRow() } else { self?.insertSlideInDeck(after: self?.index ?? 0) }
            case "slideNext": self?.moveSlide(by: 1)
            case "slidePrevious": self?.moveSlide(by: -1)
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
        table.delegate = self; table.dataSource = self; table.registerForDraggedTypes([AppDelegate.slideRowType, AppDelegate.recentRowType]); table.setDraggingSourceOperationMask(.move, forLocal: true); table.draggingDestinationFeedbackStyle = .sourceList; table.backgroundColor = .black
        table.target = self; table.action = #selector(recentClicked); table.doubleAction = #selector(recentDoubleClicked)
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
        nightButton.setAccessibilityLabel("Night / Light Mode")
        updateNightButton()
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Present")
        playButton.isBordered = false; playButton.target = self; playButton.action = #selector(presentSlides)
        playButton.contentTintColor = .secondaryLabelColor
        playButton.toolTip = "Present (⌘F)"
        playButton.setAccessibilityLabel("Present")
        fadeAllButton.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Fade All Slides")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Fade All Slides")
        fadeAllButton.isBordered = false; fadeAllButton.target = self; fadeAllButton.action = #selector(fadeAllSlides)
        fadeAllButton.contentTintColor = .secondaryLabelColor
        fadeAllButton.toolTip = "Fade slides without effects, fit text boxes (⇧⌘F)"
        fadeAllButton.setAccessibilityLabel("Fade All Slides")
        let toolbar = NSStackView(views: [fadeAllButton, nightButton, playButton])
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarView = toolbar
        for view in [scroll, separator, canvas] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        root.addSubview(toolbar)
        emptyRecents.font = .systemFont(ofSize: 11); emptyRecents.textColor = .tertiaryLabelColor
        emptyRecents.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(emptyRecents)
        NSLayoutConstraint.activate([
            emptyRecents.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14), emptyRecents.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            emptyRecents.topAnchor.constraint(equalTo: root.topAnchor, constant: 66)
        ])
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)
        ])
        let sidebarHeader = NSBox(); sidebarHeader.boxType = .custom; sidebarHeader.borderWidth = 0; sidebarHeader.fillColor = .black
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebarHeader)
        NSLayoutConstraint.activate([sidebarHeader.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), sidebarHeader.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), sidebarHeader.topAnchor.constraint(equalTo: root.topAnchor), sidebarHeader.bottomAnchor.constraint(equalTo: scroll.topAnchor)])
        // Three very small buttons at the top of the sidebar: recent files and slides on the left, hide / show on the right.
        // The last one stays on screen (top left) when the sidebar is collapsed.
        for (button, symbol, label, action) in [(recentsButton, "clock", "Recent files (⌘1)", #selector(showRecentFiles)), (slidesButton, "rectangle.stack", "Slides (⌘2)", #selector(showSlides)), (sidebarButton, "sidebar.left", "Hide / show sidebar (⌘S)", #selector(toggleSidebar)), (headingButton, "folder.badge.plus", "New heading", #selector(addSidebarHeading(_:)))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            button.isBordered = false; button.imagePosition = .imageOnly; button.target = self; button.action = action
            button.contentTintColor = .tertiaryLabelColor; button.toolTip = label; button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(button)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 16), button.heightAnchor.constraint(equalToConstant: 16), button.topAnchor.constraint(equalTo: root.topAnchor, constant: 6)])
        }
        let pinned = sidebarButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8); pinned.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pinned, sidebarButton.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 8),
            recentsButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 10),
            slidesButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 32),
            headingButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 62)
        ])
        sidebarLeading = scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        sidebarWidthConstraint = scroll.widthAnchor.constraint(equalToConstant: sidebarWidth)
        scrollTop = scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)
        installSidebarExtras(in: root, scroll: scroll, separator: separator)
        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            sidebarLeading, scrollTop, scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarWidthConstraint,
            separator.leadingAnchor.constraint(equalTo: scroll.trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1), separator.topAnchor.constraint(equalTo: root.topAnchor), separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: separator.trailingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebarViews = [scroll, separator, sidebarHeader, recentsButton, slidesButton, sidebarResizeHandle]
        setSidebarHidden(sidebarHidden, remember: false, animated: false)
        canvas.showsOrderBadges = UserDefaults.standard.object(forKey: "showFadeNumbers") as? Bool ?? true
        canvas.usesNightMode = true
        canvas.showsEdgeShade = true
        canvas.onMoveLayer = { [weak self] delta in self?.moveLayer(by: delta) }
        canvas.onReorderFade = { [weak self] delta in self?.reorderFade(by: delta) }
        canvas.onOpenFile = { [weak self] in self?.openFile() }
        canvas.onWillEdit = { [weak self] in self?.checkpoint() }
        canvas.onChanged = { [weak self] in self?.didChange() }
        canvas.onDelete = { [weak self] in self?.deleteObject() }
        let context = NSMenu()
        context.addItem(menuItem("Bring Forward", #selector(bringForward)))
        context.addItem(menuItem("Send Backward", #selector(sendBackward)))
        context.addItem(.separator()); context.addItem(menuItem("Delete", #selector(deleteObject)))
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
    var autosaveTimer: Timer?
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowDiscard() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit is immediate. The only time it stops is when edits could not be written to the file.
        guard !flushSave(silent: true) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Can’t save your changes to the file."
        alert.informativeText = "Quitting now loses unsaved changes. Use File > Save a Copy… to keep them."
        alert.addButton(withTitle: "Stay"); alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { presentation?.discardWorkFolder() }
}

@main struct SlidyApp {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--verify") { Verification.run(); return }
        if let at = CommandLine.arguments.firstIndex(of: "--overflow"), CommandLine.arguments.count > at + 1 { Verification.overflow(path: CommandLine.arguments[at + 1]); return }
        if let at = CommandLine.arguments.firstIndex(of: "--shortcuts"), CommandLine.arguments.count > at + 1 { Verification.shortcutsSheet(path: CommandLine.arguments[at + 1]); return }
        if let at = CommandLine.arguments.firstIndex(of: "--snap"), CommandLine.arguments.count > at + 2 { Verification.snap(arguments: Array(CommandLine.arguments[(at + 1)...])); return }
        if let at = CommandLine.arguments.firstIndex(of: "--drive"), CommandLine.arguments.count > at + 3 { Verification.drive(arguments: Array(CommandLine.arguments[(at + 1)...])); return }
        if let at = CommandLine.arguments.firstIndex(of: "--select"), CommandLine.arguments.count > at + 3 { Verification.select(arguments: Array(CommandLine.arguments[(at + 1)...])); return }
        if let at = CommandLine.arguments.firstIndex(of: "--hits"), CommandLine.arguments.count > at + 1 { Verification.hits(path: CommandLine.arguments[at + 1]); return }
        if let at = CommandLine.arguments.firstIndex(of: "--dump"), CommandLine.arguments.count > at + 1 { Verification.dump(path: CommandLine.arguments[at + 1]); return }
        if let at = CommandLine.arguments.firstIndex(of: "--memory"), CommandLine.arguments.count > at + 1 { Verification.memory(path: CommandLine.arguments[at + 1], mode: CommandLine.arguments.count > at + 2 ? CommandLine.arguments[at + 2] : "all"); return }
        #endif
        let application = NSApplication.shared
        let delegate = AppDelegate(); application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
