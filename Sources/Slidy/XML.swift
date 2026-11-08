import Foundation
import AppKit

let drawingNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
let presentationNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
let relationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
let packageNS = "http://schemas.openxmlformats.org/package/2006/relationships"
let emu: Double = 12700

extension XMLElement {
    var elements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func child(_ name: String) -> XMLElement? { elements.first { $0.localName == name } }
    func all(_ name: String) -> [XMLElement] { elements.filter { $0.localName == name } }
    func descendant(_ name: String) -> XMLElement? {
        if let direct = child(name) { return direct }
        for element in elements { if let found = element.descendant(name) { return found } }
        return nil
    }
    func descendants(_ name: String) -> [XMLElement] {
        elements.flatMap { ($0.localName == name ? [$0] : []) + $0.descendants(name) }
    }
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    func number(_ name: String, _ fallback: Double = 0) -> Double { Double(attr(name) ?? "") ?? fallback }
    func set(_ name: String, _ value: String) {
        if let a = attribute(forName: name) { a.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
    func ensure(_ name: String) -> XMLElement {
        if let found = child(name.components(separatedBy: ":").last!) { return found }
        let result = XMLElement(name: name); addChild(result); return result
    }
}
func xml(_ text: String) throws -> XMLDocument {
    let doc = try XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    guard doc.dtd == nil else { throw AppError.message("File XML chứa DTD không được hỗ trợ.") }
    return doc
}
func readXML(_ url: URL) throws -> XMLDocument { try xml(String(contentsOf: url, encoding: .utf8)) }
func fragment(_ text: String) -> XMLElement {
    // Internal, constant XML templates only.
    let document = try! xml("<root xmlns:p=\"\(presentationNS)\" xmlns:a=\"\(drawingNS)\" xmlns:r=\"\(relationshipNS)\">\(text)</root>")
    let element = document.rootElement()!.elements[0]; element.detach(); return element
}
func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
extension NSColor {
    convenience init(hex: String) {
        let number = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
