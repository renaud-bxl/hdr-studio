import AppKit

// Dessine l'icône de l'app (1024 px) : usage  swift make-icon.swift sortie.png
let size = 1024
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.22, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.055, blue: 0.07, alpha: 1)])?.draw(in: shape, angle: -90)
let disc = NSBezierPath(ovalIn: tile.insetBy(dx: 206, dy: 206))
NSGradient(colors: [NSColor.white,
                    NSColor(srgbRed: 1.0, green: 0.72, blue: 0.27, alpha: 1),
                    NSColor(srgbRed: 0.86, green: 0.34, blue: 0.14, alpha: 1)])?.draw(in: disc, angle: -50)
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
