# Documents (iOS) — Increments 1 & 2

The official app name is **Documents** (home-screen display name). "DocDeck"
remains the internal Xcode target, module, and scheme name used by the
commands below.

An original SwiftUI document-hub app for iOS 26 (Phase 0 foundations, Phase 1
core, and Phase 2 toolbox of the parent plan in `../analysis/IOS_PLAN.md`).
All code, assets, and wording are original; nothing is copied from any
third-party application.

## Requirements

- macOS with Xcode 26.x (iOS 26 SDK) and an iOS 26 simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) on PATH (`brew install xcodegen`)
- Network access on first generate/build so Xcode can fetch the single
  third-party dependency, [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT), via Swift Package Manager
- Device builds use automatic signing with the team configured in `project.yml`
  (`DEVELOPMENT_TEAM`); simulator builds work with or without a team

## Generate, build, run

```bash
cd ios

# 1. Generate DocDeck.xcodeproj from project.yml
xcodegen generate

# 2. Build (simulator only)
xcodebuild -project DocDeck.xcodeproj -scheme DocDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

# 3. Run the unit tests
xcodebuild test -project DocDeck.xcodeproj -scheme DocDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:DocDeckTests
```

Or open `DocDeck.xcodeproj` in Xcode, pick the iPhone 17 Pro Max simulator, and hit Run.
Note: the `.xcodeproj` is generated — edit `project.yml`, then re-run `xcodegen generate`.

### Running on a physical device

1. Build for device: `xcodebuild -project DocDeck.xcodeproj -scheme DocDeck -destination 'generic/platform=iOS' build`
2. Install: `xcrun devicectl device install app --device <coredevice-id> <path>/DocDeck.app`
3. First launch only: on the iPhone go to **Settings → General → VPN & Device
   Management** and trust the developer certificate, then launch the app.

## What's in this increment

### Structure

```
ios/
├── project.yml                 # XcodeGen spec (DocDeck app + DocDeckTests + ZIPFoundation package)
├── DocDeck/
│   ├── DocDeckApp.swift        # @main, SwiftData container + store wiring
│   ├── Home/                   # Tab shell: Recent, Favorites, Tools, Cloud, Browse
│   ├── Viewers/                # QLPreviewController wrapper + open/share flow
│   ├── Core/DocumentStore/     # SwiftData model + @MainActor store service
│   ├── Core/FileBridge/        # copy-into-container import, name dedupe, deletion
│   ├── Core/PDFTools/          # pure PDF toolbox logic (merge/split/watermark/sign/extract) + print
│   ├── Core/Scanning/          # VisionKit wrapper, PDF assembler, Vision OCR
│   ├── Core/Conversion/        # on-device converters + registry (office → Phase 2b)
│   ├── Core/Archives/          # ZIP compress/extract on ZIPFoundation
│   ├── Tools/                  # Tools grid, PDF Tools screen + flows, scanner & convert flows, archive sheets
│   ├── Settings/               # Settings placeholder + Trash management
│   └── Resources/              # Assets.xcassets (placeholder accent color/icon)
└── DocDeckTests/               # Store, FileBridge, PDF toolbox, scanning, OCR, archive, conversion tests
```

### Feature status vs parent plan phases

