import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct PhotoError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

private func executable(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let folders = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return folders.lazy.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private final class PhotoCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    private var child: Process?
    private var scratch: URL?

    init() {
        signal(SIGTERM, SIG_IGN)
        signalSource.setEventHandler { [weak self] in self?.stop() }
        signalSource.resume()
    }

    func prepare(_ directory: URL) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            scratch = directory
        }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            try process.run()
            child = process
        }
    }

    func clearChild() {
        lock.withLock { child = nil }
    }

    func clean() {
        lock.withLock {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            scratch = nil
        }
    }

    private func stop() {
        lock.withLock {
            // Stop the standalone HEIF utility even if it inherited ignored SIGTERM.
            if let child, child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        exit(128 + SIGTERM)
    }
}

private let cancellation = PhotoCancellation()

private func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let messages = Pipe()
    process.standardOutput = messages
    process.standardError = messages
    try cancellation.launch(process)
    defer { cancellation.clearChild() }
    let data = messages.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw PhotoError("Échec de \(executable.lastPathComponent) : \(detail.suffix(600))")
    }
}

private struct LinearImage {
    let buffer: CGContext
    let width: Int
    let height: Int
    let orientation: Int
    let isHDR: Bool

    var outputWidth: Int { orientation >= 5 ? height : width }
    var outputHeight: Int { orientation >= 5 ? width : height }

    func pixelOffset(x: Int, y: Int) -> Int {
        let origin: (Int, Int)
        switch orientation {
        case 2: origin = (width - 1 - x, y)
        case 3: origin = (width - 1 - x, height - 1 - y)
        case 4: origin = (x, height - 1 - y)
        case 5: origin = (y, x)
        case 6: origin = (y, height - 1 - x)
        case 7: origin = (width - 1 - y, height - 1 - x)
        case 8: origin = (width - 1 - y, x)
        default: origin = (x, y)
        }
        return 4 * (origin.1 * width + origin.0)
    }
}

private func isHEIF(_ source: CGImageSource) -> Bool {
    guard let typeID = CGImageSourceGetType(source) as String?, let type = UTType(typeID) else { return false }
    return type.conforms(to: .heic) || type.conforms(to: .heif) || typeID == "public.avif"
}

@available(macOS 14.0, *)
private func hasGainMap(_ source: CGImageSource, index: Int) -> Bool {
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
        return true
    }
    if #available(macOS 15.0, *) {
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }
    return false
}

@available(macOS 14.0, *)
private func decode(_ source: CGImageSource, linearSpace: CGColorSpace,
                    maxDimension: Int? = nil) throws -> LinearImage? {
    let index = CGImageSourceGetPrimaryImageIndex(source)
    let metadata = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    let rawOrientation = (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
    let request: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                                   kCGImageSourceShouldCacheImmediately: maxDimension == nil]
    guard let image = CGImageSourceCreateImageAtIndex(source, index, request as CFDictionary) else { return nil }
    // Protect the two full-size processing buffers from excessive allocations.
    guard image.width > 0, image.height > 0, image.width <= 80_000_000 / image.height else {
        throw PhotoError("Cette photo dépasse la limite de 80 mégapixels.")
    }
    var isHDR = image.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
    if #available(macOS 15.0, *) {
        isHDR = isHDR || image.contentHeadroom > 1.0
    }
    isHDR = isHDR || hasGainMap(source, index: index)

    let longest = max(image.width, image.height)
    let limit = min(longest, maxDimension ?? longest)
    let width = max(1, Int((Double(image.width) * Double(limit) / Double(longest)).rounded()))
    let height = max(1, Int((Double(image.height) * Double(limit) / Double(longest)).rounded()))
    var raster = image
    if limit < longest && !isHDR {
        // Use subsampled decoding when ImageIO can retain the source profile.
        // Decode HDR sources directly to avoid an SDR thumbnail or a lost gain map.
        var options = request
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        options[kCGImageSourceThumbnailMaxPixelSize] = limit
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
           thumbnail.colorSpace == image.colorSpace {
            raster = thumbnail
        }
    }
    let format = CGBitmapInfo.byteOrder32Little.union(.floatComponents).rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                                bytesPerRow: width * 16, space: linearSpace, bitmapInfo: format),
          let storage = canvas.data else {
        throw PhotoError("La mémoire disponible ne permet pas de traiter cette photo.")
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    canvas.clear(bounds)
    canvas.setBlendMode(.copy)
    if #available(macOS 15.0, *) {
        // Keep the decoded HDR values; 0 asks Core Graphics not to tone map them.
        _ = canvas.setEDRTargetHeadroom(0)
    }
    if limit < longest { canvas.interpolationQuality = .high }
    canvas.draw(raster, in: bounds)

    if isHEIF(source) {
        // On systems without VideoToolbox decoding, ImageIO can silently draw an
        // empty raster from a valid HEIC header. Fully transparent inputs can
        // also take this branch and still get flattened to black in software.
        let rgba = storage.assumingMemoryBound(to: Float.self)
        guard stride(from: 3, to: width * height * 4, by: 4).contains(where: { rgba[$0] > 0 }) else {
            return nil
        }
    }
    return LinearImage(buffer: canvas, width: width, height: height, orientation: orientation, isHDR: isHDR)
}

