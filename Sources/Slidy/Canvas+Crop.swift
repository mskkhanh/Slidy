import AppKit
import CoreText
import QuartzCore

/// Crop mode for pictures (double-click a picture).
extension CanvasView {
    // MARK: Crop mode
    /// Double-click on a picture: shows the whole picture dimmed with a crop frame; drag its handles, Return applies, Esc cancels.
    func startCrop(_ item: SlideItem) {
        guard let presentation, let image = presentation.image(for: item), item.imageURL != nil, item.canMove, editor == nil, !presenting else { return }
        let inset = item.imageCrop
        let fullWidth = item.frame.width / max(0.05, 1 - inset.left - inset.right), fullHeight = item.frame.height / max(0.05, 1 - inset.top - inset.bottom)
        cropItem = item; cropOriginalFrame = item.frame; cropOriginalInsets = inset
        overlay.cropImage = image
        overlay.cropFull = CGRect(x: item.frame.minX - inset.left * fullWidth, y: item.frame.minY - inset.top * fullHeight, width: fullWidth, height: fullHeight)
        overlay.cropRect = item.frame
        overlay.cropHandleSize = 10 / surfaceScale
        updateSelection()
    }
    func exitCrop() {
        cropItem = nil; cropDrag = nil
        overlay.cropImage = nil; overlay.needsDisplay = true
        updateSelection()
    }
    func cancelCrop() { exitCrop() }
    /// Applies the crop: the visible part keeps its size and place; the cut sides become <a:srcRect>.
    func commitCrop() {
        guard let item = cropItem else { return }
        let full = overlay.cropFull, rect = overlay.cropRect
        guard abs(rect.minX - cropOriginalFrame.minX) > 0.2 || abs(rect.minY - cropOriginalFrame.minY) > 0.2
                || abs(rect.width - cropOriginalFrame.width) > 0.2 || abs(rect.height - cropOriginalFrame.height) > 0.2 else { exitCrop(); return }
        let insets = NSEdgeInsets(top: (rect.minY - full.minY) / full.height, left: (rect.minX - full.minX) / full.width,
                                  bottom: (full.maxY - rect.maxY) / full.height, right: (full.maxX - rect.maxX) / full.width)
        onWillEdit?()
        presentation?.setImageCrop(item, insets)
        item.updateFrame(rect)
        exitCrop()
        rebuild(); onChanged?()
    }
    func cropMouseDown(_ event: NSEvent) {
        let point = surface.convert(event.locationInWindow, from: nil)
        let reach = 14 / surfaceScale
        let near = CropHandles.list(of: overlay.cropRect).filter { abs($0.point.x - point.x) <= reach && abs($0.point.y - point.y) <= reach }
            .min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }
        cropDrag = near.map { ($0.edges, point, overlay.cropRect) }
    }
    func cropMouseDragged(_ event: NSEvent) {
        guard let drag = cropDrag else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        let full = overlay.cropFull, start = drag.rect, minSize: CGFloat = 24
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
        var rect = start
        if drag.edges.contains(.left) { let x = clamp(start.minX + dx, full.minX, start.maxX - minSize); rect.origin.x = x; rect.size.width = start.maxX - x }
        if drag.edges.contains(.right) { rect.size.width = clamp(start.width + dx, minSize, full.maxX - start.minX) }
        if drag.edges.contains(.top) { let y = clamp(start.minY + dy, full.minY, start.maxY - minSize); rect.origin.y = y; rect.size.height = start.maxY - y }
        if drag.edges.contains(.bottom) { rect.size.height = clamp(start.height + dy, minSize, full.maxY - start.minY) }
        overlay.cropRect = rect; overlay.needsDisplay = true
    }
    /// Test hook: the crop frame can be set directly.
    var cropFrame: CGRect { get { overlay.cropRect } set { overlay.cropRect = newValue; overlay.needsDisplay = true } }
}
