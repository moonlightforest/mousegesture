import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("MouseGesture.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, menu: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 100
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    if !menu {
        NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 92, height: 92), xRadius: 22, yRadius: 22).fill()
    }
    let ink = menu ? NSColor.black : NSColor.white
    ink.setStroke()
    let mouse = NSBezierPath(roundedRect: NSRect(x: 30, y: 20, width: 40, height: 60), xRadius: 19, yRadius: 19)
    mouse.lineWidth = menu ? 7 : 5
    mouse.stroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 50, y: 80)); line.line(to: NSPoint(x: 50, y: 56))
    line.move(to: NSPoint(x: 31, y: 56)); line.line(to: NSPoint(x: 69, y: 56))
    line.lineWidth = menu ? 5 : 3.5
    line.stroke()
    // A rightward arrow makes the gesture tool distinct from a plain mouse.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 73, y: 38)); arrow.line(to: NSPoint(x: 91, y: 38))
    arrow.move(to: NSPoint(x: 83, y: 47)); arrow.line(to: NSPoint(x: 92, y: 38)); arrow.line(to: NSPoint(x: 83, y: 29))
    arrow.lineWidth = menu ? 6 : 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try render(size: base * factor, menu: false).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
for factor in [1, 2] {
    let suffix = factor == 2 ? "@2x" : ""
    try render(size: 18 * factor, menu: true).write(to: resources.appendingPathComponent("MenuBarIcon\(suffix).png"))
}
