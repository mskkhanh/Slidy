#if DEBUG
import AppKit
// Headless verification uses the same parser, editor, exporter and renderer as the UI.
enum Verification {
    /// Resident memory of this process, in MB (what Activity Monitor calls Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    /// `--memory input.pptx`: renders every slide, builds thumbnails and saves repeatedly, then reports memory growth.
    static func memory(path: String, mode: String = "all") {
        _ = NSApplication.shared
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("slidy-memory-\(UUID().uuidString).pptx")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: temp)
            defer { try? FileManager.default.removeItem(at: temp); try? FileManager.default.removeItem(at: temp.appendingPathExtension("bak")) }
            let document = try Presentation(url: temp)
            var readings: [String] = []
            for round in 0..<60 {
                autoreleasepool {
                    if mode != "save" {
                        for slide in document.slides {
                            let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 292, height: 164)); view.usesNightMode = true
                            view.display(slide, in: document)
                            if mode != "views" {
                                view.layoutSubtreeIfNeeded()
                                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
                            }
                        }
                    }
                    if mode == "save" || (mode == "all" && round % 6 == 0) { try? document.saveInPlace() }
                }
                CATransaction.flush(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))   // let Core Animation release finished layers, as the app's run loop does
                if round % 10 == 0 { readings.append(String(format: "%.1f", footprintMB())) }
            }
            print("Memory (MB) every 10 rounds of 24 slides + saves: \(readings.joined(separator: " → "))")
        } catch { fputs("Memory test failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    /// `--dump deck.pptx`: lists every object per slide (frame, kind, text) to understand selection problems.
    static func dump(path: String) {
        do {
            let document = try Presentation(url: URL(fileURLWithPath: path))
            for (index, slide) in document.slides.enumerated() {
                print("--- slide \(index + 1) (\(slide.items.count) objects)")
                for (z, item) in slide.items.enumerated() {
                    let f = item.frame
                    print(String(format: "  z%d id=%@ move=%d cell=%d list=%d fade=%d  x%.0f y%.0f w%.0f h%.0f  paras=%d  %@", z, item.id, item.canMove ? 1 : 0, item.isTableCell ? 1 : 0, item.hasList ? 1 : 0, item.hasFade ? 1 : 0, f.minX, f.minY, f.width, f.height, item.paragraphs.count, String(item.text.replacingOccurrences(of: "\n", with: " | ").prefix(40))))
                }
            }
        } catch { fputs("\(error)\n", stderr) }
    }
    /// `--hits deck.pptx`: for every object, which object receives a click at its centre.
    static func hits(path: String) {
        _ = NSApplication.shared
        do {
            let document = try Presentation(url: URL(fileURLWithPath: path))
            let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            var blocked = 0
            for (index, slide) in document.slides.enumerated() {
                canvas.display(slide, in: document); canvas.layoutSubtreeIfNeeded()
                for item in slide.items where item.canMove {
                    let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
                    let point = canvas.surface.convert(centre, to: canvas)
                    let hit = canvas.surface.hitTest(canvas.convert(point, to: canvas.surface.superview))
                    var view = hit
                    while let current = view, !(current is ObjectView) { view = current.superview }
                    let target = (view as? ObjectView)?.item
                    if target !== item { blocked += 1; print("slide \(index + 1): click on \(item.id) (\(item.text.prefix(24))) goes to \(target?.id ?? "background")") }
                }
            }
            print("\(blocked) objects do not receive a click at their centre")
        } catch { fputs("\(error)\n", stderr) }
    }
    /// `--select deck.pptx slide id id id`: clicks the first object, then shift-clicks the others, like a person would.
    static func select(arguments: [String]) {
        _ = NSApplication.shared
        do {
            let document = try Presentation(url: URL(fileURLWithPath: arguments[0]))
            let slide = document.slides[Int(arguments[1])! - 1]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            let canvas = CanvasView(frame: window.contentView!.bounds); canvas.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(canvas); canvas.showsOrderBadges = true
            canvas.display(slide, in: document); canvas.layoutSubtreeIfNeeded()
            for (step, id) in arguments.dropFirst(2).enumerated() {
                guard let item = slide.items.first(where: { $0.id == id }) else { print("no object \(id)"); continue }
                let local = canvas.surface.convert(CGPoint(x: item.frame.midX, y: item.frame.midY), to: nil)
                guard let hit = window.contentView!.hitTest(window.contentView!.convert(local, from: nil)) else { print("\(id): nothing under the click"); continue }
                var view: NSView? = hit
                while let current = view, !(current is ObjectView) { view = current.superview }
                let flags: NSEvent.ModifierFlags = step == 0 ? [] : [.shift]
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: step * 2, clickCount: 1, pressure: 1)!
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: step * 2 + 1, clickCount: 1, pressure: 1)!
                let receiver = (view as? ObjectView)?.item.id ?? "\(type(of: hit))"
                (view ?? hit).mouseDown(with: down); (view ?? hit).mouseUp(with: up)
                print("\(step == 0 ? "click" : "shift-click") \(id): received by \(receiver); selection now \(canvas.selection.map(\.id))")
            }
        } catch { fputs("\(error)\n", stderr) }
    }
    static func overflow(path: String) {
        _ = NSApplication.shared
        guard let document = try? Presentation(url: URL(fileURLWithPath: path)) else { return }
        var count = 0
        for (index, slide) in document.slides.enumerated() {
            for item in slide.items where item.canMove && item.textBody != nil && !item.text.isEmpty {
                let layouts = layoutParagraphs(item)
                guard let last = layouts.last else { continue }
                let drawn = last.origin.y + last.height
                if drawn > item.frame.height + 1 { count += 1; print(String(format: "slide %d id=%@ frame h%.0f, text needs %.0f (+%.0f): %@", index + 1, item.id, item.frame.height, drawn, drawn - item.frame.height, String(item.text.prefix(30)))) }
            }
        }
        print("\(count) text objects draw below their frame")
    }
    /// Every relationship target and every content-type override must point at a part that exists.
    static func packageProblems(in folder: URL) -> [String] {
        var problems: [String] = []
        let root = folder.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return ["cannot read package"] }
        for case let url as URL in walker where url.pathExtension == "rels" {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            let base = ((relative as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for chunk in text.components(separatedBy: "<Relationship ").dropFirst() where !chunk.contains("TargetMode=\"External\"") {
                guard let start = chunk.range(of: "Target=\"") else { continue }
                let target = String(chunk[start.upperBound...].prefix { $0 != "\"" })
                let resolved = Presentation.resolveTarget(target, from: base)
                if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(resolved).path) { problems.append("\(relative) -> missing \(resolved)") }
            }
        }
        let types = (try? String(contentsOf: folder.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)) ?? ""
        for chunk in types.components(separatedBy: "<Override PartName=\"").dropFirst() {
            let part = String(chunk.prefix { $0 != "\"" })
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(part.dropFirst())).path) { problems.append("content type for missing \(part)") }
        }
        return problems
    }
    static func partNames(in folder: URL) -> Set<String> {
        var names = Set<String>()
        let root = folder.resolvingSymlinksInPath()
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { names.insert(String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))) }
        }
        return names
    }
    /// `--snap deck.pptx out.png`: renders slide 2 with a freshly inserted test picture, including layer shadows, to look at it.
    static func snap(arguments: [String]) {
        _ = NSApplication.shared
        do {
            let document = try Presentation(url: URL(fileURLWithPath: arguments[0]))
            let url = URL(fileURLWithPath: arguments[1]).deletingPathExtension().appendingPathExtension("src.png")
            let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
            NSGradient(colors: [NSColor.systemTeal, NSColor.systemIndigo])!.draw(in: NSRect(x: 0, y: 0, width: 400, height: 300), angle: 45)
            NSGraphicsContext.restoreGraphicsState()
            try picture.representation(using: .png, properties: [:])!.write(to: url)
            let slide = document.slides[1]
            let item = try document.addImage(to: slide, url: url)
            let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            canvas.display(slide, in: document); canvas.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["CROPLOOK"] != nil {
                canvas.selected = item; canvas.startCrop(item)
                canvas.cropFrame = CGRect(x: item.frame.minX + 40, y: item.frame.minY + 30, width: item.frame.width - 130, height: item.frame.height - 90)
            }
            if ProcessInfo.processInfo.environment["HEADSNAP"] != nil {   // a heading with stacked Vietnamese accents, shown and edited
                let heading = document.addText(to: slide, list: false, heading: true)
                document.updateText(heading, text: "TIẾP TỤC Ầ Ẩ Ẫ Ệ")
                canvas.rebuild()
                if ProcessInfo.processInfo.environment["HEADSNAP"] == "edit" { canvas.selected = heading; canvas.startEditing(); }
                if ProcessInfo.processInfo.environment["HEADSNAP"] == "list", let list = slide.items.first(where: { $0.canMove && $0.hasList }) {
                    canvas.selected = list; canvas.startEditing(); canvas.editor?.setSelectedRange(NSRange(location: 8, length: 0)); canvas.updateCaret(restartBlink: true)
                }
            }
            canvas.displayIfNeeded()
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[1]))
            print("wrote \(arguments[1]); picture at \(item.frame.integral), corner ratio \(item.cornerRatio), shadow \(String(describing: item.shadow))")
        } catch { fputs("\(error)\n", stderr) }
    }
    /// `--shortcuts out.png`: renders the ⌘/ sheet.
    static func shortcutsSheet(path: String) {
        _ = NSApplication.shared
        let panel = ShortcutsPanel()
        panel.appearance = NSAppearance(named: .aqua)   // dark text so the render is readable on white
        guard let content = panel.contentView else { return }
        panel.orderFront(nil); panel.layoutIfNeeded(); content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(content.bounds.size)")
    }
}

#endif
