import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let layer = output.deletingLastPathComponent().appendingPathComponent(
  "Tamebar.icon/Assets/Mark.svg")
guard let mark = NSImage(contentsOf: layer) else {
  fatalError("Missing Tamebar foreground layer")
}
let size = 1024
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
let tile = NSBezierPath(
  roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
// #f5f5f7, the same paper as Background.svg.
NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1).setFill()
tile.fill()
mark.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
