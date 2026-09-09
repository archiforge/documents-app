# Current implementation status

**Status date:** 2026-09-09

This file records the implementation state of the iOS app and the evidence
available for the current completion pass. The numbered phases in
`analysis/IOS_PLAN.md` describe an earlier five-tab plan. Use this file and
the source paths in the tables below for the current work sequence.

## Approved implementation wave

On 2026-09-09 the user approved all three implementation plans: local encrypted-copy Private Safe, on-device AI Option A with reviewed Chart and Formula candidates, and the self-hosted Java 21/Maven/Spring Boot Office conversion service. Luna Max agents implemented the features and audit corrections. The latest checkpoint covers this expansion; the separate baseline section records earlier checks.

## Latest integration checkpoint

- Integrated unit suite: **PASS361**, `approved-final-unit-r1.xcresult`.
- Final Safe storage, recovery, session, and audit regressions: **PASS21**,
  `approved-safe-final-r1.xcresult` (also included in the integrated suite).
- Phone UI: all **16 distinct tests have passing evidence**. The full run
  `approved-phone-ui-r3.xcresult` passed 15 and exposed one large-type Manage
  scrolling failure. After correcting the test to scroll to Files imports,
  `approved-final-phone-followup-r1.xcresult` passed that test and both Safe
  tests (**PASS3**). This is combined evidence, not a clean single full run.
- Expanded iPad UI: **PASS6**, `approved-ipad-ui-r1.xcresult`, followed by
  final Safe and large-type Manage checks (**PASS3**),
  `approved-final-ipad-followup-r1.xcresult`.
- Final static analysis: **PASS**, `approved-final-analyze-r1.log`.
- Final unsigned Release build: **PASS**, `approved-final-release-r1.log`.
  Bundle ID `com.docdeck.app`, minimum iOS 26, and iPhone/iPad families verified.
- Office backend: **PASS24** Java tests and packaged successfully with Java 21.
  Independent real HTTP audit: **PASS51**, including ten conversions with
  parsed output and source-text markers, authentication, rejection cases,
  cancellation responses, and workspace cleanup. Evidence:
  `office-http-audit/evidence/20260909T192447Z-a2b1c189/audit.json`.
- A stricter cancellation follow-up passed **17 targeted checks**, including
  observing the actual headless LibreOffice process, DELETE returning 202,
  conversion returning 499 `cancelled`, and empty job storage afterward:
  `office-http-audit/evidence/20260909T193332Z-e06d1068/audit.json`.
  These overlap the full audit and are not 17 additional unique scenarios.
- LibreOffice 26.2.6.3 isolation: aggregate descendant-memory termination,
  native TCP denial, and outside-job read denial passed independent launcher
  probes. Memory enforcement samples every 100 ms; it is not a kernel-hard
  instantaneous memory bound.

## Product surface

The home shell has three tabs: **Recent**, **Tools**, and **Manage**. Favorites
is a row action, Cloud is not a product surface, and browsing is under Manage
→ Sources. The current shell is implemented in
`ios/Documents/Home/HomeView.swift`.

