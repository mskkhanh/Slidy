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
        if let route = ProcessInfo.processInfo.environment["PASTE"]?.split(separator: ":").compactMap({ Int($0) }), route.count == 2 {   // copy on one slide, paste on another
            let source = presentation.slides[route[0] - 1], destination = presentation.slides[route[1] - 1]
            delegate.table.selectRowIndexes(IndexSet(integer: route[0] - 1), byExtendingSelection: false); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let wanted = Set(arguments.dropFirst(2))
            let chosen = wanted.contains("table") ? source.items.filter(\.isTableCell) : source.items.filter { wanted.contains($0.id) }
            delegate.canvas.select(chosen)
            delegate.window.makeFirstResponder(delegate.canvas)
            delegate.canvas.copy(nil)
            delegate.table.selectRowIndexes(IndexSet(integer: route[1] - 1), byExtendingSelection: false); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let before = destination.items.count, beforeIDs = Set(destination.items.map(\.id))
            delegate.pasteIntoSlide(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let added = destination.items.filter { !beforeIDs.contains($0.id) || $0.isTableCell && !beforeIDs.contains($0.id) }
            print("  pasted onto slide \(route[1]): \(before) -> \(destination.items.count) objects, selection \(delegate.canvas.selection.count)")
            for (copy, original) in zip(destination.items.suffix(chosen.count), chosen) {
                let font = { (i: SlideItem) in (i.paragraphs.first?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { "\($0.fontName) \($0.pointSize)" } ?? "-" }
                print("  \(original.id) -> \(copy.id): text same \(copy.text == original.text), font \(font(copy) == font(original)), frame \(copy.frame.integral == original.frame.integral)")
            }
            let ids = destination.document.rootElement()?.descendants("cNvPr").compactMap { $0.attr("id") } ?? []
            print("  object ids unique in the slide XML: \(Set(ids).count == ids.count), pasted without Fade: \(added.allSatisfy { !$0.hasFade })")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after undo: \(presentation.slides[route[1] - 1].items.count) objects")
            delegate.pasteIntoSlide(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            delegate.pasteIntoSlide(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            print("  two more pastes: \(presentation.slides[route[1] - 1].items.count) objects; second paste shifted: \(presentation.slides[route[1] - 1].items.suffix(chosen.count).first.map { $0.frame.minX - (chosen.first?.frame.minX ?? 0) } ?? 0)")
            return
        }
        if ProcessInfo.processInfo.environment["FADEKEY"] != nil {   // ⇧↑ / ⇧↓ reorder Fade; ⌘↑ / ⌘↓ do not; without Fade ⇧↓ nudges
            let slide = presentation.slides[slideIndex]
            delegate.applyFade(toTopToBottom: [slide])
            delegate.window.makeFirstResponder(delegate.canvas)
            let n = delegate.window.windowNumber
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) { delegate.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!); RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            let order = { slide.fadeGroups.map { $0.map(\.id) } }
            let start = order()
            guard start.count >= 2, let second = slide.fadeGroups[1].first else { print("  need two effects"); return }
            delegate.canvas.select([second])
            key(126, .shift)
            print("  ⇧↑ on the second effect: order \(start) -> \(order()), moved first: \(order().first == [second.id])")
            key(125, .shift)
            print("  ⇧↓ moves it back: \(order() == start)")
            let before = order()
            key(126, .command)   // ⌘↑ must not touch the Fade order
            print("  ⌘↑ leaves the Fade order alone: \(order() == before)")
            slide.removeFade(from: second); slide.timingDirty = true
            delegate.canvas.select([second])
            let y = second.frame.minY
            key(126, .shift)
            print("  without Fade, ⇧↑ nudges by 10: \(Int(y - second.frame.minY))")
            return
        }
        if let badgeID = ProcessInfo.processInfo.environment["BADGE"] {   // the Fade number follows its object while it is dragged and resized
            let slide = presentation.slides[slideIndex]
            guard let item = slide.items.first(where: { $0.id == badgeID && $0.hasFade }) else { print("  object \(badgeID) has no Fade on this slide"); return }
            delegate.window.layoutIfNeeded(); delegate.canvas.layoutSubtreeIfNeeded()
            delegate.canvas.select([item])
            let scale = delegate.canvas.surface.frame.width / max(1, delegate.canvas.surface.bounds.width)
            let n = delegate.window.windowNumber
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 8, clickCount: 1, pressure: 1)! }
            func badgeNearCorner() -> CGRect? {   // the badge sits just above the object's top edge, near its right end
                delegate.canvas.badgeFrames.min { hypot($0.maxX - item.frame.maxX, $0.midY - item.frame.minY) < hypot($1.maxX - item.frame.maxX, $1.midY - item.frame.minY) }
            }
            func handleRect(_ r: CGRect, scale: CGFloat) -> [CGRect] {   // where resize handles are, with their grab area
                let reach = 14 / scale
                return [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)].map { CGRect(x: $0.x - reach, y: $0.y - reach, width: reach * 2, height: reach * 2) }
            }
            let badgeBefore = badgeNearCorner(), frameBefore = item.frame
            if let badge = badgeBefore {
                let clear = !handleRect(item.frame, scale: scale).contains { $0.intersects(badge) }
                print("  badge clear of every resize handle and its grab area: \(clear) (badge \(Int(badge.minX)),\(Int(badge.minY)) \(Int(badge.width))x\(Int(badge.height)); object top \(Int(item.frame.minY)))")
            }
            let from = delegate.canvas.surface.convert(CGPoint(x: item.frame.midX, y: item.frame.midY), to: nil)
            let to = CGPoint(x: from.x + 50 * scale, y: from.y - 35 * scale)
            guard let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(from, from: nil)) else { return }
            hit.mouseDown(with: mouse(.leftMouseDown, from)); hit.mouseDragged(with: mouse(.leftMouseDragged, to))   // still dragging: no mouse-up yet
            let badgeDuring = badgeNearCorner()
            let moved = (item.frame.minX - frameBefore.minX, item.frame.minY - frameBefore.minY)
            let badgeMoved = ((badgeDuring?.minX ?? 0) - (badgeBefore?.minX ?? 0), (badgeDuring?.minY ?? 0) - (badgeBefore?.minY ?? 0))
            print("  while dragging: object moved by (\(Int(moved.0)),\(Int(moved.1))), its badge moved by (\(Int(badgeMoved.0)),\(Int(badgeMoved.1)))")
            hit.mouseUp(with: mouse(.leftMouseUp, to))
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            // Resize from the lower-right handle.
            let handle = delegate.canvas.surface.convert(CGPoint(x: min(item.frame.maxX, delegate.presentation!.size.width) - 1, y: item.frame.maxY - 1), to: nil)
            let handleTo = CGPoint(x: handle.x + 60 * scale, y: handle.y)
            let beforeResize = badgeNearCorner(), widthBefore = item.frame.width
            print("  selection \(delegate.canvas.selection.count), handle press at slide point (\(Int(item.frame.maxX)),\(Int(item.frame.maxY)))")
            if let handleHit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(handle, from: nil)) {
                print("  press lands on \(type(of: handleHit)) \((handleHit as? ObjectView)?.item.id ?? "")")
                handleHit.mouseDown(with: mouse(.leftMouseDown, handle)); handleHit.mouseDragged(with: mouse(.leftMouseDragged, handleTo))
                let duringResize = badgeNearCorner()
                print("  while resizing: width \(Int(widthBefore)) -> \(Int(item.frame.width)); badge right edge \(Int(beforeResize?.maxX ?? 0)) -> \(Int(duringResize?.maxX ?? 0)) (object right edge \(Int(item.frame.maxX)))")
                handleHit.mouseUp(with: mouse(.leftMouseUp, handleTo))
            }
            return
        }
        if ProcessInfo.processInfo.environment["CROP"] != nil {   // double-click a picture, drag a handle, Return applies, Esc cancels, ⌘Z undoes
            let slide = presentation.slides[slideIndex]
            let png = FileManager.default.temporaryDirectory.appendingPathComponent("crop-test-\(UUID().uuidString).png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try? bitmap.representation(using: .png, properties: [:])?.write(to: png)
            defer { try? FileManager.default.removeItem(at: png) }
            guard let picture = try? presentation.addImage(to: slide, url: png) else { print("  could not add a picture"); return }
            delegate.canvas.display(slide, in: presentation); delegate.window.layoutIfNeeded(); delegate.canvas.layoutSubtreeIfNeeded()
            let scale = delegate.canvas.surface.frame.width / max(1, delegate.canvas.surface.bounds.width)
            let n = delegate.window.windowNumber
            func mouse(_ type: NSEvent.EventType, _ slidePoint: CGPoint, clicks: Int = 1) -> NSEvent { NSEvent.mouseEvent(with: type, location: delegate.canvas.surface.convert(slidePoint, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 11, clickCount: clicks, pressure: 1)! }
            func hitView(_ slidePoint: CGPoint) -> NSView? { delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(delegate.canvas.surface.convert(slidePoint, to: nil), from: nil)) }
            func key(_ code: UInt16) { delegate.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!); RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            let center = CGPoint(x: picture.frame.midX, y: picture.frame.midY)
            let before = picture.frame
            // 1. Double-click enters crop mode.
            hitView(center)?.mouseDown(with: mouse(.leftMouseDown, center, clicks: 2)); hitView(center)?.mouseUp(with: mouse(.leftMouseUp, center, clicks: 2))
            print("  double-click: crop mode \(delegate.canvas.isCropping)")
            // 2. Drag the right-middle handle 60 points to the left, the top-middle handle 30 points down.
            let right = CGPoint(x: before.maxX, y: before.midY)
            let down = mouse(.leftMouseDown, right); let drag = mouse(.leftMouseDragged, CGPoint(x: right.x - 60, y: right.y))
            delegate.canvas.mouseDown(with: down); delegate.canvas.mouseDragged(with: drag); delegate.canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: right.x - 60, y: right.y)))
            let top = CGPoint(x: delegate.canvas.cropFrame.midX, y: delegate.canvas.cropFrame.minY)
            delegate.canvas.mouseDown(with: mouse(.leftMouseDown, top)); delegate.canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: top.x, y: top.y + 30))); delegate.canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: top.x, y: top.y + 30)))
            let frame = delegate.canvas.cropFrame
            print("  crop frame: width \(Int(before.width)) -> \(Int(frame.width)), height \(Int(before.height)) -> \(Int(frame.height)), top edge moved \(Int(frame.minY - before.minY))")
            // 3. Escape cancels and leaves the picture alone.
            key(53)
            print("  Esc: cropping \(delegate.canvas.isCropping), picture frame unchanged \(picture.frame == before), crop \(picture.imageCrop.right)")
            // 4. Do it again and apply with Return.
            hitView(center)?.mouseDown(with: mouse(.leftMouseDown, center, clicks: 2)); hitView(center)?.mouseUp(with: mouse(.leftMouseUp, center, clicks: 2))
            delegate.canvas.cropFrame = CGRect(x: before.minX + 20, y: before.minY + 10, width: before.width - 80, height: before.height - 40)
            key(36)
            let crop = picture.imageCrop
            print("  Return: cropping \(delegate.canvas.isCropping), frame \(picture.frame.integral), crop l \(String(format: "%.3f", crop.left)) t \(String(format: "%.3f", crop.top)) r \(String(format: "%.3f", crop.right)) b \(String(format: "%.3f", crop.bottom))")
            let xml = slide.document.xmlString
            print("  XML has srcRect: \(xml.contains("<a:srcRect")), rounded corners kept: \(picture.geometry == "roundRect")")
            // 5. Saved and read back; undo restores the full picture.
            try? presentation.saveInPlace()
            let back = try? Presentation(url: URL(fileURLWithPath: arguments[0]))
            let saved = back?.slides[slideIndex].items.first(where: { $0.imageURL != nil && abs($0.frame.minX - picture.frame.minX) < 0.6 })
            print("  saved: crop read back l \(String(format: "%.3f", saved?.imageCrop.left ?? -1)) r \(String(format: "%.3f", saved?.imageCrop.right ?? -1)), frame \(String(describing: saved?.frame.integral))")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let undone = presentation.slides[slideIndex].items.first(where: { $0.imageURL != nil })
            print("  undo: frame \(String(describing: undone?.frame.integral)), crop r \(undone?.imageCrop.right ?? -1)")
            return
        }
        if ProcessInfo.processInfo.environment["MODIFIED"] != nil {   // opening a deck must not mark it as changed
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            print("  after opening: modified = \(delegate.modified), undo available = \(delegate.undo.canUndo)")
            return
        }
        if ProcessInfo.processInfo.environment["RENAME"] != nil {   // renaming a file from the recent list, on a private copy
            let directory = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
            let original = URL(fileURLWithPath: arguments[0])
            let other = directory.appendingPathComponent("other deck.pptx"); try? FileManager.default.copyItem(at: original, to: other)
            let stranger = directory.appendingPathComponent("not open.pptx"); try? FileManager.default.copyItem(at: original, to: stranger)
            guard RecentPresentation.key("/private/tmp/a.pptx") == RecentPresentation.key("/tmp/a.pptx") else { print("  keys differ for /private/tmp"); return }
            print("  recents before: \(delegate.recentPresentations.map(\.path))")
            func attempt(_ name: String, on url: URL) -> String {
                do { let result = try delegate.renameFile(at: url, to: name); return "ok -> \(result.lastPathComponent)" } catch { return "refused: \(error.localizedDescription)" }
            }
            print("  empty name: \(attempt("  ", on: original))")
            print("  slash: \(attempt("a/b", on: original))")
            print("  colon: \(attempt("x:y", on: original))")
            print("  already exists: \(attempt("other deck", on: original))")
            print("  after refusals the file is still: \(original.lastPathComponent) exists \(FileManager.default.fileExists(atPath: original.path))")
            // The open file: rename, keep working.
            let renamed = (try? delegate.renameFile(at: original, to: "Renamed deck.pptx")) ?? original   // a typed ".pptx" is not doubled
            print("  open file renamed: \(renamed.lastPathComponent), old path gone \(!FileManager.default.fileExists(atPath: original.path)), new exists \(FileManager.default.fileExists(atPath: renamed.path))")
            print("  presentation points at it: \(delegate.presentation?.source.lastPathComponent ?? "-"), window title: \(delegate.window.title)")
            print("  recents after: \(delegate.recentPresentations.map(\.path))")
            let before = (try? Data(contentsOf: renamed)) ?? Data()
            let slide = presentation.slides[slideIndex]
            if let item = slide.items.first(where: { $0.canMove }) { delegate.canvas.select([item]); delegate.toggleSelectedFade() }
            _ = delegate.flushSave()
            let after = (try? Data(contentsOf: renamed)) ?? Data()
            print("  autosave writes to the new name: \(before != after), old name not recreated: \(!FileManager.default.fileExists(atPath: original.path))")
            // Only the part before the extension changes; case-only changes work too.
            print("  case only: \(attempt("RENAMED DECK", on: renamed))")
            // A file that is not open.
            delegate.recentPresentations = [RecentPresentation(path: stranger.path, slide: 3)] + delegate.recentPresentations
            print("  other file: \(attempt("Another name", on: stranger)), recent entry kept its slide: \(delegate.recentPresentations.first { $0.path.hasSuffix("Another name.pptx") }?.slide ?? -1)")
            // The in-place editor: double-click starts it, Return commits, the extension is never shown or editable.
            let uiTarget = directory.appendingPathComponent("Another name.pptx")
            delegate.recentPresentations = [RecentPresentation(path: uiTarget.path, slide: 0)]
            delegate.toggleRecents(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            delegate.table.reloadData(); delegate.window.layoutIfNeeded()
            delegate.beginRename(row: 0)
            if let field = delegate.renameField {
                print("  editor shows only the name: \(field.stringValue.debugDescription), editable \(field.isEditable)")
                field.stringValue = "Typed in the sidebar.pptx"
                delegate.finishRename(commit: true)
                print("  after Return: on disk \(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Typed in the sidebar.pptx").path)), no double extension \(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Typed in the sidebar.pptx.pptx").path))")
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("Typed in the sidebar.pptx"))
            } else { print("  the in-place editor did not start") }
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Another name.pptx"))
            delegate.recentPresentations = []
            return
        }
        if ProcessInfo.processInfo.environment["AUTOLIST"] != nil {   // opening a deck applies the standard list spacing by itself
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))   // autosave has run
            let lists = presentation.slides.flatMap { $0.items.filter { $0.canMove && $0.hasList } }
            let standard = lists.allSatisfy { $0.paragraphs.filter { $0.bullet != nil }.allSatisfy { p in
                let size = Double((p.text.length > 0 ? (p.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize : nil) ?? 22)
                return abs(p.spacing - size * Presentation.listLineFactor) < 1.5 } }
            print("  after opening: \(lists.count) lists, all standard: \(standard), undo steps: \(delegate.undo.canUndo ? "some" : "none"), modified (not yet saved): \(delegate.modified), save failing: \(delegate.saveFailing)")
            let saved = (try? Presentation(url: URL(fileURLWithPath: arguments[0])))?.slides.flatMap { $0.items.filter { $0.canMove && $0.hasList } } ?? []
            print("  saved file: \(saved.count) lists, all standard: \(saved.allSatisfy { $0.paragraphs.filter { $0.bullet != nil }.allSatisfy { $0.after == 0 && $0.before > 0 } })")
            let stamp = Presentation.modificationDate(of: URL(fileURLWithPath: arguments[0]))
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))   // no save loop: the file stays as it is
            print("  no further saves: \(Presentation.modificationDate(of: URL(fileURLWithPath: arguments[0])) == stamp)")
            // Showing another slide changes nothing more.
            delegate.table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false); RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            print("  after showing another slide: still saved as is: \(Presentation.modificationDate(of: URL(fileURLWithPath: arguments[0])) == stamp), modified \(delegate.modified)")
            return
        }
        if ProcessInfo.processInfo.environment["SIDEBAR"] != nil {   // ⌘B slides the left column out and in smoothly
            delegate.window.layoutIfNeeded()
            let open = delegate.canvas.frame.minX
            delegate.setSidebarHidden(false, remember: false, animated: false); delegate.window.layoutIfNeeded()
            delegate.setSidebarHidden(true, remember: false)
            var samples: [Int] = []
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)); samples.append(Int(delegate.canvas.frame.minX)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            print("  sliding out: slide area left edge over time \(samples), at rest \(Int(delegate.canvas.frame.minX)) (open was \(Int(open))), column hidden \(delegate.sidebarViews.allSatisfy { $0.isHidden })")
            delegate.setSidebarHidden(false, remember: false)
            var back: [Int] = []
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)); back.append(Int(delegate.canvas.frame.minX)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            print("  sliding in: \(back), at rest \(Int(delegate.canvas.frame.minX)), column visible \(delegate.sidebarViews.allSatisfy { !$0.isHidden })")
            return
        }
        if ProcessInfo.processInfo.environment["WAND"] != nil {   // the wand button: only slides without effects get Fade
            let before = presentation.slides.map { $0.fadeGroups.map { $0.map(\.id) } }
            let plain = delegate.slidesWithoutEffects(in: presentation)
            let plainIndexes = Set(presentation.slides.enumerated().filter { slide in plain.contains { $0 === slide.element } }.map(\.offset))
            delegate.applyFade(toTopToBottom: plain)
            let after = presentation.slides.map { $0.fadeGroups.map { $0.map(\.id) } }
            var untouched = 0, changed = 0, wrong: [Int] = []
            for index in presentation.slides.indices {
                if plainIndexes.contains(index) { if !after[index].isEmpty { changed += 1 } else { wrong.append(index + 1) } }
                else if after[index] == before[index] { untouched += 1 } else { wrong.append(index + 1) }
            }
            // Trim: text stays where it is (same picture of every slide), boxes shrink, a second run changes nothing.
            func shot() -> NSBitmapImageRep? {
                delegate.canvas.select([]); delegate.canvas.showsOrderBadges = false; delegate.canvas.updateOrderBadges(); delegate.canvas.displayIfNeeded()
                guard let bitmap = delegate.canvas.bitmapImageRepForCachingDisplay(in: delegate.canvas.bounds) else { return nil }
                delegate.canvas.cacheDisplay(in: delegate.canvas.bounds, to: bitmap); delegate.canvas.showsOrderBadges = true; return bitmap
            }
            func differing(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
                guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return -1 }
                var count = 0
                for i in stride(from: 0, to: a.bytesPerRow * a.pixelsHigh, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i+1]) - Int(y[i+1])) + abs(Int(x[i+2]) - Int(y[i+2])) > 24 { count += 1 }
                return count
            }
            var pictures: [NSBitmapImageRep?] = []
            for slide in presentation.slides { delegate.canvas.display(slide, in: presentation); pictures.append(shot()) }
            let widths: [CGFloat] = presentation.slides.map { $0.items.filter(\.canMove).map(\.frame.width).reduce(0, +) }
            let first = delegate.tidyDeck(presentation)
            var worst = 0, worstSlide = 0
            for (index, slide) in presentation.slides.enumerated() { delegate.canvas.display(slide, in: presentation); let d = differing(pictures[index], shot()); if d > worst { worst = d; worstSlide = index + 1 } }
            let widthsAfter: [CGFloat] = presentation.slides.map { $0.items.filter(\.canMove).map(\.frame.width).reduce(0, +) }
            var narrower = 0
            for (a, b) in zip(widths, widthsAfter) where a - b > 1 { narrower += 1 }
            print("  trim: \(first.trimmed) text boxes on \(first.trimmedSlides) slides; slides with narrower boxes \(narrower); biggest change in any slide picture: \(worst) pixels (slide \(worstSlide))")
            print("  report: \(AppDelegate.tidyReport(first).replacingOccurrences(of: "\n", with: " | "))")
            let second = delegate.tidyDeck(presentation)
            print("  second run: \(second.trimmed) trimmed, \(second.faded) faded -> \(AppDelegate.tidyReport(second).replacingOccurrences(of: "\n", with: " | "))")
            delegate.canvas.display(presentation.slides[slideIndex], in: presentation); delegate.canvas.showsOrderBadges = true; delegate.canvas.updateOrderBadges(); delegate.canvas.displayIfNeeded()
            if let bitmap = delegate.canvas.bitmapImageRepForCachingDisplay(in: delegate.canvas.bounds) {   // the slide with its order badges, to look at
                delegate.canvas.cacheDisplay(in: delegate.canvas.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + ".badges.png"))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            print("  wand: \(plain.count) slides without effects got Fade (\(changed) now have it), \(untouched) slides with effects or no objects untouched, wrong: \(wrong)")
            return
        }
        if ProcessInfo.processInfo.environment["RECENTS"] != nil {   // a long file name in the recent files list takes two lines
            let long = "/tmp/Buổi học miễn phí 1 2 (13 11) Lập kế hoạch ngày mai trong 5 phút.pptx"
            let short = "/tmp/Ngắn.pptx"
            delegate.recentPresentations = [RecentPresentation(path: long, slide: 0), RecentPresentation(path: short, slide: 0)]
            delegate.toggleRecents(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            for row in 0..<2 {
                let height = delegate.tableView(delegate.table, heightOfRow: row)
                guard let cell = delegate.tableView(delegate.table, viewFor: nil, row: row) else { continue }
                cell.frame = NSRect(x: 0, y: 0, width: 174, height: height); cell.layoutSubtreeIfNeeded()
                let label = cell.subviews.compactMap { $0 as? NSTextField }.first
                let lineHeight = (label?.font?.boundingRectForFont.height ?? 15)
                print("  row \(row): row height \(height), label \(label?.frame.size ?? .zero), about \(Int(((label?.frame.height ?? 0) / lineHeight).rounded())) line(s), line break \(String(describing: label?.lineBreakMode)), max lines \(label?.maximumNumberOfLines ?? -1)")
            }
            delegate.recentPresentations = []
            return
        }
        if ProcessInfo.processInfo.environment["DRAGTABLE"] != nil {   // click a table cell and drag: the whole table moves; ⌘Z puts it back
            let slide = presentation.slides[slideIndex]
            let cells = slide.items.filter(\.isTableCell)
            guard let cell = cells.first else { print("  no table on this slide"); return }
            delegate.window.layoutIfNeeded(); delegate.canvas.layoutSubtreeIfNeeded()
            let scale = delegate.canvas.surface.frame.width / max(1, delegate.canvas.surface.bounds.width)
            let from = delegate.canvas.surface.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), to: nil)
            let to = CGPoint(x: from.x + 40 * scale, y: from.y - 30 * scale)
            let n = delegate.window.windowNumber
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 6, clickCount: 1, pressure: 1)! }
            let before = cells.map(\.frame)
            let offBefore = cells.first?.tableNode?.child("xfrm")?.child("off")?.attr("x") ?? "?"
            guard let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(from, from: nil)) else { return }
            var view: NSView? = hit; while let current = view, !(current is ObjectView) { view = current.superview }
            (view as? ObjectView)?.mouseDown(with: mouse(.leftMouseDown, from))   // ⌘ is held only while dragging: no snapping, exact distance
            (view as? ObjectView)?.mouseDragged(with: mouse(.leftMouseDragged, to, .command)); (view as? ObjectView)?.mouseUp(with: mouse(.leftMouseUp, to, .command))
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let moved = slide.items.filter(\.isTableCell)
            let shifts = Set(zip(before, moved.map(\.frame)).map { "\(Int(($1.minX - $0.minX).rounded())),\(Int(($1.minY - $0.minY).rounded()))" })
            print("  dragged the table: \(moved.count) cells all moved by \(shifts) (asked 40,-30 would be the on-screen delta); frame offset x \(offBefore) -> \(moved.first?.tableNode?.child("xfrm")?.child("off")?.attr("x") ?? "?")")
            try? delegate.presentation?.saveInPlace()
            let reopened = try? Presentation(url: URL(fileURLWithPath: arguments[0]))
            let savedCells = reopened?.slides[slideIndex].items.filter(\.isTableCell) ?? []
            print("  saved and reopened: cells in the new place: \(zip(savedCells.map(\.frame), moved.map(\.frame)).allSatisfy { abs($0.minX - $1.minX) < 0.6 && abs($0.minY - $1.minY) < 0.6 })")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let back = presentation.slides[slideIndex].items.filter(\.isTableCell)
            print("  after undo: cells back where they were: \(zip(before, back.map(\.frame)).allSatisfy { abs($0.minX - $1.minX) < 0.6 && abs($0.minY - $1.minY) < 0.6 })")
            return
        }
        if ProcessInfo.processInfo.environment["LAYER"] != nil {   // ⌥⌘↑ / ⌥⌘↓ move the selected object one layer per press
            let slide = presentation.slides[slideIndex]
            func names(_ s: Slide) -> String { var seen: [String] = []; for item in s.items where item.canMove || item.isTableCell { let k = item.tableID.map { "table\($0)" } ?? item.id; if seen.last != k { seen.append(k) } }; return seen.joined(separator: " ") }
            func xmlOrder(_ s: Slide) -> String { (s.tree.children ?? []).compactMap { ($0 as? XMLElement) }.filter { ["sp", "pic", "graphicFrame"].contains($0.localName ?? "") }.compactMap { $0.descendant("cNvPr")?.attr("id") }.joined(separator: " ") }
            guard let target = slide.items.first(where: \.canMove) else { print("  nothing movable"); return }
            let n = delegate.window.windowNumber
            func arrow(_ code: UInt16) { delegate.window.makeFirstResponder(delegate.canvas); delegate.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!) }
            delegate.canvas.selected = target
            print("  start:      \(names(slide)) | xml \(xmlOrder(slide)) | selected \(target.id)")
            arrow(126); print("  ⌥⌘↑ once:   \(names(slide)) | xml \(xmlOrder(slide))")
            arrow(126); print("  ⌥⌘↑ twice:  \(names(slide)) | xml \(xmlOrder(slide))")
            arrow(125); print("  ⌥⌘↓ once:   \(names(slide)) | xml \(xmlOrder(slide))")
            for _ in 0..<20 { arrow(126) }; print("  ⌥⌘↑ ×20:    \(names(slide)) (stops on top)")
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            let saved = try? Presentation(url: URL(fileURLWithPath: arguments[0]))
            print("  saved file: \(saved.map { names($0.slides[slideIndex]) } ?? "unreadable")")
            for _ in 0..<30 where delegate.undo.canUndo { delegate.undo.undo() }
            print("  after undo: \(names(presentation.slides[slideIndex]))")
            return
        }
        if ProcessInfo.processInfo.environment["TABLEFADE"] != nil {   // F on a table: the table first, then each cell's text, row by row
            let slide = presentation.slides[slideIndex]
            guard let cell = slide.items.first(where: { $0.isTableCell && !$0.isTableFrame }), let id = cell.tableID else { print("  no table on this slide"); return }
            func shot() -> NSBitmapImageRep? {
                delegate.canvas.select([]); delegate.canvas.showsOrderBadges = false; delegate.canvas.updateOrderBadges(); delegate.canvas.displayIfNeeded()
                guard let bitmap = delegate.canvas.bitmapImageRepForCachingDisplay(in: delegate.canvas.bounds) else { return nil }
                delegate.canvas.cacheDisplay(in: delegate.canvas.bounds, to: bitmap); delegate.canvas.showsOrderBadges = true; return bitmap
            }
            func differing(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
                guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return -1 }
                var count = 0; let length = a.bytesPerRow * a.pixelsHigh
                for i in stride(from: 0, to: length, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i+1]) - Int(y[i+1])) + abs(Int(x[i+2]) - Int(y[i+2])) > 24 { count += 1 }
                return count
            }
            func sequence(_ s: Slide) -> String { s.fadeSequence.map { step in step.map { $0.item.isTableFrame ? "TABLE" : "\"\($0.item.text.prefix(14))\"" }.joined(separator: "+") }.joined(separator: " > ") }
            let cellTexts = slide.items.filter { $0.tableID == id && !$0.isTableFrame }.map(\.text).filter { !$0.isEmpty }
            let before = shot()
            if let png = before?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: arguments[0] + ".before.png")) }
            delegate.canvas.select(delegate.canvas.members(of: cell))
            print("  table selected: \(delegate.canvas.selection.count) items; \(cellTexts.count) cells with text; effects before: \(sequence(slide))")
            delegate.toggleSelectedFade()
            let boxes = slide.items.filter { $0.cellTextOf == id }
            print("  after F: \(boxes.count) text boxes, cells still holding text \(slide.items.filter { $0.tableID == id && !$0.text.isEmpty }.count), same texts in order \(boxes.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.map(\.text) == cellTexts)")
            print("  order: \(sequence(slide))")
            let after = shot()
            if let png = after?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: arguments[0] + ".after.png")) }
            print("  picture of the slide: \(differing(before, after)) pixels differ")
            if let box = boxes.first { delegate.canvas.select(delegate.canvas.members(of: box)); print("  clicking a cell text selects the group: \(delegate.canvas.selection.count) items (table + texts)") }
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            if let saved = try? Presentation(url: URL(fileURLWithPath: arguments[0])) {
                let s = saved.slides[slideIndex]
                print("  saved file: order \(sequence(s))")
                print("  saved file: text boxes \(s.items.filter { $0.cellTextOf == id }.count), timing targets \(s.document.xmlString.components(separatedBy: "<p:spTgt").count - 1)")
            }
            delegate.canvas.select(delegate.canvas.members(of: cell)); delegate.toggleSelectedFade()
            print("  F again: \(sequence(slide).isEmpty ? "no effects on the table" : sequence(slide)); text boxes kept \(slide.items.filter { $0.cellTextOf == id }.count)")
            for _ in 0..<10 where delegate.undo.canUndo { delegate.undo.undo() }
            let restored = presentation.slides[slideIndex]
            print("  after undo: text boxes \(restored.items.filter { $0.cellTextOf == id }.count), cell texts back \(restored.items.filter { $0.tableID == id && !$0.isTableFrame }.map(\.text).filter { !$0.isEmpty } == cellTexts), picture differs by \(differing(before, shot())) pixels")
            return
        }
        if ProcessInfo.processInfo.environment["BOLD"] != nil {   // ⌘B on selected text while editing; ⌃← / ⌃→ and the sidebar buttons
            let slide = presentation.slides[slideIndex]
            guard let item = slide.items.first(where: { $0.canMove && $0.text.count > 8 }) else { print("  no text"); return }
            func runs(_ i: SlideItem) -> String { (i.textBody?.all("p").first?.all("r") ?? []).map { "[\($0.child("t")?.stringValue ?? "")|b=\($0.child("rPr")?.attr("b") ?? "-")]" }.joined() }
            print("  before: \(runs(item))")
            delegate.canvas.selected = item; delegate.canvas.startEditing()
            let skip = InlineTextView.marker(in: delegate.canvas.editor?.string ?? "")?.length ?? 0
            delegate.canvas.editor?.setSelectedRange(NSRange(location: skip + 2, length: 4))
            delegate.toggleBold()
            delegate.canvas.finishEditing(commit: true)
            let text = item.text
            print("  ⌘B on characters 2–5: \(runs(item))")
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            if let saved = try? Presentation(url: URL(fileURLWithPath: arguments[0])), let again = saved.slides[slideIndex].items.first(where: { $0.id == item.id }) {
                print("  saved file: \(runs(again)); text unchanged \(again.text == text)")
            }
            delegate.canvas.selected = item; delegate.canvas.startEditing()
            delegate.canvas.editor?.setSelectedRange(NSRange(location: skip + 2, length: 4)); delegate.toggleBold(); delegate.canvas.finishEditing(commit: true)
            print("  ⌘B again (off): \(runs(item))")
            delegate.canvas.select([item]); delegate.toggleBold(); print("  ⌘B on the object: \(runs(item))")
            delegate.toggleBold(); print("  ⌘B on the object again: \(runs(item))")
            let n = delegate.window.windowNumber
            func control(_ code: UInt16) { delegate.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!) }
            func shot(_ name: String) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                guard let content = delegate.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + "." + name + ".png"))
            }
            shot("open")
            control(123); print("  ⌃←: sidebar hidden \(delegate.sidebarHidden); toggle button still on screen at x \(Int(delegate.sidebarButton.frame.minX)), hidden \(delegate.sidebarButton.isHidden)"); shot("collapsed")
            control(124); print("  ⌃→: sidebar hidden \(delegate.sidebarHidden)")
            delegate.recentsButton.performClick(nil); print("  recent button: showing recents \(delegate.showingRecents)"); shot("recents")
            delegate.slidesButton.performClick(nil); print("  slides button: showing recents \(delegate.showingRecents)")
            delegate.sidebarButton.performClick(nil); print("  toggle button: hidden \(delegate.sidebarHidden)"); delegate.sidebarButton.performClick(nil); print("  toggle button again: hidden \(delegate.sidebarHidden)")
            for _ in 0..<10 where delegate.undo.canUndo { delegate.undo.undo() }
            return
        }
        if ProcessInfo.processInfo.environment["DELETETABLE"] != nil {   // click a cell: the whole table is selected; Delete removes it; ⌘Z restores it
            let slide = presentation.slides[slideIndex]
            let cells = slide.items.filter(\.isTableCell)
            guard let cell = cells.first else { print("  no table on this slide"); return }
            let local = delegate.canvas.surface.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), to: nil)
            let n = delegate.window.windowNumber
            func mouse(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 5, clickCount: 1, pressure: 1)! }
            delegate.window.layoutIfNeeded(); delegate.canvas.layoutSubtreeIfNeeded()
            if let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(local, from: nil)) {
                var view: NSView? = hit; while let current = view, !(current is ObjectView) { view = current.superview }
                (view as? ObjectView)?.mouseDown(with: mouse(.leftMouseDown)); (view as? ObjectView)?.mouseUp(with: mouse(.leftMouseUp))
            }
            print("  clicked a cell: \(delegate.canvas.selection.count) of \(cells.count) table cells selected")
            let before = slide.document.xmlString.components(separatedBy: "<a:tbl>").count - 1
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
            delegate.window.makeFirstResponder(delegate.canvas)
            delegate.canvas.keyDown(with: key)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            print("  after Delete: cells left \(slide.items.filter(\.isTableCell).count), tables in the slide XML \(before) -> \(slide.document.xmlString.components(separatedBy: "<a:tbl>").count - 1)")
            delegate.undo.undo(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let restored = presentation.slides[slideIndex]
            print("  after undo: cells \(restored.items.filter(\.isTableCell).count), tables in XML \(restored.document.xmlString.components(separatedBy: "<a:tbl>").count - 1)")
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
                let reach = (ProcessInfo.processInfo.environment["REACH"].flatMap { Double($0) }.map { CGFloat($0) } ?? -1) / scale   // negative: inside the corner, positive: outside it
                let corner = delegate.canvas.surface.convert(CGPoint(x: sized.frame.maxX + reach, y: sized.frame.maxY + reach), to: nil)
                let target = ProcessInfo.processInfo.environment["RESIZE_TO"].flatMap { Double($0) }.map { CGFloat($0) } ?? (sized.frame.maxY + 60)
                let to = CGPoint(x: corner.x, y: corner.y - (target - sized.frame.maxY) * scale)
                let n = delegate.window.windowNumber
                func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, eventNumber: 78, clickCount: 1, pressure: 1)! }
                if let hit = delegate.window.contentView!.hitTest(delegate.window.contentView!.convert(corner, from: nil)) {
                    let before = sized.frame
                    print("  press lands on \(type(of: hit))")
                    hit.mouseDown(with: event(.leftMouseDown, corner)); hit.mouseDragged(with: event(.leftMouseDragged, to))
                    print("  resize: \(resizeID) bottom edge \(String(format: "%.1f", before.maxY)) -> \(String(format: "%.1f", sized.frame.maxY)) (asked for \(String(format: "%.1f", target)), guides \(delegate.canvas.guideCount))")
                    hit.mouseUp(with: event(.leftMouseUp, to))
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
            let originalCells = document.slides.flatMap(\.items).filter(\.isTableCell).count
            let untouched = output.appendingPathComponent("unchanged.pptx")
            try document.save(to: untouched)
            let unchanged = try Presentation(url: untouched)
            guard unchanged.slides.map({ $0.items.map(\.text) }) == originalTexts,
                  unchanged.slides.flatMap(\.items).filter(\.isTableCell).count == originalCells else {
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
            guard newTexts == ["Heading", "Text"] || newTexts == ["Text", "Heading"] else { throw AppError.message("New slide text is wrong: \(newTexts)") }
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
            guard let bodyBox = reloaded.slides[2].items.first(where: { $0.text == "Text" }), let headBox = reloaded.slides[2].items.first(where: { $0.text == "Heading" }) else { throw AppError.message("New slide boxes missing") }
            guard bodyBox.frame.height < 60, headBox.frame.height < 120, bodyBox.frame.width < 400, headBox.frame.width < 400,
                  bodyBox.frame.height < (reference.items.first { $0.id == bodyBox.id }?.frame.height ?? 1000) else { throw AppError.message("New slide boxes are not snug: body \(bodyBox.frame), heading \(headBox.frame)") }
            let oneLine = bodyBox.frame.height
            reloaded.updateText(bodyBox, text: "Một\nHai\nBa")
            guard bodyBox.frame.height > oneLine * 2.2 else { throw AppError.message("Box did not grow with more lines: \(oneLine) -> \(bodyBox.frame.height)") }
            reloaded.updateText(bodyBox, text: String(repeating: "chữ dài ", count: 60))
            guard bodyBox.frame.width <= reloaded.size.width - bodyBox.frame.minX, bodyBox.frame.height > oneLine * 3 else { throw AppError.message("Long text should wrap within the margin: \(bodyBox.frame)") }
            reloaded.updateText(bodyBox, text: "Text")
            guard abs(bodyBox.frame.height - oneLine) < 1.5 else { throw AppError.message("Box did not shrink back: \(bodyBox.frame.height) vs \(oneLine)") }
            // Live: the editor of an auto-fit box grows while lines are typed.
            let liveCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            liveCanvas.display(reloaded.slides[2], in: reloaded); liveCanvas.layoutSubtreeIfNeeded()
            liveCanvas.selected = bodyBox; liveCanvas.startEditing()
            if let liveEditor = liveCanvas.editor {
                guard !liveEditor.drawsBackground else { throw AppError.message("The text editor must be transparent") }
                guard let editedView = liveCanvas.objectViews.first(where: { $0.item === bodyBox }), !editedView.isHidden, editedView.paragraphViews.allSatisfy(\.isHidden) else { throw AppError.message("While editing, the object keeps its fill and hides only its text") }
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
            // List spacing: one standard line spacing (1.2 × font size inside a paragraph, 1.94 × between paragraphs) for every bullet and numbered list.
            let spaceDoc = try Presentation(url: URL(fileURLWithPath: arguments[2]))
            let spaceSlide = spaceDoc.slides[1]
            let standardFor: (Double) -> Double = { size in (size * Presentation.listLineFactor / 100).rounded() }   // points
            let newList = spaceDoc.addText(to: spaceSlide, list: true)
            spaceDoc.updateText(newList, text: "Un\nDeux\nTrois", bulletRows: [0, 1, 2])
            guard newList.paragraphs.allSatisfy({ abs($0.spacing - standardFor(2400)) < 1 }) else { throw AppError.message("New list does not use the standard spacing: \(newList.paragraphs.map(\.spacing))") }
            let plainText = spaceDoc.addText(to: spaceSlide, list: false)
            spaceDoc.updateText(plainText, text: "Un\nDeux", bulletRows: [0, 1])   // text turned into a list by typing "- "
            guard plainText.paragraphs.allSatisfy({ $0.bullet != nil && abs($0.spacing - standardFor(2400)) < 1 }) else { throw AppError.message("A paragraph turned into a list item did not get the standard spacing") }
            guard newList.paragraphs.allSatisfy({ $0.after == 0 && $0.before > 0 }) else { throw AppError.message("Standard list spacing puts the gap before each paragraph and none after") }
            let existingLists = spaceDoc.slides.flatMap { $0.items.filter { $0.canMove && $0.hasList && $0 !== newList && $0 !== plainText } }
            let nonListBefore = spaceDoc.slides.flatMap { $0.items.filter { !$0.hasList }.flatMap { $0.paragraphs.map(\.spacing) } }
            var changedLists = 0
            for list in existingLists where spaceDoc.standardizeListSpacing(list) { changedLists += 1 }
            guard changedLists > 0, existingLists.allSatisfy({ list in list.paragraphs.filter({ $0.bullet != nil }).allSatisfy { paragraph in
                let size = Double((paragraph.text.length > 0 ? (paragraph.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize : nil) ?? 22)
                return abs(paragraph.spacing - size * Presentation.listLineFactor) < 1.5 } }) else { throw AppError.message("Existing lists did not get the standard spacing") }
            guard spaceDoc.slides.flatMap({ $0.items.filter { !$0.hasList }.flatMap { $0.paragraphs.map(\.spacing) } }) == nonListBefore else { throw AppError.message("Text that is not a list must keep its spacing") }
            guard spaceDoc.slides.flatMap({ $0.items.filter(\.isTableCell) }).allSatisfy({ !$0.hasList }) else { throw AppError.message("Table cells must be left alone") }
            let spaceURL = output.appendingPathComponent("spacing.pptx")
            try spaceDoc.save(to: spaceURL)
            let reopenedSpace = try Presentation(url: spaceURL)
            let savedLists = reopenedSpace.slides.flatMap { $0.items.filter { $0.canMove && $0.hasList } }
            guard savedLists.count == existingLists.count + 2, savedLists.allSatisfy({ $0.paragraphs.filter { $0.bullet != nil }.allSatisfy { $0.after == 0 && $0.before > 0 } }) else { throw AppError.message("List spacing did not survive saving") }
            // Khanh's measured value: 22 pt text -> 42.59 pt line height.
            guard abs(Presentation.listPitchFactor * 22 - 42.59) < 0.01, abs((Presentation.listLineFactor + Presentation.listGapFactor) * 22 - 42.59) < 0.01 else { throw AppError.message("Standard factor is not the measured 4259 / 2200") }
            // The app speaks English only: no Vietnamese in the shortcut list or in any UI string a new object brings along.
            guard !Shortcuts.sections.flatMap({ $0.items.map { $0.keys + $0.action } + [$0.title] }).contains(where: { $0.contains(where: { "ăâđêôơưáàảãạéèẻẽẹíìỉĩịóòỏõọúùủũụýỳỷỹỵ".contains($0) }) }) else { throw AppError.message("Vietnamese text in the shortcut list") }
            // The ⌘/ list is complete and short.
            let shortcutText = Shortcuts.sections.flatMap { $0.items }.map { "\($0.keys) \($0.action)" }
            for required in ["⌘↑ / ⌘↓", "⇧↑ / ⇧↓", "⌘B", "⌘L", "⌘0", "⌘E", "⌘F · ⌘Enter", "T · H", "⌥-click", "Wand button"] {
                guard shortcutText.contains(where: { $0.contains(required) }) else { throw AppError.message("Shortcut list is missing \(required)") }
            }
            // Features that still work but are deliberately not listed.
            for hidden in ["⌘G", "Drag", "Double-click", "Space", "Return", "Delete"] {
                guard !shortcutText.contains(where: { $0.hasPrefix(hidden) }) else { throw AppError.message("The shortcut list should leave out \(hidden)") }
            }
            // Only Slidy's own shortcuts: the ones every Mac app has stay out, so the sheet is short.
            for common in ["⌘C", "⌘Z", "⌘S", "⌘O", "⌘Q", "⌘X", "⌘V"] {
                guard !shortcutText.contains(where: { $0.hasPrefix(common) }) else { throw AppError.message("The shortcut list should leave out the familiar \(common)") }
            }
            guard Shortcuts.sections.flatMap({ $0.items }).count <= 24 else { throw AppError.message("The shortcut list is too long") }
            guard Shortcuts.sections.flatMap({ $0.items }).allSatisfy({ $0.action.count <= 28 }) else { throw AppError.message("A shortcut description is too long") }
            // Inserted pictures get slightly rounded corners (standard roundRect) and no shadow.
            let shadowDoc = try Presentation(url: URL(fileURLWithPath: arguments[2]))
            let pictureURL = output.appendingPathComponent("round-test.png")
            let pictureBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try pictureBitmap.representation(using: .png, properties: [:])!.write(to: pictureURL)
            let insertedPicture = try shadowDoc.addImage(to: shadowDoc.slides[1], url: pictureURL)
            guard insertedPicture.shadow == nil, !shadowDoc.slides[1].document.xmlString.contains("<a:outerShdw") else { throw AppError.message("Inserted pictures must not get a shadow") }
            let roundURL = output.appendingPathComponent("round.pptx")
            try shadowDoc.save(to: roundURL)
            guard let savedPicture = try Presentation(url: roundURL).slides[1].items.first(where: { $0.id == insertedPicture.id }),
                  savedPicture.geometry == "roundRect", savedPicture.cornerRatio > 0.01, savedPicture.cornerRatio < 0.06,
                  shadowDoc.slides[1].document.xmlString.contains("prst=\"roundRect\"") else { throw AppError.message("Picture corners are not slightly rounded") }
            guard shadowDoc.slides[0].items.filter({ $0.imageURL != nil }).allSatisfy({ $0.geometry != "roundRect" }) else { throw AppError.message("Existing pictures must keep their own corners") }
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
