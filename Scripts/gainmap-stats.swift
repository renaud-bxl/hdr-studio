import Foundation
import ImageIO

// Vérifie qu'un HEIC contient une gain map HDR et affiche ses statistiques.
// Usage : swift gainmap-stats.swift image.heic
guard CommandLine.arguments.count > 1,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil) else {
    print("source illisible"); exit(1)
}
var found = false
for (name, type) in [("ISO", kCGImageAuxiliaryDataTypeISOGainMap), ("HDR", kCGImageAuxiliaryDataTypeHDRGainMap)] {
    guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) as? [String: Any],
          let data = info[kCGImageAuxiliaryDataInfoData as String] as? Data, !data.isEmpty else { continue }
    found = true
    var lo: UInt8 = 255, hi: UInt8 = 0, sum = 0
    for b in data { if b < lo { lo = b }; if b > hi { hi = b }; sum += Int(b) }
    print("gainmap=\(name) octets=\(data.count) min=\(lo) max=\(hi) moyenne=\(sum / data.count)")
}
if !found { print("gainmap=absente"); exit(2) }
