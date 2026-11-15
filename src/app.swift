import AppKit
import UniformTypeIdentifiers
import CoreImage

func runPhoto(_ src: URL, _ dest: URL, _ ev: Double) -> String {
    let ctx = CIContext()
    guard let base = CIImage(contentsOf: src) else { return "Echec lecture: \(src.lastPathComponent)" }
    let hdr = base.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev])
    guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return "Echec espace" }
    let out = dest.appendingPathComponent(src.deletingPathExtension().lastPathComponent + "_HDR.heic")
    guard let data = ctx.heifRepresentation(of: base, format: CIFormat.RGBA8, colorSpace: p3,
        options: [CIImageRepresentationOption.hdrImage: hdr]) else { return "Echec HDR: \(src.lastPathComponent)" }
    do { try data.write(to: out); return out.lastPathComponent } catch { return "Echec ecriture: \(src.lastPathComponent)" }
}

func runVideo(_ src: URL, _ dest: URL) -> String {
    let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hdrvideo.sh").path
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/bash")
    t.arguments = [script, src.path, dest.path]
    let pipe = Pipe(); t.standardOutput = pipe; t.standardError = pipe
    do { try t.run(); t.waitUntilExit() } catch { return "Echec lancement: \(src.lastPathComponent)" }
    return t.terminationStatus == 0 ? (src.lastPathComponent + " vers DV") : ("Echec: " + src.lastPathComponent)
}

final class PanelView: NSView {
    let isVideo: Bool
    var files: [URL] = [] { didSet { updateLabels() } }
    var destination: URL? { didSet { updateLabels() } }

    let filesLabel = NSTextField(labelWithString: "0 fichier(s)")
    let destLabel = NSTextField(labelWithString: "Aucun dossier choisi")
    let dropLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let exportButton = NSButton()
    let evSlider = NSSlider(value: 1.3, minValue: 0.5, maxValue: 2.5, target: nil, action: nil)
    let evLabel = NSTextField(labelWithString: "1.3")
    let statusLabel = NSTextField(labelWithString: "")

    init(isVideo: Bool) {
        self.isVideo = isVideo
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        buildUI()
        updateLabels()
    }
    required init?(coder: NSCoder) { fatalError() }

    func buildUI() {
        let drop = NSBox()
        drop.boxType = .custom
        drop.borderType = .lineBorder
        drop.borderColor = NSColor.separatorColor
        drop.borderWidth = 2
        drop.cornerRadius = 12
        drop.fillColor = NSColor.clear
        dropLabel.alignment = .center
        dropLabel.textColor = .secondaryLabelColor
        dropLabel.lineBreakMode = .byTruncatingMiddle
        drop.contentView = dropLabel
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let addButton = NSButton(title: "Ajouter...", target: self, action: #selector(addFiles))
        let clearButton = NSButton(title: "Vider", target: self, action: #selector(clearFiles))
        let row1 = NSStackView(views: [addButton, clearButton, filesLabel]); row1.spacing = 10

        let destButton = NSButton(title: "Dossier d'export...", target: self, action: #selector(pickDest))
        let row2 = NSStackView(views: [destButton, destLabel]); row2.spacing = 10
        destLabel.lineBreakMode = .byTruncatingMiddle

        exportButton.title = isVideo ? "Exporter en Dolby Vision" : "Exporter en HDR"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(doExport)
        exportButton.keyEquivalent = "\r"

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true

        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(drop)
        stack.addArrangedSubview(row1)
        if !isVideo {
            evSlider.target = self; evSlider.action = #selector(evChanged)
            evSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let evRow = NSStackView(views: [NSTextField(labelWithString: "Intensité HDR"), evSlider, evLabel])
            evRow.spacing = 10
            stack.addArrangedSubview(evRow)
        } else {
            let t = NSTextField(labelWithString: "Sortie : Dolby Vision 10 bits, profil 8.1 (base HDR10)")
            t.textColor = .secondaryLabelColor
            stack.addArrangedSubview(t)
        }
        stack.addArrangedSubview(row2)
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(exportButton)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc func evChanged() { evLabel.stringValue = String(format: "%.1f", evSlider.doubleValue) }
    @objc func addFiles() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls where !files.contains(u) { files.append(u) } }
    }
    @objc func clearFiles() { files.removeAll() }
    @objc func pickDest() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false; p.prompt = "Choisir"
        if p.runModal() == .OK { destination = p.url }
    }
    func updateLabels() {
        filesLabel.stringValue = "\(files.count) fichier(s)"
        destLabel.stringValue = destination?.path ?? "Aucun dossier choisi"
        if files.isEmpty {
            dropLabel.stringValue = isVideo ? "Glisse tes vidéos ici (ou clique Ajouter)" : "Glisse tes photos ici (ou clique Ajouter)"
        } else {
            dropLabel.stringValue = files.map { $0.lastPathComponent }.joined(separator: ", ")
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        for u in urls where !files.contains(u) { files.append(u) }
        return true
    }

    @objc func doExport() {
        guard let dest = destination else { NSSound.beep(); return }
        guard !files.isEmpty else { return }
        let items = files, video = isVideo, ev = evSlider.doubleValue
        progress.isHidden = false; progress.maxValue = Double(items.count); progress.doubleValue = 0
        exportButton.isEnabled = false
        statusLabel.stringValue = "Traitement en cours..."
        DispatchQueue.global(qos: .userInitiated).async {
            var okc = 0
            for f in items {
                let msg = video ? runVideo(f, dest) : runPhoto(f, dest, ev)
                if !msg.hasPrefix("Echec") { okc += 1 }
                DispatchQueue.main.async { self.progress.doubleValue += 1; self.statusLabel.stringValue = msg }
            }
            let total = items.count, good = okc
            DispatchQueue.main.async {
                self.exportButton.isEnabled = true
                self.progress.isHidden = true
                self.statusLabel.stringValue = "Terminé."
                let a = NSAlert()
                a.messageText = "Export terminé"
                a.informativeText = "\(good)/\(total) fichier(s) traité(s) vers \(dest.lastPathComponent)."
                a.runModal()
            }
        }
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        let tab = NSTabView()
        let t1 = NSTabViewItem(); t1.label = "Photo"; t1.view = PanelView(isVideo: false)
        let t2 = NSTabViewItem(); t2.label = "Vidéo"; t2.view = PanelView(isVideo: true)
        tab.addTabViewItem(t1); tab.addTabViewItem(t2)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "HDR Studio"
        window.center()
        window.contentView = tab
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
