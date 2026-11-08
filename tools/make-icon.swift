import AppKit

// Draws the Slidy app icon (1024x1024 PNG): pure black rounded square with one thin-line slide.
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
NSColor.black.setFill()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()

// One thin-line slide (16:10) with a short title stroke.
let slide = NSRect(x: 512 - 250, y: 512 - 156, width: 500, height: 312)
let frame = NSBezierPath(roundedRect: slide, xRadius: 28, yRadius: 28)
frame.lineWidth = 18
NSColor.white.setStroke(); frame.stroke()
let title = NSBezierPath()
title.lineWidth = 18; title.lineCapStyle = .round
title.move(to: NSPoint(x: slide.minX + 70, y: slide.maxY - 80))
title.line(to: NSPoint(x: slide.minX + 230, y: slide.maxY - 80))
title.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
