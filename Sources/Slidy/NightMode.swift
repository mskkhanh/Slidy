import AppKit

/// Display-only night mode: light slide backgrounds and fills render black, dark text and lines render soft off-white.
/// Colors are remapped only while drawing. The slide model and the saved .pptx are never touched.
enum NightMode {
    private static let key = "nightMode"
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let softText = NSColor(white: 0.84, alpha: 1)
    private static func brightness(_ color: NSColor) -> CGFloat? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
    /// Slide background shade: a touch lighter than the pure black editor, so the slide's edge is visible.
    static let slideBlack = NSColor(white: 0.135, alpha: 1)
    /// Slide background and shape fills: light becomes near-black.
    static func surface(_ color: NSColor) -> NSColor {
        guard let value = brightness(color), value > 0.6 else { return color }
        return slideBlack
    }
    /// A light shape fill (a card, a table header) on a slide: a step lighter than the slide's night background,
    /// so the shape stays visible. A fill that matches the slide background stays invisible, as designed.
    static let raised = NSColor(white: 0.23, alpha: 1)
    static func fill(_ color: NSColor, on background: NSColor?) -> NSColor {
        guard let value = brightness(color), value > 0.6 else { return color }
        if let background, let a = color.usingColorSpace(.sRGB), let b = background.usingColorSpace(.sRGB),
           abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.03 { return surface(background) }
        if let background, let other = brightness(background), other <= 0.6 { return color }   // a light shape on a dark slide keeps its color
        return raised
    }
    /// A slide that is already black would melt into the black editor: show it a touch lighter (editing only).
    static func separated(_ color: NSColor) -> NSColor {
        guard let value = brightness(color), value < 0.04 else { return color }
        return slideBlack
    }
    /// Text and lines: dark becomes soft off-white.
    static func ink(_ color: NSColor) -> NSColor {
        guard let value = brightness(color), value < 0.4 else { return color }
        return softText
    }
    static func text(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: softText, range: whole)
        result.enumerateAttribute(.foregroundColor, in: whole) { _, _, _ in }
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            let original = (value as? NSColor) ?? .black
            result.addAttribute(.foregroundColor, value: ink(original), range: range)
        }
        return result
    }
}
