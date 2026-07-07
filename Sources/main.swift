import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Einstellungen

enum OutputFormat: String {
    case webp
    case png

    var fileExtension: String { rawValue }
    var utiString: String {
        switch self {
        case .webp: return "org.webmproject.webp"
        case .png: return UTType.png.identifier
        }
    }
}

struct Settings {
    var format: OutputFormat = .webp
    var roundingEnabled: Bool = true    // Ecken abrunden; sonst nur verkleinern + komprimieren
    var radiusPercent: Double = 22.37   // Apple-Squircle (System-Icons), continuous corners
    var quality: Double = 0.82          // nur für WebP (lossy)
    var optimizeLossy: Bool = true      // PNG: pngquant-Quantisierung erlauben (wie ImageOptim „lossy“)
    var resizeEnabled: Bool = true      // auf maxEdge verkleinern (nie vergrößern)
    var maxEdge: Int = 2500             // maximale Kantenlänge in Pixeln
    var cleanNames: Bool = true         // Leer-/Sonderzeichen im Dateinamen → _

    static func load() -> Settings {
        let d = UserDefaults.standard
        var s = Settings()
        if let raw = d.string(forKey: "format"), let f = OutputFormat(rawValue: raw) { s.format = f }
        if let g = d.object(forKey: "roundingEnabled") as? Bool { s.roundingEnabled = g }
        if let r = d.object(forKey: "radiusPercent") as? Double { s.radiusPercent = r }
        if let q = d.object(forKey: "quality") as? Double { s.quality = q }
        if let l = d.object(forKey: "optimizeLossy") as? Bool { s.optimizeLossy = l }
        if let e = d.object(forKey: "resizeEnabled") as? Bool { s.resizeEnabled = e }
        if let m = d.object(forKey: "maxEdge") as? Int, m > 0 { s.maxEdge = m }
        if let c = d.object(forKey: "cleanNames") as? Bool { s.cleanNames = c }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(format.rawValue, forKey: "format")
        d.set(roundingEnabled, forKey: "roundingEnabled")
        d.set(radiusPercent, forKey: "radiusPercent")
        d.set(quality, forKey: "quality")
        d.set(optimizeLossy, forKey: "optimizeLossy")
        d.set(resizeEnabled, forKey: "resizeEnabled")
        d.set(maxEdge, forKey: "maxEdge")
        d.set(cleanNames, forKey: "cleanNames")
    }
}

// Externe Kommandozeilen-Tools (Homebrew): cwebp für WebP-Export,
// pngquant + oxipng/optipng für die PNG-Optimierung (dieselben Kompressoren wie ImageOptim).
func findTool(_ name: String) -> String? {
    let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        return -1
    }
}

func webpEncodingSupported() -> Bool {
    if findTool("cwebp") != nil { return true }
    guard let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
    return ids.contains(OutputFormat.webp.utiString)
}

// PNG nachverdichten wie ImageOptim: erst pngquant (verlustarm quantisiert, spart am meisten),
// dann oxipng bzw. optipng (verlustfreie Restoptimierung). Fehlende Tools werden übersprungen.
func optimizePNG(at url: URL, lossy: Bool) {
    if lossy, let pngquant = findTool("pngquant") {
        // Exit-Codes 98/99 = Ergebnis wäre größer/Qualität nicht erreichbar → Original bleibt, ok.
        runTool(pngquant, ["--force", "--skip-if-larger", "--speed", "1", "--strip",
                           "--quality", "65-90", "--ext", ".png", url.path])
    }
    if let oxipng = findTool("oxipng") {
        runTool(oxipng, ["-o", "4", "--strip", "safe", "--quiet", url.path])
    } else if let optipng = findTool("optipng") {
        runTool(optipng, ["-quiet", "-o2", url.path])
    }
}

// MARK: - Bildverarbeitung

func loadCGImage(from url: URL, maxEdge: Int?) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
    // Über den Thumbnail-Weg laden: rechnet die EXIF-Ausrichtung ein (iPhone-Fotos)
    // und verkleinert in einem Rutsch hochwertig auf die maximale Kantenlänge.
    // Kleinere Bilder werden nie vergrößert.
    let fullEdge = max(w, h, 16)
    let limit = maxEdge.map { min($0, fullEdge) } ?? fullEdge
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: limit,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

