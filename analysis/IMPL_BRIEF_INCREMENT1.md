# Implementation Brief — Increment 1 (Phase 0 + Phase 1 core)

Parent plan: `/Users/mohamed/Work/Personal/projects/oneplus-docs-app/analysis/IOS_PLAN.md`
Feature spec from the reversed Android app: `/Users/mohamed/Work/Personal/projects/oneplus-docs-app/analysis/REPORT.md`

## Goal
Scaffold and implement the iOS 26 app **"DocDeck"** (placeholder brand) — Phase 0 (foundations) and Phase 1 core (home shell + viewers + document store) from the parent plan. All code original. **Do not copy or reference any APK assets, strings, icons, or code** — REPORT.md is a behavioral spec only.

## Environment (verified working)
- macOS, Xcode 26.6, iOS SDK 26.5, iOS 26.5 simulator runtime.
- Simulator destination: `platform=iOS Simulator,name=iPhone 17 Pro Max`.
- XcodeGen 2.46.0 on PATH (`xcodegen`).
- No signing team available: build/test for **simulator only**, set `CODE_SIGNING_ALLOWED: "NO"` / no development team in project.yml so builds don't require an Apple ID.
- Project root: `/Users/mohamed/Work/Personal/projects/oneplus-docs-app/ios` (create it). Do not modify anything outside `ios/`.

## Constraints
- Swift 6 language mode, SwiftUI-first, iOS 26.0 deployment target.
- Apple frameworks only — **zero third-party dependencies** in this increment.
- SwiftData for persistence. Strict-concurrency annotations where straightforward; don't fight the compiler over edge cases — note them instead.
- Liquid Glass era UI: use `TabView` for the home tabs, NavigationStack per tab, system materials; keep styling tasteful and simple. No custom design system yet.
- Keep modules as folders inside one app target (no SPM packages yet).

## Required structure
```
ios/
├── project.yml                 # XcodeGen spec (targets: DocDeck app, DocDeckTests)
├── DocDeck/
│   ├── DocDeckApp.swift        # @main, SwiftData container setup
│   ├── Home/                   # Tab shell: Recent, Favorites, Tools, Cloud, Browse
│   ├── Viewers/                # QuickLookPreview (QLPreviewController wrapper) + open flow
│   ├── Core/DocumentStore/     # SwiftData model + service (see spec below)
│   ├── Core/FileBridge/        # import via UIDocumentPicker (copy-into-container)
│   ├── Tools/                  # Tools grid + stub screens
│   ├── Settings/               # placeholder settings screen
│   └── Resources/              # Assets.xcassets (generated placeholder icon is fine)
└── DocDeckTests/               # unit tests (see DoD)
```

## Feature spec

### 1. Home shell (tabs, exact parity names)
Tabs: **Recent** · **Favorites** · **Tools** · **Cloud** · **Browse**.
- Recent: list of `DocumentRecord` sorted by `lastOpenedAt` desc; row shows name, kind glyph (SF Symbol by file type), relative date, size; swipe actions: favorite, trash; tap → open in viewer; empty state with an "Import" call-to-action.
- Favorites: same list filtered by `isFavorite && !isTrashed`.
- Tools: the tools grid (§4 below).
- Cloud: placeholder screen ("Cloud documents — Phase 3") with explanatory text.
- Browse: folder-browser of the app container's Documents directory (folders + files, tap file → viewer, tap folder → navigate). Include an Import button (toolbar) in Recent and Browse.

### 2. DocumentStore (SwiftData)
`DocumentRecord`: `id: UUID`, `displayName: String`, `fileURL` stored as container-relative path string, `kind: DocumentKind` (enum: pdf, word, excel, powerpoint, text, markdown, html, image, archive, other — derived from extension), `sizeBytes: Int64`, `lastOpenedAt: Date`, `importedAt: Date`, `isFavorite: Bool`, `isTrashed: Bool`, `trashedAt: Date?`.
Service API (actor or @MainActor class): `importFile(from url: URL)`, `recordOpen(_:)`, `toggleFavorite(_:)`, `trash(_:)`, `restore(_:)`, `deleteForever(_:)`, `emptyTrash()`, queries for recent/favorites/trash. Import semantics: **copy** the picked file into `<container>/Documents/` (dedupe names with ` (n)` suffix) and store the relative path; touch `lastOpenedAt` on open.

### 3. FileBridge
- Import via `fileImporter` (SwiftUI modifier) or `UIDocumentPickerViewController` with `allowsMultipleSelection = true`, importing types `UTType.data` family (accept everything).
- Trash/restore/deleteForever must delete the on-disk file for deleteForever only (trash keeps the file).
- Expose container Documents dir helper.

### 4. Tools grid (parity with Android EnumId; all stubs unless noted)
Grid items: New Document **(working)** · Scan Document · Scan ID Card · Test Paper · Extract Chart · Extract Formula · Smart Extraction · Format Convert · To PDF · To Word · To Excel · To PPT · Document Summary · Document Translation.
- Each non-working item pushes a stub screen: title, SF Symbol, "Coming in Phase N" (map per parent plan §5: scan/convert = Phase 2, AI items = Phase 3).
- New Document: sheet to name a file + choose type (.txt / .md), creates it in Documents, records it, opens viewer.

### 5. Viewer
- `QLPreviewController` wrapped in `UIViewControllerRepresentable`, fed a local file URL; used for every file type (Quick Look handles PDF/office/text/images natively).
- Record `lastOpenedAt` when opened.
- Toolbar/share: ShareLink for the file.

### 6. Settings
Placeholder list: app version (from bundle), Empty Trash button (with confirmation), About text stating original implementation.

## Definition of Done (evidence required in final report)
1. `cd ios && xcodegen generate` succeeds.
2. `xcodebuild -project DocDeck.xcodeproj -scheme DocDeck -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` → **BUILD SUCCEEDED** (paste tail of output).
3. `xcodebuild test -project DocDeck.xcodeproj -scheme DocDeck -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DocDeckTests` → all tests pass (paste summary line). Tests must cover at least: import + dedupe naming, recent ordering on recordOpen, favorite toggle, trash/restore/deleteForever incl. on-disk deletion, emptyTrash.
4. `ios/README.md` with build/run instructions and current feature status vs parent plan phases.
5. No files modified outside `ios/`.

## Notes / gotchas
- XcodeGen: put `options: { createIntermediateGroups: true }`; app target `type: application`, `platform: iOS`, `deploymentTarget: "26.0"`; settings: `GENERATE_INFOPLIST_FILE: YES`, `INFOPLIST_KEY_UILaunchScreen_Generation: YES`, `CODE_SIGNING_ALLOWED: "NO"`, Swift 6 (`SWIFT_VERSION: "6.0"`), `ENABLE_USER_SCRIPT_SANDBOXING: YES`. Test target depends on app target.
- If Swift 6 strict concurrency produces blocking errors in QL/SwiftData bridging, `@preconcurrency` imports or a targeted `nonisolated(unsafe)` with a comment is acceptable — list each deviation in the final report.
- Simulator boot: `xcrun simctl boot "iPhone 17 Pro Max"` if needed; headless testing works without opening Simulator.app.
- Budget reality check: if anything above turns out materially larger than expected, implement in priority order 2 → 1 → 5 → 3 → 4 → 6 and say what was deferred.
