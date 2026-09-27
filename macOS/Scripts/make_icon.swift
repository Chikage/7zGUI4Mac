import AppKit

// Code-native artwork: a compact archive monogram and a zipper track.
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 206, yRadius: 206)
let gradient = NSGradient(starting: NSColor.systemBlue, ending: NSColor(red: 0.05, green: 0.22, blue: 0.62, alpha: 1))
gradient?.draw(in: background, angle: -70)
let title: NSString = "7z"
title.draw(
    at: NSPoint(x: 170, y: 285),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 385, weight: .bold),
        .foregroundColor: NSColor.white,
        .kern: -24,
    ])
NSColor.white.withAlphaComponent(0.24).setFill()
NSBezierPath(rect: NSRect(x: 720, y: 70, width: 82, height: 880)).fill()
for index in 0..<11 {
    NSColor.white.withAlphaComponent(0.9).setFill()
    let x = index.isMultiple(of: 2) ? 713 : 753
    NSBezierPath(roundedRect: NSRect(x: x, y: 130 + index * 67, width: 55, height: 38), xRadius: 8, yRadius: 8).fill()
}
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 698, y: 724, width: 124, height: 157), xRadius: 32, yRadius: 32).fill()
NSColor.systemBlue.setFill()
NSBezierPath(roundedRect: NSRect(x: 737, y: 756, width: 46, height: 70), xRadius: 17, yRadius: 17).fill()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Cannot render app icon") }
try png.write(to: URL(fileURLWithPath: destination))
