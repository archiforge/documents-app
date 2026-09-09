# Documents repository guidance

## Project and references

Documents is an original SwiftUI document-hub app for iOS 26, using Swift 6,
SwiftData, and native Apple frameworks. The project, app target, module, and
scheme are named `Documents`. Preserve the bundle ID `com.docdeck.app`: it
maintains existing device installs and their document containers.

- [ios/README.md](ios/README.md): environment setup and device installation.
  Feature-status tables describe earlier increments; verify current behavior
  in the code.
- [design/README.md](design/README.md) and [design/screens.html](design/screens.html):
  visual targets, requirement IDs, and approved divergences. The board and
  `HomeView` use three tabs: Recent, Tools, and Manage. Status labels and
  code pointers can lag implementation. When changing the design, update the
  board and mapping together, bump the board version, and record divergences.
- [analysis/IOS_PLAN.md](analysis/IOS_PLAN.md), the implementation briefs, and
  [analysis/REPORT.md](analysis/REPORT.md): historical plans and behavioral
  reference. Phase numbering differs between plans; identify the applicable
  brief instead of inferring scope from a phase number. “OnePlus Documents”
  names the analyzed Android app, not this app's branding. Preserve those
  analysis references; keep app code, assets, icons, and wording original.

## Build and verification

Use macOS with Xcode 26.x, an iOS 26 simulator runtime, and XcodeGen on PATH.
ZIPFoundation provides ZIP operations through Swift Package Manager. The local
`ios/Packages/NativeArchives` package provides 7z/RAR extraction. Before the
first build, run `./Scripts/bootstrap.sh` from that package directory to build
its pinned libarchive/liblzma XCFramework. Package resolution and the initial
native-source downloads require network access; generated artifacts are ignored.

`ios/project.yml` is authoritative for project configuration. After changing
it or adding/removing source or test files, run `xcodegen generate` from `ios/`
and include the resulting project changes. Avoid hand-editing generated
`Documents.xcodeproj` configuration.

Run from `ios/`; substitute an available simulator if needed
(`xcrun simctl list devices available`):

```sh
xcodegen generate
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  test -only-testing:DocumentsTests
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' analyze
```

For a focused unit run, use `-only-testing:DocumentsTests/<TestClass>`.
For UI smoke tests, substitute `-only-testing:DocumentsUITests`. A plain
`test` runs both targets. Run checks appropriate to the change and report
actual commands and PASS/FAIL/BLOCKED results; historical test counts are not
a current baseline. Documentation-only edits need link/configuration checks
and `git diff --check`, without an app build.

## Code map and conventions

- `ios/Documents/DocumentsApp.swift` owns the SwiftData container and
  app-scoped services injected through SwiftUI's environment. `Home/` owns
  tabs, list filtering/sorting/search, and bulk selection; `Components/`
  contains shared document actions. `Viewers/`, `Tools/`, and `Settings/`
  contain their respective UI flows.
- `Core/DocumentStore/` owns persistence and document metadata;
  `Core/FileBridge/` owns container file operations; `Core/DeviceLibrary/`
  indexes app files and user-granted folders. Keep document mutations in
  `DocumentStore`, an `@MainActor @Observable` service.
- `Core/Scanning/`, `Core/PDFTools/`, `Core/Conversion/`, and `Core/Archives/`
  implement processing behind the UI. `Core/Thumbnails/` owns thumbnail
  caching; `Core/Support/` includes startup recovery, quick actions, and
  temporary artifact cleanup. Preserve actor isolation: pass Sendable values
  such as `Data` to background processing, rather than SwiftData records.

## Data invariants

- `DocumentsSchema.swift` defines versioned schemas and the migration plan;
  current aliases point to `SchemaV3`. Preserve historical schema layouts
  and add a migration path when changing persisted models.
- `absolutePath == nil` identifies an app-owned file addressed through its
  container-relative path. External records are indexed in place: deletion
  removes their metadata only, and rename is rejected. Folder access comes
  from security-scoped bookmarks, not the cached absolute path.
- Resolve owned files through the store's injected `FileBridge` in store
  operations. `DocumentRecord.fileURL` uses the default container, so it
  bypasses injected test directories. Preserve existing save-failure rollback
  and file cleanup behavior when extending mutations.
- Ordinary Delete means soft trash. `TrashPolicy` retains files for 30 days;
  purge uses the injected `DocumentStore.now` clock. Recent's Date sort uses
  the file's `createdAt`, falling back to `importedAt`.
- Preserve launch ordering: temporary artifact sweep, `StartupRecovery`,
  expired-trash purge, then device-library indexing. Recovery reconciles
  records; `DeviceLibraryService` owns adoption of unindexed files.

## Tests and repository hygiene

- Tests use XCTest in `ios/DocumentsTests/` and `ios/DocumentsUITests/`.
  Store tests use `@MainActor`, an in-memory SwiftData container, and an
  injected `FileBridge` rooted in a unique temporary directory. Reuse
  `TestSupport.swift` factories for generated PDF/image/OCR fixtures.
  Exercise persistence failures and migrations when changing those behaviors.
  Migration tests need temporary on-disk stores reopened through the migration
  plan; in-memory containers do not exercise migration.
- Keep the shared scheme's test targets nonparallel. Simulator tests cover
  processing logic, but camera capture and Files-provider folder grants need
  physical-device verification when changed.
- Start new features from `master` on `feature/<feature-name>` branches.
- Keep root artifact ignore patterns anchored, especially `/tools/`: an
  unanchored `tools/` can also hide `ios/Documents/Tools/` on macOS. Use
  `git check-ignore` when changing ignore rules or moving directories.
  Keep APKs, videos, decompiled output, logs, build products, and local agent
  state out of version control, as specified in `.gitignore`.
