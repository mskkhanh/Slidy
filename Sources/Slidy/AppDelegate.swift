import AppKit

/// App entry: owns the window, the open presentation and its state. Behaviour lives in the AppDelegate+*.swift extensions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    let canvas = CanvasView()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    let nightButton = NSButton()
    let playButton = NSButton()
    let fadeAllButton = NSButton()
    var toolbarView: NSView?
    var recentSidebarEntries: [RecentPresentation] = []
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
    static let sidebarOffset: CGFloat = 175
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
            case "deleteSlide": self?.deleteSlideInDeck(at: self?.index ?? 0)
            case "newSlide": self?.insertSlideInDeck(after: self?.index ?? 0)
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
        table.delegate = self; table.dataSource = self; table.registerForDraggedTypes([AppDelegate.slideRowType]); table.setDraggingSourceOperationMask(.move, forLocal: true); table.draggingDestinationFeedbackStyle = .sourceList; table.backgroundColor = .black
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
        fadeAllButton.toolTip = "Fade slides without effects"
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
            emptyRecents.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14), emptyRecents.widthAnchor.constraint(equalToConstant: 146),
            emptyRecents.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)
        ])
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)
        ])
        sidebarLeading = scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            sidebarLeading, scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor), scroll.widthAnchor.constraint(equalToConstant: 174),
            separator.leadingAnchor.constraint(equalTo: scroll.trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1), separator.topAnchor.constraint(equalTo: root.topAnchor), separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: separator.trailingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebarViews = [scroll, separator]
        setSidebarHidden(sidebarHidden, remember: false, animated: false)
        canvas.showsOrderBadges = true
        canvas.usesNightMode = true
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
