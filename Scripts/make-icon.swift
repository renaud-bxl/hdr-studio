import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func gradient(_ context: CGContext, _ first: CGColor, _ second: CGColor,
              from: CGPoint, to: CGPoint) {
    let colors = [first, second] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func word(_ value: Int) -> Data {
    var field = UInt32(value).bigEndian
    return withUnsafeBytes(of: &field) { Data($0) }
}

var contents = Data()
for (size, tag) in [(16, "icp4"), (32, "icp5"), (32, "ic11"), (64, "ic12"), (128, "ic07"),
                    (256, "ic08"), (256, "ic13"), (512, "ic09"), (512, "ic14"), (1024, "ic10")] {
        let image = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        image.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let tile = CGPath(roundedRect: CGRect(x: 78, y: 78, width: 868, height: 868),
                          cornerWidth: 195, cornerHeight: 195, transform: nil)
        image.saveGState()
        image.addPath(tile)
        image.clip()
        gradient(image, rgb(0.22, 0.20, 0.37), rgb(0.05, 0.05, 0.11),
                 from: CGPoint(x: 256, y: 900), to: CGPoint(x: 760, y: 140))
        image.restoreGState()
        image.addPath(tile)
        image.setStrokeColor(rgb(0.38, 0.35, 0.58))
        image.setLineWidth(5)
        image.strokePath()

        let disc = CGRect(x: 253, y: 253, width: 518, height: 518)
        image.saveGState()
        image.addEllipse(in: disc)
        image.clip()
        image.translateBy(x: 512, y: 512)
        image.rotate(by: -.pi / 6)
        gradient(image, rgb(0.93, 0.84, 1.0), rgb(0.46, 0.60, 0.96),
                 from: CGPoint(x: -210, y: 200), to: CGPoint(x: -29, y: -240))
        image.clip(to: CGRect(x: 0, y: -300, width: 300, height: 600))
        gradient(image, rgb(0.47, 0.40, 0.67), rgb(0.16, 0.18, 0.39),
                 from: CGPoint(x: 70, y: 230), to: CGPoint(x: 200, y: -240))
        image.restoreGState()
        image.setStrokeColor(rgb(0.77, 0.74, 0.98))
        image.setLineWidth(7)
        image.strokeEllipse(in: disc)

        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Écriture de l’icône impossible") }
        contents.append(contentsOf: tag.utf8)
        contents.append(word(png.length + 8))
        contents.append(png as Data)
}
try (Data("icns".utf8) + word(contents.count + 8) + contents).write(to: output, options: .atomic)