// SMPTE ST 2084. A square-root luminance index retains precision in dark tones.
private let pqTable: [Float] = (0...16_384).map { index in
    let position = Double(index) / 16_384
    let power = pow(position * position, 2610.0 / 16_384.0)
    let value = pow((3424.0 / 4096.0 + (2413.0 / 128.0) * power)
                    / (1.0 + (2392.0 / 128.0) * power), 2523.0 / 32.0)
    return Float(value * 65_535)
}

private func encodePQ(_ linear: Float) -> UInt16 {
    // Extended linear BT.2020 1.0 is the 203 cd/m² HDR reference white.
    let scaled = sqrt(min(1, max(0, linear * 0.0203))) * 16_384
    let index = min(16_383, Int(scaled))
    let value = pqTable[index] + (pqTable[index + 1] - pqTable[index]) * (scaled - Float(index))
    return UInt16(clamping: Int(value.rounded()))
}

@inline(__always)
private func highlightGain(luma: Float, peak: Float, isHDR: Bool, sdrLift: Float, hdrLift: Float) -> Float {
    if isHDR {
        // At the default level, keep the source HDR. Above it, adjust only
        // light above diffuse white and ease off as a channel nears the PQ limit.
        let excess = max(0, luma - 1)
        guard excess > 0, hdrLift > 0 else { return 1 }
        let requested = hdrLift * (excess / (excess + 0.3)) * (excess / luma)
        let room = max(0, (10_000 / 203.0) / peak - 1)
        return 1 + (requested * room) / (requested + room)
    }

    // Keep the SDR midtones while expanding the top of the range.
    let t = min(1, max(0, (luma - 0.32) / 0.68))
    return 1 + sdrLift * t * t * (3 - 2 * t)
}

// Each destination pixel represents an area of the processed source. Fractions
// at the edges are kept as integer weights, including at odd sizes.
private struct AreaSpan {
    let lower: Int
    let upper: Int
    let range: Range<Int>
    let step: Int

    init(index: Int, sourceSize: Int, targetSize: Int) {
        lower = index * sourceSize
        upper = lower + sourceSize
        step = targetSize
        range = (lower / step)..<((upper + step - 1) / step)
    }

    @inline(__always)
    func weight(_ index: Int) -> Float {
        Float(min(upper, (index + 1) * step) - max(lower, index * step))
    }
}

