import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205).fill()
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: 512, y: 838))
        drop.curve(to: NSPoint(x: 260, y: 414), controlPoint1: NSPoint(x: 435, y: 725), controlPoint2: NSPoint(x: 260, y: 560))
        drop.curve(to: NSPoint(x: 764, y: 414), controlPoint1: NSPoint(x: 260, y: 128), controlPoint2: NSPoint(x: 764, y: 128))
        drop.curve(to: NSPoint(x: 512, y: 838), controlPoint1: NSPoint(x: 764, y: 560), controlPoint2: NSPoint(x: 585, y: 725))
        NSColor(calibratedRed: 0.5, green: 0.91, blue: 0.79, alpha: 1).setFill(); drop.fill()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 330, y: 408)); line.line(to: NSPoint(x: 435, y: 408)); line.line(to: NSPoint(x: 510, y: 516)); line.line(to: NSPoint(x: 580, y: 353)); line.line(to: NSPoint(x: 690, y: 450))
        line.lineWidth = 40; line.lineCapStyle = .round; line.lineJoinStyle = .round
        NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.15, alpha: 1).setStroke(); line.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
