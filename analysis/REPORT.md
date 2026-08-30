# OnePlus "Documents" APK — Reverse-Engineering Report

**Sample:** `Documents.apk` (142 MB, 11,293 entries, 8 dex files ≈ 71 MB code, 16,787 classes)
**Tools:** apktool 2.x (resources/manifest), jadx 1.5.6 (Java decompile), unzip/strings.
**Artifacts:** `analysis/apk/` (raw unzip), `analysis/apktool/` (decoded resources + manifest), `analysis/jadx/sources/` (302 MB decompiled Java).

---

## 1. Identity

| Field | Value |
|---|---|
| Package | `andes.oplus.documentsreader` |
| Label | **Documents** (`documents_app_name`) |
| Version | 16.8.32 (versionCode 16008032) — OxygenOS 16 generation |
| SDK | min 35 / target 35 (Android 15), compileSdk 35 |
| Application class | `com.yozo.office.MainApp` |
| Architecture | arm64-v8a only |
| Nature | **OxygenOS system app** (platform-signed feature set: `MANAGE_EXTERNAL_STORAGE`, `com.oplus.permission.safe.*`, HeyTap cloud, cross-user IPC) |
| Core engine | **Yozo Office** (永中) document engine, licensed by OPlus. App code = Yozo core + `andes.oplus.documentsreader` OPlus layer |

## 2. Architecture

- **Language/DI:** Kotlin (metadata confirms Kotlin 1.9+), **Koin** dependency injection, MVVM (ViewModel + LiveData), DataBinding in Yozo layers.
- **Multi-process isolation (the defining design):** manifest declares process pools `:yozo.Office.PG0`–`PG9` (presentation/office viewers) and `:yozo.Office.PDF0`–`PDF9` (PDF viewers), each with 5 components per slot (activity + helpers), plus **per-process thumbnail services** (`OfficeThumbnailService0-5`, `PdfThumbnailService0-5`) and `PdfContentSearchService0..n`. Each opened document runs in an isolated worker process → crash containment + parallel thumbnailing.
- **Component counts:** 294 activities, 40 services, 20 providers, 2 receivers.
- **Entry flow:** `DispatchActivity` (content/file URI dispatch by MIME) → `MainActivity`/`InnerMainActivity` (home) or `PDFDeskActivity*`/`AppDeskFrameActivity` (viewers). Deep links: `yozolink://open.yozo.summarize`, `doctools://andes.oplus.documentsreader/...`.
- **OPlus layer modules** (`andes.oplus.documentsreader.*`): `launcher` (home tabs), `recent`, `filepreview`, `doctools`, `docscan`, `formatconvert`, `markdownconvert`, `createfile`, `recycle` (trash), `cloudfonts`, `search`, `mydocument`, `backuprestore` (OPlus BR plugin, backup folder `OplusDocumentsReader`), `sidepreview` (split/foldable preview), `supershare` (cross-device), `account` (HeyTap), `exposetoyozo` (bridge into the engine), `aidepend` (AI deps), `widget`, `dragdrop`, `selectdoc/selectdir`.
- **UI kit:** OPlus **COUI** (`coui` package) + Lottie (`airbnb`) animations incl. dark-mode variants, plus standard AndroidX/Glide/OkHttp/Jackson/SmartRefreshLayout/SubsamplingScaleImageView.

## 3. Feature catalog

### 3.1 Home screen (tabs)
`Recent` (`main_tab_recently`) · `Favorites` (`main_tab_collect`) · `Tools` (`main_tab_tool`) · `Cloud` (`cloud_docs`, HeyTap cloud documents) · folder browse (`FolderTabFragment`, "Browse directory > Cloud documents").

### 3.2 Tools grid (authoritative, from `doctools/enumer/EnumId`)
| Group | Tools |
|---|---|
| Document tool / Fast create / Deal | new document, document processing |
| **Scan** | Scan document (`ID_SCAN_DOC`), Scan ID cards (`ID_SCAN_ID_CARD`), Test paper (`ID_TEST_PAPER`) |
| **Extract** | Chart extraction (`ID_EXTRACT_CHART`), Formula extraction (`ID_EXTRACT_FORMULA`), Smart extraction (`ID_SMART_EXTRACTION`), image extraction (assets) |
| **Convert** | Format convert (`ID_FORMAT_CONVERT`), To PDF / To Word / To Excel / To PPT |
| **AI tools** | Document Summary (`ID_DOC_SUMMARY`), Document translation (`ID_DOC_TRANSLATION`) |
Invocation surfaces: home, tools tab, in-document panel (`EnumWay`: HOME/TOOL/PANEL).

