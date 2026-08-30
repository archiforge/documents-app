# Phase 1 Implementation Brief — Durable Document Model

Branch: `feature/phase1-durable-model` (from `master`). Project: iOS 26 SwiftUI + SwiftData app **Documents**, XcodeGen at `ios/project.yml` (regenerate with `xcodegen generate` from `ios/` after adding files). Baseline: 122/122 unit tests green, `xcodebuild analyze` clean. All work in `ios/Documents/` + `ios/DocumentsTests/`.

**Deliver 7 seams, in this order, each with tests before/with it (red first where practical):**

## 1. Versioned schema (`Core/DocumentStore/DocumentsSchema.swift`)

- `enum SchemaV1: VersionedSchema` — `versionIdentifier = Schema.Version(1, 0, 0)`; `models = [DocumentRecord.self, FolderGrant.self]` where both are `@Model` classes nested in `SchemaV1` and **field-identical to today's unversioned models** (DocumentRecord: id/displayName/relativePath/kindRaw/sizeBytes/lastOpenedAt/importedAt/isFavorite/isTrashed/trashedAt/provenanceRaw/absolutePath; FolderGrant: id/displayName/bookmarkData/resolvedPath/addedAt).
- `enum SchemaV2: VersionedSchema` — same, plus **`DocumentRecord.pageCount: Int? = nil`** (PDF page count badge, filled once by the thumbnail pipeline; avoids re-parsing PDFs per row render).
- `enum DocumentsSchemaMigrationPlan: SchemaMigrationPlan` — `stages = [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]`.
- Compatibility aliases so all call sites keep compiling: `typealias DocumentRecord = SchemaV2.DocumentRecord`, `typealias FolderGrant = SchemaV2.FolderGrant`. Keep every computed helper (`kind`, `provenance`, `fileURL`, `isScanned`-style helpers if any) on the V2 class; V1 copies may be bare data. Keep `DocumentKind(filename:)`/`Provenance` enums as-is.
- `DocumentsApp.init` builds `try ModelContainer(for: SchemaV2.self, migrationPlan: DocumentsSchemaMigrationPlan.self)`. Existing test files that build in-memory containers with `DocumentRecord.self` may stay unversioned (versioning only matters for on-disk stores).
- **Migration test (`DocumentsSchemaMigrationTests.swift`)**: create an on-disk store in a temp directory using `ModelContainer(for: Schema(versionedSchema: SchemaV1.self)...)`, insert one DocumentRecord + one FolderGrant, save, drop the container; reopen with the migration-plan container and assert every field survived and `pageCount == nil`, then insert/update through V2. Run the real `xcodebuild test` on it — in-memory stores never exercise migration.

## 2. Injectable clock + 30-day trash (`Core/DocumentStore/TrashPolicy.swift`, DocumentStore)

- `DocumentStore` gains `var now: () -> Date = Date.init` (test seam). Replace `Date.now`/`.now` uses inside store mutations (`recordOpen`, `trash`) with `now()`. Existing store tests keep the default.
- `enum TrashPolicy`: `static let retentionDays = 30`; `static func purgeDate(trashedAt: Date) -> Date` (trashedAt + 30d); `static func remainingDays(trashedAt: Date, now: Date) -> Int` (ceil of days until purge, min 0).
- `DocumentStore.purgeExpiredTrash() throws -> Int`: fetch trashed, filter `trashedAt` older than cutoff (`trashedAt == nil` treated as expired — legacy rows), delete each through the existing ownership-aware `delete(_:)` (external records are disowned, never file-deleted), return count. Filter in memory; the trash is small (`#Predicate` with optionals is not worth it).
- Call `purgeExpiredTrash()` at app startup (in `DocumentsApp` `.task`, tolerate failure with a log). TrashView rows show "Deletes in N days" (or "Deletes today") under the name.
- Tests (`TrashPolicyTests.swift`): boundary exactly 30d survives, 30d+1s purges; nil trashedAt purges; injected clock honored; external trashed record → disowned (file untouched) via temp file fixture; count returned.

## 3. Atomic rename (`DocumentStore.rename(_:to:)`)

- Only **app-owned** records (`absolutePath == nil`) may rename; external records throw (store never mutates user files inside granted folders).
- Input is the new **base name** (extension preserved and appended automatically): trim whitespace; reject empty, > 255 UTF-8 bytes for the final filename, `/` or `:` anywhere, leading `.`, and a target name that already exists in the file's directory (fail with "name already exists" — do NOT silently dedupe to " (1)").
- Order of operations: `FileManager.moveItem` file to the new name in the same directory → update record (`displayName`, `relativePath`) → `try save()`; on save failure move the file back and restore record fields, then rethrow. On move failure nothing was persisted.
- Tests (`DocumentStoreRenameTests.swift`): success round-trip (file moved, record points at it, opens); duplicate rejected (file unchanged); each invalid-name case; external record rejected; **save-failure rollback** (use `saveFailureForTesting`: file restored to old name, record unchanged).

