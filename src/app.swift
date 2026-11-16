import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Thème

enum Theme {
    static let bg = NSColor(srgbRed: 0.059, green: 0.063, blue: 0.075, alpha: 1)
    static let panel = NSColor(srgbRed: 0.098, green: 0.106, blue: 0.125, alpha: 1)
    static let panelHi = NSColor(srgbRed: 0.149, green: 0.161, blue: 0.188, alpha: 1)
    static let line = NSColor(white: 1, alpha: 0.09)
    static let text = NSColor(white: 1, alpha: 0.93)
    static let dim = NSColor(white: 1, alpha: 0.56)
    static let accent = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.27, alpha: 1)
    static let onAccent = NSColor(srgbRed: 0.10, green: 0.07, blue: 0.02, alpha: 1)
    static let ok = NSColor(srgbRed: 0.43, green: 0.86, blue: 0.62, alpha: 1)
    static let bad = NSColor(srgbRed: 1.0, green: 0.47, blue: 0.43, alpha: 1)
}

func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    l.translatesAutoresizingMaskIntoConstraints = false
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

func spacedCaps(_ s: String, color: NSColor = Theme.dim, size: CGFloat = 10.5) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .kern: 1.4, .foregroundColor: color,
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    ])
}

// MARK: - Conversion

func uniqueURL(in dir: URL, stem: String, suffix: String, ext: String) -> URL {
    var u = dir.appendingPathComponent(stem + suffix + "." + ext)
    var n = 2
    while FileManager.default.fileExists(atPath: u.path) {
        u = dir.appendingPathComponent("\(stem)\(suffix) \(n).\(ext)")
        n += 1
    }
    return u
}

let sharedCIContext = CIContext()

/// Photo SDR vers HEIC avec gain map HDR. Les hautes lumières sont rehaussées
/// (courbe r + k·r³ en lumière linéaire), les ombres et tons moyens restent en place.
func convertPhoto(_ src: URL, _ out: URL, stops: Double) -> String? {
    guard let base = CIImage(contentsOf: src, options: [CIImageOption.applyOrientationProperty: true]) else {
        return "Image illisible"
    }
    let k = CGFloat(pow(2.0, stops) - 1.0)
    let c = CIVector(x: 0, y: 1, z: 0, w: k)
    let hdr = base.applyingFilter("CIColorPolynomial", parameters: [
        "inputRedCoefficients": c, "inputGreenCoefficients": c, "inputBlueCoefficients": c,
        "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
    ])
    guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return "Espace colorimétrique indisponible" }
    guard let data = sharedCIContext.heifRepresentation(
        of: base, format: CIFormat.RGBA8, colorSpace: p3,
        options: [CIImageRepresentationOption.hdrImage: hdr]) else { return "Encodage HDR impossible" }
    do { try data.write(to: out) } catch { return "Écriture impossible dans le dossier d'export" }
    return nil
}

func convertVideo(_ src: URL, _ out: URL, mode: String, stops: Double) -> String? {
    guard let script = Bundle.main.path(forResource: "hdrvideo", ofType: "sh") else {
        return "Moteur vidéo introuvable dans l'app"
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script, src.path, out.path, mode, String(format: "%.2f", stops)]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "Lancement du moteur vidéo impossible" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return nil }
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").last.map(String.init) ?? "Erreur inconnue"
}

// MARK: - Mode ligne de commande (tests)

do {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--convert-photo"), a.count > i + 3 {
        let e = convertPhoto(URL(fileURLWithPath: a[i + 1]), URL(fileURLWithPath: a[i + 2]), stops: Double(a[i + 3]) ?? 1.3)
        print(e ?? "OK"); exit(e == nil ? 0 : 1)
    }
    if let i = a.firstIndex(of: "--convert-video"), a.count > i + 4 {
        let e = convertVideo(URL(fileURLWithPath: a[i + 1]), URL(fileURLWithPath: a[i + 2]), mode: a[i + 3], stops: Double(a[i + 4]) ?? 2.0)
        print(e ?? "OK"); exit(e == nil ? 0 : 1)
    }
}

// MARK: - Modèle

final class Item {
    enum State { case waiting, running, done, failed }
    let url: URL
    var state: State = .waiting
    var output: URL?
    var message = ""
    init(_ url: URL) { self.url = url }
}

