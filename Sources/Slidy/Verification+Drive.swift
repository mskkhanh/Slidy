#if DEBUG
import AppKit

// `--drive`: scenarios played on the real window with real mouse and key events (one per environment variable).
extension Verification {
    /// A picture of the slide as the canvas draws it, without selection and order numbers.
    static func slidePicture(_ canvas: CanvasView) -> NSBitmapImageRep? {
        canvas.select([]); canvas.showsOrderBadges = false; canvas.updateOrderBadges(); canvas.displayIfNeeded()
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap); canvas.showsOrderBadges = true; return bitmap
    }
    /// How many pixels differ visibly between two pictures of the same size (-1 when they cannot be compared).
    static func differing(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return -1 }
        var count = 0
        for i in stride(from: 0, to: a.bytesPerRow * a.pixelsHigh, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i+1]) - Int(y[i+1])) + abs(Int(x[i+2]) - Int(y[i+2])) > 24 { count += 1 }
        return count
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
            func badgeNearCorner() -> CGRect? {   // the badge sits right before the object's first character, near its top-left
                delegate.canvas.badgeFrames.min { hypot($0.maxX - item.frame.minX, $0.midY - item.frame.minY) < hypot($1.maxX - item.frame.minX, $1.midY - item.frame.minY) }
            }
            func handleRect(_ r: CGRect, scale: CGFloat) -> [CGRect] {   // where resize handles are, with their grab area
                let reach = 14 / scale
                let corners = item.imageURL != nil ? [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)] : [CGPoint(x: r.maxX, y: r.maxY)]   // only a picture has four handles
                return corners.map { CGRect(x: $0.x - reach, y: $0.y - reach, width: reach * 2, height: reach * 2) }
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
                print("  while resizing: width \(Int(widthBefore)) -> \(Int(item.frame.width)); badge left edge \(Int(beforeResize?.minX ?? 0)) -> \(Int(duringResize?.minX ?? 0)) (stays: the object grows to the right)")
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
            func shot() -> NSBitmapImageRep? { slidePicture(delegate.canvas) }
            var pictures: [NSBitmapImageRep?] = []
            for slide in presentation.slides { delegate.canvas.display(slide, in: presentation); pictures.append(shot()) }
            let widths: [CGFloat] = presentation.slides.map { $0.items.filter(\.canMove).map(\.frame.width).reduce(0, +) }
            let first = delegate.tidyDeck(presentation)
            var worst = 0, worstSlide = 0
            for (index, slide) in presentation.slides.enumerated() { delegate.canvas.display(slide, in: presentation); let d = Self.differing(pictures[index], shot()); if d > worst { worst = d; worstSlide = index + 1 } }
            let widthsAfter: [CGFloat] = presentation.slides.map { $0.items.filter(\.canMove).map(\.frame.width).reduce(0, +) }
            var narrower = 0
            for (a, b) in zip(widths, widthsAfter) where a - b > 1 { narrower += 1 }
            print("  trim: \(first.trimmed) text boxes on \(first.trimmedSlides) slides; slides with narrower boxes \(narrower); biggest change in any slide picture: \(worst) pixels (slide \(worstSlide))")
            print("  report: \(AppDelegate.tidyReport(first).replacingOccurrences(of: "\n", with: " | "))")
            let second = delegate.tidyDeck(presentation)
            print("  second run: \(second.trimmed) trimmed, \(second.faded) faded -> \(AppDelegate.tidyReport(second).replacingOccurrences(of: "\n", with: " | "))")
            let nightBefore = NightMode.isOn; defer { NightMode.isOn = nightBefore }
            if ProcessInfo.processInfo.environment["NIGHT"] != nil { NightMode.isOn = true }
            delegate.canvas.display(presentation.slides[slideIndex], in: presentation); delegate.canvas.showsOrderBadges = true; delegate.canvas.updateOrderBadges(); delegate.canvas.displayIfNeeded()
            if let bitmap = delegate.canvas.bitmapImageRepForCachingDisplay(in: delegate.canvas.bounds) {   // the slide with its order badges, to look at
                delegate.canvas.cacheDisplay(in: delegate.canvas.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + ".badges.png"))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            print("  wand: \(plain.count) slides without effects got Fade (\(changed) now have it), \(untouched) slides with effects or no objects untouched, wrong: \(wrong)")
            return
        }
        if ProcessInfo.processInfo.environment["RECENTS"] != nil {   // a long file name in the recent files list stays on one line (cut with …, full name in the tooltip)
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
            func shot() -> NSBitmapImageRep? { slidePicture(delegate.canvas) }
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
            print("  picture of the slide: \(Self.differing(before, after)) pixels differ")
            if let box = boxes.first { delegate.canvas.select(delegate.canvas.members(of: box)); print("  clicking a cell text selects the group: \(delegate.canvas.selection.count) items (table + texts)") }
            // Copy and paste the table with its cell texts: the copies belong to the copy, not to the original table.
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // a new event, so the paste is its own undo step
            if let box = boxes.first {
                delegate.canvas.select(delegate.canvas.members(of: box))
                if ObjectClipboard.write(delegate.canvas.selection, from: slide), let payload = ObjectClipboard.read() {
                    delegate.pasteObjects(payload, into: slide, in: presentation)
                    let pastedTables = Set(slide.items.compactMap(\.tableID)).subtracting([id])
                    let pastedTexts = slide.items.filter { $0.cellTextOf != nil && $0.cellTextOf != id }
                    print("  pasted: \(pastedTables.count) new table, \(pastedTexts.count) texts attached to it (\(pastedTexts.allSatisfy { pastedTables.contains($0.cellTextOf ?? "") })), original keeps \(slide.items.filter { $0.cellTextOf == id }.count)")
                    delegate.undo.undo()
                    print("  paste undone: tables \(Set(presentation.slides[slideIndex].items.compactMap(\.tableID)).count)")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
            if let saved = try? Presentation(url: URL(fileURLWithPath: arguments[0])) {
                let s = saved.slides[slideIndex]
                print("  saved file: order \(sequence(s))")
                print("  saved file: text boxes \(s.items.filter { $0.cellTextOf == id }.count), timing targets \(s.document.xmlString.components(separatedBy: "<p:spTgt").count - 1)")
            }
            if let current = slide.items.first(where: { $0.isTableCell && !$0.isTableFrame && $0.tableID == id }) { delegate.canvas.select(delegate.canvas.members(of: current)) }   // the undo re-read the slide
            delegate.toggleSelectedFade()
            print("  F again: \(sequence(slide).isEmpty ? "no effects on the table" : sequence(slide)); text boxes kept \(slide.items.filter { $0.cellTextOf == id }.count)")
            for _ in 0..<10 where delegate.undo.canUndo { delegate.undo.undo() }
            let restored = presentation.slides[slideIndex]
            print("  after undo: text boxes \(restored.items.filter { $0.cellTextOf == id }.count), cell texts back \(restored.items.filter { $0.tableID == id && !$0.isTableFrame }.map(\.text).filter { !$0.isEmpty } == cellTexts), picture differs by \(Self.differing(before, shot())) pixels")
            return
        }
        if ProcessInfo.processInfo.environment["BOLD"] != nil {   // ⌘B on selected text while editing; ⌘S and the sidebar buttons
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
            func shot(_ name: String) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                guard let content = delegate.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + "." + name + ".png"))
            }
            shot("open")
            func command(_ key: String) { _ = NSApp.mainMenu?.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: n, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!) }
            command("s"); print("  ⌘S: sidebar hidden \(delegate.sidebarHidden); toggle button still on screen at x \(Int(delegate.sidebarButton.frame.minX)), hidden \(delegate.sidebarButton.isHidden)"); shot("collapsed")
            command("s"); print("  ⌘S again: sidebar hidden \(delegate.sidebarHidden)")
            delegate.recentsButton.performClick(nil); print("  recent button: showing recents \(delegate.showingRecents)"); shot("recents")
            delegate.slidesButton.performClick(nil); print("  slides button: showing recents \(delegate.showingRecents)")
            command("1"); print("  ⌘1: showing recents \(delegate.showingRecents)"); shot("recents2")
            command("2"); print("  ⌘2: showing recents \(delegate.showingRecents)")
            command("1"); command("e"); print("  ⌘1 then ⌘E: showing recents \(delegate.showingRecents) (⌘E still toggles)"); if delegate.showingRecents { command("2") }
            print("  buttons: recent x \(Int(delegate.recentsButton.frame.minX)), slides x \(Int(delegate.slidesButton.frame.minX)), toggle x \(Int(delegate.sidebarButton.frame.minX)) (sidebar is 174 wide)")
            delegate.sidebarButton.performClick(nil); print("  toggle button: hidden \(delegate.sidebarHidden)"); delegate.sidebarButton.performClick(nil); print("  toggle button again: hidden \(delegate.sidebarHidden)")
            for _ in 0..<10 where delegate.undo.canUndo { delegate.undo.undo() }
            return
        }
        if ProcessInfo.processInfo.environment["GROW"] != nil {   // typing more text: the frame grows with it
            let slide = presentation.slides[slideIndex]
            _ = delegate.tidyDeck(presentation)
            for item in slide.items where item.canMove && item.fill == nil && !item.text.isEmpty {
                let before = item.frame
                delegate.canvas.selected = item; delegate.canvas.startEditing()
                delegate.canvas.editor?.insertText(" thêm rất nhiều chữ nữa để dòng này dài hơn hẳn khung cũ và phải xuống hàng thêm vài lần nữa cho chắc chắn", replacementRange: NSRange(location: (delegate.canvas.editor?.string as NSString?)?.length ?? 0, length: 0))
                delegate.canvas.finishEditing(commit: true)
                let layouts = layoutParagraphs(item)
                let bottom = (layouts.last.map { $0.origin.y + $0.height } ?? 0)
                print("  \(item.autoFit ? "auto-fit" : "fixed   ") \"\(item.text.prefix(12))\": \(Int(before.width))×\(Int(before.height)) -> \(Int(item.frame.width))×\(Int(item.frame.height)); text ends at \(Int(bottom)) (inside: \(bottom <= item.frame.height + 1))")
            }
            for _ in 0..<30 where delegate.undo.canUndo { delegate.undo.undo() }
            return
        }
        if ProcessInfo.processInfo.environment["GROUPS"] != nil {   // headings in the recent files list: create, drag files under them, collapse, remove
            let saved = (delegate.recentPresentations, delegate.recentGroups)
            defer { delegate.recentPresentations = saved.0; delegate.recentGroups = saved.1 }
            let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
            delegate.recentGroups = []
            delegate.recentPresentations = names.map { RecentPresentation(path: "/tmp/\($0).pptx", slide: 0) }
            let keys = names.map { RecentPresentation.key("/tmp/\($0).pptx") }
            func rows() -> String { delegate.sidebarRows.map { row -> String in
                switch row { case .heading(let g): return "[\(g.title)\(g.collapsed ? " +" : "")]"; case .file(let f, let indented): return (indented ? "  " : "") + f.url.deletingPathExtension().lastPathComponent
                case .add: return "(+)" } }.joined(separator: " | ") }
            delegate.showingRecents = true; delegate.updateRecentSidebar()
            print("  start: \(rows())")
            delegate.addSidebarHeading(nil)
            delegate.renameField?.stringValue = "Week 1"; delegate.finishRename(commit: true)
            delegate.addSidebarHeading(nil)
            delegate.renameField?.stringValue = "Week 2"; delegate.finishRename(commit: true)
            print("  two headings: \(rows())")
            func drop(_ value: String, row: Int, on: Bool = false) -> Bool { let ok = delegate.applyRecentDrop(value, row: row, operation: on ? .on : .above); delegate.updateRecentSidebar(); return ok }
            // Drag Bravo and Delta onto "Week 1" (dropped on the heading), Echo under "Week 2" (dropped just below it).
            let week1 = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.title == "Week 1" } else { return false } } ?? 0
            _ = drop("file:" + keys[1], row: week1, on: true)
            let week1b = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.title == "Week 1" } else { return false } } ?? 0
            _ = drop("file:" + keys[3], row: week1b, on: true)
            let week2 = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.title == "Week 2" } else { return false } } ?? 0
            _ = drop("file:" + keys[4], row: week2 + 1)
            print("  after drops: \(rows())")
            // Within a heading: Echo above ... (reorder inside Week 1: Delta above Bravo)
            let bravoRow = delegate.sidebarRows.firstIndex { if case .file(let f, _) = $0 { return f.key == keys[1] } else { return false } } ?? 0
            _ = drop("file:" + keys[3], row: bravoRow)
            print("  Delta above Bravo: \(rows())")
            // Back out of a heading: drop Delta at the very top of the list.
            _ = drop("file:" + keys[3], row: 0)
            print("  Delta back to the plain list: \(rows())")
            // Reorder headings: Week 2 above Week 1.
            let w2 = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.title == "Week 2" } else { return false } } ?? 0
            let w1 = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return g.title == "Week 1" } else { return false } } ?? 0
            _ = drop("group:" + (delegate.recentGroup(at: w2)?.id ?? ""), row: w1)
            print("  headings swapped: \(rows())")
            // Collapse / expand.
            let first = delegate.sidebarRows.firstIndex { if case .heading = $0 { return true } else { return false } } ?? 0
            let button = NSButton(); button.tag = first
            delegate.toggleGroup(button); print("  collapsed: \(rows())")
            if let live = (delegate.window.contentView.map { _ in delegate.table }) { _ = live }
            delegate.table.reloadData(); delegate.window.layoutIfNeeded()
            if let content = delegate.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) { content.cacheDisplay(in: content.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + ".groups.png")) }
            delegate.toggleGroup(button); print("  expanded: \(rows())")
            // The ✕ buttons show only while the pointer is over their row.
            delegate.updateRecentSidebar()
            func removeButtons(_ row: Int) -> [NSView] {
                func find(_ view: NSView) -> [NSView] { view.subviews.flatMap { ($0.identifier == HoverReveal.identifier ? [$0] : []) + find($0) } }
                return delegate.table.rowView(atRow: row, makeIfNecessary: true).map(find) ?? []
            }
            let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: delegate.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            let fileRow = delegate.sidebarRows.firstIndex { if case .file = $0 { return true } else { return false } } ?? 0
            let headingRow = delegate.sidebarRows.firstIndex { if case .heading = $0 { return true } else { return false } } ?? 0
            for (name, row) in [("file", fileRow), ("heading", headingRow)] {
                let buttons = removeButtons(row)
                let hidden = buttons.map(\.alphaValue)
                if let rowView = delegate.table.rowView(atRow: row, makeIfNecessary: true) { rowView.mouseEntered(with: hoverEvent) }
                let shown = buttons.map(\.alphaValue)
                if let rowView = delegate.table.rowView(atRow: row, makeIfNecessary: true) { rowView.mouseExited(with: hoverEvent) }
                print("  \(name) row ✕: \(buttons.count) button, hidden \(hidden), pointer over \(shown), pointer away \(buttons.map(\.alphaValue))")
            }
            // Filter: type to narrow the list to matching names (any case, any accents), flat, no headings.
            delegate.searchQuery = "ECHO"; delegate.updateRecentSidebar(); print("  filter ECHO: \(rows())")
            delegate.searchQuery = "xyz"; delegate.updateRecentSidebar(); print("  filter xyz: \(rows()) (empty text shown: \(!delegate.emptyRecents.isHidden), \"\(delegate.emptyRecents.stringValue)\")")
            delegate.searchQuery = ""; delegate.updateRecentSidebar()
            // Pin: pinned files lead the plain list; unpin puts it back.
            delegate.togglePin(keys[2]); print("  pinned Charlie: \(rows())")
            delegate.togglePin(keys[2]); print("  unpinned: \(rows())")
            // Move to heading from the menu, and out again.
            let weekA = delegate.recentGroups.first?.id ?? ""
            delegate.moveRecent(keys[0], toGroup: weekA); print("  Alpha moved under \(delegate.recentGroups.first?.title ?? "?"): \(rows())")
            delegate.moveRecent(keys[0], toGroup: nil); print("  Alpha moved out: \(rows())")
            // Right-click menus.
            let menu = NSMenu()
            delegate.fillSidebarMenu(menu, row: fileRow); print("  file menu: \(menu.items.map { $0.isSeparatorItem ? "-" : $0.title })")
            if let move = menu.items.first(where: { $0.title == "Move to Heading" }) { print("  move submenu: \(move.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [])") }
            delegate.fillSidebarMenu(menu, row: headingRow); print("  heading menu: \(menu.items.map { $0.isSeparatorItem ? "-" : $0.title })")
            delegate.fillSidebarMenu(menu, row: delegate.sidebarRows.count - 1); print("  menu on the + row: \(menu.items.count) items")
            // Keyboard: ← folds the selected heading, → opens it, Return folds / opens too; ← on a file steps up to its heading.
            func arrow(_ code: UInt16) -> Bool { delegate.sidebarKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: delegate.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!) }
            let h = delegate.sidebarRows.firstIndex { if case .heading(let g) = $0 { return !g.collapsed && !g.keys.isEmpty } else { return false } } ?? 0
            delegate.table.selectRowIndexes(IndexSet(integer: h), byExtendingSelection: false)
            _ = arrow(123); print("  ←: \(rows())")
            _ = arrow(124); print("  →: \(rows())")
            delegate.table.selectRowIndexes(IndexSet(integer: h), byExtendingSelection: false); delegate.activateSelectedSidebarRow(); print("  Return on heading: \(rows())")
            delegate.table.selectRowIndexes(IndexSet(integer: delegate.sidebarRows.firstIndex { if case .heading = $0 { return true } else { return false } } ?? 0), byExtendingSelection: false); delegate.activateSelectedSidebarRow()
            delegate.collapseAllHeadings(); print("  collapse all: \(rows())")
            delegate.expandAllHeadings(); print("  expand all: \(rows())")
            // Width: drag the divider; limits hold.
            let before = delegate.sidebarWidth
            delegate.setSidebarWidth(260); delegate.window.layoutIfNeeded()
            let wide = delegate.table.enclosingScrollView?.frame.width ?? 0
            delegate.setSidebarWidth(50); delegate.window.layoutIfNeeded()
            let narrow = delegate.table.enclosingScrollView?.frame.width ?? 0
            delegate.setSidebarWidth(900); delegate.window.layoutIfNeeded()
            print("  width: \(Int(before)) -> \(Int(wide)) (asked 260), \(Int(narrow)) (asked 50), \(Int(delegate.table.enclosingScrollView?.frame.width ?? 0)) (asked 900); saved \(UserDefaults.standard.double(forKey: "sidebarWidth"))")
            delegate.setSidebarWidth(before)
            // Dates on the right.
            let now = Date(); let cal = Calendar.current
            print("  dates: today \(AppDelegate.shortDate(now)), 2 days \(AppDelegate.shortDate(cal.date(byAdding: .day, value: -2, to: now)!)), 10 days \(AppDelegate.shortDate(cal.date(byAdding: .day, value: -10, to: now)!)), last year \(AppDelegate.shortDate(cal.date(byAdding: .year, value: -1, to: now)!))")
            // Persisted, and the file list itself is untouched.
            print("  saved headings: \(delegate.recentGroups.map { "\($0.title)=\($0.keys.count)" }), recent files still \(delegate.recentPresentations.count)")
            // Renaming a file under a heading keeps it there; removing a file takes it out of the heading.
            let victim = RecentPresentation.key("/tmp/Bravo.pptx"); delegate.replaceGroupKey(victim, with: RecentPresentation.key("/tmp/Bravo2.pptx"))
            print("  renamed key follows: \(delegate.recentGroups.flatMap(\.keys).contains(RecentPresentation.key("/tmp/Bravo2.pptx"))), old gone: \(!delegate.recentGroups.flatMap(\.keys).contains(victim))")
            // More than 20 files: the ones under a heading are kept.
            let many = (0..<30).map { RecentPresentation(path: "/tmp/F\($0).pptx", slide: 0) } + delegate.recentPresentations
            let trimmed = delegate.trimmedRecents(many)
            print("  trim: \(trimmed.count) kept of \(many.count); grouped kept: \(delegate.recentGroups.flatMap(\.keys).filter { key in many.contains { $0.key == key } }.allSatisfy { key in trimmed.contains { $0.key == key } })")
            // A picture of the list with real files (dates), a heading, the open file and a hovered row.
            let decks = [".fixtures/deck1.pptx", ".fixtures/deck2.pptx"].map { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent($0).path }
            delegate.recentGroups = [RecentGroup(id: "g", title: "Buổi học", collapsed: false, keys: [RecentPresentation.key(decks[1])])]
            delegate.recentPresentations = [RecentPresentation(path: arguments[0], slide: 0), RecentPresentation(path: decks[0], slide: 0), RecentPresentation(path: decks[1], slide: 0), RecentPresentation(path: "/tmp/Một tên file rất dài để thử cắt đuôi bằng dấu ba chấm.pptx", slide: 0)]
            delegate.pinnedKeys = [RecentPresentation.key(decks[0])]
            delegate.setSidebarWidth(230); delegate.updateRecentSidebar(); delegate.window.layoutIfNeeded()
            delegate.table.rowView(atRow: 2, makeIfNecessary: true)?.mouseEntered(with: hoverEvent)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if let content = delegate.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) { content.cacheDisplay(in: content.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[0] + ".sidebar.png")) }
            delegate.pinnedKeys = []; delegate.setSidebarWidth(174)
            // Removing a heading sends its files back to the plain list.
            let removeButton = NSButton(); removeButton.tag = first
            delegate.recentGroups = delegate.recentGroups.filter { $0.id != delegate.recentGroup(at: first)?.id }; delegate.updateRecentSidebar()
            print("  heading removed: \(rows())")
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
}
#endif