### 3.3 Viewers & editors (Yozo engine)
- **Formats handled** (manifest MIME list): doc/docx (+macro variants), xls/xlsx, ppt/pptx, **pdf**, **ofd** (CN e-invoice), rtf, html, txt, csv, **wps/et/dps/dpt/ett/wpt** (Kingsoft), json, lrc, code files (c/c++/java/python/js/asp…). Advertised cloud-preview formats: **CAD, Keynote, Pages, Numbers, Markdown, AutoCAD, Photoshop, Illustrator, Sketch, XD, Xmind, Visio**.
- **Full WYSIWYG editors** for word/sheet/slides: 3,312 `yozo_ui_*` strings, spreadsheet table styles + merged cells/pivot guards (`accessibility_ss_*`), presentation strings (`accessibility_pg_*`), shapes & text boxes, signature insert, undo/redo toolbars, find & replace (`oppo_res_find_replace_*`), **LaTeX formula editor** (`com.yozo.office.latex`, `latex_convert`, `oplusdoc_formula_*`), DejaVuMathTeXGyre font, OMML→MathML XSLT for Word math.
- **Reading UX:** eye protection mode, double/single page modes, split view, Pad/Pad Pro landscape layouts (`PDFPadActivity`, `PDFPadProActivity`), split-screen side preview for foldables.

### 3.4 PDF suite (`com.yozo.pdfdesk`, pdfium + iTextPDF + PdfBox)
View (pdfium native render), annotate, ink, **merge PDFs** (≤1 GB), **split PDF**, **watermark** add/remove, **document encryption** (incl. "security chip" path on OPlus devices), **extract images**, **PDF signature**, print (AirPrint-equivalent via `PrintActivity`), PDF search across processes, slideshow mode.

### 3.5 AI & cloud services (all OPlus-server-backed, HeyTap account gated)
1. **Document Summary** (GenAI; "save summary to Notes").
2. **AI Rewriter** ("AI-powered rewriting").
3. **Mind mapping** — generate mind map from document, **Powered by Xmind** (`com.oplus.graphic.mindmap`).
4. **Document translation** — CN/EN/KO/JA, ≤200 pages.
5. **Voice comments** — 60 s voice annotations (AI VoiceScribe privacy notice).
6. **Formula/chart/image extraction** (OCR → editable content; `ocr.xlsx` sample asset, mml2tex).
7. **Cloud preview/conversion** for CAD/Keynote/etc.: files uploaded to OPlus servers, device DUID retained 3 years.
8. **Cloud fonts** — Fangsong/Hei/Kai substitutes downloaded on missing fonts.
9. **AI Search** — local index + semantic search ("AI Search needs to complete an initial setup… indexing").
10. **AI Writer / AI chat / AI Assistant for Documents** (`com.oplus.aiwriter.sdk.KitSdkProvider`, `AiChatDocumentProvider`).
11. **Breeno (assistant) capability exposure** via OPlus Andes platform: `assets/capabilities.json` registers `andes.oplus.documentsreader.translate_document` etc. for the system LLM.

### 3.6 File management
Favorites, rename, delete, compress (7zip native `libp7zip_1.so`), extract, open with…, send/share, details, sort, select all, drag & drop (incl. cross-window), recycle bin, backup/restore via OPlus BR framework, supershare cross-device transfer.

### 3.7 Ecosystem integrations (manifest `<queries>`)
WeChat, QQ, ColorOS Gallery, Notes (coloros/oneplus), Email, Encryption (private safe), OCR Scanner, File Manager, OPlus DMP, AI Memory, Assistant Screen, Metis analytics, Pantanal (widgets/seedlings).

## 4. SDK / library inventory
Yozo Office engine (core), pdfium, iTextPDF, PdfBox (tom_roush), 7zip, Glide, OkHttp, Jackson, Lottie, SmartRefreshLayout, SubsamplingScaleImageView, Koin, AndroidX, Chrome-derived libs (`libc++_chrome.cr`, icu, partition_alloc — part of the Yozo/Chromium-based rendering stack), AIUnit SDK, COUI.

## 5. What cannot be cloned (dependency reality check)
1. **Yozo Office engine** — proprietary, licensed to OPlus, Android-only. No right to reuse; no iOS build exists.
2. **OPlus system surface** — MANAGE_EXTERNAL_STORAGE, private safe, security-chip encryption, OPlus BR backup, Pantanal widgets, interconnect supershare, DUID cloud preview service.
3. **OPlus/HeyTap cloud AI stack** — Breeno/Andes capabilities, HeyTap account, cloud fonts, CAD conversion service, Xmind partnership.
4. **Assets & branding** — icons, Lottie set, COUI theming, string catalog, Yozo UI are OPlus/Yozo copyrighted expression.

**Conclusion:** a legitimate "identical copy" for iOS must be a **functional clone**: same feature set and UX intent, implemented with original code and assets, a different document engine, and Apple-platform-native substitutions for the OPlus-only services (§ see IOS_PLAN.md).