| Area | State | Source and evidence |
|---|---|---|
| Recent list | Implemented; live unit/UI coverage passed | `Home/RecentTab.swift`, `Home/FormatFilterRow.swift`, search, sort, selection mode, and the create menu; the live checkout run passed 309 unit and 12 UI tests, the expanded unit run passed 361, and corrected iPad navigation/accessibility follow-ups also passed |
| Recent create menu | Implemented | The pencil action offers scan and new document routes through `QuickActionRouter` |
| Manage | Implemented; live unit/UI coverage passed | `Home/ManageTab.swift` provides Created by me, app Documents, resolved granted folders, Recently deleted, and Settings; navigation follow-up passed on iPad (`ipad-navigation-tests-r3`, PASS2) |
| App folder browsing | Implemented; live unit/UI coverage passed | `Home/BrowseTab.swift`, `Home/FolderDestinationPicker.swift`, `Core/DocumentStore/DocumentStore+Folders.swift`, and `Core/FileBridge/FileBridge+Folders.swift` |
| Folder create and Move | Implemented for app-owned records | Names, traversal, symlink escape, collisions, external-record rejection, persistence rollback, and bulk partial failures are covered by the live suite and the archive/deletion/Move/startup focused run (`archive-deletion-final-tests`, PASS64) |
| Granted folders | Read-only browsing and indexing implemented | Security-scoped folder resolution stays in `FolderGrantService`; only a paired physical device can verify the Files grant flow |
| Soft delete and permanent deletion | Implemented with recoverable staging | `DocumentStore` stages app-owned bytes before permanent deletion; `StartupRecovery` reconciles deletion and Move journals before missing-record cleanup |
| Scan capture | Implemented with VisionKit | `Tools/ScannerFlowView.swift` uses native camera UI; camera capture requires a physical device |
| Scan drafts | Implemented in app-private storage | `Core/Scanning/ScanDraftStore.swift` keeps unfinished pages outside the indexed Documents tree and retains malformed drafts for user recovery |
| Scan editor | Implemented; recovery and targeted UI coverage passed | `Core/Scanning/ScanEditorView.swift` supports reorder, rotate, recrop, and remove while preserving source bytes; actual resume/rename/rotate/relaunch/save UI passed once (`scanner-recovery-ui-tests-r3`) |
| PDF toolbox | Implemented | Merge, split, watermark, sign, image extraction, print, and password protection are wired through `Tools/PDFTools` and `Core/PDFTools` |
| PDF password protection | Implemented; helper, UI, and live-suite evidence passed | `PDFPasswordProtection.swift` uses PDFKit's native write options; helper PASS3 and end-to-end UI PASS1 were recorded after the live Section correction |
| ZIP archive operations | Implemented | `ArchiveService` uses ZIPFoundation for ZIP creation and extraction |
| 7-Zip and RAR extraction | Implemented for bounded, unencrypted extraction | `Core/Archives/ArchiveService.swift`, `ios/Packages/NativeArchives/`; NativeArchives builds arm64 iOS device and arm64 iOS Simulator slices from a fresh-checkout bootstrap; processing is covered by the live suite |
| On-device conversion | Implemented for text, Markdown, HTML, and images to PDF | Office source and target routes use the approved service client |
| Office conversion | Implemented and audited; HTTPS deployment/configuration required for use | Java 21/Maven/LibreOffice service passes 24 Java tests and 51 independent HTTP checks; HTTPS client and Settings route pass iOS checks; see [`OFFICE_CONVERSION_PLAN.md`](OFFICE_CONVERSION_PLAN.md) |
| AI summary, translation, and extraction | Implemented and audited; device readiness checks remain | Five on-device flows provide runtime readiness and reviewed output; 12 AI unit tests pass in the integrated suite, and the real Smart Extraction review/discard/rename/save UI passes; see [`ON_DEVICE_AI_PLAN.md`](ON_DEVICE_AI_PLAN.md) |
| Private Safe | Implemented and audited; device authentication checks remain | Manage entry and document-copy action are connected; all 21 storage, recovery, session, and final audit tests pass; see [`PRIVATE_SAFE_PLAN.md`](PRIVATE_SAFE_PLAN.md) |
| Localization and accessibility | English catalog and UI changes delivered; targeted phone/iPad audits passed | `Resources/Localizable.xcstrings`, `Resources/AppStrings.swift`, English development region, large Dynamic Type and accessibility UI coverage; phone layout/accessibility passed 6, phone Tools passed 2, iPad navigation passed 2, and iPad accessibility/Tools passed 6 |

## Verification commands and evidence

Run from `ios/`. Project generation and the final integrated unit run passed:

```sh
xcodegen generate
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,id=6F121CEB-B2B4-47DD-99B5-C301EAD4A67F' \
  -derivedDataPath /private/tmp/documents-app-completion/live-deriveddata \
  -resultBundlePath /private/tmp/documents-app-completion/approved-final-unit-r1.xcresult \
  test -only-testing:DocumentsTests
```

Result: **PASS361**, `** TEST SUCCEEDED **`. This includes the 21 Safe,
12 AI, seven source-access, and five independent Office coordinator audit
checks alongside the existing processing and persistence tests.

The final phone UI follow-up passed with the source built by the unit run:

```sh
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,id=6F121CEB-B2B4-47DD-99B5-C301EAD4A67F' \
  -derivedDataPath /private/tmp/documents-app-completion/live-deriveddata \
  -resultBundlePath /private/tmp/documents-app-completion/approved-final-phone-followup-r1.xcresult \
  test-without-building \
  -only-testing:DocumentsUITests/AccessibilityReleaseTests/testLargeTypeKeepsManageFolderNavigationReachable \
  -only-testing:DocumentsUITests/PrivateSafeSmokeTests
```

Result: **PASS3**, `** TEST EXECUTE SUCCEEDED **`. The same selectors passed
on iPad destination `6F80D12A-CECB-4B14-BF37-8DD4F8CFB78E`, with result bundle
`approved-final-ipad-followup-r1.xcresult`. The preceding expanded iPad run
passed Safe, Office Settings, AI review, and Tools checks (**PASS6**).
Phone and iPad screenshot attachments were inspected during the UI audits.

The final analyzer and unsigned Release device build passed:

