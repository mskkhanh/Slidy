import AppKit

final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SlideEditorWindow: NSWindow {
    var onShortcut: ((String) -> Void)?
    var onEscape: (() -> Bool)?
    /// The slide thumbnail list: Return there adds a slide.
    weak var slideList: NSView?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, let onShortcut {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, event.keyCode == 53, !(firstResponder is NSTextView), onEscape?() == true { return }
            if modifiers.isEmpty, [51, 117].contains(event.keyCode), let slideList, firstResponder === slideList {
                if !event.isARepeat { onShortcut("deleteSlide") }
                return
            }
            if modifiers.isEmpty, [36, 76].contains(event.keyCode), let slideList, firstResponder === slideList {
                if !event.isARepeat { onShortcut("newSlide") }
                return
            }
            if modifiers == .command, [125, 126].contains(event.keyCode), !(firstResponder is NSTextView) {
                if !event.isARepeat { onShortcut(event.keyCode == 125 ? "slideNext" : "slidePrevious") }
                return
            }
            if modifiers == .control, [123, 124].contains(event.keyCode) {   // ⌃← hides the sidebar, ⌃→ shows it
                if !event.isARepeat { onShortcut(event.keyCode == 123 ? "sidebarHide" : "sidebarShow") }
                return
            }
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