## 4. App-scope indexing

- `DocumentsApp` owns `@State private var library = DeviceLibraryService()` and `.environment(library)`; its `.task` runs: `TempArtifactTracker.sweepAtLaunch()`, `purgeExpiredTrash()` (log failures), `StartupRecovery.run(store:)`, then `library.start(store: store)`.
- `RecentTab` drops its local `@State library`, `.task { library.start }`, and `.onDisappear { library.stop }`; it reads `@Environment(DeviceLibraryService.self)`. Indexing now survives tab switches (the audit gap).
- `SettingsView` drops the `grantService:` parameter and reads the library from `@Environment(DeviceLibraryService.self)` (grep for its only call site: RecentTab).
- `DeviceLibraryService.stop()` stays for tests; nothing in the UI calls it anymore.

## 5. Startup recovery (`Core/Support/StartupRecovery.swift`)

- `enum StartupRecovery { static func run(store: DocumentStore) }`, called from `DocumentsApp` `.task` before indexing starts. All failures logged via `Logger`, never fatal.
- Reconciles metadata vs disk **before** the library adopts anything:
  1. App-owned records (`absolutePath == nil`) whose resolved file no longer exists → `store.disown` (a record without a file is a lie). Trashed app-owned records with missing files also disowned.
  2. (External vanished-file pruning already exists in DeviceLibraryService; leave it.)
- Deviation note (deliberate): the plan's "startup recovery screen" is reduced to **silent recovery + logging** — a screen would surface internal state users cannot act on.
- Tests (`StartupRecoveryTests.swift`): record with deleted file is disowned, file-present records untouched, idempotent second run, orphan container file adopted happens via library sync (assert it's not recovery's job — or adopt here if simpler, but only ONE owner).

## 6. Bounded thumbnail pipeline (`Core/Thumbnails/ThumbnailStore.swift` + DocumentRow)

- `actor ThumbnailStore`: disk cache at `Caches/DocumentThumbnails/`. Entry filename `"{record.id}-{Int(mtime.timeIntervalSince1970)}.png"` (content-change invalidation for free).
- `func image(for record: DocumentRecord, documentsDirectory: URL) async -> UIImage?`: cache hit → return; else generate **off the main actor** (PDF → PDFKit page 1 render, image kinds → `CGImageSourceCreateThumbnailAtIndex`), max pixel size 400, write PNG, return. Non-PDF/non-image kinds return nil (rows keep the SF Symbol glyph — honest scope).
- Bounds: max cache bytes 32MB, evict oldest-mtime entries over the cap; `sweep(keeping:)` deletes entries whose filename no longer matches any current record key (called from StartupRecovery).
- `ThumbnailView` (new, used by `DocumentRow`): 48×48 rounded box; `.task` loads via the shared `ThumbnailStore`; shows image or falls back to the kind glyph. For PDFs also compute `PDFDocument.pageCount` during generation and persist once through `DocumentStore.setPageCount(_:for:)` (a normal throwing save; ignore/log failure).
- `DocumentRow` metadata line shows `"\(pageCount) pages"` for PDFs with non-nil pageCount.
- Tests (`ThumbnailStoreTests.swift`): PDF generates a non-nil image + pageCount persisted; PNG generates; cache hit returns without regenerating (check no second file/mtime churn); mtime bump changes key; sweep removes stale entries; eviction respects the cap (use a tiny injected cap, not 32MB).

## 7. Wire-through & hygiene

- `xcodegen generate` from `ios/` after adding files; project.yml should need no manual edits (sources are globbed).
- Every new store mutation follows the existing pattern: mutate → `try save()` → on failure roll back in-memory state and rethrow; UI surfaces via `.storeFailureAlert`.

## Constraints

- Never commit: `AGENTS.md` is intentionally modified in the working tree — leave it unstaged, commit only files you created/changed for this feature. Commit incrementally (one commit per numbered section above, conventional subject lines like the repo's history).
- Only dependency remains ZIPFoundation. No new packages. Match existing code style (doc comments on every type, `// MARK:` sections, no third-party abstractions).
- Do not touch `analysis/*.md` "OnePlus" wording; do not rename anything else.

## Verification gate (work is done only when all hold)

1. `xcodebuild -project Documents.xcodeproj -scheme Documents -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:DocumentsTests` — all green, **report the exact count and the log path** (tee to `logs/verify-phase1.log`).
2. Same destination with `analyze` — clean.
3. `git diff master...HEAD` reviewed: no unintended files, AGENTS.md not committed.

**Known residual risk (document, don't block):** real-device installs carry stores created by the *unversioned* pre-Phase-1 model; the migration test covers the SchemaV1→V2 path, and device verification of upgrade-in-place stays on the pending device checklist.
