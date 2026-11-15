import Foundation
import CoreImage
import CoreGraphics

let args = CommandLine.arguments
if args.count < 2 {
    print("usage: hdrphoto <image> [image ...]")
    exit(1)
}

let ctx = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

var ok = 0
for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let base = CIImage(contentsOf: url) else { err("Lecture impossible: \(path)"); continue }

    let hdr = base.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.3])

    let stem = url.deletingPathExtension().lastPathComponent
    let outURL = url.deletingLastPathComponent().appendingPathComponent(stem + "_HDR.heic")

    guard let data = ctx.heifRepresentation(
        of: base,
        format: CIFormat.RGBA8,
        colorSpace: p3,
        options: [CIImageRepresentationOption.hdrImage: hdr]
    ) else {
        err("Echec representation HEIF: \(path)")
        continue
    }
    do {
        try data.write(to: outURL)
        print("OK -> \(outURL.path)")
        ok += 1
    } catch {
        err("Echec ecriture \(path): \(error)")
    }
}
print("Termine: \(ok) image(s) traitee(s).")
