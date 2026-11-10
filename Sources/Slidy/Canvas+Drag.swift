import AppKit
import CoreText
import QuartzCore

/// Selecting, dragging, resizing and snapping objects with the mouse.
extension CanvasView {
    func resizeCorners(for item: SlideItem) -> [CGPoint] {
        let lowerRight = CGPoint(x: item.frame.maxX, y: item.frame.maxY)
        guard item.imageURL != nil else { return [lowerRight] }
        return [
            CGPoint(x: item.frame.minX, y: item.frame.minY),
            CGPoint(x: item.frame.maxX, y: item.frame.minY),
            CGPoint(x: item.frame.minX, y: item.frame.maxY),
            lowerRight
        ]
    }
    /// The handle under `point`, if any. The grab area is much larger than the handle you see (14 screen points around it)
    /// and reaches outside the object, so a handle is easy to catch.
    func resizeHandle(at point: CGPoint, for item: SlideItem) -> CGPoint? {
        let radius: CGFloat = 14 / surfaceScale
        return resizeCorners(for: item)
            .filter { abs(point.x - $0.x) <= radius && abs(point.y - $0.y) <= radius }
            .min { hypot(point.x - $0.x, point.y - $0.y) < hypot(point.x - $1.x, point.y - $1.y) }
    }
    /// A plain click on the handle of the single selected object starts a resize, whichever view received the click.
    func beginResizeIfOnHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty,
              selection.count == 1, let item = selected, item.canMove, editor == nil, !presenting else { return false }
        let point = surface.convert(event.locationInWindow, from: nil)
        guard let corner = resizeHandle(at: point, for: item) else { return false }
        window?.makeFirstResponder(self)
        dragOrigin = point; dragItem = item; originalFrame = item.frame; editedDrag = false
        dragFrames = [:]; dragTables = []; pendingCollapse = nil; resizeCorner = corner
        return true
    }
    func backgroundClick(_ event: NSEvent) {
        if presenting { advance(); return }
        if cropItem != nil { cropMouseDown(event); return }
        if beginResizeIfOnHandle(event) { return }
        finishEditing(commit: true)
        window?.makeFirstResponder(self)
        guard event.type == .leftMouseDown else { return }
        marqueeBase = event.modifierFlags.contains(.shift) ? selection.filter(\.canMove) : []
        select(marqueeBase)
        marqueeStart = surface.convert(event.locationInWindow, from: nil)
    }
    func updateMarquee(_ event: NSEvent) {
        guard let start = marqueeStart, let slide else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        let existing = Set(marqueeBase.map(ObjectIdentifier.init))
        select(slide.items.filter { $0.canMove && (existing.contains(ObjectIdentifier($0)) || area.contains($0.frame)) })
        overlay.marquee = area; overlay.lineWidth = 1 / surfaceScale; overlay.needsDisplay = true
    }
    func endMarquee() {
        guard marqueeStart != nil else { return }
        marqueeStart = nil
        marqueeBase = []
        overlay.marquee = nil; overlay.needsDisplay = true
    }
    func objectMouseDown(_ view: ObjectView, event: NSEvent) {
        if presenting { advance(); return }
        if cropItem != nil { cropMouseDown(event); return }
        if beginResizeIfOnHandle(event) { return }
        finishEditing(commit: true)
        guard !view.item.inherited else { backgroundClick(event); return }
        window?.makeFirstResponder(self)
        dragOrigin = nil
        if event.type == .leftMouseDown, !event.modifierFlags.intersection([.shift, .command]).isEmpty {
            guard view.item.canMove || view.item.isTableCell else { return }
            let group = members(of: view.item)
            let present = selection.contains { $0 === view.item }
            select(present ? selection.filter { chosen in !group.contains { $0 === chosen } } : selection + group)
            return
        }
        let point = surface.convert(event.locationInWindow, from: nil)
        var target = view.item
        // ⌥-click picks the object underneath (e.g. the card behind its text); repeat to go deeper.
        if event.modifierFlags.contains(.option), let slide {
            let stack = slide.items.filter { $0.canMove && $0.frame.contains(point) }.reversed()
            let order = Array(stack)
            if let current = selected, let position = order.firstIndex(where: { $0 === current }) { target = order[(position + 1) % order.count] }
            else if order.count > 1 { target = order[1] }
        }
        if event.clickCount == 2, target.imageURL != nil, target.canMove, !event.modifierFlags.contains(.option) {
            select([target]); startCrop(target); return   // double-click on a picture crops it
        }
        // A plain click on one of several selected objects keeps the selection so they can be dragged together;
        // releasing without a drag then narrows the selection to the clicked object.
        let keepsMultiSelection = selection.count > 1 && selection.contains { $0 === target } && !event.modifierFlags.contains(.option)
        if !keepsMultiSelection { select(members(of: target)) }   // a click on a table cell selects the whole table
        pendingCollapse = keepsMultiSelection ? target : nil
        if event.clickCount == 2 && target.textBody != nil { selected = target; pendingCollapse = nil; startEditing(at: point); return }
        guard target.canMove || target.isTableCell else { return }
        dragOrigin = point; dragItem = target; originalFrame = target.frame; editedDrag = false
        // Several objects, or a table (all its cells), are dragged together from their starting frames.
        let movesTogether = keepsMultiSelection || target.isTableCell || (target.cellTextOf != nil && selection.count > 1)
        let moving = selection.filter { $0.canMove || $0.isTableCell }
        dragFrames = movesTogether ? Dictionary(uniqueKeysWithValues: moving.map { (ObjectIdentifier($0), $0.frame) }) : [:]
        dragTables = []
        var seenTables = Set<ObjectIdentifier>()
        for cell in moving { if let table = cell.tableNode, seenTables.insert(ObjectIdentifier(table)).inserted, let off = table.child("xfrm")?.child("off") { dragTables.append((table, off.number("x"), off.number("y"))) } }
        resizeCorner = movesTogether ? nil : resizeHandle(at: point, for: target)
    }
    func objectMouseDragged(_ view: ObjectView, event: NSEvent) { continueDrag(event) }
    func continueDrag(_ event: NSEvent) {
        if cropItem != nil { cropMouseDragged(event); return }
        if marqueeStart != nil { updateMarquee(event); return }
        guard let start = dragOrigin, let item = dragItem, let host = objectViews.first(where: { $0.item === item }), editor == nil, !presenting else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        guard abs(dx) + abs(dy) > 0.5 else { return }
        if !editedDrag { onWillEdit?(); editedDrag = true }
        if !dragFrames.isEmpty {   // several selected objects move together
            var dx = dx, dy = dy
            if !event.modifierFlags.contains(.command), let first = dragFrames.values.first {
                let union = dragFrames.values.dropFirst().reduce(first) { $0.union($1) }.offsetBy(dx: dx, dy: dy)
                let snap = snapped(union, excluding: Set(dragFrames.keys))
                dx += snap.dx; dy += snap.dy; overlay.guides = snap.guides
            } else { overlay.guides = [] }
            for moved in selection where moved.canMove || moved.isTableCell {
                guard var frame = dragFrames[ObjectIdentifier(moved)] else { continue }
                frame.origin.x += dx; frame.origin.y += dy
                if moved.isTableCell { moved.frame = frame } else { moved.updateFrame(frame) }   // cells live inside the table's own frame
                objectViews.first { $0.item === moved }?.frame = frame
            }
            for table in dragTables {
                guard let off = table.node.child("xfrm")?.child("off") else { continue }
                off.set("x", String(Int(table.x + Double(dx) * emu))); off.set("y", String(Int(table.y + Double(dy) * emu)))
            }
            updateSelection(); updateOrderBadges()
            return
        }
        var frame = originalFrame
        if let corner = resizeCorner {
            if item.imageURL != nil {
                let left = corner.x == originalFrame.minX
                let top = corner.y == originalFrame.minY
                let dw = (left ? -dx : dx) / originalFrame.width
                let dh = (top ? -dy : dy) / originalFrame.height
                let delta = abs(dw) >= abs(dh) ? dw : dh
                let scale = max(30 / originalFrame.width, 24 / originalFrame.height, 1 + delta)
                frame.size = CGSize(width: originalFrame.width * scale, height: originalFrame.height * scale)
                if left { frame.origin.x = originalFrame.maxX - frame.width }
                if top { frame.origin.y = originalFrame.maxY - frame.height }
            } else {
                frame.size.width = max(30, originalFrame.width + dx)
                frame.size.height = max(24, originalFrame.height + dy)
            }
            if !event.modifierFlags.contains(.command) {
                frame = snapResize(frame, original: originalFrame, corner: corner, isImage: item.imageURL != nil, item: item)
            } else { overlay.guides = [] }
        } else {
            frame.origin.x += dx; frame.origin.y += dy
            if !event.modifierFlags.contains(.command) {
                let snap = snapped(frame, excluding: [ObjectIdentifier(item)])
                frame.origin.x += snap.dx; frame.origin.y += snap.dy; overlay.guides = snap.guides
            } else { overlay.guides = [] }
        }
        item.updateFrame(frame); host.frame = frame; updateSelection()
        updateOrderBadges()   // the Fade number travels with the object while it is dragged or resized
    }
    /// Edges and centres that dragged or resized objects snap to: the other objects and the slide itself.
    func snapTargets(excluding: Set<ObjectIdentifier>) -> [CGRect] {
        guard let slide, let presentation else { return [] }
        var targets = slide.items.filter { !excluding.contains(ObjectIdentifier($0)) && !$0.inherited && $0.frame.width > 0 }.map(\.frame)
        targets.append(CGRect(origin: .zero, size: presentation.size))
        return targets
    }
    static func xs(_ r: CGRect) -> [CGFloat] { [r.minX, r.midX, r.maxX] }
    static func ys(_ r: CGRect) -> [CGFloat] { [r.minY, r.midY, r.maxY] }
    /// The smallest move (within 6 screen points) that puts one of `values` on a target line, or nil.
    func nearestSnap(_ values: [CGFloat], targets: [[CGFloat]]) -> CGFloat? {
        let threshold = 6 / surfaceScale
        var result: CGFloat?
        for line in targets { for target in line { for value in values {
            let delta = target - value
            if abs(delta) <= threshold, result == nil || abs(delta) < abs(result!) { result = delta }
        } } }
        return result
    }
    /// Guide lines for every edge or centre of `rect` that sits exactly on an edge or centre of a target.
    func guideLines(for rect: CGRect, targets: [CGRect]) -> [(CGPoint, CGPoint)] {
        var guides: [(CGPoint, CGPoint)] = []
        for target in targets {
            for value in Self.xs(target) where Self.xs(rect).contains(where: { abs($0 - value) < 0.5 }) {
                guides.append((CGPoint(x: value, y: min(rect.minY, target.minY)), CGPoint(x: value, y: max(rect.maxY, target.maxY))))
            }
            for value in Self.ys(target) where Self.ys(rect).contains(where: { abs($0 - value) < 0.5 }) {
                guides.append((CGPoint(x: min(rect.minX, target.minX), y: value), CGPoint(x: max(rect.maxX, target.maxX), y: value)))
            }
        }
        return guides
    }
    /// Smart guides while moving: snaps a rectangle and returns the guide lines. Hold ⌘ to move freely.
    func snapped(_ rect: CGRect, excluding: Set<ObjectIdentifier>) -> (dx: CGFloat, dy: CGFloat, guides: [(CGPoint, CGPoint)]) {
        let targets = snapTargets(excluding: excluding)
        let dx = nearestSnap(Self.xs(rect), targets: targets.map(Self.xs)) ?? 0
        let dy = nearestSnap(Self.ys(rect), targets: targets.map(Self.ys)) ?? 0
        return (dx, dy, guideLines(for: rect.offsetBy(dx: dx, dy: dy), targets: targets))
    }
    /// Smart guides while resizing: the edge being dragged snaps to other objects and the slide.
    func snapResize(_ frame: CGRect, original: CGRect, corner: CGPoint, isImage: Bool, item: SlideItem) -> CGRect {
        let targets = snapTargets(excluding: [ObjectIdentifier(item)])
        let txs = targets.map(Self.xs), tys = targets.map(Self.ys)
        var frame = frame
        if !isImage {   // text and shapes grow from the bottom-right handle
            if let d = nearestSnap([frame.maxX], targets: txs) { frame.size.width = max(30, frame.width + d) }
            if let d = nearestSnap([frame.maxY], targets: tys) { frame.size.height = max(24, frame.height + d) }
        } else {        // images keep their proportions: snap the dragged corner on one axis and rescale
            let left = corner.x == original.minX, top = corner.y == original.minY
            var factor: CGFloat?
            if let d = nearestSnap([left ? frame.minX : frame.maxX], targets: txs) { factor = (frame.width + (left ? -d : d)) / frame.width }
            if let d = nearestSnap([top ? frame.minY : frame.maxY], targets: tys) {
                let other = (frame.height + (top ? -d : d)) / frame.height
                if factor == nil || abs(other - 1) < abs(factor! - 1) { factor = other }
            }
            if let factor, factor > 0.05 {
                frame.size = CGSize(width: frame.width * factor, height: frame.height * factor)
                if left { frame.origin.x = original.maxX - frame.width }
                if top { frame.origin.y = original.maxY - frame.height }
            }
        }
        overlay.guides = guideLines(for: frame, targets: targets)
        return frame
    }
    func objectMouseUp(_ view: ObjectView, event: NSEvent) { finishDrag() }
    func finishDrag() {
        if cropItem != nil { cropDrag = nil; return }
        overlay.guides = []; overlay.needsDisplay = true
        endMarquee()
        if !editedDrag, let clicked = pendingCollapse { select(members(of: clicked)) }
        pendingCollapse = nil; dragFrames = [:]; dragTables = []
        dragOrigin = nil
        if editedDrag { editedDrag = false; rebuild(); onChanged?() }
    }
}
