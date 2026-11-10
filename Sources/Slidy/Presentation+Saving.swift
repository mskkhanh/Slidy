import AppKit
import ArchiveBridge

/// Writing the Fade timing and saving the .pptx.
extension Presentation {
    func writeTiming(_ slide: Slide) {
        guard !slide.originalTiming || slide.timingDirty else { return }
        let root = slide.document.rootElement()!
        root.child("timing")?.detach()
        let steps = slide.fadeSequence
        guard !steps.isEmpty else { return }
        var effects = "", id = 3
        for step in steps {
            effects += """
            <p:par><p:cTn id="\(id)" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>
            <p:par><p:cTn id="\(id+1)" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
            """
            id += 2
            for (index, entry) in step.enumerated() {
                let (item, paragraph) = entry
                let target = "<p:tgtEl><p:spTgt spid=\"\(item.id)\">" + (paragraph.map { "<p:txEl><p:pRg st=\"\($0)\" end=\"\($0)\"/></p:txEl>" } ?? "") + "</p:spTgt></p:tgtEl>"
                let nodeType = index == 0 ? "clickEffect" : "withEffect"
                effects += """
                <p:par><p:cTn id="\(id)" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" nodeType="\(nodeType)" grpId="0"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
                <p:set><p:cBhvr><p:cTn id="\(id+1)" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\(target)<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>
                <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="\(id+2)" dur="\(Int((item.fadeDuration(for: paragraph) * 1000).rounded()))"/>\(target)</p:cBhvr></p:animEffect>
                </p:childTnLst></p:cTn></p:par>
                """
                id += 3
            }
            effects += "</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>"
        }
        let timing = fragment("""
        <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst><p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\(effects)</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
        """)
        let builds = slide.fadeGroups.flatMap { $0 }.filter { $0.textBody != nil }.map {
            "<p:bldP spid=\"\($0.id)\" grpId=\"0\" build=\"\($0.fadesByParagraph ? "p" : "allAtOnce")\" uiExpand=\"1\" animBg=\"0\"/>"
        }.joined()
        if !builds.isEmpty { timing.addChild(fragment("<p:bldLst>\(builds)</p:bldLst>")) }
        if let ext = root.child("extLst"), let index = root.children?.firstIndex(of: ext) { root.insertChild(timing, at: index) }
        else { root.addChild(timing) }
    }
    /// Writes the edits back into the original file (atomic replace; no backup copy is made).
    func saveInPlace() throws {
        // Never overwrite changes made to the file by another app (PowerPoint, a sync tool...) since it was opened.
        if let stamp = sourceStamp, let now = Self.modificationDate(of: source), now != stamp {
            throw AppError.message("The file was changed outside Slidy, so Slidy won’t overwrite it. Use File > Save a Copy… to keep your changes, then reopen the file.")
        }
        try save(to: source, allowOverwrite: true)
        sourceStamp = Self.modificationDate(of: source)
    }
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    func save(to destination: URL, allowOverwrite: Bool = false) throws {
        guard allowOverwrite || destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
            throw AppError.message("Choose a different name for the copy.")
        }
        if orderDirty {
            try (try part("ppt/presentation.xml")).xmlData.write(to: folder.appendingPathComponent("ppt/presentation.xml"), options: .atomic)
            orderDirty = false
        }
        for slide in slides {
            writeTiming(slide)
            let data = slide.document.xmlData
            if data != slide.writtenXML {
                try data.write(to: folder.appendingPathComponent(slide.path), options: .atomic)
                slide.writtenXML = data
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Slidy-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var error = [CChar](repeating: 0, count: 1024)
        guard sp_pack(folder.path, temporary.path, &error, Int32(error.count)) == 0 else { throw AppError.message(String(cString: error)) }
        // Same-directory rename provides an atomic replacement, including on retry.
        // replaceItemAt swaps the file atomically and keeps its permissions, tags and creation date.
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch { throw AppError.message("Can’t save the file to that location.") }
    }
}
