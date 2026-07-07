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
    var quality: Double = 0.82          // für WebP, JPEG und HEIC
    var convertToJPEG: Bool = false     // ohne Rundung: nach JPEG wandeln statt Eingabeformat behalten
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
        if let j = d.object(forKey: "convertToJPEG") as? Bool { s.convertToJPEG = j }
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
        d.set(convertToJPEG, forKey: "convertToJPEG")
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

// JPEG kennt keine Transparenz – Bilder mit Alphakanal vorher auf Weiß legen,
// sonst würde ImageIO sie auf Schwarz reduzieren.
func flattenedOntoWhite(_ image: CGImage) -> CGImage {
    switch image.alphaInfo {
    case .none, .noneSkipLast, .noneSkipFirst:
        return image
    default:
        break
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    return ctx.makeImage() ?? image
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

    // Ohne Rundung: nur verkleinern + komprimieren,
    // Suffix = Pixel-Limit (wie beim alten Verkleinerungs-Droplet), z. B. „-2500“
    let suffix = settings.resizeEnabled ? "-\(settings.maxEdge)" : "-opt"

    // Wahlweise alles nach JPEG wandeln (mit einstellbarer Qualität) …
    if settings.convertToJPEG {
        let outURL = freeOutputURL(for: input, suffix: suffix, fileExtension: "jpg",
                                   cleanName: settings.cleanNames)
        if let error = writeImageIO(flattenedOntoWhite(image), to: outURL,
                                    uti: UTType.jpeg.identifier, quality: settings.quality) {
            return fail(error)
        }
        if let jpegoptim = findTool("jpegoptim") {
            runTool(jpegoptim, ["-s", "--quiet", outURL.path])
        }
        return ProcessResult(input: input, output: outURL, error: nil)
    }

    // … oder das Eingabeformat beibehalten
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
    private var noRoundPopup: NSPopUpButton!
    private var qualityField: NSTextField!
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
        buildMenu()
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

    // Ohne Hauptmenü gibt es keine Tastenkürzel (⌘Q, ⌘W, ⌘C …) – bei einer
    // rein per Code gebauten App muss es von Hand angelegt werden.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Über RoundDrop",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "RoundDrop ausblenden",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Andere ausblenden",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "RoundDrop beenden",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "RoundDrop", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "Ablage")
        fileMenu.addItem(withTitle: "Schließen",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "Ablage", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let windowWidth: CGFloat = 440

        // Drop-Fläche mit mittig zentriertem Text
        let drop = DropView(frame: .zero)
        drop.onDrop = { [weak self] urls in self?.handle(urls) }

        let title = label("Bilder hier ablegen", size: 15, weight: .semibold)
        let subtitle = label("verkleinern · komprimieren · optional runde Ecken", size: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        let dropText = NSStackView(views: [title, subtitle])
        dropText.orientation = .vertical
        dropText.alignment = .centerX
        dropText.spacing = 5
        dropText.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(dropText)
        NSLayoutConstraint.activate([
            dropText.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropText.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
        ])

        // Rundung
        roundCheckbox = NSButton(checkboxWithTitle: "Ecken abrunden (Apple-Squircle, transparent)",
                                 target: self, action: #selector(settingsChanged))
        roundCheckbox.font = .systemFont(ofSize: 12)
        roundCheckbox.state = settings.roundingEnabled ? .on : .off

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: ["WebP", "PNG"])
        formatPopup.selectItem(at: settings.format == .webp ? 0 : 1)
        formatPopup.target = self
        formatPopup.action = #selector(settingsChanged)
        if !webpEncodingSupported() {
            formatPopup.item(at: 0)?.isEnabled = false
            formatPopup.selectItem(at: 1)
        }

        radiusField = numberField(String(format: "%.2f", settings.radiusPercent), width: 55)
        let radiusRow = row([label("Format:", size: 12, weight: .regular), formatPopup,
                             spacer(10),
                             label("Radius:", size: 12, weight: .regular), radiusField,
                             hint("%")], indent: 18)
        radiusRow.toolTip = "22,37 % = Apple-System-Icons; Prozent der kürzeren Bildkante"

        noRoundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        noRoundPopup.addItems(withTitles: ["Eingabeformat beibehalten", "in JPEG umwandeln"])
        noRoundPopup.selectItem(at: settings.convertToJPEG ? 1 : 0)
        noRoundPopup.target = self
        noRoundPopup.action = #selector(settingsChanged)
        let noRoundRow = row([label("Ohne Rundung:", size: 12, weight: .regular), noRoundPopup])

        // Verkleinern & Qualität
        resizeCheckbox = NSButton(checkboxWithTitle: "Verkleinern auf max.",
                                  target: self, action: #selector(settingsChanged))
        resizeCheckbox.font = .systemFont(ofSize: 12)
        resizeCheckbox.state = settings.resizeEnabled ? .on : .off
        maxEdgeField = numberField(String(settings.maxEdge), width: 60)
        let resizeRow = row([resizeCheckbox, maxEdgeField, hint("px längste Kante")])
        resizeRow.toolTip = "Proportional verkleinern; kleinere Bilder werden nie vergrößert"

        qualityField = numberField(String(Int((settings.quality * 100).rounded())), width: 45)
        let qualityRow = row([label("Qualität:", size: 12, weight: .regular), qualityField,
                              hint("%  ·  JPEG / WebP / HEIC")])

        // Kompression & Namen
        optimizeCheckbox = NSButton(checkboxWithTitle: "PNG stark komprimieren (pngquant)",
                                    target: self, action: #selector(settingsChanged))
        optimizeCheckbox.font = .systemFont(ofSize: 12)
        optimizeCheckbox.state = settings.optimizeLossy ? .on : .off
        optimizeCheckbox.toolTip = "Verlustarme Farbquantisierung wie in ImageOptim; danach verlustfreie Nachoptimierung"
        if findTool("pngquant") == nil { optimizeCheckbox.isEnabled = false }

        cleanNamesCheckbox = NSButton(checkboxWithTitle: "Dateinamen bereinigen (Sonderzeichen → _)",
                                      target: self, action: #selector(settingsChanged))
        cleanNamesCheckbox.font = .systemFont(ofSize: 12)
        cleanNamesCheckbox.state = settings.cleanNames ? .on : .off
        cleanNamesCheckbox.toolTip = "z. B. „Täst Bild (1).png“ → „Taest_Bild_1“"

        // Werkzeug-Status
        let separator = NSBox()
        separator.boxType = .separator

        let pngLossless = findTool("oxipng") != nil ? "oxipng"
                        : (findTool("optipng") != nil ? "optipng" : "oxipng")
        let toolsRow = row([hint("Werkzeuge:"),
                            toolBadge("cwebp", purpose: "WebP-Export"),
                            toolBadge("pngquant", purpose: "PNG-Kompression"),
                            toolBadge(pngLossless, purpose: "PNG verlustfrei"),
                            toolBadge("jpegoptim", purpose: "JPEG-Optimierung")])

        statusLabel = label("Bereit.", size: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        // Gesamtaufbau
        let mainStack = NSStackView(views: [drop,
                                            roundCheckbox, radiusRow, noRoundRow,
                                            resizeRow, qualityRow,
                                            optimizeCheckbox, cleanNamesCheckbox,
                                            separator, toolsRow, statusLabel])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(14, after: drop)
        mainStack.setCustomSpacing(14, after: cleanNamesCheckbox)
        mainStack.setCustomSpacing(14, after: separator)

        let content = NSView()
        content.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            drop.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            drop.heightAnchor.constraint(equalToConstant: 150),
            separator.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
        ])

        updateControlAvailability()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 100),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "RoundDrop"
        window.contentView = content
        content.widthAnchor.constraint(equalToConstant: windowWidth).isActive = true
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: windowWidth, height: content.fittingSize.height))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func row(_ views: [NSView], indent: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets.left = indent
        return stack
    }

    private func spacer(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    private func hint(_ text: String) -> NSTextField {
        let l = label(text, size: 12, weight: .regular)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func numberField(_ value: String, width: CGFloat) -> NSTextField {
        let f = NSTextField(string: value)
        f.alignment = .right
        f.target = self
        f.action = #selector(settingsChanged)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    private func toolBadge(_ tool: String, purpose: String) -> NSTextField {
        let path = findTool(tool)
        let l = label("\(path != nil ? "✓" : "✗") \(tool)", size: 11, weight: .medium)
        l.textColor = path != nil ? .systemGreen : .systemRed
        l.toolTip = path != nil
            ? "\(purpose) – gefunden: \(path!)"
            : "\(purpose) – fehlt, Installation: brew install \(tool)"
        return l
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
        // Format-Auswahl (WebP/PNG) gilt nur mit Rundung; ohne Rundung greift das Popup „Ohne Rundung“
        formatPopup.isEnabled = rounding
        noRoundPopup.isEnabled = !rounding
    }

    @objc private func settingsChanged() {
        settings.format = formatPopup.indexOfSelectedItem == 0 ? .webp : .png
        settings.roundingEnabled = roundCheckbox.state == .on
        settings.convertToJPEG = noRoundPopup.indexOfSelectedItem == 1
        settings.optimizeLossy = optimizeCheckbox.state == .on
        if let q = Int(qualityField.stringValue), q >= 1, q <= 100 {
            settings.quality = Double(q) / 100
        } else {
            qualityField.stringValue = String(Int((settings.quality * 100).rounded()))
        }
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
        else if arg == "--jpeg" { settings.roundingEnabled = false; settings.convertToJPEG = true }
        else if arg == "--keep-format" { settings.convertToJPEG = false }
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
