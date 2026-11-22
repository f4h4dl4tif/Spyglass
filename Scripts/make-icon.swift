import AppKit
// Spyglass icon: deep teal squircle, a white folder, and a brass spyglass lens peeking over it.
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.72, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.48, alpha: 1)])!.draw(in: bg, angle: -90)
// soft top highlight
NSGraphicsContext.saveGraphicsState(); bg.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()
// folder
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 610, width: 250, height: 90), xRadius: 34, yRadius: 34).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 250, width: 564, height: 410), xRadius: 46, yRadius: 46).fill()
NSGraphicsContext.restoreGraphicsState()
// lens
let c = NSPoint(x: 600, y: 470), r: CGFloat = 150
NSGraphicsContext.saveGraphicsState(); shadow.set()
let handle = NSBezierPath(); handle.move(to: NSPoint(x: c.x + r * 0.62, y: c.y - r * 0.62)); handle.line(to: NSPoint(x: c.x + r * 1.55, y: c.y - r * 1.5))
handle.lineWidth = 64; handle.lineCapStyle = .round
NSColor(calibratedRed: 0.80, green: 0.55, blue: 0.20, alpha: 1).setStroke(); handle.stroke()
let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.28, alpha: 1).setFill(); ring.fill()
NSGraphicsContext.restoreGraphicsState()
let glass = NSBezierPath(ovalIn: NSRect(x: c.x - r + 30, y: c.y - r + 30, width: 2 * r - 60, height: 2 * r - 60))
NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.88, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.48, blue: 0.66, alpha: 1)])!.draw(in: glass, angle: -60)
NSColor.white.withAlphaComponent(0.85).setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 70, y: c.y + 20, width: 56, height: 56)).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
