import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let iconBlue = NSColor(srgbRed: 0.16, green: 0.39, blue: 0.84, alpha: 1)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                               bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        let side = CGFloat(pixels)
        let bounds = NSRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84)
        iconBlue.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.19, yRadius: side * 0.19).fill()
        drawCoin("€", center: NSPoint(x: side * 0.38, y: side * 0.58), diameter: side * 0.39,
                 fill: NSColor(srgbRed: 0.76, green: 0.87, blue: 1.00, alpha: 1))
        drawCoin("$", center: NSPoint(x: side * 0.62, y: side * 0.42), diameter: side * 0.39,
                 fill: NSColor(srgbRed: 0.69, green: 0.98, blue: 0.84, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

func drawCoin(_ symbol: String, center: NSPoint, diameter: CGFloat, fill: NSColor) {
    let radius = diameter / 2
    let boundary = NSRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)
    let coin = NSBezierPath(ovalIn: boundary)
    fill.setFill()
    coin.fill()
    iconBlue.setStroke()
    coin.lineWidth = diameter * 0.065
    coin.stroke()

    let text = NSAttributedString(string: symbol, attributes: [
        .font: NSFont.systemFont(ofSize: diameter * 0.62, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.07, green: 0.18, blue: 0.36, alpha: 1)
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
}
