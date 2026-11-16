import Foundation
import CoreImage

// Mesure le rendu HDR d'un HEIC exporté : compare, en lumière linéaire, l'image SDR d'origine
// et l'image HDR reconstituée par macOS à partir de la gain map.
// Usage : probe-photo source.jpg export.heic
guard CommandLine.arguments.count > 2 else { print("usage: probe-photo source export.heic"); exit(1) }
let ctx = CIContext()
let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

func sample(_ img: CIImage, _ fx: CGFloat) -> Float {
    let e = img.extent
    var px = [Float](repeating: 0, count: 4)
    let r = CGRect(x: e.minX + min(e.width - 1, fx * (e.width - 1)), y: e.midY, width: 1, height: 1)
    ctx.render(img, toBitmap: &px, rowBytes: 16, bounds: r, format: .RGBAf, colorSpace: lin)
    return px[1]
}
guard let sdr = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let hdr = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: [.expandToHDR: true]),
      let flat = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) else { print("lecture impossible"); exit(1) }
print("position  source  export_sdr  export_hdr  gain")
for i in 0...10 {
    let f = CGFloat(i) / 10
    let a = sample(sdr, f), b = sample(flat, f), c = sample(hdr, f)
    print(String(format: "%4.1f     %.4f   %.4f      %.4f     x%.2f", Double(f), a, b, c, b > 0.0005 ? c / b : 1))
}
if #available(macOS 15.0, *) { print("headroom annonce = \(hdr.contentHeadroom)") }