// Web-tauglicher Dateiname: Umlaute → ae/oe/ue, Akzente entfernt,
// alles außer Buchstaben/Ziffern/Bindestrich → Unterstrich.
func sanitizedBaseName(_ base: String) -> String {
    var s = base
    for (from, to) in ["ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"] {
        s = s.replacingOccurrences(of: from, with: to)
    }
    s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-") {
            out.unicodeScalars.append(scalar)
        } else {
            out.append("_")
        }
    }
    while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return out.isEmpty ? "bild" : out
}

func roundedImage(_ image: CGImage, radiusPercent: Double) -> CGImage? {
    let width = image.width
    let height = image.height
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    let radius = CGFloat(min(width, height)) * CGFloat(min(max(radiusPercent, 0), 50)) / 100

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Exakt Apples Squircle-Kurve (wie bei System-Icons), nicht bloß Kreisecken.
    let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
        .path(in: rect).cgPath

    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: rect)
    return ctx.makeImage()
}

struct ProcessResult {
    var input: URL
    var output: URL?
    var error: String?
}

func freeOutputURL(for input: URL, suffix: String, fileExtension: String, cleanName: Bool) -> URL {
    let dir = input.deletingLastPathComponent()
    var base = input.deletingPathExtension().lastPathComponent
    if cleanName { base = sanitizedBaseName(base) }
    var candidate = dir.appendingPathComponent("\(base)\(suffix).\(fileExtension)")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base)\(suffix)-\(n).\(fileExtension)")
        n += 1
    }
    return candidate
}

func sourceUTI(of url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
}

func process(_ input: URL, settings: Settings) -> ProcessResult {
    let maxEdge = settings.resizeEnabled ? settings.maxEdge : nil
    guard let image = loadCGImage(from: input, maxEdge: maxEdge) else {
        return ProcessResult(input: input, output: nil, error: "Kein lesbares Bild")
    }

    func fail(_ message: String) -> ProcessResult {
        ProcessResult(input: input, output: nil, error: message)
    }

    // Mit Rundung: transparenzfähiges Zielformat (WebP/PNG laut Auswahl), Suffix „-rund“
    if settings.roundingEnabled {
        guard let rounded = roundedImage(image, radiusPercent: settings.radiusPercent) else {
            return fail("Verarbeitung fehlgeschlagen")
        }
        var format = settings.format
        if format == .webp && !webpEncodingSupported() { format = .png }

        let outURL = freeOutputURL(for: input, suffix: "-rund",
                                   fileExtension: format.fileExtension,
                                   cleanName: settings.cleanNames)
        if format == .webp {
            if let error = writeWebP(rounded, to: outURL, quality: settings.quality) {
                return fail(error)
            }
        } else {
            if let error = writeImageIO(rounded, to: outURL, uti: format.utiString) {
                return fail(error)
            }
            optimizePNG(at: outURL, lossy: settings.optimizeLossy)
        }
        return ProcessResult(input: input, output: outURL, error: nil)
    }

    // Ohne Rundung: Eingabeformat beibehalten, nur verkleinern + komprimieren,
    // Suffix = Pixel-Limit (wie beim alten Verkleinerungs-Droplet), z. B. „-2500“
    let suffix = settings.resizeEnabled ? "-\(settings.maxEdge)" : "-opt"
    let srcUTI = sourceUTI(of: input) ?? UTType.png.identifier
    let writableUTIs = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    let outURL: URL

    if srcUTI == OutputFormat.webp.utiString && webpEncodingSupported() {
        outURL = freeOutputURL(for: input, suffix: suffix, fileExtension: "webp",
                               cleanName: settings.cleanNames)
        if let error = writeWebP(image, to: outURL, quality: settings.quality) { return fail(error) }
    } else if srcUTI == UTType.jpeg.identifier {
        outURL = freeOutputURL(for: input, suffix: suffix, fileExtension: "jpg",
                               cleanName: settings.cleanNames)
        if let error = writeImageIO(image, to: outURL, uti: srcUTI, quality: settings.quality) {
            return fail(error)
        }
        if let jpegoptim = findTool("jpegoptim") {
            runTool(jpegoptim, ["-s", "--quiet", outURL.path])
        }
    } else if srcUTI != UTType.png.identifier && writableUTIs.contains(srcUTI) {
        // HEIC, TIFF, GIF … unverändert im Originalformat
        let ext = UTType(srcUTI)?.preferredFilenameExtension ?? input.pathExtension.lowercased()
        outURL = freeOutputURL(for: input, suffix: suffix, fileExtension: ext,
                               cleanName: settings.cleanNames)
        let lossyQuality = srcUTI == UTType.heic.identifier ? settings.quality : nil
        if let error = writeImageIO(image, to: outURL, uti: srcUTI, quality: lossyQuality) {
            return fail(error)
        }
    } else {
        // PNG-Eingabe oder nicht schreibbares Format → PNG mit Optimierung
        outURL = freeOutputURL(for: input, suffix: suffix, fileExtension: "png",
                               cleanName: settings.cleanNames)
        if let error = writeImageIO(image, to: outURL, uti: UTType.png.identifier) {
            return fail(error)
        }
        optimizePNG(at: outURL, lossy: settings.optimizeLossy)
    }
    return ProcessResult(input: input, output: outURL, error: nil)
}