// MARK: - Composants

final class FlatButton: NSButton {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind
    override var isEnabled: Bool { didSet { restyle() } }

    init(_ title: String, kind: Kind, target: AnyObject?, action: Selector?) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }

    func setTitle(_ t: String) { title = t; restyle(); invalidateIntrinsicContentSize() }

    func restyle() {
        let fg: NSColor
        let bg: NSColor
        switch kind {
        case .primary:
            bg = isEnabled ? Theme.accent : Theme.panelHi
            fg = isEnabled ? Theme.onAccent : Theme.dim
        case .secondary:
            bg = Theme.panelHi
            fg = isEnabled ? Theme.text : Theme.dim
        case .ghost:
            bg = .clear
            fg = isEnabled ? Theme.dim : Theme.dim.withAlphaComponent(0.4)
        }
        layer?.cornerRadius = kind == .primary ? 11 : 8
        layer?.backgroundColor = bg.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: kind == .primary ? 14 : 13, weight: kind == .primary ? .semibold : .medium)
        ])
    }
    override var intrinsicContentSize: NSSize {
        let w = ceil(attributedTitle.size().width)
        switch kind {
        case .primary: return NSSize(width: max(w + 44, 150), height: 40)
        case .secondary: return NSSize(width: w + 28, height: 30)
        case .ghost: return NSSize(width: w + 12, height: 24)
        }
    }
}

final class Segment: NSView {
    var onChange: ((Int) -> Void)?
    private var buttons: [NSButton] = []
    var selected = 0 { didSet { restyle() } }
    var isEnabled = true { didSet { buttons.forEach { $0.isEnabled = isEnabled } } }

    init(titles: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, t) in titles.enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.focusRingType = .none
            b.setButtonType(.momentaryChange)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 104).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }

    @objc func tap(_ s: NSButton) {
        guard s.tag != selected else { return }
        selected = s.tag
        onChange?(selected)
    }
    func restyle() {
        layer?.backgroundColor = Theme.panel.cgColor
        layer?.cornerRadius = 12
        for b in buttons {
            let on = b.tag == selected
            b.layer?.cornerRadius = 9
            b.layer?.backgroundColor = (on ? Theme.accent : NSColor.clear).cgColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: on ? Theme.onAccent : Theme.dim,
                .font: NSFont.systemFont(ofSize: 13.5, weight: on ? .semibold : .medium)
            ])
        }
    }
}

final class DropZone: NSView {
    var onFiles: (([URL]) -> Void)?
    var onChoose: (() -> Void)?
    private let border = CAShapeLayer()
    private let icon = NSImageView()
    let title = makeLabel("", size: 16, weight: .semibold)
    let sub = makeLabel("", size: 12.5, color: Theme.dim)
    private var hot = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        icon.contentTintColor = Theme.accent
        let choose = FlatButton("Choisir des fichiers…", kind: .secondary, target: self, action: #selector(chooseTapped))
        let stack = NSStackView(views: [icon, title, sub, choose])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }

