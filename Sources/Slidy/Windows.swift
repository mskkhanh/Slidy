import AppKit

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
