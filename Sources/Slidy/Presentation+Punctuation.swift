import AppKit

// The wand ends every sentence with a period: headings, single sentences and each row of a list.
extension Presentation {
    /// True for a line that reads as a sentence with no closing mark. Labels are left alone: all-capital eyebrows, one- to three-word
    /// titles, lines with "·" "|" "→", links and addresses, numbers, and lines that already end with punctuation.
    static func needsPeriod(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = line.last else { return false }
        guard last.isLetter || last.isNumber || last == ")" || last == "%" else { return false }   // . ! ? … : ; , quotes and the like end it already
        let letters = line.filter(\.isLetter)
        guard letters.count >= 3, letters != letters.uppercased() else { return false }              // an all-capital eyebrow
        guard line.split(whereSeparator: \.isWhitespace).count >= 4 else { return false }            // a short title or label
        for mark in ["·", "|", "→", "://", "@", "www."] where line.contains(mark) { return false }
        return true
    }
    private func sentenceRuns(_ paragraph: XMLElement) -> [XMLElement] {
        paragraph.elements.filter { ["r", "br", "fld"].contains($0.localName ?? "") }
    }
    /// The paragraphs of a text object that would get a period.
    private func paragraphsNeedingPeriod(_ item: SlideItem) -> [XMLElement] {
        guard item.canMove, !item.isTableCell, item.cellTextOf == nil, !item.inherited, let body = item.textBody else { return [] }
        return body.all("p").filter { paragraph in
            let runs = sentenceRuns(paragraph)
            guard let last = runs.last, last.localName == "r", last.child("t") != nil else { return false }
            return Self.needsPeriod(runs.map { $0.localName == "br" ? "\n" : ($0.child("t")?.textContent ?? "") }.joined())
        }
    }
    func periodsToAdd(in item: SlideItem) -> Int { paragraphsNeedingPeriod(item).count }
    /// Adds the periods; the formatting of the line stays (the period joins the last run). Returns how many lines got one.
    @discardableResult
    func addSentencePeriods(_ item: SlideItem) -> Int {
        let paragraphs = paragraphsNeedingPeriod(item)
        for paragraph in paragraphs {
            guard let t = sentenceRuns(paragraph).last?.child("t") else { continue }
            let value = t.textContent
            let trimmed = String(value.reversed().drop(while: { $0.isWhitespace }).reversed())   // the period goes right after the last word
            t.stringValue = trimmed + "."
        }
        if !paragraphs.isEmpty { configureText(item); fitFrame(item) }
        return paragraphs.count
    }
}
