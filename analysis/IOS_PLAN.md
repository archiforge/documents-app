# iOS 26 "Documents" — Build Plan (functional clone of OnePlus Documents 16.8.32)

Source analysis: `analysis/REPORT.md`. This plan turns that feature catalog into an iOS 26 app.

---

## 0. Ground rules (read first)

1. **Functional clone, not a copy.** We replicate the feature set and UX intent with **original Swift code, original assets, and our own branding**. No Yozo/OPlus code, resources, icons, Lottie files, or string catalog may be lifted from the APK — they are proprietary expression. The decompiled output is used only as a behavioral spec.
2. **iOS cannot mirror Android's system reach.** There is no `MANAGE_EXTERNAL_STORAGE` on iOS. File scope = our app container + anything reachable through `UIDocumentPicker`, `FileProvider`, and Quick Look. "File manager" features therefore center on the app's own store plus Files-app integration.
3. **No multi-process viewer pool.** Android's PG0–9/PDF0–9 process isolation is an Android memory/crash tactic. iOS gets the same outcome with async rendering, off-main-thread decoding, andJetsam-friendly page eviction.

## 1. Product definition

**One-liner:** an iOS 26 document hub — view/edit office documents, a full PDF toolbox, a scanner, converters, and on-device AI (summary, rewrite, translate, semantic search, mind maps) — wrapped in Liquid Glass.

**Targets:** iOS 26.0+, iPhone + iPad (Stage Manager, split view), Swift 6.2, SwiftUI-first, Xcode 26.

## 2. Platform substitutions (Android feature → iOS 26 mechanism)

| Android capability | iOS 26 replacement |
|---|---|
| Breeno/Andes LLM capabilities | **App Intents + App Shortcuts** (Siri/Spotlight/action-button invocations) |
| OPlus cloud GenAI (summary/rewrite) | **Foundation Models framework** (on-device Apple Intelligence; gated by device capability) |
| Document translation service (CN/EN/KO/JA) | **Translation framework** (`TranslationSession`, custom languages) |
| AI Search (local index) | **Foundation Models embeddings + Core Spotlight** (semantic + lexical) |
| Document scanner | **VisionKit `DocumentScannerViewController`** (near 1:1) |
| ID-card / test-paper scan, OCR | **VisionKit + Vision `VNRecognizeTextRequest`** |
| Chart/formula/image extraction | Vision OCR + structured-output heuristics; formula path exports LaTeX (no MathML/OMML parity needed) |
| Mind mapping ("Powered by Xmind") | Native SwiftUI mind-map renderer + **Markdown/OPML export** (no Xmind license) |
| Cloud documents (HeyTap) | **iCloud Drive (CloudKit/FileProvider)** + any third-party FileProvider |
| Cloud fonts | **Downloadable fonts** (`CTFontManagerRegisterFontsForURL`) with a small license-free CJK/Latin pack |
| CAD/Keynote cloud preview | **Quick Look for supported types**; server conversion (headless LibreOffice or commercial API) for the rest — same architecture OPlus uses, our own backend |
| 7zip compress/extract | `ZIPFoundation` (zip) + libarchive (7z/rar read) |
| Security-chip encryption | **FileProtection complete + password-encrypted ZIP/PDF** (note parity gap in §7) |
| Recycle bin, favorites, recents | SwiftData store inside app container |
| Backup/restore (OPlus BR) | Automatic iCloud device backup of container + explicit export/import bundles |
| Supershare | ShareLink / AirDrop / Share extension |
| Print | `UIPrintInteractionController` (AirPrint) |
| Multi-process thumbnails | `QLThumbnailGenerator` + background `Task` pools |
| Foldable side preview | iPad `NavigationSplitView`, slide over |
| COUI Lottie theming | **iOS 26 Liquid Glass** (`glassEffect`, adaptive materials), our own motion language |
| Voice comments | AVFoundation recording stored as annotation objects |

## 3. Architecture

