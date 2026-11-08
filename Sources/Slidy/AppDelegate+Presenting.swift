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
    func updateShowNumber() {
        guard let presentation else { return }
        showNumber?.stringValue = "\(showIndex + 1)/\(presentation.slides.count)"
    }
    func endShow() { showWindow?.close(); showWindow = nil; showCanvas = nil; showNumber = nil; window.makeKeyAndOrderFront(nil) }
}
