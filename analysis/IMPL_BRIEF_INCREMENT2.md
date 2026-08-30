# Implementation Brief — Increment 2 (Phase 2: Toolbox)

Parent plan: `/Users/mohamed/Work/Personal/projects/oneplus-docs-app/analysis/IOS_PLAN.md` (§5 items 6–9, §6 Phase 2).
Existing code: `/Users/mohamed/Work/Personal/projects/oneplus-docs-app/ios` (Increment 1 done, tests green). Read the existing code first and match its style (Swift 6, SwiftUI, @MainActor store, hermetic tests).

## Goal
Replace the Phase-2 stubs in the Tools grid with working features: document/ID/test-paper scanning (VisionKit), the PDF toolbox (merge/split/watermark/sign/extract/print), ZIP archives, and on-device converters (text/markdown/HTML/images → PDF). Office-format conversion stays behind a protocol with a clear "conversion service pending" error (Phase 2b).

## Constraints
- Work ONLY inside `ios/`. Keep Increment 1 behavior and tests green.
- Third-party allowed now, but ONLY: **ZIPFoundation** (SPM, MIT). Everything else Apple frameworks.
- XcodeGen: add the package in `project.yml` (`packages:` + target dependency), regenerate.
- Camera/scanner UI is not testable on simulator — keep all *logic* (PDF assembly, merge/split/watermark, OCR, zip, converters) in pure, injectable services that unit tests exercise without a camera.
- Swift 6 strict concurrency; list any targeted workarounds.
- New features must be recorded through the existing `DocumentStore` (imported results become `DocumentRecord`s, appear in Recent).
- UI: SwiftUI, system materials, SF Symbols; keep it simple and consistent with Increment 1. No new design system.

## Features

### 1. Scanner (Tools: Scan Document / Scan ID Card / Test Paper)
- Use VisionKit's document scanner (`VNDocumentCameraViewController`; if the iOS 26 SDK offers a newer `DocumentScannerViewController`, prefer it — check the SDK, document the choice).
- Scan Document: multi-page scan → assemble PDF (one page per scanned image) via `UIGraphicsPDFRenderer` or PDFKit page insertion → save via `DocumentStore.importFile`-style path (add a `saveGeneratedFile(name:data:)` helper if needed) → open viewer.
- Scan ID Card: capture front + back (two scanner presentations or camera picker), produce a single 2-page PDF named `ID Card <date>.pdf`; also run OCR (Vision `VNRecognizeTextRequest`) and store extracted text in a sidecar `.txt`? NO — keep it simple: PDF only; OCR text shown in a result sheet with a Copy button.
- Test Paper: scan + OCR → produce a `.txt` (or `.md`) with the recognized text, recorded in the store.
- Shared `ScanningService` (presentation handled by a UIViewControllerRepresentable wrapper) + `PDFAssembler` (images → PDF) as pure logic for tests.
- Simulator: scanner entry points show a graceful "Camera unavailable on simulator" alert ONLY if `UIImagePickerController.isSourceTypeAvailable(.camera)` is false; logic remains testable.

### 2. PDF Toolbox (`Core/PDFTools/PDFToolbox.swift`, PDFKit-based)
All functions pure (input URLs/data → output data), surfaced via a "PDF Tools" screen reachable from the Tools grid (a new item is fine) AND from a context menu on PDF rows in Recent/Favorites/Browse.
- **Merge:** select ≥2 PDFs → single PDF (PDFDocument page insertion), name `Merged_<date>.pdf`.
- **Split:** pick a PDF → modes: (a) extract page range, (b) every N pages → produces one or more PDFs.
- **Watermark:** text + diagonal tiled overlay rendered onto every page into a NEW PDF (CGContext per page: draw page, then rotated semi-transparent text); original untouched.
- **Sign:** PencilKit `PKCanvasView` sheet → ink image stamped on chosen page (bottom-right, ~30% width) into a new PDF; "flatten" by rendering (no live annotation left).
- **Extract images:** walk `CGPDFDocument` page XObjects; extract `DCTDecode` (JPEG) streams as-is; other filters → skip; if a PDF yields zero embedded images, fall back to rendering each page to PNG and say so in the result UI. Output folder of images + records in store.
- **Print:** `UIPrintInteractionController` with the PDF data (job name = file name).
- **Encrypt:** DO NOT implement — leave a disabled row with "Requires conversion service (Phase 2b)" footnote (PDFKit cannot write password-protected PDFs; we won't hand-roll crypto).
- Result files saved through the store; success toast/alert with the new file name.

### 3. Archives
- ZIPFoundation via SPM.
- Compress: multi-select documents (from Recent/Browse selection or a picker) → `Archive_<date>.zip` in store.
- Extract: pick a `.zip` → unpack into `Documents/Extracted/<zipname>/`, record each extracted file? Record the folder as one record is wrong kind — instead record nothing; Browse shows the folder. Show a result sheet listing extracted file names.
- Non-zip archives (7z/rar): alert "Format support pending" (libarchive deferred).

### 4. Converters (`Core/Conversion/`)
- `ConversionTarget` enum: pdf/word/excel/ppt; `DocumentConverter` protocol `func convert(_ record: DocumentRecord, to target:) async throws -> URL`.
- On-device implementations registered for: plain text → PDF; Markdown → PDF (AttributedString markdown render); HTML → PDF (`UIMarkupTextPrintFormatter` + `UIPrintPageRenderer` into a UIGraphicsPDFRenderer context); images → PDF.
- Office sources (docx/xlsx/pptx) → any target: `ConversionServiceUnavailableError` with a friendly message ("Server conversion arrives in Phase 2b"). Tools grid items To Word/Excel/PPT and Format Convert route here; To PDF works for the on-device types and shows the pending message for office types.
- Converted outputs recorded in the store and opened.

### 5. Tools grid wiring
Update `ToolItem` kinds: Scan Document/ID Card/Test Paper → scanner flows; Format Convert & To PDF/Word/Excel/PPT → converter flows with a source picker (pick from store); Extract Chart/Formula/Smart Extraction stay Phase-3 stubs; add "PDF Tools" entry opening the toolbox screen; New Document unchanged.

## Definition of Done (evidence required)
1. `xcodegen generate` + simulator build on `iPhone 17 Pro Max` → BUILD SUCCEEDED.
2. Device build `-destination 'generic/platform=iOS'` → BUILD SUCCEEDED (signing already configured).
3. `xcodebuild test -only-testing:DocumentsTests` → all green, including NEW tests for: PDFAssembler (2 images → 2-page PDF), merge (page-count math), split range + every-N, watermark (output page count == input, bytes differ), sign stamp (page count preserved), JPEG extraction from a generated PDF containing a JPEG XObject (if too brittle: test the DCTDecode stream parser against a crafted minimal PDF you generate in-test), zip round-trip, OCR on a rendered text image (assert recognized string contains the text), each on-device converter (text/md/html/image → PDF with expected page count ≥1), office-source conversion throws the pending error.
4. README updated (feature status; note encrypt + office conversion deferred to 2b; note ZIPFoundation dependency).
5. Nothing outside `ios/` touched.

## Priority if time-constrained
PDF toolbox → scanner → converters → archives. List any deferrals explicitly.

## Gotchas
- PDFKit/CG types are not Sendable — keep services `@MainActor` or confine to functions returning `Data`; don't leak `PDFDocument` across actors.
- `UIPrintPageRenderer` is main-actor; run HTML→PDF on MainActor.
- Vision OCR: `recognitionLanguages = ["en-US", "zh-Hans"]`, `recognitionLevel = .accurate`.
- Keep every new string original; no text copied from the Android app.
