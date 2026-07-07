# RoundDrop

Kleines macOS-Droplet: Bilder ablegen → verkleinert, komprimiert und auf Wunsch
mit abgerundeten Ecken (Apple-Squircle, „continuous corners“) und transparentem
Hintergrund.

## Benutzung

- **Fenster:** App starten, Bilder in die gestrichelte Fläche ziehen.
- **Droplet:** App ins Dock ziehen, Bilder aufs Dock-Icon fallen lassen
  (oder im Finder: Bilder auf `RoundDrop.app` ziehen).
- Ergebnis landet neben dem Original:
  - mit Eckenrundung als `name-rund.webp` bzw. `name-rund.png`
  - ohne Eckenrundung im **Format der Eingabedatei** mit Pixel-Suffix,
    z. B. `name-2500.jpg` (JPEG bleibt JPEG, PNG bleibt PNG, HEIC bleibt HEIC)

## Einstellungen (im Fenster)

- **Format:** WebP (klein, ideal fürs Web – braucht `brew install webp`) oder PNG.
  Gilt nur bei aktivierter Eckenrundung; ohne Rundung bleibt das Eingabeformat.
- **Ecken abrunden:** an/aus. Aus = nur verkleinern, komprimieren, umbenennen.
  JPEGs werden dabei zusätzlich mit `jpegoptim` nachoptimiert (falls installiert).
- **Ohne Rundung:** wahlweise das Eingabeformat beibehalten oder alles
  **in JPEG umwandeln** (Transparenz wird dabei auf Weiß gelegt).
- **Qualität:** 1–100 %, gilt für JPEG, WebP und HEIC (Standard 82).
- **Verkleinern auf max. n px:** begrenzt die längere Bildkante (Standard 2500 px),
  proportional, hochwertig, niemals vergrößern. Abschaltbar per Checkbox.
- **Dateinamen bereinigen:** `Täst Bild (2026) übel.png` → `Taest_Bild_2026_uebel-rund.webp`
  (Umlaute → ae/oe/ue/ss, Akzente entfernt, Leer-/Sonderzeichen → `_`).
- **Eckenradius:** Prozent der kürzeren Bildkante.
  `22,37` = der dokumentierte Apple-Squircle der System-Icons.
  Die Kurve ist immer Apples geglättete „continuous“-Kurve, keine Kreisecken.
- **PNG stark komprimieren:** nutzt dieselben Kompressoren wie ImageOptim –
  `pngquant` (verlustarme Farbquantisierung) plus `oxipng`/`optipng` (verlustfrei).
  Abgehakt bleibt nur die verlustfreie Stufe aktiv.
  Benötigt `brew install pngquant oxipng`.

## Download & Installation

Fertiger Build: siehe [Releases](https://github.com/noestreich/RoundDrop/releases).
ZIP entpacken, `RoundDrop.app` z. B. in den Programme-Ordner ziehen.

Die App ist nur ad-hoc signiert (kein Apple-Developer-Zertifikat). macOS
blockiert sie nach dem Download deshalb zunächst — einmalig freigeben mit:

```bash
xattr -dr com.apple.quarantine RoundDrop.app
```

(oder Rechtsklick → Öffnen → „Trotzdem öffnen“.)

Optionale Helfer für kleinere Dateien:

```bash
brew install webp pngquant oxipng jpegoptim
```

Ohne sie fällt die App automatisch auf PNG bzw. unoptimierte Ausgabe zurück.

## Neu bauen

Benötigt nur die Xcode-Kommandozeilenwerkzeuge:

```bash
./build.sh
```

## Kommandozeile (optional)

```bash
RoundDrop.app/Contents/MacOS/RoundDrop [--round|--no-round|--jpeg] [--png|--webp] \
    [--keep-format] [--lossless] [--radius=22.37] [--quality=0.82] [--max=2500] \
    [--keep-name] bild1.jpg bild2.png …
```

`--max=0` schaltet das Verkleinern aus, `--keep-name` lässt Dateinamen unangetastet,
`--no-round` überspringt die Eckenrundung (Ausgabe im Eingabeformat),
`--jpeg` überspringt die Rundung und wandelt alles nach JPEG.

## Technik

- Ein einziges Swift-File ([Sources/main.swift](Sources/main.swift)), AppKit + SwiftUI-Pfad
  (`RoundedRectangle(style: .continuous)`) für die exakte Apple-Kurve.
- WebP-Export über `cwebp` (Homebrew), da macOS-ImageIO WebP nur lesen kann.
  Ohne `cwebp` fällt die App automatisch auf PNG zurück.
- PNG-Optimierung über `pngquant` + `oxipng` (bzw. `optipng`); fehlende Tools
  werden einfach übersprungen. Messwerte Testbild (640×400-Verlauf):
  237 KB roh → 104 KB verlustfrei → 20 KB mit pngquant → 3,9 KB als WebP.
