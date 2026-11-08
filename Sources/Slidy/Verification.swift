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
                    let glyph = item.paragraphs[0].bullet == nil ? 0 : manager.glyphIndexForCharacter(at: 2)
                    let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let location = manager.location(forGlyphAt: glyph)
                    let editorX = editor.textContainerOrigin.x + rect.minX + location.x
                    let editorY = editor.textContainerOrigin.y + rect.minY
                    let shownRect = layout.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    let shownX = layout.origin.x + shownRect.minX + layout.manager.location(forGlyphAt: 0).x
                    let shownY = layout.origin.y + shownRect.minY
                    let existingBullets = Set(item.paragraphs.indices.filter { item.paragraphs[$0].bullet != nil })
                    guard editor.plainText == item.text, editor.bulletRows == existingBullets else {
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
            print("Fade persistence: \(timingChecked) slides re-read from the saved file with identical order, groups and valid timing XML")
            print("PASS text, Vietnamese, line breaks, list insertion, geometry, image, save/reopen, \(expected) fade steps, back navigation")
        } catch { fputs("Verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

#endif
