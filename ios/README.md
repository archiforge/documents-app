# Documents for iOS

Documents is an original SwiftUI document hub for iOS 26. The app, target,
module, scheme, and home-screen name use **Documents**. The bundle identifier
remains `com.docdeck.app` so existing device installs keep their app
container.

For the implementation matrix, approved scope, and remaining verification, see
[`analysis/CURRENT_STATUS.md`](../analysis/CURRENT_STATUS.md). For the screen
frames and requirement mapping, see [`design/README.md`](../design/README.md).

## Requirements

- macOS with Xcode 26.x and an iOS 26 simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) on `PATH`
- Network access for the ZIPFoundation package and the first
  `NativeArchives` bootstrap
- Automatic signing for device builds with the team in `project.yml`

The project uses two Swift Package Manager dependencies:

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.19 for ZIP
  creation and extraction
- The local `NativeArchives` package for bounded, read-only, unencrypted
  7-Zip and RAR extraction on arm64 iOS device and arm64 iOS Simulator

## Bootstrap NativeArchives

`NativeArchives` builds the libarchive and XZ Utils C libraries into an iOS
device and simulator XCFramework. Bootstrap it from the repository root
before you run XcodeGen or build the app:

```sh
cd ios/Packages/NativeArchives
./Scripts/bootstrap.sh
cd ../..
xcodegen generate
```

The script pins libarchive 3.8.9 and XZ Utils 5.8.3 by SHA-256. It requires
the Xcode command-line tools and network access for the source archives.
Generated files in `ios/Packages/NativeArchives/.build/` and
`ios/Packages/NativeArchives/Artifacts/` are ignored by Git and must not be
committed.

## Generate, build, and test

Run these commands from `ios/` after the NativeArchives bootstrap:

```sh
# Generate Documents.xcodeproj from project.yml.
xcodegen generate

# Build for the iOS simulator.
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

# Run the unit tests.
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:DocumentsTests test

# Run the UI tests when the simulator is available.
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:DocumentsUITests test
```

Edit `project.yml` instead of the generated project. Run `xcodegen generate`
after adding or removing source files or changing project settings.

## Physical-device validation

Build and install a device build with the following commands:

```sh
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'generic/platform=iOS' build
xcrun devicectl device install app --device CORE_DEVICE_ID PATH_TO_DOCUMENTS_APP
```

The camera capture flow and Files-provider security-scoped folder grants
require a paired physical device. A paired iPhone is connected, but these
hardware flows still need manual verification; simulator tests do not establish
hardware support.

## Source layout

```text
ios/
├── project.yml                     # XcodeGen specification
├── Documents/
│   ├── DocumentsApp.swift          # SwiftData container and services
│   ├── Home/                       # Recent, Tools, Manage, and folder views
│   ├── Components/                 # Shared document actions and rename UI
│   ├── Viewers/                    # Quick Look and sharing
│   ├── Core/DocumentStore/         # SwiftData model and store mutations
│   ├── Core/FileBridge/            # Container files, staging, and folders
│   ├── Core/DeviceLibrary/         # App and granted-folder indexing
│   ├── Core/Scanning/              # VisionKit, drafts, OCR, and scan editor
│   ├── Core/PDFTools/              # PDF operations and password protection
│   ├── Core/Conversion/            # Local conversion and HTTPS Office client
│   ├── Core/AI/                    # On-device extraction and model processing
│   ├── Core/PrivateSafe/           # Encrypted copies and authentication
│   ├── Core/Archives/              # ZIPFoundation and NativeArchives flows
│   ├── Tools/                      # Scanner, PDF, conversion, and archive UI
│   ├── Settings/                   # Settings and Recently deleted
│   └── Resources/                 # English string catalog and assets
└── DocumentsTests/                 # Unit and integration tests
```

## Implementation status

