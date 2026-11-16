import AppKit

// Dessine l'icône de l'app (1024 px) : usage  make-icon sortie.png
let size = 1024
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
let blue = NSColor(srgbRed: 0.247, green: 0.427, blue: 0.965, alpha: 1)
let violet = NSColor(srgbRed: 0.545, green: 0.310, blue: 0.941, alpha: 1)
NSGradient(starting: blue, ending: violet)?.draw(in: NSBezierPath(roundedRect: r, xRadius: 186, yRadius: 186), angle: 45)
let w = r.width
for (i, spec) in [(0.30, 0.50), (0.46, 0.75), (0.62, 1.0)].enumerated() {
    let bar = NSRect(x: r.minX + w * (0.22 + 0.21 * CGFloat(i)), y: r.minY + w * 0.21, width: w * 0.14, height: w * CGFloat(spec.0))
    NSColor(white: 1, alpha: CGFloat(spec.1)).setFill()
    NSBezierPath(roundedRect: bar, xRadius: w * 0.05, yRadius: w * 0.05).fill()
}
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