```
App target (SwiftUI, iOS 26 Liquid Glass)
├── Features/            # one module per tab/tool, each owns views + view models
│   ├── Home (Recent · Favorites · Tools · Cloud · Browse)
│   ├── Viewers (PDF, Office, Text/Markdown/HTML/Code)
│   ├── Editors (Office editing via licensed engine, §4.2)
│   ├── PDFTools (merge/split/watermark/encrypt/sign/extract)
│   ├── Scanner (VisionKit)
│   ├── Convert (to PDF/Word/Excel/PPT; server pipeline)
│   ├── AI (summary, rewrite, translate, search, mind map, voice comments)
│   └── Settings/Onboarding/Consent
├── Core/
│   ├── DocumentStore    # SwiftData: recents, favorites, trash, annotations, tags
│   ├── FileBridge       # security-scoped bookmarks, UIDocumentPicker, FileProvider, Quick Look import/export
│   ├── RenderPipeline   # QLThumbnailGenerator, page cache, background decode
│   ├── AIKit            # Foundation Models wrappers, embeddings index, Translation
│   ├── ConversionClient # server-side office→PDF and office→office conversion
│   └── Intents          # App Intents mirroring the tools grid
└── Extensions/          # Share, Quick Look plugin (preview our formats system-wide), Widget, Files FileProvider (optional later)
```

- **Swift 6.2 strict concurrency**; all rendering/OCR/conversion off-main via actors.
- **SwiftData** for metadata; files stay as bookmarks to user locations or in-container copies.
- **Modular SPM packages** per feature so the Office engine stays swappable.

## 4. Key technical decisions

### 4.1 Document viewing (office formats)
**Chosen:** hybrid — native Quick Look where sufficient + **server-side conversion to PDF** for faithful rendering (LibreOffice headless in containers, behind our own API). Mirrors how OPlus handles hard formats (cloud conversion) but on our backend.
**Rejected:** (a) pure on-device OSS parsers (SwiftDocX/CoreXLSX: no layout fidelity for docx/pptx); (b) bundling a full renderer client-side (massive size, licensing).
**Cost:** conversion service infra; mitigated by aggressive caching + on-device QL fallback.

### 4.2 Document editing — the honest hard part
Yozo ships full WYSIWYG word/sheet/slides editing. Rebuilding that natively is multi-year.
**Chosen:** phase it.
- v1: PDF annotation/markup (PDFKit — native, excellent), text/markdown editing.
- v2: licensed office editing engine (evaluate **OnlyOffice SDK / Aspose / Mescius Documents** for iOS) for docx/xlsx/pptx editing, integrated behind our `Editors` module interface.
**Rejected:** writing our own OOXML editor from scratch.

### 4.3 PDF toolbox
**Chosen: PDFKit** for view/annotate/sign (ink)/merge/split/image-extract/search/slideshow. Watermark via rendered overlay pages. Password encryption: PDFKit lacks create-side encryption → small Swift wrapper over **QPDF or OpenSSL-based module** (or route through conversion service). This is the only notable PDF parity gap.

