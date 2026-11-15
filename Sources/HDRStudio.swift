import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MediaKind: String, CaseIterable, Identifiable {
    case photo = "Photo"
    case video = "Vidéo"

    var id: String { rawValue }
    var extensions: Set<String> {
        switch self {
        case .photo: return ["jpg", "jpeg", "png", "heic", "heif", "hif", "tif", "tiff", "dng", "avif", "webp"]
        case .video: return ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mxf", "mts", "m2ts", "mpg", "mpeg", "ts", "3gp"]
        }
    }

    var pickerTypes: [UTType] {
        extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    var symbol: String { self == .photo ? "photo" : "film" }
    var title: String { self == .photo ? "Dépose tes photos ici" : "Dépose tes vidéos ici" }
    var description: String {
        self == .photo ? "JPEG, PNG, HEIC, TIFF et autres images compatibles"
            : "MOV, MP4, MKV, WebM et autres vidéos compatibles"
    }

    var outputExtension: String { self == .photo ? "heic" : "mov" }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case hlg, pq
    var id: String { rawValue }
    var label: String { "Rec. 2100 " + rawValue.uppercased() }
}

struct QueueItem: Identifiable {
    enum Status {
        case ready
        case processing(Double?)
        case done(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    let kind: MediaKind
    var status: Status = .ready
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The worker and the cancel button can both access this object.
final class ExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func start(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func finished() {
        lock.withLock { process = nil }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func publish(_ temporary: URL, to folder: URL, basename: String, ext: String) throws -> URL {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            for number in 1...10_000 {
                let suffix = number == 1 ? "" : " \(number)"
                let output = folder.appendingPathComponent(basename + suffix).appendingPathExtension(ext)
                do {
                    try FileManager.default.moveItem(at: temporary, to: output)
                    return output
                } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    error.code == NSFileWriteFileExistsError {
                    continue
                }
            }
            throw ExportError(message: "Aucun nom de fichier libre n’a été trouvé dans ce dossier.")
        }
    }
}

enum Converter {
    static func export(
        _ item: QueueItem, to folder: URL, format: VideoFormat, control: ExportControl,
        onProgress: (Double) -> Void
    ) throws -> URL {
        let resources = Bundle.main.resourceURL
        let executable: URL?
        switch item.kind {
        case .photo: executable = Bundle.main.url(forAuxiliaryExecutable: "hdr-photo")
        case .video: executable = resources?.appendingPathComponent("hdr-video")
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExportError(message: "Le moteur de conversion est introuvable. Réinstalle HDR Studio.")
        }

        let temporary = folder.appendingPathComponent(".hdrstudio-\(UUID().uuidString)")
            .appendingPathExtension(item.kind.outputExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let logfile = FileManager.default.temporaryDirectory.appendingPathComponent("hdrstudio-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logfile) }
        guard FileManager.default.createFile(atPath: logfile.path, contents: nil) else {
            throw ExportError(message: "Impossible de préparer la conversion.")
        }
        let log = try FileHandle(forWritingTo: logfile)
        defer { try? log.close() }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" +
            (environment["PATH"].map { ":\($0)" } ?? "")
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.arguments = [item.url.path, temporary.path] +
            (item.kind == .photo ? ["0.65"] : [format.rawValue, "0.65"])

        try control.start(process)
        defer { control.finished() }

        var buffer = Data()
        var duration = 0.0
        var lastProgress = -1.0
        while true {
            let bytes = pipe.fileHandleForReading.availableData
            if bytes.isEmpty { break }
            buffer.append(bytes)
            while let end = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                if line.hasPrefix("duration_us="), let value = Double(line.dropFirst("duration_us=".count)) {
                    duration = value
                }
                if duration > 0, line.hasPrefix("out_time_us="),
                   let value = Double(line.dropFirst("out_time_us=".count)) {
                    let progress = max(0, min(0.99, value / duration))
                    if progress >= lastProgress + 0.007 {
                        lastProgress = progress
                        onProgress(progress)
                    }
                }
            }
            if buffer.count > 64_000 { buffer.removeAll() }
        }
        process.waitUntilExit()
        guard !control.isCancelled else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let logReader = try? FileHandle(forReadingFrom: logfile)
            let size = (try? logReader?.seekToEnd()) ?? 0
            try? logReader?.seek(toOffset: size > 4_096 ? size - 4_096 : 0)
            let details = (try? logReader?.readToEnd())
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            try? logReader?.close()
            throw ExportError(message: details.isEmpty ? "Le fichier n’a pas pu être converti." : details)
        }

        let name = item.url.deletingPathExtension().lastPathComponent
        let label = item.kind == .photo ? "HDR" : format.rawValue.uppercased()
        return try control.publish(temporary, to: folder, basename: "\(name) – \(label)", ext: item.kind.outputExtension)
    }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var kind: MediaKind = .photo {
        didSet { if oldValue != kind { notice = nil } }
    }
    @Published var videoFormat: VideoFormat = .hlg
    @Published var isDropTarget = false
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var activeKind: MediaKind?
    @Published private(set) var isCancelling = false
    @Published private(set) var notice: String?
    @Published private(set) var folder: URL?
    @Published var issue: Issue?
    private var control: ExportControl?

    struct Issue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var visibleItems: [QueueItem] { items.filter { $0.kind == kind } }
    var isBusy: Bool { activeKind != nil }
    var canExport: Bool {
        !isBusy && visibleItems.contains {
            if case .done = $0.status { return false }
            return true
        }
    }

    func chooseInputs() {
        let picker = NSOpenPanel()
        picker.message = "Choisis \(kind == .photo ? "les photos" : "les vidéos") à traiter."
        picker.prompt = "Ajouter"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = kind.pickerTypes
        if picker.runModal() == .OK { add(picker.urls, to: kind) }
    }

    func add(_ urls: [URL], to kind: MediaKind) {
        guard !isBusy else { return }
        let normalized = urls.map(\.standardizedFileURL)
        let supported = normalized.filter {
            $0.isFileURL && kind.extensions.contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        for url in supported where !items.contains(where: { $0.url == url }) {
            items.append(QueueItem(url: url, kind: kind))
        }
        notice = normalized.count != supported.count
            ? "Certains fichiers ne sont pas compatibles avec cet onglet." : nil
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        items.removeAll { $0.id == id }
    }

    func clear() {
        guard !isBusy else { return }
        items.removeAll { $0.kind == kind }
        notice = nil
    }

    func show(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func chooseDestinationAndExport() {
        guard canExport else { return }
        let picker = NSOpenPanel()
        picker.message = "Où veux-tu exporter les fichiers traités ?"
        picker.prompt = "Exporter ici"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = folder
        guard picker.runModal() == .OK, let destination = picker.url else { return }
        start(to: destination)
    }

    private func start(to destination: URL) {
        let toConvert = visibleItems.filter {
            if case .done = $0.status { return false }
            return true
        }
        let format = videoFormat
        let control = ExportControl()
        self.control = control
        activeKind = kind
        notice = nil
        folder = destination
        var done = 0
        var failed = 0

        Task { [self] in
            for item in toConvert {
                guard !control.isCancelled else { break }
                update(item.id, to: .processing(nil))
                do {
                    let output = try await Task.detached(priority: .userInitiated) { [weak self] in
                        try Converter.export(item, to: destination, format: format, control: control) { [weak self] value in
                            Task { @MainActor [weak self] in
                                self?.progress(item.id, value)
                            }
                        }
                    }.value
                    update(item.id, to: .done(output))
                    done += 1
                } catch is CancellationError {
                    update(item.id, to: .cancelled)
                    break
                } catch {
                    update(item.id, to: .failed(error.localizedDescription))
                    failed += 1
                }
            }
            if control.isCancelled {
                notice = done == 0 ? "Traitement arrêté." : "Traitement arrêté · \(done) exporté(s)."
            } else {
                let successful = done <= 1 ? "\(done) fichier exporté" : "\(done) fichiers exportés"
                notice = failed > 0 ? "\(successful) · \(failed) échec(s)" : successful
            }
            activeKind = nil
            isCancelling = false
            self.control = nil
        }
    }

    func cancel() {
        isCancelling = true
        control?.cancel()
    }

    private func update(_ id: UUID, to status: QueueItem.Status) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = status }
    }

    private func progress(_ id: UUID, _ fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .processing = items[index].status else { return }
        items[index].status = .processing(fraction)
    }
}

@main
struct HDRStudioApp: App {
    var body: some Scene {
        Window("HDR Studio", id: "studio") { StudioView() }
            .defaultSize(width: 640, height: 620)
    }
}

struct StudioView: View {
    @StateObject private var model = StudioModel()
    private let mint = Color(red: 0.64, green: 0.94, blue: 0.84)
    private let backdrop = Color(red: 0.065, green: 0.075, blue: 0.09)
    private let surface = Color(red: 0.095, green: 0.114, blue: 0.133)
    private let line = Color.white.opacity(0.11)

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            header

            Picker("Type de fichier", selection: $model.kind) {
                ForEach(MediaKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .disabled(model.isBusy)

            dropZone

            if model.kind == .video {
                HStack {
                    Label("Format vidéo", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Format vidéo", selection: $model.videoFormat) {
                        ForEach(VideoFormat.allCases) { format in Text(format.label).tag(format) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.isBusy)
                }
            } else {
                Label("Sortie : HEIC HDR · 10 bits", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            queue
            Divider().overlay(line)
            footer
        }
        .padding(27)
        .padding(.top, 7)
        .frame(minWidth: 535, minHeight: 558)
        .background(backdrop)
        .preferredColorScheme(.dark)
        .alert(item: $model.issue) { issue in
            Alert(title: Text(issue.title), message: Text(issue.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(surface)
                RoundedRectangle(cornerRadius: 13).strokeBorder(line)
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 23, weight: .semibold))
                    .rotationEffect(.degrees(-30))
                    .foregroundStyle(mint)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("HDR Studio").font(.system(size: 29, weight: .bold))
                Text("Tes photos et vidéos en HDR, sur ton Mac.").foregroundStyle(.secondary)
            }
            Spacer()
            Text("10 BITS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(mint)
                .background(mint.opacity(0.11), in: Capsule())
                .accessibilityHidden(true)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(mint)
                .accessibilityHidden(true)
            Text(model.kind.title).font(.headline)
            Text(model.kind.description).font(.subheadline).foregroundStyle(.secondary)
            Button("Choisir des fichiers…") { model.chooseInputs() }
                .controlSize(.regular)
                .padding(.top, 4)
                .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 154)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(model.isDropTarget ? mint.opacity(0.14) : surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(
                model.isDropTarget ? mint : mint.opacity(0.35),
                style: StrokeStyle(lineWidth: 1, dash: [5, 5])
            )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTarget) { providers in
            guard !model.isBusy else { return false }
            let kind = model.kind
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    let url = (value as? URL) ?? (value as? Data).flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                    if let url { Task { @MainActor in model.add([url], to: kind) } }
                }
            }
            return !providers.isEmpty
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("FICHIERS").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.25).foregroundStyle(.secondary)
                Text("\(model.visibleItems.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !model.visibleItems.isEmpty {
                    Button("Vider la liste") { model.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.isBusy)
                }
            }
            if model.visibleItems.isEmpty {
                VStack {
                    Text("Aucun fichier ajouté").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.visibleItems) { item in fileRow(item) }
                    }
                }
            }
        }
        .frame(minHeight: 88, maxHeight: .infinity)
    }

    private func fileRow(_ item: QueueItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                .help(item.url.path)
            Spacer(minLength: 12)
            switch item.status {
            case .ready:
                Button { model.remove(item.id) } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retirer \(item.url.lastPathComponent)")
                    .disabled(model.isBusy)
            case .processing(let fraction):
                if let fraction {
                    ProgressView(value: fraction).frame(width: 76)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .done(let output):
                Button { model.show(output) } label: { Label("Exporté", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(mint)
                    .help("Afficher le fichier dans le Finder")
            case .failed(let reason):
                Button {
                    model.issue = .init(title: "Échec de l’export", message: reason)
                } label: { Label("Détails", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.orange)
            case .cancelled:
                Text("Arrêté").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Text(notice).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(model.isBusy ? "Export en cours…" : "Les originaux sont conservés.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.isBusy {
                Button(model.isCancelling ? "Arrêt…" : "Arrêter") { model.cancel() }
                    .controlSize(.large)
                    .disabled(model.isCancelling)
            } else {
                Button {
                    model.chooseDestinationAndExport()
                } label: {
                    Label("Traiter", systemImage: "arrow.right")
                        .font(.headline).padding(.horizontal, 13).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(mint)
                .foregroundStyle(model.canExport ? .black : .secondary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
            }
        }
        .frame(minHeight: 32)
    }
}