    override func layout() {
        super.layout()
        if border.superlayer == nil { layer?.addSublayer(border) }
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 16, cornerHeight: 16, transform: nil)
    }
    private func restyle() {
        layer?.cornerRadius = 16
        layer?.backgroundColor = (hot ? Theme.accent.withAlphaComponent(0.10) : Theme.panel).cgColor
        border.fillColor = nil
        border.lineWidth = 1.5
        border.lineDashPattern = [7, 6]
        border.strokeColor = (hot ? Theme.accent : NSColor(white: 1, alpha: 0.20)).cgColor
    }
    @objc private func chooseTapped() { onChoose?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hot = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { hot = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { hot = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hot = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        onFiles?(urls)
        return true
    }
}

final class FileRow: NSView {
    private let item: Item
    private let onAction: () -> Void

    init(item: Item, locked: Bool, onAction: @escaping () -> Void) {
        self.item = item
        self.onAction = onAction
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let name = makeLabel(item.url.lastPathComponent, size: 13, weight: .medium)
        let detail = makeLabel("", size: 11.5, color: Theme.dim)
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.translatesAutoresizingMaskIntoConstraints = false

        let lead: NSView
        var trailing: NSView?
        switch item.state {
        case .waiting:
            lead = FileRow.symbol("circle.dashed", Theme.dim)
            detail.stringValue = FileRow.sizeText(item.url)
            if !locked {
                let b = FlatButton("Retirer", kind: .ghost, target: self, action: #selector(act))
                trailing = b
            }
        case .running:
            let sp = NSProgressIndicator()
            sp.style = .spinning
            sp.controlSize = .small
            sp.translatesAutoresizingMaskIntoConstraints = false
            sp.startAnimation(nil)
            lead = sp
            detail.stringValue = "Conversion en cours…"
            detail.textColor = Theme.accent
        case .done:
            lead = FileRow.symbol("checkmark.circle.fill", Theme.ok)
            detail.stringValue = item.output?.lastPathComponent ?? "Terminé"
            trailing = FlatButton("Afficher", kind: .ghost, target: self, action: #selector(act))
        case .failed:
            lead = FileRow.symbol("exclamationmark.triangle.fill", Theme.bad)
            detail.stringValue = item.message.isEmpty ? "Échec" : item.message
            detail.textColor = Theme.bad
            detail.toolTip = item.message
            if !locked { trailing = FlatButton("Retirer", kind: .ghost, target: self, action: #selector(act)) }
        }
        addSubview(lead)
        addSubview(texts)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            lead.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lead.centerYAnchor.constraint(equalTo: centerYAnchor),
            lead.widthAnchor.constraint(equalToConstant: 18),
            texts.leadingAnchor.constraint(equalTo: lead.trailingAnchor, constant: 12),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if let t = trailing {
            addSubview(t)
            NSLayoutConstraint.activate([
                t.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                t.centerYAnchor.constraint(equalTo: centerYAnchor),
                texts.trailingAnchor.constraint(lessThanOrEqualTo: t.leadingAnchor, constant: -10)
            ])
        } else {
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.cornerRadius = 10
        layer?.backgroundColor = Theme.panel.cgColor
    }
    @objc private func act() { onAction() }

    static func symbol(_ name: String, _ color: NSColor) -> NSImageView {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        v.contentTintColor = color
        return v
    }
    static func sizeText(_ url: URL) -> String {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return "En attente" }
        return ByteCountFormatter.string(fromByteCount: n.int64Value, countStyle: .file)
    }
}

final class IconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        Theme.panelHi.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width * 0.27, yRadius: r.width * 0.27).fill()
        let c = NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.25, dy: r.width * 0.25))
        NSGradient(colors: [NSColor.white, Theme.accent, NSColor(srgbRed: 0.86, green: 0.34, blue: 0.14, alpha: 1)])?
            .draw(in: c, angle: -50)
    }
}

