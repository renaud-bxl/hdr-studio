import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

private struct DolbyError: LocalizedError {
    let errorDescription: String?
    let status: Int32
    init(_ message: String, _ cause: Error? = nil, status: Int32 = EXIT_FAILURE) {
        errorDescription = cause.map { "\(message) \($0.localizedDescription)" } ?? message
        self.status = status
    }
}

// The HLG preparation step already encodes audio as AAC.
private final class AudioRoute {
    let reader: AVAssetReaderTrackOutput
    let writer: AVAssetWriterInput
    var finished = false

    init(track: AVAssetTrack, format: CMFormatDescription) {
        reader = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.alwaysCopiesSampleData = false
        writer = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    }
}

@main
struct HDRDolby {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw DolbyError("Utilisation : hdr-dolby-apple source-hlg.mov sortie.mov")
            }
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            try await convert(from: source, to: destination)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit((error as? DolbyError)?.status ?? EXIT_FAILURE)
        }
    }

    private static func progress(_ name: String, _ time: CMTime) {
        guard time.isNumeric else { return }
        let micros = CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
        FileHandle.standardOutput.write(Data("\(name)=\(max(0, micros))\n".utf8))
    }

    private static func ambientViewingEnvironment(_ format: CMFormatDescription) -> Data {
        if let source = CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment) as? Data,
           source.count == 8 {
            return source
        }
        // TN3145 requires an amve box for Dolby Vision 8.4. When no source
        // environment is provided, describe Apple's nominal indoor viewing
        // example (314 lux) with a D65 illuminant. ISO/IEC 23008-2 units:
        // 0.0001 lux and 0.00002 in CIE x/y. All fields are big-endian.
        var illuminance = UInt32(3_140_000).bigEndian
        var x = UInt16(15_635).bigEndian
        var y = UInt16(16_450).bigEndian
        return withUnsafeBytes(of: &illuminance) { Data($0) }
            + withUnsafeBytes(of: &x) { Data($0) }
            + withUnsafeBytes(of: &y) { Data($0) }
    }

    private static func convert(from source: URL, to destination: URL) async throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else {
            throw DolbyError("La vidéo HLG préparée est introuvable.")
        }
        guard destination.pathExtension.lowercased() == "mov" else {
            throw DolbyError("La vidéo Dolby Vision doit être enregistrée au format MOV.")
        }
        guard !files.fileExists(atPath: destination.path),
              (try? files.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw DolbyError("Un fichier portant ce nom existe déjà.")
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw DolbyError("La vidéo HLG préparée ne contient pas d’image.")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else {
            throw DolbyError("Impossible de déterminer la durée de la vidéo.")
        }
        let timeRange = try await track.load(.timeRange)
        let nativeScale = try await track.load(.naturalTimeScale)
        let transform = try await track.load(.preferredTransform)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw DolbyError("Les dimensions de la vidéo HLG préparée sont incompatibles.")
        }
        guard let trc = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                  as? String, trc == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String),
              let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
                  as? String, primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String),
              let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
                  as? String, matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) else {
            throw DolbyError("La source de l’encodeur Dolby Vision doit être en Rec. 2100 HLG.")
        }
        let nominalFPS = try await track.load(.nominalFrameRate)
        let fps = (nominalFPS.isFinite && nominalFPS > 0) ? Double(nominalFPS) : 30
        let bitrate = Int(min(150_000_000.0, max(800_000.0, Double(width) * Double(height) * fps * 0.25)))
        let ambient = ambientViewingEnvironment(format)

        let reader = try AVAssetReader(asset: asset)
        let videoReader = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        videoReader.alwaysCopiesSampleData = false

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var keepOutput = false
        defer {
            if !keepOutput {
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
                try? files.removeItem(at: destination)
            }
        }
        writer.shouldOptimizeForNetworkUse = true
        // Preserve offsets of delayed audio tracks when the MOV edit list
        // converts stream timestamps into the common movie timescale.
        writer.movieTimeScale = 240_000
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        // Ask VideoToolbox to analyze the edited pixels, even if the source happens
        // to carry old dynamic metadata. The resulting MOV is Dolby Vision 8.4.
        var videoFormat: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: color,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String: false
            ] as [String: Any]
        ]
        if let aspect = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
                as? [String: Any],
           let h = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber,
           let v = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber,
           h.intValue > 0, v.intValue > 0 {
            videoFormat[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: h,
                AVVideoPixelAspectRatioVerticalSpacingKey: v
            ]
        }
        guard reader.canAdd(videoReader), writer.canApply(outputSettings: videoFormat, forMediaType: .video) else {
            throw DolbyError("Le moteur vidéo de ce Mac ne prend pas en charge cet encodage Dolby Vision.")
        }
        let videoWriter = AVAssetWriterInput(mediaType: .video, outputSettings: videoFormat)
        videoWriter.transform = transform
        if nativeScale > 0 { videoWriter.mediaTimeScale = nativeScale }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriter, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoWriter) else {
            throw DolbyError("Impossible d’ajouter la piste vidéo Dolby Vision à la sortie.")
        }
        reader.add(videoReader)
        writer.add(videoWriter)

        var audioRoutes: [AudioRoute] = []
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            guard let audioFormat = try await audio.load(.formatDescriptions).first else {
                throw DolbyError("Une piste audio ne peut pas être lue.")
            }
            let route = AudioRoute(track: audio, format: audioFormat)
            guard reader.canAdd(route.reader), writer.canAdd(route.writer) else {
                throw DolbyError("Impossible de conserver toutes les pistes audio.")
            }
            reader.add(route.reader)
            writer.add(route.writer)
            audioRoutes.append(route)
        }

        guard reader.startReading() else {
            let decoderUnavailable = (reader.error as? AVError)?.code == .decoderNotFound
            throw DolbyError("Le moteur vidéo du Mac ne parvient pas à lire la vidéo HLG.",
                             reader.error, status: decoderUnavailable ? EX_UNAVAILABLE : EXIT_FAILURE)
        }
        guard writer.startWriting() else {
            throw DolbyError("Le moteur Dolby Vision du Mac ne démarre pas.", writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        progress("duration_us", duration)

        var videoFinished = false
        var wroteFrame = false
        var lastReport: CMTime?
        var lastEnd: CMTime?
        var lastActivity = ProcessInfo.processInfo.systemUptime
        while !videoFinished || audioRoutes.contains(where: { !$0.finished }) {
            guard writer.status == .writing, reader.status != .failed else {
                throw DolbyError("L’encodage Dolby Vision a été interrompu.", writer.error ?? reader.error)
            }
            var advanced = false
            if !videoFinished, videoWriter.isReadyForMoreMediaData {
                if let sample = videoReader.copyNextSampleBuffer() {
                    guard let frame = CMSampleBufferGetImageBuffer(sample),
                          CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
                        throw DolbyError("Le moteur vidéo n’a pas fourni d’image en 10 bits.")
                    }
                    // Decoder attachments can omit gamut/transfer; these are
                    // necessary for the encoder to insert Dolby Vision metadata.
                    CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey,
                                          kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey,
                                          kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                    CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey,
                                          kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(frame, kCVImageBufferAmbientViewingEnvironmentKey,
                                          ambient as CFData, .shouldPropagate)
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard timestamp.isNumeric, adaptor.append(frame, withPresentationTime: timestamp) else {
                        throw DolbyError("Impossible d’encoder une image en Dolby Vision.", writer.error)
                    }
                    wroteFrame = true
                    let frameDuration = CMSampleBufferGetDuration(sample)
                    if frameDuration.isNumeric, frameDuration > .zero {
                        lastEnd = timestamp + frameDuration
                    }
                    if lastReport.map({ CMTimeGetSeconds(timestamp - $0) >= 0.15 }) ?? true {
                        progress("out_time_us", timestamp)
                        lastReport = timestamp
                    }
                } else {
                    if reader.status == .failed {
                        throw DolbyError("Lecture de la vidéo HLG interrompue.", reader.error)
                    }
                    let end = lastEnd ?? timeRange.end
                    // The adaptor takes PTS only. For a video-only file, the
                    // session boundary supplies the final sample's end time.
                    if audioRoutes.isEmpty, end.isNumeric, end > .zero {
                        writer.endSession(atSourceTime: end)
                    }
                    videoWriter.markAsFinished()
                    videoFinished = true
                }
                advanced = true
            }
            for route in audioRoutes where !route.finished && route.writer.isReadyForMoreMediaData {
                if let sample = route.reader.copyNextSampleBuffer() {
                    guard route.writer.append(sample) else {
                        throw DolbyError("Impossible de conserver une piste audio.", writer.error)
                    }
                } else {
                    if reader.status == .failed {
                        throw DolbyError("Lecture d’une piste audio interrompue.", reader.error)
                    }
                    route.writer.markAsFinished()
                    route.finished = true
                }
                advanced = true
            }
            if advanced {
                lastActivity = ProcessInfo.processInfo.systemUptime
            } else {
                guard ProcessInfo.processInfo.systemUptime - lastActivity < 45 else {
                    throw DolbyError("Le moteur Dolby Vision ne répond plus.")
                }
                usleep(2_000)
            }
        }
        guard wroteFrame, reader.status != .failed else {
            throw DolbyError("Aucune image Dolby Vision n’a été encodée.", reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw DolbyError("Le fichier Dolby Vision n’a pas pu être finalisé.", writer.error)
        }
        keepOutput = true
        progress("out_time_us", duration)
        FileHandle.standardOutput.write(Data("progress=end\n".utf8))
    }
}