func writeImageIO(_ image: CGImage, to url: URL, uti: String, quality: Double? = nil) -> String? {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
        return "Konnte Zieldatei nicht anlegen"
    }
    var props: [CFString: Any] = [:]
    if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? nil : "Speichern fehlgeschlagen"
}

func writeWebP(_ image: CGImage, to url: URL, quality: Double) -> String? {
    // Bevorzugt cwebp (bessere Kompression); als PNG zwischenspeichern und konvertieren.
    if let cwebp = findTool("cwebp") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rounddrop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let error = writeImageIO(image, to: tmp, uti: UTType.png.identifier) { return error }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cwebp)
        task.arguments = [
            "-q", String(Int(quality * 100)),
            "-alpha_q", "100",
            "-m", "6",
            "-metadata", "none",
            tmp.path, "-o", url.path,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "cwebp konnte nicht gestartet werden"
        }
        return task.terminationStatus == 0 ? nil : "cwebp-Fehler (Status \(task.terminationStatus))"
    }
    // Fallback: ImageIO, falls eine künftige macOS-Version WebP-Encoding kann
    return writeImageIO(image, to: url, uti: OutputFormat.webp.utiString, quality: quality)
}

// MARK: - Drop-Zone

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: inset, xRadius: 16, yRadius: 16)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        }
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var radiusField: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var roundCheckbox: NSButton!
    private var optimizeCheckbox: NSButton!
    private var resizeCheckbox: NSButton!
    private var maxEdgeField: NSTextField!
    private var cleanNamesCheckbox: NSButton!
    private var settings = Settings.load()
    private let queue = DispatchQueue(label: "rounddrop.processing", qos: .userInitiated)
    // Dateien, die ankommen, bevor das Fenster gebaut ist (das „Öffnen“-Event
    // kann vor applicationDidFinishLaunching eintreffen)
    private var pendingURLs: [URL] = []
    // Beenden erst erlauben, wenn keine Verarbeitung mehr läuft (sonst drohen halbfertige Dateien)
    private var runningBatches = 0
    private var quitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            handle(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if runningBatches > 0 {
            quitRequested = true
            statusLabel?.stringValue = "Moment – Verarbeitung läuft noch, beende danach …"
            return .terminateLater
        }
        return .terminateNow
    }

    // Wird aufgerufen, wenn Dateien auf das Dock-/Finder-Icon gezogen werden
    func application(_ application: NSApplication, open urls: [URL]) {
        if window == nil {
            pendingURLs.append(contentsOf: urls)
        } else {
            handle(urls)
        }
    }

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 420))

        let drop = DropView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.onDrop = { [weak self] urls in self?.handle(urls) }

        let title = label("Bilder hier ablegen", size: 15, weight: .semibold)
        title.alignment = .center
        let subtitle = label("verkleinern · komprimieren · optional runde Ecken", size: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        drop.addSubview(title)
        drop.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: drop.centerYAnchor, constant: 10),
            subtitle.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
        ])

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        formatPopup.addItems(withTitles: ["WebP (klein, fürs Web)", "PNG"])
        formatPopup.selectItem(at: settings.format == .webp ? 0 : 1)
        formatPopup.target = self
        formatPopup.action = #selector(settingsChanged)
        if !webpEncodingSupported() {
            formatPopup.item(at: 0)?.isEnabled = false
            formatPopup.selectItem(at: 1)
        }

        roundCheckbox = NSButton(checkboxWithTitle: "Ecken abrunden (Apple-Squircle, transparenter Hintergrund)",
                                 target: self, action: #selector(settingsChanged))
        roundCheckbox.translatesAutoresizingMaskIntoConstraints = false
        roundCheckbox.font = .systemFont(ofSize: 12)
        roundCheckbox.state = settings.roundingEnabled ? .on : .off

        let radiusLabel = label("Eckenradius:", size: 12, weight: .regular)
        radiusField = NSTextField(string: String(format: "%.2f", settings.radiusPercent))
        radiusField.translatesAutoresizingMaskIntoConstraints = false
        radiusField.alignment = .right
        radiusField.target = self
        radiusField.action = #selector(settingsChanged)
        let percentLabel = label("%  (22,37 = Apple-Icons)", size: 12, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor

        resizeCheckbox = NSButton(checkboxWithTitle: "Verkleinern auf max.",
                                  target: self, action: #selector(settingsChanged))
        resizeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        resizeCheckbox.font = .systemFont(ofSize: 12)
        resizeCheckbox.state = settings.resizeEnabled ? .on : .off
        maxEdgeField = NSTextField(string: String(settings.maxEdge))
        maxEdgeField.translatesAutoresizingMaskIntoConstraints = false
        maxEdgeField.alignment = .right
        maxEdgeField.target = self
        maxEdgeField.action = #selector(settingsChanged)
        let pixelLabel = label("px Kantenlänge (nie vergrößern)", size: 12, weight: .regular)
        pixelLabel.textColor = .secondaryLabelColor

        cleanNamesCheckbox = NSButton(checkboxWithTitle: "Dateinamen bereinigen (Leer-/Sonderzeichen → _)",
                                      target: self, action: #selector(settingsChanged))
        cleanNamesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        cleanNamesCheckbox.font = .systemFont(ofSize: 12)
        cleanNamesCheckbox.state = settings.cleanNames ? .on : .off

        optimizeCheckbox = NSButton(checkboxWithTitle: "PNG stark komprimieren (pngquant, wie ImageOptim)",
                                    target: self, action: #selector(settingsChanged))
        optimizeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        optimizeCheckbox.font = .systemFont(ofSize: 12)
        optimizeCheckbox.state = settings.optimizeLossy ? .on : .off
        if findTool("pngquant") == nil {
            optimizeCheckbox.isEnabled = false
            optimizeCheckbox.title = "PNG stark komprimieren (pngquant fehlt: brew install pngquant)"
        }

        statusLabel = label("Bereit.", size: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        for v: NSView in [drop, formatPopup, roundCheckbox, radiusLabel, radiusField, percentLabel,
                          resizeCheckbox, maxEdgeField, pixelLabel,
                          optimizeCheckbox, cleanNamesCheckbox, statusLabel] {
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            drop.heightAnchor.constraint(equalToConstant: 180),

            formatPopup.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 12),
            formatPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            formatPopup.widthAnchor.constraint(equalToConstant: 200),

            roundCheckbox.topAnchor.constraint(equalTo: formatPopup.bottomAnchor, constant: 10),
            roundCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            roundCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            radiusLabel.centerYAnchor.constraint(equalTo: radiusField.centerYAnchor),
            radiusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 38),
            radiusField.topAnchor.constraint(equalTo: roundCheckbox.bottomAnchor, constant: 8),
            radiusField.leadingAnchor.constraint(equalTo: radiusLabel.trailingAnchor, constant: 8),
            radiusField.widthAnchor.constraint(equalToConstant: 60),
            percentLabel.centerYAnchor.constraint(equalTo: radiusField.centerYAnchor),
            percentLabel.leadingAnchor.constraint(equalTo: radiusField.trailingAnchor, constant: 6),

            resizeCheckbox.centerYAnchor.constraint(equalTo: maxEdgeField.centerYAnchor),
            resizeCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            maxEdgeField.topAnchor.constraint(equalTo: radiusField.bottomAnchor, constant: 10),
            maxEdgeField.leadingAnchor.constraint(equalTo: resizeCheckbox.trailingAnchor, constant: 8),
            maxEdgeField.widthAnchor.constraint(equalToConstant: 60),
            pixelLabel.centerYAnchor.constraint(equalTo: maxEdgeField.centerYAnchor),
            pixelLabel.leadingAnchor.constraint(equalTo: maxEdgeField.trailingAnchor, constant: 6),

            cleanNamesCheckbox.topAnchor.constraint(equalTo: maxEdgeField.bottomAnchor, constant: 10),
            cleanNamesCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cleanNamesCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            optimizeCheckbox.topAnchor.constraint(equalTo: cleanNamesCheckbox.bottomAnchor, constant: 10),
            optimizeCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            optimizeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: optimizeCheckbox.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        updateControlAvailability()

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "RoundDrop"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: size, weight: weight)
        return l
    }

    private func updateControlAvailability() {
        let rounding = roundCheckbox.state == .on
        radiusField.isEnabled = rounding
        // Ohne Rundung wird das Format der Eingabedatei beibehalten
        formatPopup.isEnabled = rounding
    }

    @objc private func settingsChanged() {
        settings.format = formatPopup.indexOfSelectedItem == 0 ? .webp : .png
        settings.roundingEnabled = roundCheckbox.state == .on
        settings.optimizeLossy = optimizeCheckbox.state == .on
        settings.resizeEnabled = resizeCheckbox.state == .on
        settings.cleanNames = cleanNamesCheckbox.state == .on
        let value = radiusField.stringValue.replacingOccurrences(of: ",", with: ".")
        if let r = Double(value), r >= 0, r <= 50 {
            settings.radiusPercent = r
        } else {
            radiusField.stringValue = String(format: "%.2f", settings.radiusPercent)
        }
        if let m = Int(maxEdgeField.stringValue), m >= 16 {
            settings.maxEdge = m
        } else {
            maxEdgeField.stringValue = String(settings.maxEdge)
        }
        updateControlAvailability()
        settings.save()
    }

    private func handle(_ urls: [URL]) {
        settingsChanged()
        let current = settings
        statusLabel.stringValue = "Verarbeite \(urls.count) Datei(en) …"
        statusLabel.textColor = .secondaryLabelColor
        runningBatches += 1
        queue.async {
            let results = urls.map { process($0, settings: current) }
            DispatchQueue.main.async {
                self.runningBatches -= 1
                self.show(results)
                if self.quitRequested && self.runningBatches == 0 {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    private func show(_ results: [ProcessResult]) {
        let ok = results.filter { $0.output != nil }
        let failed = results.filter { $0.output == nil }
        var parts: [String] = []
        if let last = ok.last, let out = last.output {
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? nil
            let kb = size.map { " (\(($0 + 512) / 1024) KB)" } ?? ""
            parts.append(ok.count == 1
                ? "✓ \(out.lastPathComponent)\(kb)"
                : "✓ \(ok.count) Dateien erstellt, zuletzt \(out.lastPathComponent)\(kb)")
        }
        if !failed.isEmpty {
            parts.append("✗ \(failed.count) fehlgeschlagen (\(failed.first?.error ?? "?"))")
        }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        statusLabel.textColor = failed.isEmpty ? .systemGreen : .systemOrange
    }
}

// MARK: - Start (mit CLI-Modus für Tests/Skripte)

let cliArgs = Array(CommandLine.arguments.dropFirst())
if !cliArgs.isEmpty {
    var settings = Settings.load()
    var files: [URL] = []
    for arg in cliArgs {
        if arg == "--png" { settings.format = .png }
        else if arg == "--webp" { settings.format = .webp }
        else if arg == "--lossless" { settings.optimizeLossy = false }
        else if arg == "--keep-name" { settings.cleanNames = false }
        else if arg == "--round" { settings.roundingEnabled = true }
        else if arg == "--no-round" { settings.roundingEnabled = false }
        else if arg.hasPrefix("--max=") {
            let m = Int(arg.dropFirst("--max=".count)) ?? 0
            settings.resizeEnabled = m >= 16
            if m >= 16 { settings.maxEdge = m }
        }
        else if arg.hasPrefix("--radius=") {
            settings.radiusPercent = Double(arg.dropFirst("--radius=".count)) ?? settings.radiusPercent
        } else if arg.hasPrefix("--quality=") {
            settings.quality = Double(arg.dropFirst("--quality=".count)) ?? settings.quality
        } else {
            files.append(URL(fileURLWithPath: arg))
        }
    }
    if files.isEmpty {
        FileHandle.standardError.write(Data("Keine Eingabedateien.\n".utf8))
        exit(1)
    }
    var failures = 0
    for file in files {
        let result = process(file, settings: settings)
        if let out = result.output {
            print("OK \(out.path)")
        } else {
            failures += 1
            FileHandle.standardError.write(Data("FEHLER \(file.path): \(result.error ?? "?")\n".utf8))
        }
    }
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