private func render(_ image: LinearImage, strength: Float, pqSpace: CGColorSpace,
                    previewLimit: Int? = nil) throws -> CGImage {
    let sourceWidth = image.outputWidth
    let sourceHeight = image.outputHeight
    let longest = max(sourceWidth, sourceHeight)
    let limit = min(longest, previewLimit ?? longest)
    let width = max(1, Int((Double(sourceWidth) * Double(limit) / Double(longest)).rounded()))
    let height = max(1, Int((Double(sourceHeight) * Double(limit) / Double(longest)).rounded()))
    guard let storage = image.buffer.data else { throw PhotoError("La photo n’a pas pu être rendue.") }
    let input = storage.assumingMemoryBound(to: Float.self)
    var output = Data(count: width * height * 8)
    let sdrLift = strength * (3.9 + 1.8 * strength)
    let extra = max(0, (strength - 0.65) / 0.35)
    let hdrLift = 0.40 * extra * extra

    @inline(__always)
    func processPixel(x: Int, y: Int) -> (Float, Float, Float) {
        let source = image.pixelOffset(x: x, y: y)
        let r = input[source].isFinite ? max(0, input[source]) : 0
        let g = input[source + 1].isFinite ? max(0, input[source + 1]) : 0
        let b = input[source + 2].isFinite ? max(0, input[source + 2]) : 0
        // Alpha is already premultiplied: transparent content is composited onto black.
        // Lift only the highlights and scale the channels together to preserve hue.
        let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
        let gain = highlightGain(luma: luma, peak: max(r, g, b), isHDR: image.isHDR,
                                 sdrLift: sdrLift, hdrLift: hdrLift)
        return (r * gain, g * gain, b * gain)
    }

    output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        let pixels = raw.bindMemory(to: UInt16.self)
        @inline(__always)
        func store(x: Int, y: Int, r: Float, g: Float, b: Float) {
            let target = 4 * (y * width + x)
            pixels[target] = encodePQ(r)
            pixels[target + 1] = encodePQ(g)
            pixels[target + 2] = encodePQ(b)
            pixels[target + 3] = 65_535
        }

        if width == sourceWidth && height == sourceHeight {
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = processPixel(x: x, y: y)
                    store(x: x, y: y, r: r, g: g, b: b)
                }
            }
        } else {
            let columns = (0..<width).map { AreaSpan(index: $0, sourceSize: sourceWidth, targetSize: width) }
            let rows = (0..<height).map { AreaSpan(index: $0, sourceSize: sourceHeight, targetSize: height) }
            let normalization = 1 / (Float(sourceWidth) * Float(sourceHeight))
            for (y, row) in rows.enumerated() {
                for (x, column) in columns.enumerated() {
                    var r: Float = 0, g: Float = 0, b: Float = 0
                    for sy in row.range {
                        let verticalWeight = row.weight(sy)
                        for sx in column.range {
                            let weight = verticalWeight * column.weight(sx)
                            let (sr, sg, sb) = processPixel(x: sx, y: sy)
                            r += sr * weight
                            g += sg * weight
                            b += sb * weight
                        }
                    }
                    store(x: x, y: y, r: r * normalization, g: g * normalization, b: b * normalization)
                }
            }
        }
    }
    let info = CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
    guard let provider = CGDataProvider(data: output as CFData),
          let result = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                               bytesPerRow: width * 8, space: pqSpace, bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw PhotoError("Impossible de créer l’image HDR.")
    }
    return result
}

