import AppKit
import UniformTypeIdentifiers

// Full-screen presentation mode.
extension AppDelegate {
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
        showNumber = number; updateShowNumber(); refreshPresentingDot(old: nil)
        playerCanvas.onNavigate = { [weak self] direction in self?.navigateShow(direction) }
        playerCanvas.onJumpSlide = { [weak self] direction in self?.navigateShow(direction, complete: true) }
        playerCanvas.onExit = { [weak self] in self?.endShow() }
        player.level = .mainMenu + 1; player.collectionBehavior = [.fullScreenAuxiliary]
        showWindow = player; showCanvas = playerCanvas
        player.makeKeyAndOrderFront(nil); player.makeFirstResponder(playerCanvas)
    }
    func navigateShow(_ direction: Int, complete: Bool = false) {
        guard let presentation else { return }
        var next = showIndex + direction
        while presentation.slides.indices.contains(next), presentation.slides[next].isHidden { next += direction }   // hidden slides are skipped
        guard presentation.slides.indices.contains(next) else { return }
        let previous = showIndex
        showIndex = next; refreshPresentingDot(old: previous)
        showCanvas?.display(presentation.slides[showIndex], in: presentation, presenting: true)
        // Coming back to an earlier slide, or jumping with ⌘↑/⌘↓, shows it complete with every effect already revealed.
        if direction < 0 || complete { showCanvas?.revealAll() }
        updateShowNumber()
    }
    func updateShowNumber() {
        guard let presentation else { return }
        showNumber?.stringValue = "\(showIndex + 1)/\(presentation.slides.count)"
    }
    func endShow() {
        let last = showIndex
        showWindow?.close(); showWindow = nil; showCanvas = nil; showNumber = nil; window.makeKeyAndOrderFront(nil)
        refreshPresentingDot(old: last)
    }
    /// The small dot beside the slide that is on screen while presenting.
    func refreshPresentingDot(old: Int?) {
        guard presentation != nil, !recentsMode else { return }
        var rows = IndexSet(integer: showIndex)
        if let old { rows.insert(old) }
        rows = rows.filteredIndexSet { $0 < table.numberOfRows }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }
}