| Area | Status | Plan phase |
|---|---|---|
| Tab shell: Recent · Favorites · Tools · Cloud · Browse | Done | Phase 1 |
| DocumentStore (SwiftData): import, recents, favorites, trash/restore/delete-forever/empty-trash, generated-file saving | Done | Phases 0–2 |
| FileBridge: `fileImporter` multi-select import, copy-into-container with ` (n)` dedupe, on-disk deletion on delete-forever | Done | Phase 0 |
| Viewer: Quick Look (`QLPreviewController`) for PDF/office/text/markdown/HTML/images, `lastOpenedAt` touch on open, ShareLink | Done | Phase 1 |
| Browse: folder browser over the app container with import toolbar; PDF context menu adopts files into the toolbox | Done | Phases 1–2 |
| Scanner: Scan Document (multi-page → PDF), Scan ID Card (front+back → 2-page PDF + OCR text with Copy), Test Paper (scan + OCR → .txt) | Done (camera UI needs a device; simulator shows a graceful alert) | Phase 2 |
| PDF toolbox: merge, split (range / every-N), watermark (tiled diagonal), sign (PencilKit ink, flattened), extract images (JPEG passthrough + PNG fallback), print (AirPrint) | Done | Phase 2 |
| PDF encrypt | Deferred — disabled row, "Requires conversion service (Phase 2b)" | Phase 2b |
| Archives: compress files → `Archive_<date>.zip`, extract ZIP into `Documents/Extracted/<name>/`; 7z/RAR report "Format support pending" | Done (ZIPFoundation) | Phase 2 |
| Converters: text/Markdown/HTML/images → PDF on-device; office sources and office targets report the pending Phase-2b service error | Done (on-device subset) | Phase 2 |
| Tools grid (17 items): New Document, scanner trio, PDF Tools, conversion quintet, Compress, Extract working; extraction/AI items stay Phase-3 stubs | Done | Phases 1–2 |
| Settings: version, Empty Trash (confirmation), About | Done | Phase 1 |
| Cloud tab | Placeholder ("Cloud documents — Phase 3") | Phase 3 |
| Extraction / AI (summary, translation, smart extraction), cloud docs | Stubs only | Phase 3 |
| Office editing, App Intents, widgets, extensions | Not started | Phases 4–5 |

### Design decisions & known notes

- Swift 6 language mode. The store is a `@MainActor @Observable` class (brief allows
  actor OR @MainActor class); MainActor was chosen because SwiftData's `ModelContext`
  and all UI callers are main-actor isolated.
- `DocumentRecord` persists the container-relative path; `kind` is stored as a raw
  string for migration-friendly schema.
- Tests run against an in-memory `ModelContainer` plus a temp directory `FileBridge`,
  so they never touch the host app's real Documents.
- The Quick Look wrapper intentionally uses QL for every file type in this increment
  (it natively renders PDF, office, text, and images); specialized renderers arrive
  in later phases.
- **Scanner API choice:** the iOS 26 SDK ships no newer `DocumentScannerViewController`;
  VisionKit's scanner options are `VNDocumentCameraViewController` (page-oriented
  captures) and `DataScannerViewController` (live AR scanning without page output),
  so DocDeck wraps `VNDocumentCameraViewController`.
- **PDF image extraction:** `CGPDFStream.copyData()` returns decoded bytes, which would
  destroy JPEGs; DocDeck instead walks the raw PDF bytes for `DCTDecode` streams and
  slices `stream…endstream` payloads, trimming to JPEG SOI/EOI markers. PDFs with no
  embedded JPEGs fall back to rendering each page as PNG (flagged in the result).
- **HTML → PDF** runs on the main actor because `UIMarkupTextPrintFormatter` /
  `UIPrintPageRenderer` are main-actor types.
- **Targeted Swift 6 concurrency workarounds:**
  - `DocumentScannerView.Coordinator` is `@MainActor` and conforms
    `@preconcurrency` to `VNDocumentCameraViewControllerDelegate`, because the
    Objective-C protocol is imported without isolation even though VisionKit
    delivers its callbacks on the main thread.
  - `DocumentConverter.convert(_:to:)` is `@MainActor`: SwiftData's
    `DocumentRecord` is not Sendable, and the HTML converter needs the main
    actor anyway.
  - OCR takes `Data` (Sendable) rather than `UIImage` so recognition can hop
    off the main actor; a `@MainActor` convenience wraps `UIImage` callers.
- **Deferred to Phase 2b:** PDF password encryption (PDFKit cannot write
  encrypted PDFs; no hand-rolled crypto) and office-format conversion in either
  direction (needs the server conversion pipeline). 7z/RAR archives wait for
  libarchive.
- Placeholder app icon: the AppIcon set is empty by design; generate real branding
  before any distribution.