@available(macOS 14.0, *)
private func exportPhoto(input: URL, output: URL, strength: Float, preview: Bool) throws {
    let files = FileManager.default
    let resultExtension = preview ? "png" : "heic"
    guard output.pathExtension.lowercased() == resultExtension else {
        throw PhotoError("Le nom du fichier de sortie doit se terminer par .\(resultExtension).")
    }
    guard input.standardizedFileURL != output.standardizedFileURL,
          !files.fileExists(atPath: output.path) else {
        throw PhotoError("Le fichier de sortie existe déjà. Choisis un autre nom.")
    }
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0,
          let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
          let pqSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
        throw PhotoError("Impossible de lire cette photo. Vérifie que le fichier est une image prise en charge.")
    }
    let scratch = output.deletingLastPathComponent()
        .appendingPathComponent(".hdr-photo-\(UUID().uuidString)", isDirectory: true)
    try cancellation.prepare(scratch)
    defer { cancellation.clean() }

    let staged = scratch.appendingPathComponent("result.\(resultExtension)")
    let previewLimit: Int? = preview ? 1_200 : nil
    let maxDimension = previewLimit.map { $0 * 2 }
    var decoded = try decode(source, linearSpace: linearSpace, maxDimension: maxDimension)
    if decoded == nil, isHEIF(source), let decoder = executable("heif-convert") {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard !hasGainMap(source, index: index) else {
            throw PhotoError("macOS n’a pas pu lire la couche HDR de cette photo HEIC. Exporte d’abord la photo en PNG HDR depuis Photos ou ton éditeur.")
        }
        let fallback = scratch.appendingPathComponent("source.png")
        try run(decoder, [input.path, fallback.path])
        if let png = CGImageSourceCreateWithURL(fallback as CFURL, nil) {
            decoded = try decode(png, linearSpace: linearSpace, maxDimension: maxDimension)
        }
    }
    guard let decoded else {
        throw PhotoError("Impossible de décoder cette photo. Pour les HEIC, installe libheif avec « brew install libheif ».")
    }
    let image = try render(decoded, strength: strength, pqSpace: pqSpace, previewLimit: previewLimit)
    if preview {
        // Lift highlights before the final reduction, averaging in linear light.
        // Averaging first can drop small bright features below the lift threshold.
        try writePNG(image, to: staged)
        try files.moveItem(at: staged, to: output)
        print("source_hdr=\(decoded.isHDR ? 1 : 0)")
        return
    }

    // ImageIO can write ISO HDR directly on supported Macs. Verify depth and
    // transfer before accepting its output; some macOS environments disable HEVC.
    if #available(macOS 15.0, *),
       let destination = CGImageDestinationCreateWithURL(staged as CFURL, UTType.heic.identifier as CFString, 1, nil) {
        let options = [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOHDR as Any,
                       kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        if CGImageDestinationFinalize(destination),
           let result = CGImageSourceCreateWithURL(staged as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(result, CGImageSourceGetPrimaryImageIndex(result), nil) as? [CFString: Any],
           (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 10,
           let cgResult = CGImageSourceCreateImageAtIndex(result, CGImageSourceGetPrimaryImageIndex(result), nil),
           let profile = cgResult.colorSpace, CGColorSpaceIsPQBased(profile) {
            try files.moveItem(at: staged, to: output)
            return
        }
        try? files.removeItem(at: staged)
    }

    guard let encoder = executable("heif-enc") else {
        throw PhotoError("L’encodeur HDR de macOS est indisponible. Installe libheif avec « brew install libheif ».")
    }
    let intermediate = scratch.appendingPathComponent("hdr.png")
    try writePNG(image, to: intermediate)
    try run(encoder, ["-q", "94", "-b", "10", "--colour_primaries", "9", "--transfer_characteristic", "16",
                      "--matrix_coefficients", "9", "--enable-two-colr-boxes", "-o", staged.path, intermediate.path])
    try files.moveItem(at: staged, to: output)
}

private func writePNG(_ image: CGImage, to output: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw PhotoError("Impossible de créer le fichier HDR temporaire.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw PhotoError("Impossible d’écrire le fichier HDR temporaire.")
    }
}

do {
    guard #available(macOS 14.0, *) else {
        throw PhotoError("L’export HEIC HDR nécessite macOS Sonoma 14 ou version ultérieure.")
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    let preview = arguments.first == "--preview"
    if preview { arguments.removeFirst() }
    guard arguments.count == 3, let strength = Float(arguments[2]), strength.isFinite,
          (0.0...1.0).contains(strength) else {
        throw PhotoError("Utilisation : hdr-photo [--preview] <photo-source> <sortie.heic ou .png> <intensité entre 0 et 1>")
    }
    try exportPhoto(input: URL(fileURLWithPath: arguments[0]),
                    output: URL(fileURLWithPath: arguments[1]), strength: strength, preview: preview)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
