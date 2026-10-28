import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(srgbRed: 0.17, green: 0.34, blue: 0.73, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
NSColor(srgbRed: 1, green: 0.965, blue: 0.80, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 215, y: 192, width: 595, height: 630), xRadius: 48, yRadius: 48).fill()
NSColor(srgbRed: 0.19, green: 0.31, blue: 0.52, alpha: 0.65).setStroke()
for y in stride(from: 335, through: 630, by: 98) {
    let path = NSBezierPath()
    path.lineWidth = 30
    path.lineCapStyle = .round
    path.move(to: NSPoint(x: 306, y: y)); path.line(to: NSPoint(x: 716, y: y)); path.stroke()
}
NSColor(srgbRed: 0.86, green: 0.89, blue: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 455, y: 690, width: 112, height: 232), xRadius: 38, yRadius: 38).fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
