import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.19, green: 0.35, blue: 0.29, alpha: 1).setFill()
background.fill()

let page = NSBezierPath(roundedRect: NSRect(x: 236, y: 156, width: 552, height: 712), xRadius: 34, yRadius: 34)
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.94, alpha: 1).setFill()
page.fill()

let hash = "#" as NSString
let hashAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 224, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.16, alpha: 1)
]
hash.draw(at: NSPoint(x: 312, y: 520), withAttributes: hashAttributes)

let threadColor = NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.33, alpha: 1)
threadColor.setStroke()
threadColor.setFill()

let line = NSBezierPath()
line.lineWidth = 15
line.lineCapStyle = .round
line.move(to: NSPoint(x: 356, y: 356))
line.curve(to: NSPoint(x: 658, y: 310), controlPoint1: NSPoint(x: 438, y: 358), controlPoint2: NSPoint(x: 528, y: 270))
line.stroke()

for point in [NSPoint(x: 350, y: 356), NSPoint(x: 508, y: 318), NSPoint(x: 664, y: 310)] {
    NSBezierPath(ovalIn: NSRect(x: point.x - 23, y: point.y - 23, width: 46, height: 46)).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
