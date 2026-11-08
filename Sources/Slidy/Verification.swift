#if DEBUG
import AppKit
// Headless verification uses the same parser, editor, exporter and renderer as the UI.
enum Verification {
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
            print("PASS text, Vietnamese, line breaks, list insertion, geometry, image, save/reopen, \(expected) fade steps, back navigation")
        } catch { fputs("Verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

#endif