```sh
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'platform=iOS Simulator,id=6F121CEB-B2B4-47DD-99B5-C301EAD4A67F' \
  -derivedDataPath /private/tmp/documents-app-completion/live-deriveddata analyze
xcodebuild -project Documents.xcodeproj -scheme Documents \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath /private/tmp/documents-app-completion/live-deriveddata \
  CODE_SIGNING_ALLOWED=NO build
```

Results: **PASS**, `** ANALYZE SUCCEEDED **` and `** BUILD SUCCEEDED **`.
Logs are `approved-final-analyze-r1.log` and `approved-final-release-r1.log`.
The built app preserves bundle ID `com.docdeck.app`, minimum iOS 26, and
both iPhone/iPad device families. Compiler output includes existing test
actor-isolation/deprecation and orientation warnings; this unsigned build
is not a signed release or physical-device sign-off.

All logs and result bundles above are under
`/private/tmp/documents-app-completion/` on the verification host. Earlier
baseline evidence remains in `live-unit-final-tests` (310 tests),
`live-all-tests-r2` (309 unit and 12 UI), and the targeted scanner, archive,
PDF, phone, and iPad logs referenced in the product table.

## Office service verification

From `office-conversion-service/`, the actual build command was:

```sh
env JAVA_HOME=/private/tmp/documents-app-completion/runtimes/jdk-21.0.12.1+1/Contents/Home \
  mvn test package
```

Result: **PASS24**, no failures, errors, or skipped tests; packaging succeeded.
The rebuilt JAR used the final UID-aware socket limit and pinned LibreOffice
26.2.6.3 runtime with the repository sandbox/profile launcher. It ran on
`127.0.0.1:18080` with a synthetic bearer token and workspace `/private/tmp/o`.
See the [service README](../office-conversion-service/README.md) for the
required runtime environment. The independent harness was:

```sh
python3 /private/tmp/documents-app-completion/office-http-audit/scripts/office_http_audit.py \
  --base-url http://127.0.0.1:18080 \
  --token "$OFFICE_CONVERSION_TOKEN" --workspace-root /private/tmp/o
```

All 51 full-audit checks passed. Ten real conversions covered RTF to PDF,
text/Markdown/HTML to DOCX, CSV to XLSX/PDF, ODP to PPTX/PDF, and ODS to
XLSX/PDF. Returned PDFs passed `pdfinfo`/`pdftotext`; Office outputs passed
ZIP CRC/XML validation and contained the synthetic source markers. A separate
17-check follow-up established cancellation after the actual LibreOffice
process started, plus cleanup. This is representative format coverage, not
a fidelity claim for every legacy Office variant or complex layout.

The temporary server was stopped after verification. Port 18080 had no
listener, no matching LibreOffice/launcher process remained, and the job
workspace was empty. No external service was deployed.

## Physical-device verification limits

The paired iPhone became connected during this pass. Interactive hardware
checks were not performed. Camera capture, Files-provider
security-scoped grants, archive Files-provider round-trip, actual Safe
Face ID/passcode and data-protection transitions, and Foundation Models /
Translation readiness remain **unverified**. Simulator fake authentication
and provider fixtures do not establish those system behaviors. Archive
processing itself passes real ZIP, 7-Zip, and RAR fixture tests.

## Roadmap and decisions

The approved implementation and automated audits are complete. Remaining
work requires the device or deployment environment:

1. Complete the physical-device checks listed above with the user's
   participation.
2. Configure a self-hosted HTTPS Office endpoint and optional token in
   Settings for use outside the local verification host. The backend is
   implemented and locally verified; no service was published or deployed.

All three feature plans were approved on 2026-09-09. No additional
architecture decision is pending for this scope. Chart and Formula remain
reviewed, editable candidates under approved on-device Option A; this does
not claim exact chart reconstruction or mathematical equivalence. Office
conversion supports its documented matrix, not arbitrary Office fidelity or
PDF-to-Office conversion.

## Build and package prerequisites

`ios/project.yml` declares ZIPFoundation and the local `NativeArchives`
SwiftPM package. NativeArchives provides bounded, unencrypted 7-Zip and RAR
extraction; it replaces the old documentation claim that ZIPFoundation is the
only package. Its fresh-checkout bootstrap builds arm64 iOS device and arm64
iOS Simulator slices.

From the repository root, bootstrap its generated XCFramework before
XcodeGen or an Xcode build:

```sh
cd ios/Packages/NativeArchives
./Scripts/bootstrap.sh
cd ../..
xcodegen generate
```

The bootstrap pins libarchive 3.8.9 and XZ Utils 5.8.3 by SHA-256. The
generated `ios/Packages/NativeArchives/.build/` and
`ios/Packages/NativeArchives/Artifacts/` directories are ignored by Git.