### 4.4 AI
**Chosen: on-device first.** Foundation Models for summary/rewrite/semantic-search embeddings (with availability gating and consent UX, mirroring OPlus's consent strings); Translation framework for full-document translation (200-page cap replicated as a setting). Server LLM fallback is optional later; on-device keeps us free of account/privacy infrastructure in v1.
**Mind map:** Foundation Models generates the outline from document text; SwiftUI tree renderer with edit/export (Markdown/OPML/PNG).

### 4.5 Scanner
VisionKit `DocumentScannerViewController` for document scan (multi-page → PDF). ID-card mode = VisionKit capture + Vision text extraction into structured fields. Test-paper mode = OCR pass with region cleanup. No third parties.

## 5. Feature-parity matrix (priority)

| # | Feature | Source ref | Priority | Phase |
|---|---|---|---|---|
| 1 | Home tabs: Recent/Favorites/Tools/Cloud/Browse | §3.1 | P0 | 1 |
| 2 | PDF viewer + annotate/ink/sign/search/slideshow | §3.4 | P0 | 1 |
| 3 | Text/Markdown/HTML/code viewer | §3.3 | P0 | 1 |
| 4 | Office viewers (doc/xls/ppt families) via QL + convert pipeline | §3.3 | P0 | 1–2 |
| 5 | Recents/favorites/trash/details/sort/rename | §3.6 | P0 | 1 |
| 6 | Scanner (doc/ID/test paper) | §3.2 | P1 | 2 |
| 7 | PDF tools: merge/split/watermark/encrypt/extract/print | §3.4 | P1 | 2 |
| 8 | Compress/extract archives | §3.6 | P1 | 2 |
| 9 | Convert to PDF/Word/Excel/PPT (server pipeline) | §3.2 | P1 | 2 |
| 10 | AI summary / rewrite / translate / semantic search | §3.5 | P1 | 3 |
| 11 | Mind map generation + export | §3.5 | P2 | 3 |
| 12 | Voice comments | §3.5 | P2 | 3 |
| 13 | Formula/chart/image extraction | §3.2 | P2 | 3 |
| 14 | Cloud documents (iCloud/FileProvider) + cloud fonts | §3.5 | P2 | 3–4 |
| 15 | Office **editing** (licensed engine) | §3.3 | P2 | 4 |
| 16 | App Intents/Siri, widgets, Quick Look plugin, share extensions | §3.7 | P2 | 4 |
| 17 | OFD invoice viewer | §3.3 | P3 | 5 (market-dependent) |
Dropped: OPlus-only items (private safe chip path, DUID cloud preview, supershare, Pantanal, BR framework) — replaced per §2.

## 6. Phases, milestones, effort (2 iOS engineers + 1 designer; conversion backend part-time)

- **Phase 0 — Foundations (2 wks).** Xcode 26 project, SPM modules, SwiftData schema, FileBridge with security-scoped bookmarks, Liquid Glass shell, consent/onboarding. *DoD:* app opens files from Files/Share extension; recents persist.
- **Phase 1 — Viewers + home (4–5 wks).** Items 1–5. *DoD:* open & navigate PDF/txt/md/html/code/docx/xlsx/pptx (QL or converted), favorites/trash work, iPad multitasking sane.
- **Phase 2 — Toolbox (4 wks).** Items 6–9 + scanner→PDF pipeline; conversion service v1 (LibreOffice pool). *DoD:* scan→PDF, merge/split PDFs, zip round-trip, convert docx→pdf e2e.
- **Phase 3 — AI (4 wks).** Items 10–14. Foundation Models gating + consent, embeddings index, translation, mind map, voice comments. *DoD:* summary/rewrite/translate on-device on supported devices; semantic search over indexed docs.
- **Phase 4 — Editing + platform depth (6–8 wks).** Office engine integration (licensed), App Intents, widgets, QL plugin. *DoD:* edit docx/xlsx/pptx in-app; Siri "summarize last document" works.
- **Phase 5 — Long tail.** OFD, WPS formats, RTL/localization (OPlus ships ~30 locales; start EN/ZH), accessibility audit against the `accessibility_*` feature list we extracted.

**Total to functional parity (ex-OPlus-only): ~5–6 months** for the team above; Office-editing fidelity remains the residual risk (§7).

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Office editing parity with Yozo | High | Licensed engine; never hand-roll; keep `Editors` interface swappable |
| Foundation Models device gating (older iPhones) | Medium | Graceful fallback messaging + optional server AI later; capability detection at onboarding |
| Conversion service cost/latency | Medium | Cache by content hash, QL-first policy, async with notifications (mirrors OPlus "preview status notifications") |
| PDF create-side encryption gap in PDFKit | Low | QPDF/OpenSSL wrapper module, isolated |
| App Review for scanner/AI claims | Low | No medical/ID-verification claims; ID scan is data-entry assistance only |
| IP exposure | High | §0.1 strictly enforced: no APK assets in repo; clean-room UX screenshots only |

## 8. Verification strategy
- Unit: SwiftData/FileBridge/conversion-client with fixtures (our own sample docs).
- UI tests: XCUITest smoke per phase DoD.
- Fidelity checks: render-matrix of 50 sample documents (our own + public-license samples) comparing us vs source-of-truth PDF output each phase.
- Accessibility: VoiceOver pass on viewers/tools mirroring OPlus's talkback string coverage.
- Perf budgets: cold-open < 1.5 s for 10 MB PDF; thumbnail < 300 ms/doc; AI summary latency per Foundation Models baselines.

## 9. Open decisions (need your call before Phase 1 code)
1. Office editing engine license budget (OnlyOffice SDK vs Aspose vs defer-to-v2).
2. Conversion backend: self-host LibreOffice vs commercial conversion API.
3. Branding/name (must not reference OnePlus/OPlus).