| Area | Status |
|---|---|
| Home shell | Three tabs: Recent, Tools, and Manage. Favorites is a row action, Cloud is not a tab, and browsing is under Manage → Sources. |
| Recent | Search, sort, format filters, selection mode, bulk actions, create menu, and English accessibility copy are implemented. |
| Manage and folders | Created by me, app Documents, granted-folder read-only browsing, Recently deleted, folder creation, owned-document Move, and destination validation are implemented. The expanded integrated suite passed 361 unit tests; phone and iPad navigation follow-ups passed. |
| Store and file safety | Permanent deletion stages app-owned bytes and restores them when persistence fails. Startup recovery reconciles interrupted deletion and Move journals before missing-file cleanup. External records remain metadata-only on delete and are never moved. |
| Scanner | VisionKit capture, durable app-private scan drafts, save choices, and the reorder/rotate/recrop/remove editor are implemented. Actual resume/rename/rotate/relaunch/save UI passed once (`scanner-recovery-ui-tests-r3`); camera verification is device-only. |
| PDF tools | Merge, split, watermark, sign, image extraction, print, and password-protected copies are implemented. PDF core passed three tests (`PASS3`) and password-protection UI passed once (`PASS1`); the live checkout suite also passed. |
| Archives | ZIP creation and extraction use ZIPFoundation. Bounded, unencrypted 7-Zip and RAR extraction uses NativeArchives, which bootstraps from a fresh checkout for arm64 iOS device and simulator slices; archive processing is covered by the live checkout suite. |
| Conversion | Text, Markdown, HTML, and image to PDF conversion runs on device. Office source/target routes use a configurable HTTPS service; the approved Java 21/Maven/LibreOffice implementation is in `office-conversion-service/` and passes 24 Java tests and 51 independent HTTP checks. A self-hosted HTTPS endpoint is required for use outside local verification. |
| Localization and accessibility | English `Localizable.xcstrings`, plural count helpers, Dynamic Type adjustments, labels, selected-state exposure, and larger action targets are delivered. Phone layout/accessibility passed 6 tests, phone Tools passed 2, iPad navigation passed 2, and iPad accessibility/Tools passed 6. |
| Private Safe | Manage exposes the approved local encrypted-copy Safe. Face ID/passcode, encrypted storage, preview, and explicit export are implemented; all 21 Safe storage/recovery/session tests pass, while physical-device authentication remains unverified; see [`analysis/PRIVATE_SAFE_PLAN.md`](../analysis/PRIVATE_SAFE_PLAN.md). |
| AI features | On-device Summary, Translation, Smart Extraction, and reviewed Chart/Formula flows are implemented and audited; 12 AI unit tests and the Smart Extraction review/save UI pass. Summary reflects Apple Intelligence readiness; Translation checks language availability in its flow. See [`analysis/ON_DEVICE_AI_PLAN.md`](../analysis/ON_DEVICE_AI_PLAN.md). |

## Data and platform decisions

- `DocumentRecord` stores app-owned files by container-relative path. External
  records store an absolute path and keep their source bytes in place.
- App-owned deletion and Move use hidden app-private staging and journals. The
  device-library enumerator excludes those locations and defers adoption when
  journal reconciliation cannot be inspected safely.
- Unfinished scan bytes live under Application Support, outside the indexed
  Documents tree. Invalid drafts remain available for explicit recovery or
  discard.
- The store is a `@MainActor @Observable` service because SwiftData contexts
  and UI mutations are main-actor isolated.
- The English string catalog is the only localization target in this release.
  User-provided filenames remain literal values and are not catalog keys.

## Latest expansion verification

The integrated unit suite passes **361 tests** (`approved-final-unit-r1`).
All 16 phone UI cases have passing evidence across the full run and its
corrected follow-up; the full run itself had one large-type Manage test
failure, which passed after its scrolling correction. Expanded iPad UI passed
six tests, followed by three final Safe/Manage checks. Static analysis and the
unsigned iOS Release build pass (`approved-final-analyze-r1` and
`approved-final-release-r1`). The built app preserves `com.docdeck.app` and
supports iPhone and iPad.

These checks include the Safe and AI audit corrections and the Office client.
The separate Office service passes 24 Java tests and 51 HTTP checks.
Its detailed evidence and current hardware limits are recorded in [`analysis/CURRENT_STATUS.md`](../analysis/CURRENT_STATUS.md).
Logs and `.xcresult` bundles are under
`/private/tmp/documents-app-completion/` on the verification host.

## Verification baseline before the approved feature expansion

The combined live checkout run passed 309 unit tests and 12 UI tests. The
final unit run passed 310 tests. From `ios/`:

```sh
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,id=6F121CEB-B2B4-47DD-99B5-C301EAD4A67F' \
  -derivedDataPath /private/tmp/documents-app-completion/live-deriveddata \
  -resultBundlePath /private/tmp/documents-app-completion/live-all-tests-r2.xcresult test
```

The command returned `** TEST SUCCEEDED **`. Follow-up checks passed for phone
layout/accessibility and Tools (`phone-final-layout-tests`, PASS6), phone Tools
(`phone-tools-final-tests`, PASS2), iPad navigation
(`ipad-navigation-tests-r3`, PASS2), and iPad accessibility/Tools
(`ipad-accessibility-tools-tests-r4`, PASS6). Focused archive/deletion/Move/
startup coverage passed 64 tests, scanner recovery passed once, gallery passed
once, PDF core passed three tests, password UI passed once, and the earlier
English accessibility audit passed four tests.

The final unsigned release build and analyzer also passed. The release command
was `xcodebuild -project Documents.xcodeproj -scheme Documents -destination
'generic/platform=iOS' -configuration Release -derivedDataPath
/private/tmp/documents-app-completion/live-deriveddata
CODE_SIGNING_ALLOWED=NO build`, producing `** BUILD SUCCEEDED **`; the analyzer
produced `** ANALYZE SUCCEEDED **`. Result logs are
`live-release-build.log` and `live-analyze-final.log`. Compiler output still
includes XCTest actor-isolation and deprecated-API warnings with no known
functional blocker in tested paths. These simulator and unsigned-build results
precede the approved Safe, AI, and Office expansion; see the current status file
for that wave’s verification.

A paired iPhone is now connected; hardware checks remain outstanding. Camera capture, Files-provider grants, and
an archive Files-provider round-trip therefore require later physical-device
validation. No Archive UI test was added because app-private source/ZIP files
are not reliably selectable through the simulator system provider; processing
is covered by real ZIP, 7-Zip, and RAR fixtures.