final class Badge: NSView {
    private let l = NSTextField(labelWithString: "")
    var text = "" { didSet { l.attributedStringValue = spacedCaps(text, color: Theme.accent) } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            l.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Fenêtre principale

final class MainController: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mode = 0                      // 0 = photo, 1 = vidéo
    var items: [[Item]] = [[], []]
    var running = false
    var destination: URL?

    let segment = Segment(titles: ["Photo", "Vidéo"])
    let badge = Badge()
    let drop = DropZone(frame: .zero)
    let photoSlider = NSSlider(value: 1.3, minValue: 0.5, maxValue: 2.5, target: nil, action: nil)
    let videoSlider = NSSlider(value: 2.0, minValue: 1.0, maxValue: 3.0, target: nil, action: nil)
    let photoValue = makeLabel("", size: 12.5, weight: .medium)
    let videoValue = makeLabel("", size: 12.5, weight: .medium)
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var photoOpts: NSStackView!
    var videoOpts: NSStackView!
    let listTitle = NSTextField(labelWithString: "")
    var clearButton: FlatButton!
    let scroll = NSScrollView()
    let listDoc = FlippedView()
    let emptyLabel = makeLabel("Aucun fichier ajouté", size: 13, color: Theme.dim)
    let progress = NSProgressIndicator()
    let destLabel = makeLabel("", size: 12.5, weight: .medium)
    let hintLabel = makeLabel("Les originaux ne sont jamais modifiés.", size: 11.5, color: Theme.dim)
    var destButton: FlatButton!
    var goButton: FlatButton!

    func applicationDidFinishLaunching(_ note: Notification) {
        if let p = UserDefaults.standard.string(forKey: "destination"), FileManager.default.fileExists(atPath: p) {
            destination = URL(fileURLWithPath: p)
        }
        buildMenu()
        buildWindow()
        let a = CommandLine.arguments
        if a.contains("--demo") { loadDemo() }
        if let i = a.firstIndex(of: "--tab"), a.count > i + 1, a[i + 1] == "video" { mode = 1; segment.selected = 1 }
        refreshAll()
        if let i = a.firstIndex(of: "--snapshot"), a.count > i + 1 {
            let path = a[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.snapshot(to: path) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: Construction

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Masquer HDR Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter HDR Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Fichier")
        let open = NSMenuItem(title: "Ajouter des fichiers…", action: #selector(chooseFiles), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        let dest = NSMenuItem(title: "Dossier d'export…", action: #selector(chooseDestination), keyEquivalent: "e")
        dest.target = self
        fileMenu.addItem(dest)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "HDR Studio"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.bg
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 660, height: 620)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = root

        // En-tête
        let icon = IconView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = makeLabel("HDR Studio", size: 26, weight: .bold)
        let subtitle = makeLabel("Photos HDR et vidéos Dolby Vision, traitées sur ton Mac.", size: 13.5, color: Theme.dim)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        titles.translatesAutoresizingMaskIntoConstraints = false

        segment.onChange = { [weak self] i in self?.mode = i; self?.refreshAll() }
        drop.onFiles = { [weak self] urls in self?.add(urls) }
        drop.onChoose = { [weak self] in self?.chooseFiles() }

        // Options
        for s in [photoSlider, videoSlider] {
            s.target = self
            s.action = #selector(sliderMoved)
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        formatPopup.addItems(withTitles: ["Dolby Vision 8.1 · 10 bits", "HDR10 · 10 bits"])
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        photoOpts = NSStackView(views: [makeLabel("Intensité des hautes lumières", size: 12.5, color: Theme.dim), photoSlider, photoValue])
        videoOpts = NSStackView(views: [makeLabel("Format", size: 12.5, color: Theme.dim), formatPopup,
                                        makeLabel("Intensité", size: 12.5, color: Theme.dim), videoSlider, videoValue])
        videoOpts.setCustomSpacing(22, after: formatPopup)
        for o in [photoOpts!, videoOpts!] {
            o.spacing = 10
            o.translatesAutoresizingMaskIntoConstraints = false
        }

        // Liste
        listTitle.translatesAutoresizingMaskIntoConstraints = false
        clearButton = FlatButton("Tout retirer", kind: .ghost, target: self, action: #selector(clearAll))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = listDoc
        emptyLabel.alignment = .center

        // Pied
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.line.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        destButton = FlatButton("Changer…", kind: .secondary, target: self, action: #selector(chooseDestination))
        goButton = FlatButton("Traiter", kind: .primary, target: self, action: #selector(process))
        goButton.keyEquivalent = "\r"
        let destTexts = NSStackView(views: [destLabel, hintLabel])
        destTexts.orientation = .vertical
        destTexts.alignment = .leading
        destTexts.spacing = 3
        destTexts.translatesAutoresizingMaskIntoConstraints = false

        for v in [icon, titles, badge, segment, drop, photoOpts!, videoOpts!, listTitle, clearButton!, scroll,
                  emptyLabel, rule, progress, destTexts, destButton!, goButton!] as [NSView] {
            root.addSubview(v)
        }
        let m: CGFloat = 30
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            icon.widthAnchor.constraint(equalToConstant: 54),
            icon.heightAnchor.constraint(equalToConstant: 54),
            titles.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            titles.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            badge.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),

            segment.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            segment.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24),

            drop.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            drop.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            drop.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 16),
            drop.heightAnchor.constraint(equalToConstant: 178),

            photoOpts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            photoOpts.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 16),
            photoOpts.heightAnchor.constraint(equalToConstant: 28),
            videoOpts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            videoOpts.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 16),
            videoOpts.heightAnchor.constraint(equalToConstant: 28),

            listTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            listTitle.topAnchor.constraint(equalTo: photoOpts.bottomAnchor, constant: 22),
            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            clearButton.centerYAnchor.constraint(equalTo: listTitle.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            scroll.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -14),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -84),
            progress.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            progress.centerYAnchor.constraint(equalTo: rule.centerYAnchor),

            goButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            goButton.centerYAnchor.constraint(equalTo: rule.bottomAnchor, constant: 42),
            destTexts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            destTexts.centerYAnchor.constraint(equalTo: goButton.centerYAnchor),
            destButton.leadingAnchor.constraint(equalTo: destTexts.trailingAnchor, constant: 12),
            destButton.centerYAnchor.constraint(equalTo: goButton.centerYAnchor),
            destButton.trailingAnchor.constraint(lessThanOrEqualTo: goButton.leadingAnchor, constant: -16)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Affichage

    func refreshAll() {
        let photo = mode == 0
        badge.text = photo ? "HEIC · GAIN MAP HDR" : "HEVC 10 BITS · DOLBY VISION"
        drop.title.stringValue = photo ? "Dépose tes photos ici" : "Dépose tes vidéos ici"
        drop.sub.stringValue = photo ? "JPEG, PNG, HEIC, TIFF et autres images" : "MOV, MP4, MKV et autres vidéos"
        photoOpts.isHidden = !photo
        videoOpts.isHidden = photo
        photoValue.stringValue = String(format: "+%.1f stop", photoSlider.doubleValue)
        videoValue.stringValue = String(format: "+%.1f stop", videoSlider.doubleValue)
        segment.isEnabled = !running
        for c in [photoSlider, videoSlider, formatPopup] as [NSControl] { c.isEnabled = !running }
        destButton.isEnabled = !running
        if let d = destination {
            destLabel.stringValue = "Export vers « \(d.lastPathComponent) »"
            destButton.setTitle("Changer…")
        } else {
            destLabel.stringValue = "Dossier d'export à choisir"
            destButton.setTitle("Choisir…")
        }
        progress.isHidden = !running
        reloadList()
    }

    func reloadList() {
        let list = items[mode]
        let pending = list.filter { $0.state == .waiting || $0.state == .failed }.count
        let done = list.filter { $0.state == .done }.count
        var head = "FICHIERS  \(list.count)"
        if done > 0 { head += "   ·   \(done) TERMINÉ" + (done > 1 ? "S" : "") }
        listTitle.attributedStringValue = spacedCaps(head)
        clearButton.isHidden = list.isEmpty || running
        emptyLabel.isHidden = !list.isEmpty

        listDoc.subviews.forEach { $0.removeFromSuperview() }
        let w = max(scroll.contentSize.width, 100)
        let rowH: CGFloat = 48, gap: CGFloat = 6
        for (i, it) in list.enumerated() {
            let row = FileRow(item: it, locked: running) { [weak self] in self?.rowAction(it) }
            row.translatesAutoresizingMaskIntoConstraints = true
            row.autoresizingMask = [.width]
            row.frame = NSRect(x: 0, y: CGFloat(i) * (rowH + gap), width: w, height: rowH)
            listDoc.addSubview(row)
        }
        listDoc.autoresizingMask = [.width]
        listDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(CGFloat(list.count) * (rowH + gap), 1))

        if running {
            let n = Int(progress.doubleValue) + 1
            goButton.setTitle("Traitement \(min(n, Int(progress.maxValue)))/\(Int(progress.maxValue))…")
            goButton.isEnabled = false
        } else {
            let noun = mode == 0 ? "photo" : "vidéo"
            goButton.setTitle(pending == 0 ? "Traiter" : "Traiter \(pending) \(noun)" + (pending > 1 ? "s" : ""))
            goButton.isEnabled = pending > 0
        }
    }

    // MARK: Actions

    @objc func sliderMoved() {
        photoValue.stringValue = String(format: "+%.1f stop", photoSlider.doubleValue)
        videoValue.stringValue = String(format: "+%.1f stop", videoSlider.doubleValue)
    }

    func accepts(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return mode == 0 ? t.conforms(to: .image) : (t.conforms(to: .movie) || t.conforms(to: .video))
    }

    func add(_ urls: [URL]) {
        guard !running else { return }
        var added = 0
        for u in urls where accepts(u) && !items[mode].contains(where: { $0.url == u }) {
            items[mode].append(Item(u))
            added += 1
        }
        if added == 0 { NSSound.beep() }
        reloadList()
    }

    @objc func chooseFiles() {
        guard !running else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.allowedContentTypes = mode == 0 ? [.image] : [.movie, .video]
        p.prompt = "Ajouter"
        if p.runModal() == .OK { add(p.urls) }
    }

    @objc func chooseDestination() {
        guard !running else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Exporter ici"
        p.message = "Choisis le dossier dans lequel enregistrer les fichiers convertis."
        if p.runModal() == .OK, let u = p.url {
            destination = u
            UserDefaults.standard.set(u.path, forKey: "destination")
            refreshAll()
        }
    }

    @objc func clearAll() {
        guard !running else { return }
        items[mode].removeAll()
        reloadList()
    }

    func rowAction(_ it: Item) {
        if it.state == .done, let o = it.output {
            NSWorkspace.shared.activateFileViewerSelecting([o])
        } else if !running {
            items[mode].removeAll { $0 === it }
            reloadList()
        }
    }

    @objc func process() {
        guard !running else { return }
        let pending = items[mode].filter { $0.state == .waiting || $0.state == .failed }
        guard !pending.isEmpty else { return }
        if destination == nil { chooseDestination() }
        guard let dest = destination else { return }

        let m = mode
        let stops = m == 0 ? photoSlider.doubleValue : videoSlider.doubleValue
        let format = formatPopup.indexOfSelectedItem == 0 ? "dv" : "hdr10"
        running = true
        progress.minValue = 0
        progress.maxValue = Double(pending.count)
        progress.doubleValue = 0
        refreshAll()

        DispatchQueue.global(qos: .userInitiated).async {
            for it in pending {
                DispatchQueue.main.sync { it.state = .running; it.message = ""; self.reloadList() }
                let stem = it.url.deletingPathExtension().lastPathComponent
                let out = m == 0
                    ? uniqueURL(in: dest, stem: stem, suffix: "_HDR", ext: "heic")
                    : uniqueURL(in: dest, stem: stem, suffix: format == "dv" ? "_DV" : "_HDR10", ext: "mp4")
                let err = m == 0 ? convertPhoto(it.url, out, stops: stops)
                                 : convertVideo(it.url, out, mode: format, stops: stops)
                DispatchQueue.main.sync {
                    if let err { it.state = .failed; it.message = err } else { it.state = .done; it.output = out }
                    self.progress.doubleValue += 1
                    self.reloadList()
                }
            }
            DispatchQueue.main.async {
                self.running = false
                self.refreshAll()
            }
        }
    }

    // MARK: Démo et capture (tests)

    func loadDemo() {
        let names = mode == 0
            ? ["Grand-Place au crépuscule.jpg", "IMG_4821.HEIC", "Atomium nuit.jpg", "scan_ancien.tiff"]
            : ["Drone Cinquantenaire.mov", "IMG_7730.MOV", "interview_plan2.mp4", "essai.mkv"]
        for (k, list) in [(0, names), (1, ["Drone Cinquantenaire.mov", "IMG_7730.MOV", "interview_plan2.mp4", "essai.mkv"])] {
            let src = k == 0 ? (mode == 0 ? list : ["Grand-Place au crépuscule.jpg", "IMG_4821.HEIC", "Atomium nuit.jpg", "scan_ancien.tiff"]) : list
            items[k] = src.map { Item(URL(fileURLWithPath: "/tmp/demo/" + $0)) }
            items[k][0].state = .done
            items[k][0].output = URL(fileURLWithPath: "/tmp/demo/" + (k == 0 ? "Grand-Place au crépuscule_HDR.heic" : "Drone Cinquantenaire_DV.mp4"))
            items[k][1].state = .running
            items[k][3].state = .failed
            items[k][3].message = k == 0 ? "Image illisible" : "Échec de l'encodage"
        }
        destination = URL(fileURLWithPath: "/tmp/Exports HDR")
    }

    func snapshot(to path: String) {
        guard let v = window.contentView else { exit(1) }
        v.layoutSubtreeIfNeeded()
        reloadList()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = MainController()
app.delegate = controller
app.run()
