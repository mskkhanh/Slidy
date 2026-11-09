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
    /// `--drive deck.pptx slide id id id`: the real app window and delegate, with real mouse events sent through the window.
    static func drive(arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.openURL(URL(fileURLWithPath: arguments[0]))
        let deadline = Date().addingTimeInterval(10)
        while delegate.presentation == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let presentation = delegate.presentation else { print("deck did not open"); return }
        let slideIndex = Int(arguments[1])! - 1
        delegate.table.selectRowIndexes(IndexSet(integer: slideIndex), byExtendingSelection: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        delegate.window.layoutIfNeeded(); delegate.canvas.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["MOVESLIDE"] != nil {   // slide list focused: ⌘↑ moves the slide, ⌘Z moves it back
            delegate.window.makeFirstResponder(delegate.table)
            let paths = presentation.slides.map(\.path)
            delegate.moveSlide(by: -1)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  moved slide \(slideIndex + 1) up: now at \(delegate.index + 1), order changed: \(presentation.slides.map(\.path) != paths), selected row \(delegate.table.selectedRow + 1), first responder is list: \(delegate.window.firstResponder === delegate.table)")
            delegate.undo.undo()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after undo: order restored: \(presentation.slides.map(\.path) == paths), slide at \(delegate.index + 1)")
            return
        }
        if ProcessInfo.processInfo.environment["CARET"] != nil {   // is the system caret animating while editing?
            NSApp.activate(ignoringOtherApps: true)
            delegate.window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            func report(_ label: String, _ view: NSTextView) {
                var found: [String] = []
                func walk(_ v: NSView, _ depth: Int) {
                    let name = String(describing: type(of: v))
                    if name.contains("Indicator") || name.contains("Insertion") { found.append("\(name) hidden=\(v.isHidden) alpha=\(v.alphaValue) anims=\(v.layer?.animationKeys() ?? []) sublayerAnims=\((v.layer?.sublayers ?? []).flatMap { $0.animationKeys() ?? [] })") }
                    v.subviews.forEach { walk($0, depth + 1) }
                }
                walk(view: view)
                print("  \(label): key=\(view.window?.isKeyWindow == true) active=\(NSApp.isActive) firstResponder=\(view.window?.firstResponder === view) indicators=\(found)")
                func walk(view: NSView) { walk(view, 0) }
            }
            let slide = presentation.slides[slideIndex]
            if let item = slide.items.first(where: { $0.textBody != nil && !$0.text.isEmpty && $0.canMove }) {
                delegate.canvas.selected = item; delegate.canvas.startEditing()
                RunLoop.current.run(until: Date().addingTimeInterval(2.0))
                if let editor = delegate.canvas.editor { report("Slidy editor", editor) }
            }
            // Control: a plain text view in a plain window.
            let controlWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            let control = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120)); control.string = "Control"
            controlWindow.contentView = control; controlWindow.makeKeyAndOrderFront(nil); controlWindow.makeFirstResponder(control)
            control.setSelectedRange(NSRange(location: 7, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            report("plain NSTextView", control)
            return
        }
        if ProcessInfo.processInfo.environment["DELETESLIDE"] != nil {   // slide list focused: Delete removes the slide, ⌘Z brings it back
            delegate.window.makeFirstResponder(delegate.table)
            let count = presentation.slides.count
            let paths = presentation.slides.map(\.path)
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
            delegate.window.sendEvent(key)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  Delete in the slide list: \(count) -> \(presentation.slides.count) slides, now on slide \(delegate.index + 1), removed \(Set(paths).subtracting(presentation.slides.map(\.path)))")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after undo: \(presentation.slides.count) slides, order restored: \(presentation.slides.map(\.path) == paths), on slide \(delegate.index + 1)")
            delegate.undo.redo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after redo: \(presentation.slides.count) slides")
            return
        }
        if ProcessInfo.processInfo.environment["NEWSLIDE"] != nil {   // slide list focused: Return adds a slide, ⌘Z removes it
            delegate.window.makeFirstResponder(delegate.table)
            let count = presentation.slides.count
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            delegate.window.sendEvent(key)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  Return in the slide list: \(count) -> \(presentation.slides.count) slides, now on slide \(delegate.index + 1) (\(presentation.slides[delegate.index].items.map(\.text)))")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after undo: \(presentation.slides.count) slides, on slide \(delegate.index + 1)")
            delegate.undo.redo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after redo: \(presentation.slides.count) slides, on slide \(delegate.index + 1)")
            return
        }
        let slide = presentation.slides[slideIndex]
        for (step, id) in arguments.dropFirst(2).enumerated() {
            guard let item = slide.items.first(where: { $0.id == id }) else { print("no object \(id)"); continue }
            let local = delegate.canvas.surface.convert(CGPoint(x: item.frame.midX, y: item.frame.midY), to: nil)
            let flags: NSEvent.ModifierFlags = step == 0 ? [] : [.shift]
            let number = delegate.window.windowNumber
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: step * 2, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: step * 2 + 1, clickCount: 1, pressure: 1)!
            let probe = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(local, from: nil))
            var chain: [String] = []; var walk: NSView? = probe
            while let view = walk { chain.append(String(describing: type(of: view))); walk = view.superview }
            print("  point \(local) frame \(delegate.window.frame) hit chain: \(chain.joined(separator: " < "))")
            var target: NSView? = probe
            while let current = target, !(current is ObjectView) { target = current.superview }
            (target ?? probe)?.mouseDown(with: down); (target ?? probe)?.mouseUp(with: up)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))   // let autosave and refreshes happen like in real use
            if step == arguments.count - 3, ProcessInfo.processInfo.environment["GROUP_FIRST"] != nil {   // group them, then try again
                delegate.toggleFadeGroup(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                print("  grouped: \(slide.fadeGroups.map { $0.map(\.id) })")
            }
            if step == arguments.count - 3, ProcessInfo.processInfo.environment["DRAG"] != nil {   // drag the selected objects together
                let ids = delegate.canvas.selection.map(\.id)
                let before = delegate.canvas.selection.map(\.frame)
                let from = delegate.canvas.surface.convert(CGPoint(x: item.frame.midX, y: item.frame.midY), to: nil)
                let to = CGPoint(x: from.x + 30, y: from.y - 12)
                let n = delegate.window.windowNumber
                func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 99, clickCount: 1, pressure: 1)! }
                guard let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(from, from: nil)) else { continue }
                var view: NSView? = hit; while let current = view, !(current is ObjectView) { view = current.superview }
                (view as? ObjectView)?.mouseDown(with: event(.leftMouseDown, from)); (view as? ObjectView)?.mouseDragged(with: event(.leftMouseDragged, to)); (view as? ObjectView)?.mouseUp(with: event(.leftMouseUp, to))
                let after = delegate.canvas.selection.map(\.frame)
                print("  dragged \(ids): moved by \(zip(before, after).map { String(format: "(%.0f,%.0f)", $1.minX - $0.minX, $1.minY - $0.minY) }), selection still \(delegate.canvas.selection.map(\.id))")
            }
            if step == arguments.count - 3, let pair = ProcessInfo.processInfo.environment["SNAP"]?.split(separator: ":"), pair.count == 2,   // drag one object near another's edge
               let moving = slide.items.first(where: { $0.id == String(pair[0]) }), let anchor = slide.items.first(where: { $0.id == String(pair[1]) }) {
                let scale = delegate.canvas.surface.frame.width / max(1, delegate.canvas.surface.bounds.width)
                let from = delegate.canvas.surface.convert(CGPoint(x: moving.frame.midX, y: moving.frame.midY), to: nil)
                let wanted = anchor.frame.maxX + 2 - moving.frame.minX   // 2 slide units right of the anchor's right edge
                let to = CGPoint(x: from.x + wanted * scale, y: from.y)
                let n = delegate.window.windowNumber
                func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 77, clickCount: 1, pressure: 1)! }
                delegate.canvas.selected = moving
                if let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(from, from: nil)) {
                    var view: NSView? = hit; while let current = view, !(current is ObjectView) { view = current.superview }
                    (view as? ObjectView)?.mouseDown(with: event(.leftMouseDown, from)); (view as? ObjectView)?.mouseDragged(with: event(.leftMouseDragged, to))
                    print("  snap: object \(moving.id) left edge \(String(format: "%.1f", moving.frame.minX)) vs right edge of \(anchor.id) \(String(format: "%.1f", anchor.frame.maxX)) (guides: \(delegate.canvas.guideCount))")
                    (view as? ObjectView)?.mouseUp(with: event(.leftMouseUp, to))
                }
            }
            if step == arguments.count - 3, let resizeID = ProcessInfo.processInfo.environment["RESIZE"], let sized = slide.items.first(where: { $0.id == resizeID }) {   // drag the bottom-right handle near another edge
                let scale = delegate.canvas.surface.frame.width / max(1, delegate.canvas.surface.bounds.width)
                delegate.canvas.selected = sized
                let corner = delegate.canvas.surface.convert(CGPoint(x: sized.frame.maxX - 1, y: sized.frame.maxY - 1), to: nil)
                let target = ProcessInfo.processInfo.environment["RESIZE_TO"].flatMap { Double($0) }.map { CGFloat($0) } ?? (sized.frame.maxY + 60)
                let to = CGPoint(x: corner.x, y: corner.y - (target - sized.frame.maxY) * scale)
                let n = delegate.window.windowNumber
                func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 78, clickCount: 1, pressure: 1)! }
                if let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(corner, from: nil)) {
                    var view: NSView? = hit; while let current = view, !(current is ObjectView) { view = current.superview }
                    let before = sized.frame
                    print("  corner press lands on object \((view as? ObjectView)?.item.id ?? "none")")
                    (view as? ObjectView)?.mouseDown(with: event(.leftMouseDown, corner)); (view as? ObjectView)?.mouseDragged(with: event(.leftMouseDragged, to))
                    print("  resize: \(resizeID) bottom edge \(String(format: "%.1f", before.maxY)) -> \(String(format: "%.1f", sized.frame.maxY)) (asked for \(String(format: "%.1f", target)), guides \(delegate.canvas.guideCount))")
                    (view as? ObjectView)?.mouseUp(with: event(.leftMouseUp, to))
                }
            }
            print("\(step == 0 ? "click" : "shift-click") \(id): selection now \(delegate.canvas.selection.map(\.id)) (slide \(delegate.index + 1))")
        }
    }
    /// `--overflow deck.pptx`: text whose drawn height is larger than its frame (clicks on the extra lines miss the object).
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
    static func run() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 4 else { throw AppError.message("Usage: --verify input.pptx output-directory") }
            let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let start = Date()
            let document = try Presentation(url: URL(fileURLWithPath: arguments[2]))
            print("Loaded \(document.slides.count) slides in \(Date().timeIntervalSince(start)) s; missing fonts: \(document.missingFonts)")
            _ = NSApplication.shared
            for (index, slide) in document.slides.enumerated() {
                let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
                view.display(slide, in: document); view.layoutSubtreeIfNeeded()
                view.surface.frame = view.bounds; view.surface.bounds = CGRect(origin: .zero, size: document.size)
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("slide-\(index + 1).png"))
                }
            }
            let originalTexts = document.slides.map { $0.items.map(\.text) }
            let untouched = output.appendingPathComponent("unchanged.pptx")
            try document.save(to: untouched)
            let unchanged = try Presentation(url: untouched)
            guard unchanged.slides.map({ $0.items.map(\.text) }) == originalTexts,
                  unchanged.slides.flatMap(\.items).filter(\.isTableCell).count == 26 else {
                throw AppError.message("Unedited text/table preservation failed")
            }
            let node = fragment("<p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr b=\"1\" sz=\"2400\"/><a:t>Xin </a:t></a:r><a:r><a:rPr i=\"1\" sz=\"2400\"/><a:t>chào 😀</a:t></a:r></a:p></p:txBody></p:sp>")
            let mixed = SlideItem(node: node, id: "test", frame: CGRect(x: 0, y: 0, width: 500, height: 200))
            document.configureText(mixed)
            document.updateText(mixed, text: "Xin chào anh 😀")
            guard mixed.text == "Xin chào anh 😀", mixed.textBody?.all("p")[0].all("r").first?.child("rPr")?.attr("b") == "1",
                  mixed.textBody?.all("p")[0].all("r").last?.child("rPr")?.attr("i") == "1" else { throw AppError.message("Mixed style preservation failed") }
            document.updateText(mixed, text: "")
            guard mixed.text == "" else { throw AppError.message("Empty paragraph edit failed") }
            let slide = document.slides[2]
            guard let list = slide.items.first(where: \.hasList) else { throw AppError.message("Sample list missing") }
            document.updateText(list, text: list.text + "\nMục kiểm thử tiếng Việt\u{2028}Dòng tiếp theo trong cùng mục")
            let added = document.addText(to: slide, list: false)
            guard added.fade, added.duration == defaultFadeDuration,
                  abs(added.frame.minX - document.textLeftMargin) < 0.001,
                  document.textLeftMargin < document.size.width * 0.1 else { throw AppError.message("New text defaults failed") }
            document.updateText(added, text: "Một\nHai\nBa", bulletRows: [0, 1, 2])
            guard added.fadesByParagraph else { throw AppError.message("List conversion failed") }
            added.paragraphDurations[1] = 1.0
            added.updateFrame(CGRect(x: 70, y: 300, width: 500, height: 150))
            let fixture = output.appendingPathComponent("image.png")
            let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { rect in NSColor.systemOrange.setFill(); rect.fill(); return true }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: fixture)
            let picture = try document.addImage(to: slide, url: fixture, pasted: true)
            guard picture.hasFade, picture.duration == defaultFadeDuration, slide.timingDirty,
                  picture.frame.minX >= document.size.width / 2, picture.frame.maxX <= document.size.width,
                  picture.frame.minY >= 0, picture.frame.maxY <= document.size.height,
                  abs(picture.frame.width / picture.frame.height - 1.5) < 0.001 else {
                throw AppError.message("Pasted image placement, proportions or fade failed")
            }
            let caption = document.addText(to: slide, list: false)
            slide.applyFade(to: [picture, caption])
            slide.moveFadeGroup(from: slide.fadeGroups.count - 1, to: 0)
            let destination = output.appendingPathComponent("roundtrip.pptx")
            try document.save(to: destination)
            let reopened = try Presentation(url: destination)
            guard reopened.slides.count == document.slides.count, reopened.slides[2].items.contains(where: { $0.text == "Một\nHai\nBa" && $0.fadeDuration(for: 0) == defaultFadeDuration && $0.fadeDuration(for: 1) == 1.0 }), reopened.slides[2].items.contains(where: { $0.imageURL != nil && $0.fade }) else { throw AppError.message("Roundtrip verification failed") }
            let player = CanvasView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
            player.display(reopened.slides[2], in: reopened, presenting: true)
            let expected = reopened.slides[2].fadeSequence.count
            guard player.fadeSteps.count == expected else { throw AppError.message("Bullet step count mismatch") }
            guard let first = player.fadeSteps.first, first.count == 2,
                  first.allSatisfy({ $0.1 == defaultFadeDuration && $0.0.alphaValue == 0 }) else {
                throw AppError.message("Grouped fade duration or order failed")
            }
            player.advance()
            guard player.step == 1, first.allSatisfy({ $0.0.alphaValue == 1 }) else { throw AppError.message("Group did not reveal together") }
            player.back()
            guard first.allSatisfy({ $0.0.alphaValue == 0 }) else { throw AppError.message("Group did not hide together") }
            guard player.step == 0 else { throw AppError.message("Backward step failed") }
            let edited = reopened.slides[2]
            let removed = edited.items.filter { $0.imageURL != nil || $0.text == "Một\nHai\nBa" }
            guard removed.count == 2, removed.allSatisfy(\.hasFade) else { throw AppError.message("Fade removal fixtures missing") }
            removed.forEach { edited.removeFade(from: $0) }
            let disabledURL = output.appendingPathComponent("fade-disabled.pptx")
            try reopened.save(to: disabledURL)
            let disabled = try Presentation(url: disabledURL).slides[2]
            let disabledItems = disabled.items.filter { item in removed.contains { $0.id == item.id } }
            guard disabledItems.count == 2, disabledItems.allSatisfy({ !$0.hasFade && $0.fadeGroup == nil }),
                  disabled.fadeSequence.count == expected - 3 else { throw AppError.message("Fade removal did not survive reopening") }
            for item in disabledItems { disabled.applyFade(to: [item]) }
            guard disabledItems.allSatisfy(\.hasFade), disabled.fadeSequence.count == expected + 1 else {
                throw AppError.message("Fade could not be enabled again")
            }
            // Autosave: edits go back into the original file, and no backup copy is created.
            let work = output.appendingPathComponent("autosave.pptx")
            try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: work.appendingPathExtension("bak"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: work)
            let original = try Data(contentsOf: work)
            let live = try Presentation(url: work)
            let target = live.slides[2]; _ = live.addText(to: target, list: false)
            try live.saveInPlace()
            try live.saveInPlace()
            guard !FileManager.default.fileExists(atPath: work.appendingPathExtension("bak").path), try Data(contentsOf: work) != original,
                  try Presentation(url: work).slides[2].items.count == target.items.count else { throw AppError.message("Autosave failed or left a backup file") }
            // A file changed by another app since it was opened must not be overwritten.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: work.path)
            do { try live.saveInPlace(); throw AppError.message("Outside change was overwritten") }
            catch let error as AppError { if error.localizedDescription == "Outside change was overwritten" { throw error } }
            // Reordering fade groups, and the editing-only order badges.
            let groupsBefore = disabled.fadeGroups.count
            if groupsBefore >= 2 {
                let firstItem = disabled.fadeGroups[0][0]
                disabled.moveFadeGroup(from: 0, to: 2)
                guard disabled.fadeGroups[1].contains(where: { $0 === firstItem }) else { throw AppError.message("Fade reorder failed") }
            }
            let badgeCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
            badgeCanvas.showsOrderBadges = true
            badgeCanvas.display(disabled, in: reopened); badgeCanvas.layoutSubtreeIfNeeded()
            guard badgeCanvas.surface.subviews.filter({ $0 is OrderBadgeView }).count == disabled.fadeGroups.flatMap({ $0 }).count else { throw AppError.message("Badge count mismatch") }
            badgeCanvas.display(disabled, in: reopened, presenting: true)
            guard !badgeCanvas.surface.subviews.contains(where: { $0 is OrderBadgeView }) else { throw AppError.message("Badges visible in presentation") }
            let backPlayer = CanvasView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
            backPlayer.display(reopened.slides[2], in: reopened, presenting: true); backPlayer.revealAll()
            guard backPlayer.step == backPlayer.fadeSteps.count, backPlayer.fadeSteps.flatMap({ $0 }).allSatisfy({ $0.0.alphaValue == 1 }) else { throw AppError.message("Previous slide not shown complete") }
            // The inline editor must put text where the rendered text is.
            var checked = 0, worst: CGFloat = 0, worstWhere = ""
            let probe = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            for (slideIndex, slide) in document.slides.enumerated() {
                probe.display(slide, in: document)
                for item in slide.items where item.textBody != nil && !item.isTableCell && !item.paragraphs.isEmpty && item.paragraphs[0].text.length > 0 {
                    guard let layout = layoutParagraphs(item).first else { continue }
                    let editor = probe.makeEditor(for: item)
                    guard let manager = editor.layoutManager, let container = editor.textContainer else { continue }
                    manager.ensureLayout(for: container)
                    let glyph = item.paragraphs[0].bullet.map { manager.glyphIndexForCharacter(at: $0.count + 1) } ?? 0
                    let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let location = manager.location(forGlyphAt: glyph)
                    let editorX = editor.textContainerOrigin.x + rect.minX + location.x
                    let editorY = editor.textContainerOrigin.y + rect.minY
                    let shownRect = layout.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    let shownX = layout.origin.x + shownRect.minX + layout.manager.location(forGlyphAt: 0).x
                    let shownY = layout.origin.y + shownRect.minY
                    let existingBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
                    let existingNumbered = Set(item.paragraphs.indices.filter { item.paragraphs[$0].isNumbered })
                    guard editor.plainText == item.text, editor.bulletRows == existingBullets, editor.numberedRows == existingNumbered else {
                        throw AppError.message("Opening the editor would change text on slide \(slideIndex + 1): \(item.text.prefix(30))")
                    }
                    let delta = max(abs(editorX - shownX), abs(editorY - shownY))
                    checked += 1
                    if delta > worst { worst = delta; worstWhere = "slide \(slideIndex + 1): editor (\(editorX),\(editorY)) shown (\(shownX),\(shownY))" }
                }
            }
            print("Editor alignment: \(checked) text boxes checked, worst offset \(worst) pt \(worstWhere)")
            guard worst < 2 else { throw AppError.message("Editor text is not aligned with displayed text: \(worstWhere)") }
            // Fade for every object, top to bottom, with clean numbering.
            let sample = document.slides[2]
            let movable = sample.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            sample.items.forEach { $0.order = 0 }
            movable.forEach { sample.removeFade(from: $0) }
            movable.forEach { sample.applyFade(to: [$0]) }
            guard sample.fadeGroups.flatMap({ $0 }).map(ObjectIdentifier.init) == movable.map(ObjectIdentifier.init) else { throw AppError.message("Fade-all order is not top to bottom") }
            // Fade effects must survive autosave, quit and reopening: apply, save in place, then read the file back fresh.
            let persist = output.appendingPathComponent("persist.pptx")
            try? FileManager.default.removeItem(at: persist); try? FileManager.default.removeItem(at: persist.appendingPathExtension("bak"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: persist)
            let fadeDoc = try Presentation(url: persist)
            for slide in fadeDoc.slides {
                let targets = slide.items.filter(\.canMove).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
                guard !targets.isEmpty else { continue }
                slide.items.forEach { $0.order = 0 }
                targets.forEach { slide.removeFade(from: $0) }
                targets.forEach { slide.applyFade(to: [$0]) }
            }
            if fadeDoc.slides[0].items.filter(\.canMove).count >= 3 {   // one grouped effect, one reordered effect
                let first = fadeDoc.slides[0]
                let movable = first.items.filter(\.canMove)
                movable.forEach { first.removeFade(from: $0) }
                first.applyFade(to: [movable[0], movable[1]]); first.applyFade(to: [movable[2]])
                first.moveFadeGroup(from: 1, to: 0)
            }
            try fadeDoc.saveInPlace()
            let fresh = try Presentation(url: persist)
            var timingChecked = 0
            for (index, slide) in fadeDoc.slides.enumerated() {
                let expected = slide.fadeGroups.map { $0.map(\.id) }
                let actual = fresh.slides[index].fadeGroups.map { $0.map(\.id) }
                guard expected == actual else { throw AppError.message("Fade order changed after save on slide \(index + 1): \(expected) vs \(actual)") }
                guard !expected.isEmpty else { continue }
                let document = fresh.slides[index].document
                let targets = ((try? document.nodes(forXPath: "//*[local-name()='spTgt']")) ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: "spid")?.stringValue }
                var sequence: [String] = []
                for id in targets where sequence.last != id { sequence.append(id) }
                var wanted: [String] = []
                for id in expected.flatMap({ $0 }) where wanted.last != id { wanted.append(id) }
                let shapeIDs = Set(((try? document.nodes(forXPath: "//*[local-name()='cNvPr']")) ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue })
                guard sequence == wanted, sequence.allSatisfy(shapeIDs.contains), document.rootElement()?.child("timing") != nil else {
                    throw AppError.message("Timing XML does not match the fade order on slide \(index + 1): \(sequence) vs \(wanted)")
                }
                timingChecked += 1
            }
            // Group / ungroup (⌘G) keeps numbering clean and survives saving.
            let groupSlide = fadeDoc.slides[3]
            let pair = groupSlide.items.filter { $0.canMove && $0.hasFade }
            if pair.count >= 3 {
                let before = groupSlide.fadeGroups.count
                let key = UUID().uuidString
                let order = pair[0].order
                for item in [pair[0], pair[2]] { item.fadeGroup = key; item.order = order }
                groupSlide.normalizeFadeOrder()
                guard groupSlide.fadeGroups.count == before - 1, groupSlide.fadeGroups.contains(where: { $0.count == 2 }) else { throw AppError.message("Grouping did not merge two effects") }
                try fadeDoc.saveInPlace()
                let regrouped = try Presentation(url: persist).slides[3]
                guard regrouped.fadeGroups.map({ $0.map(\.id) }) == groupSlide.fadeGroups.map({ $0.map(\.id) }) else { throw AppError.message("Group did not survive saving") }
                [pair[0], pair[2]].forEach { $0.fadeGroup = nil }
                groupSlide.normalizeFadeOrder()
                guard groupSlide.fadeGroups.count == before, groupSlide.fadeGroups.map(\.count).allSatisfy({ $0 == 1 }) else { throw AppError.message("Ungrouping did not split the effects") }
            }
            // The selection outline must stay above every object, badge and editor.
            let topCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 960, height: 540)); topCanvas.showsOrderBadges = true
            topCanvas.display(reopened.slides[3], in: reopened); topCanvas.layoutSubtreeIfNeeded()
            if let anyItem = reopened.slides[3].items.first(where: { $0.canMove && $0.textBody != nil }) {
                topCanvas.selected = anyItem
                for step in ["selected", "after rebuild", "after badges", "while editing"] {
                    if step == "after rebuild" { topCanvas.rebuild() }
                    if step == "after badges" { topCanvas.updateOrderBadges() }
                    if step == "while editing" { topCanvas.startEditing() }
                    guard topCanvas.surface.subviews.last is SelectionOverlay else { throw AppError.message("Selection is not on top \(step)") }
                }
            }
            // Reordering slides: saved into presentation.xml, content and Fade untouched, and reversible.
            let reorderURL = output.appendingPathComponent("reorder.pptx")
            try? FileManager.default.removeItem(at: reorderURL)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: reorderURL)
            let reordered = try Presentation(url: reorderURL)
            let originalPaths = reordered.slides.map(\.path)
            let structure: (Presentation) -> [[[String]]] = { $0.slides.map { $0.fadeGroups.map { $0.map(\.id) } } }
            let beforeStructure = structure(reordered)
            try reordered.moveSlide(from: 4, to: 1)
            try reordered.saveInPlace()
            let afterMove = try Presentation(url: reorderURL)
            var expectedPaths = originalPaths; expectedPaths.insert(expectedPaths.remove(at: 4), at: 1)
            var expectedStructure = beforeStructure; expectedStructure.insert(expectedStructure.remove(at: 4), at: 1)
            guard afterMove.slides.map(\.path) == expectedPaths, structure(afterMove) == expectedStructure, afterMove.slides.count == originalPaths.count else { throw AppError.message("Slide reorder was not saved correctly") }
            try afterMove.moveSlide(from: 1, to: 4)   // undo
            try afterMove.saveInPlace()
            guard try Presentation(url: reorderURL).slides.map(\.path) == originalPaths else { throw AppError.message("Slide reorder undo did not restore the order") }
            guard AppDelegate.slideDropTarget(source: 3, row: 1) == 1, AppDelegate.slideDropTarget(source: 1, row: 4) == 3,
                  AppDelegate.slideDropTarget(source: 2, row: 2) == nil, AppDelegate.slideDropTarget(source: 2, row: 3) == nil,
                  AppDelegate.slideDropTarget(source: 0, row: 24) == 23 else { throw AppError.message("Slide drop position maths is wrong") }
            // Numbered lists: shown with their numbers in the editor, written as real numbering, renumbered while typing.
            let listDoc = try Presentation(url: URL(fileURLWithPath: arguments[2]))
            let listSlide = listDoc.slides[1]
            let listItem = listDoc.addText(to: listSlide, list: true)
            listDoc.updateText(listItem, text: "Một\nHai\nBa", bulletRows: [0, 1, 2], numberedRows: [0, 1, 2])
            guard listItem.paragraphs.map({ $0.bullet }) == ["1.", "2.", "3."], listItem.paragraphs.allSatisfy(\.isNumbered),
                  listItem.textBody?.all("p").allSatisfy({ $0.child("pPr")?.child("buAutoNum") != nil }) == true else { throw AppError.message("Numbered list was not written as real numbering") }
            let numberEditor = CanvasView(frame: CGRect(x: 0, y: 0, width: 960, height: 540)).makeEditor(for: listItem)
            guard numberEditor.string == "1.\tMột\n2.\tHai\n3.\tBa", numberEditor.numberedRows == [0, 1, 2], numberEditor.plainText == "Một\nHai\nBa" else { throw AppError.message("Editor does not show the numbers: \(numberEditor.string.debugDescription)") }
            numberEditor.string = "1.\tA\n1.\tB\n•\tC\n1.\tD\n1.\tE"; numberEditor.renumber()
            guard numberEditor.string == "1.\tA\n2.\tB\n•\tC\n1.\tD\n2.\tE" else { throw AppError.message("Renumbering is wrong: \(numberEditor.string.debugDescription)") }
            guard InlineTextView.typedNumber("1") == 1, InlineTextView.typedNumber("3.") == 3, InlineTextView.typedNumber("a") == nil, InlineTextView.typedNumber("") == nil, InlineTextView.typedNumber("1234") == nil else { throw AppError.message("Typed number detection is wrong") }
            // Typing: "1" + Space starts the list, Return continues it, Return on an empty item leaves it.
            let typing = InlineTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            func key(_ code: UInt16, _ characters: String) { typing.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!) }
            typing.insertText("1", replacementRange: typing.selectedRange()); key(49, " ")
            guard typing.string == "1.\t" else { throw AppError.message("1 + Space did not start a numbered list: \(typing.string.debugDescription)") }
            typing.insertText("A", replacementRange: typing.selectedRange()); key(36, "\r")
            guard typing.string == "1.\tA\n2.\t" else { throw AppError.message("Return did not continue the numbering: \(typing.string.debugDescription)") }
            key(36, "\r")
            guard typing.string == "1.\tA\n" else { throw AppError.message("Return on an empty item did not leave the list: \(typing.string.debugDescription)") }
            // A new slide: heading and body styled like the deck, a valid package, other slides untouched, undo removes it all.
            let newURL = output.appendingPathComponent("newslide.pptx")
            try? FileManager.default.removeItem(at: newURL)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: newURL)
            let withNew = try Presentation(url: newURL)
            let existingStructure = withNew.slides.map { $0.fadeGroups.map { $0.map(\.id) } }
            let reference = withNew.slides[1]
            let created = try withNew.insertSlide(after: 1)
            try withNew.saveInPlace()
            let reloaded = try Presentation(url: newURL)
            guard reloaded.slides.count == existingStructure.count + 1, reloaded.slides[2].items.count == 2 else { throw AppError.message("New slide has the wrong shape") }
            let newTexts = reloaded.slides[2].items.map(\.text)
            guard newTexts == ["Tiêu đề", "Nội dung"] || newTexts == ["Nội dung", "Tiêu đề"] else { throw AppError.message("New slide text is wrong: \(newTexts)") }
            func look(_ item: SlideItem) -> String {
                let font = item.paragraphs.first?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let colour = (item.paragraphs.first?.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hex ?? "-"
                return "\(font?.fontName ?? "-") \(font?.pointSize ?? 0) \(colour) \(Int(item.frame.minX.rounded())),\(Int(item.frame.minY.rounded()))"
            }
            for newItem in reloaded.slides[2].items {
                guard let source = reference.items.first(where: { $0.id == newItem.id }), look(newItem) == look(source) else { throw AppError.message("New slide item \(newItem.id) does not look like the deck's: \(look(newItem))") }
            }
            guard reloaded.slides[2].background.hex == reference.background.hex else { throw AppError.message("New slide background differs") }
            var expectedWithNew = existingStructure; expectedWithNew.insert([], at: 2)
            guard reloaded.slides.map({ $0.fadeGroups.map { $0.map(\.id) } }) == expectedWithNew else { throw AppError.message("Adding a slide changed other slides' Fade") }
            // Package consistency: every relationship target exists, the slide is listed once, content type present.
            let relText = try String(contentsOf: reloaded.folder.appendingPathComponent("ppt/_rels/presentation.xml.rels"), encoding: .utf8)
            let targets = relText.components(separatedBy: "Target=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
            guard targets.allSatisfy({ FileManager.default.fileExists(atPath: reloaded.folder.appendingPathComponent("ppt/" + $0).path) }) else { throw AppError.message("A relationship points at a missing part") }
            let types = try String(contentsOf: reloaded.folder.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)
            guard types.contains("PartName=\"/\(created.path)\""), (try String(contentsOf: reloaded.folder.appendingPathComponent("ppt/presentation.xml"), encoding: .utf8)).components(separatedBy: "<p:sldId ").count - 1 == existingStructure.count + 1 else { throw AppError.message("New slide is not registered correctly") }
            let slideRels = try String(contentsOf: reloaded.folder.appendingPathComponent("ppt/slides/_rels/" + (created.path as NSString).lastPathComponent + ".rels"), encoding: .utf8)
            guard slideRels.contains("slideLayout") else { throw AppError.message("New slide has no layout") }
            // The heading and body boxes hug their text, grow with more lines, shrink back, and survive saving as spAutoFit.
            guard reloaded.slides[2].items.allSatisfy(\.autoFit) else { throw AppError.message("New slide boxes are not auto-fit after saving") }
            guard let bodyBox = reloaded.slides[2].items.first(where: { $0.text == "Nội dung" }), let headBox = reloaded.slides[2].items.first(where: { $0.text == "Tiêu đề" }) else { throw AppError.message("New slide boxes missing") }
            guard bodyBox.frame.height < 60, headBox.frame.height < 120, bodyBox.frame.width < 400, headBox.frame.width < 400,
                  bodyBox.frame.height < (reference.items.first { $0.id == bodyBox.id }?.frame.height ?? 1000) else { throw AppError.message("New slide boxes are not snug: body \(bodyBox.frame), heading \(headBox.frame)") }
            let oneLine = bodyBox.frame.height
            reloaded.updateText(bodyBox, text: "Một\nHai\nBa")
            guard bodyBox.frame.height > oneLine * 2.2 else { throw AppError.message("Box did not grow with more lines: \(oneLine) -> \(bodyBox.frame.height)") }
            reloaded.updateText(bodyBox, text: String(repeating: "chữ dài ", count: 60))
            guard bodyBox.frame.width <= reloaded.size.width - bodyBox.frame.minX, bodyBox.frame.height > oneLine * 3 else { throw AppError.message("Long text should wrap within the margin: \(bodyBox.frame)") }
            reloaded.updateText(bodyBox, text: "Nội dung")
            guard abs(bodyBox.frame.height - oneLine) < 1.5 else { throw AppError.message("Box did not shrink back: \(bodyBox.frame.height) vs \(oneLine)") }
            // Live: the editor of an auto-fit box grows while lines are typed.
            let liveCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            liveCanvas.display(reloaded.slides[2], in: reloaded); liveCanvas.layoutSubtreeIfNeeded()
            liveCanvas.selected = bodyBox; liveCanvas.startEditing()
            if let liveEditor = liveCanvas.editor {
                let startHeight = liveEditor.frame.height
                liveEditor.setSelectedRange(NSRange(location: liveEditor.string.count, length: 0))
                guard let caretStart = liveCanvas.caretRect, liveEditor.insertionPointColor == .clear else { throw AppError.message("Slidy caret is not shown while editing") }
                guard liveEditor.frame.insetBy(dx: -2, dy: -2).contains(caretStart) else { throw AppError.message("Caret is outside the editor: \(caretStart) vs \(liveEditor.frame)") }
                for _ in 0..<2 { liveEditor.insertText("\nDòng mới", replacementRange: liveEditor.selectedRange()) }
                guard liveEditor.frame.height > startHeight * 2 else { throw AppError.message("Editor did not grow while typing: \(startHeight) -> \(liveEditor.frame.height)") }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // selection notifications arrive on the main queue
                guard let caretEnd = liveCanvas.caretRect, caretEnd.minY > caretStart.minY + 20 else { throw AppError.message("Caret did not follow the typing: \(caretStart) -> \(String(describing: liveCanvas.caretRect))") }
                liveEditor.setSelectedRange(NSRange(location: 0, length: 3)); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                guard liveCanvas.caretRect == nil else { throw AppError.message("Caret should hide while text is selected") }
                liveCanvas.finishEditing(commit: false)
            } else { throw AppError.message("Could not start editing the new body box") }
            // Double-click puts the caret where the click was.
            reloaded.updateText(bodyBox, text: "Một hai ba\nBốn năm sáu")
            let clickCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            clickCanvas.display(reloaded.slides[2], in: reloaded); clickCanvas.layoutSubtreeIfNeeded()
            func caretLocation(x: CGFloat, y: CGFloat) -> Int? {
                clickCanvas.selected = bodyBox
                clickCanvas.startEditing(at: CGPoint(x: bodyBox.frame.minX + x, y: bodyBox.frame.minY + y))
                defer { clickCanvas.finishEditing(commit: false) }
                return clickCanvas.editor?.selectedRange().location
            }
            let firstLineY = bodyBox.insets.top + 6, secondLineY = bodyBox.frame.height - bodyBox.insets.bottom - 6
            guard let atStart = caretLocation(x: 1, y: firstLineY), let atEnd = caretLocation(x: bodyBox.frame.width - 1, y: firstLineY),
                  let middle = caretLocation(x: bodyBox.insets.left + 40, y: firstLineY), let secondLine = caretLocation(x: 1, y: secondLineY) else { throw AppError.message("Could not place the caret by click") }
            // The body is a list, so every line starts with a two-character marker ("•<tab>") the caret must stay after.
            guard atStart == 2, atEnd == 12, middle > 2, middle < 12, secondLine == 15 else { throw AppError.message("Caret placed at wrong spots: start \(atStart) end-of-line \(atEnd) middle \(middle) second line \(secondLine)") }
            try withNew.removeInsertedSlide(at: 2)
            try withNew.saveInPlace()
            let afterRemoval = try Presentation(url: newURL)
            let removedTypes = try String(contentsOf: afterRemoval.folder.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)
            guard afterRemoval.slides.count == existingStructure.count, !removedTypes.contains("PartName=\"/\(created.path)\""),
                  !FileManager.default.fileExists(atPath: afterRemoval.folder.appendingPathComponent(created.path).path) else { throw AppError.message("Undoing the new slide left parts behind") }
            // Deleting a slide: gone from the list, rels, content types and files (notes too); undo brings back everything.
            let deleteURL = output.appendingPathComponent("delete.pptx")
            try? FileManager.default.removeItem(at: deleteURL)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: deleteURL)
            let deckBefore = try Presentation(url: deleteURL)
            let partsBefore = packageProblems(in: deckBefore.folder).isEmpty ? partNames(in: deckBefore.folder) : []
            guard !partsBefore.isEmpty else { throw AppError.message("The original deck has package problems: \(packageProblems(in: deckBefore.folder))") }
            let structureBefore = deckBefore.slides.map { $0.fadeGroups.map { $0.map(\.id) } }
            let pathsBefore = deckBefore.slides.map(\.path)
            let removedSlide = try deckBefore.removeSlide(at: 1)
            try deckBefore.saveInPlace()
            let afterDelete = try Presentation(url: deleteURL)
            guard afterDelete.slides.count == pathsBefore.count - 1, afterDelete.slides.map(\.path) == pathsBefore.enumerated().filter { $0.offset != 1 }.map(\.element),
                  packageProblems(in: afterDelete.folder).isEmpty,
                  !partNames(in: afterDelete.folder).contains(pathsBefore[1]),
                  !partNames(in: afterDelete.folder).contains(where: { $0.contains("notesSlide") && !partsBefore.contains($0) }),
                  partNames(in: afterDelete.folder).count < partsBefore.count else { throw AppError.message("Deleting a slide left the package inconsistent: \(packageProblems(in: afterDelete.folder))") }
            var structureWithout = structureBefore; structureWithout.remove(at: 1)
            guard afterDelete.slides.map({ $0.fadeGroups.map { $0.map(\.id) } }) == structureWithout else { throw AppError.message("Deleting a slide changed other slides' Fade") }
            try deckBefore.restoreSlide(removedSlide)
            try deckBefore.saveInPlace()
            let afterUndo = try Presentation(url: deleteURL)
            guard afterUndo.slides.map(\.path) == pathsBefore, afterUndo.slides.map({ $0.fadeGroups.map { $0.map(\.id) } }) == structureBefore,
                  packageProblems(in: afterUndo.folder).isEmpty, partNames(in: afterUndo.folder) == partsBefore else { throw AppError.message("Undoing the deletion did not restore the deck: \(packageProblems(in: afterUndo.folder))") }
            let listURL = output.appendingPathComponent("numbers.pptx")
            try listDoc.save(to: listURL)
            let listBack = try Presentation(url: listURL)
            guard let backItem = listBack.slides[1].items.first(where: { $0.id == listItem.id }), backItem.paragraphs.map({ $0.bullet }) == ["1.", "2.", "3."] else { throw AppError.message("Numbered list did not survive saving") }
            // Editing the text of an existing numbered list keeps it numbered.
            listBack.updateText(backItem, text: "Một\nHai!\nBa", bulletRows: [0, 1, 2], numberedRows: [0, 1, 2])
            guard backItem.paragraphs.map({ $0.bullet }) == ["1.", "2.", "3."] else { throw AppError.message("Editing broke the numbering") }
            print("Fade persistence: \(timingChecked) slides re-read from the saved file with identical order, groups and valid timing XML")
            print("PASS text, Vietnamese, line breaks, list insertion, geometry, image, save/reopen, \(expected) fade steps, back navigation")
        } catch { fputs("Verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

#endif
