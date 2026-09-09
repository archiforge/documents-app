# Design screen board and requirements mapping

**Board version:** v6 · 2026-09-09

Open [`screens.html`](screens.html) in a browser. The board is self-contained,
requires no build step, and prints to PDF. It expresses the recorded Android
frames with iOS 26-native styling: semantic colors, SF Symbols, system text
styles, and the system tab bar. The board is a visual reference; source code
and [`analysis/CURRENT_STATUS.md`](../analysis/CURRENT_STATUS.md) determine
implementation status.

The historical phase numbers in [`analysis/IOS_PLAN.md`](../analysis/IOS_PLAN.md)
describe a superseded five-tab plan. Phase 2 has no recorded definition. The
`P4`-`P7` labels in the board remain historical anchors, not release gates.

## Current workstreams

| Workstream | Board frames | State |
|---|---|---|
| Foundations | Design tokens | Implemented with semantic system colors and text styles |
| Home shell | App shell, Recent, Tools | Three tabs are implemented in `Home/HomeView.swift`; the live checkout run passed 309 unit and 12 UI tests, the expanded unit run passed 361, and corrected iPad navigation follow-up passed 2 |
| Recent actions | Recent populated, empty, selection, rename, and create menu | Search, sort, filters, selection mode, shared rename, and the Recent create menu are implemented |
| Manage and folders | Manage, Sources folder browser, Recently deleted | Manage, folder creation, owned-document Move, and bulk Move are implemented; archive, deletion, Move, and startup focused coverage passed 64 tests (`archive-deletion-final-tests`), and the live checkout suite passed |
| Scan | Capture, multi-page, save chooser, result, editor | VisionKit flow, app-private drafts, save choices, and reorder/rotate/recrop/remove editing are implemented; scanner recovery UI passed once (`scanner-recovery-ui-tests-r3`), with targeted phone/iPad UI checks passed and camera validation device-only |
| PDF and archives | PDF Tools and viewer | Password protection and bounded, unencrypted ZIP/7-Zip/RAR extraction are implemented; PDF core passed three tests, password UI once, and the live checkout suite passed |
| Release | Settings and all-frame review | English localization and accessibility changes are delivered; phone layout/accessibility PASS6, phone Tools PASS2, iPad navigation PASS2, and iPad accessibility/Tools PASS6; unsigned Release build and analyzer passed, with physical-device checks and HTTPS service deployment remaining |

## Recent requirements

| ID | Requirement | Code and status |
|---|---|---|
| **R3.1** | Recent, Tools, and Manage are the three tabs. Favorites is a row action, Cloud is dropped, and Browse lives under Manage → Sources. | `Home/HomeView.swift`; implemented |
| **R3.2** | Recent provides search, sort, and Settings actions. | `Home/RecentTab.swift`; implemented, with large action targets |
| **R3.3** | Recent shows a large title and a localized document count. | `Home/RecentTab.swift`, `Resources/AppStrings.swift`; implemented with plural catalog entries |
| **R3.4** | Format chips cover All, Scanned, PDF, DOC, EPUB, XLS, and TXT, with selected state and empty results. | `Home/FormatFilterRow.swift`; implemented with accessibility state exposure |
| **R3.5** | Date sorting groups documents by day. | `Core/DocumentStore/DateGrouping.swift`, `Core/DocumentStore/DocumentSort.swift`; implemented |
| **R3.6** | Rows show a thumbnail, filename, metadata, provenance, and favorite action. | `Home/DocumentRow.swift`; implemented |
| **R3.7** | The Recent pencil action offers Scan Document and New Document. | `Home/RecentTab.swift`, `Core/Support/QuickActionRouter.swift`; implemented |
| **R3.8** | Selection mode supports Select all, Share, Favorite, Compress, Move, and soft Delete. | `Home/BulkSelection.swift`, `Home/BulkSelectionActions.swift`; implemented; Move reports partial failures |
| **R3.9** | Rename uses a shared 50-character form with a large-type-safe presentation. | `Components/DocumentActions.swift`; implemented |
| **R3.10** | Rows support favorite, trash, Quick Look, Rename, and PDF Tools actions. | `Home/RecentTab.swift`, `Components/DocumentActions.swift`; implemented |
| **R3.11** | Tools exposes scanner, conversion, PDF, archive, and on-device AI routes with runtime readiness explanations. | `Tools/ToolsTab.swift`, `Tools/ToolItem.swift`, `Tools/ToolCapability.swift`; implemented with Core tools, File conversion, Other tools, and AI groups; live suite and phone/iPad Tools follow-ups passed |
| **R3.12** | Search, sort, and create-menu behavior is decided and shipped. | `Home/RecentTab.swift`; implemented; no unresolved Recent interaction decision remains |

## Manage requirements

| ID | Requirement | Code and status |
|---|---|---|
| **R4.1** | Manage groups Created by me, Sources, Recently deleted, and Settings. Private Safe is an approved local encrypted-copy surface. | `Home/ManageTab.swift`; `PrivateSafe/PrivateSafeView.swift` and document copy action integrated; encrypted storage and lifecycle audit completed; 21 Safe tests pass, with physical-device authentication remaining |
| **R4.2** | Sources includes app Documents and resolved granted folders. Granted sources remain read-only. | `Home/ManageTab.swift`, `Core/DeviceLibrary/`; implemented |
| **R4.3** | Sources supports nested browsing, import, create-folder, and app-owned Move. | `Home/BrowseTab.swift`, `Home/FolderDestinationPicker.swift`, `Core/DocumentStore/DocumentStore+Folders.swift`, `Core/FileBridge/FileBridge+Folders.swift`; implemented; archive, deletion, Move, and startup focused coverage passed 64 tests, and the live checkout suite passed |
| **R4.4** | Recently deleted provides restore, permanent deletion, Empty Trash, and 30-day retention. | `Settings/TrashView.swift`, `Core/DocumentStore/DocumentStore.swift`; implemented with recoverable deletion staging |
| **R4.5** | Settings retains indexed folders, storage, and About, and adds HTTPS Office service configuration. | `Settings/SettingsView.swift`; implemented |

## Scan requirements

| ID | Requirement | Code and status |
|---|---|---|
| **R5.1** | Capture uses VisionKit native camera UI, gallery input, and one scan route. | `Tools/ScannerFlowView.swift`, `Core/Scanning/`; implemented; physical-device verification pending |
| **R5.2** | Multi-page capture supports page review, deletion, and completion. | `Tools/ScannerFlowView.swift`; implemented |
| **R5.3** | Save choices distinguish PDF, image, and text output where the scan mode supports them. | `Tools/ScannerFlowView.swift`; implemented and documented as an iOS divergence from Android auto-save |
| **R5.4** | Results provide page preview, Add, Edit, Rename, and Share actions. | `Tools/ScannerFlowView.swift`, `Core/Scanning/ScanEditorView.swift`; implemented; scanner recovery UI passed once (`scanner-recovery-ui-tests-r3`) and targeted phone/iPad checks passed |
| **R5.5** | An unfinished scan survives relaunch until it is finished or discarded. | `Core/Scanning/ScanDraftStore.swift`; implemented in app-private storage |
| **R5.6** | Scan editing is nondestructive and supports reorder, rotate, recrop, and remove. | `Core/Scanning/ScanEditorView.swift`, `Core/Scanning/ScanDraftStore.swift` (`ScanPageEditing`); implemented |

## Tools and release requirements

| ID | Requirement | Code and status |
|---|---|---|
| **R6.1** | Tool entries must expose their real capability. Office routes lead to conversion with a configured HTTPS service. Summary reports model readiness; Translation checks language-pair availability, and assisted extraction requires review. Archive Extract supports ZIP and bounded, unencrypted 7-Zip/RAR files. | `Tools/ToolItem.swift`, `Tools/ToolCapability.swift`, `Tools/ToolsTab.swift`; implemented; live suite, phone Tools PASS2, and iPad accessibility/Tools PASS6 |
| **R6.2** | PDF operations include password protection, and archive operations include ZIP plus bounded, unencrypted 7-Zip/RAR extraction. | `Core/PDFTools/`, `Core/Archives/`, `Packages/NativeArchives/`; implemented; PDF core PASS3, password UI PASS1, archive/deletion/Move/startup focused PASS64, and live suite passed |
| **R6.3** | English localization uses a string catalog with plural document and selection counts. | `Resources/Localizable.xcstrings`, `Resources/AppStrings.swift`; delivered; phone layout/accessibility PASS6 and iPad accessibility/Tools PASS6 |
| **R6.4** | Actions expose useful labels, selected state, and at least 44-point targets; Rename works at large Dynamic Type. | `Home/RecentTab.swift`, `Home/FormatFilterRow.swift`, `Components/DocumentActions.swift`; delivered; phone layout/accessibility PASS6 and iPad accessibility/Tools PASS6 |

## Decisions and divergence ledger

The board records product decisions that differ from the Android reference:

| # | Decision | Rationale |
|---|---|---|
| 1 | Save chooser before scan save instead of Android auto-save | Enables PDF, image, and text targets and lets the user review the capture |
| 2 | Three tabs; Favorites is a row action, Cloud is dropped, and Browse is under Manage | Matches the recorded navigation intent while using an iOS-native shell |
| 3 | Private Safe holds encrypted local copies; originals stay in place | Approved Face ID/passcode, device-only Keychain key, no cloud/key recovery, protected temporary exports |
| 4 | Sources map to Files imports and granted folders | Android source apps do not map to iOS; security-scoped grants provide the supported folder access model |
| 5 | VisionKit native camera replaces the external scanner package | The iOS SDK provides the camera flow and its platform chrome |
| 6 | Selected chips use an underline, and the shell uses semantic iOS styling | Preserves the interaction cue while following iOS conventions |
| 7 | Sort uses file creation date, name, size, or type with explicit order | The recorded Recent behavior uses the file's actual creation date for date grouping |
| 8 | Chips are All, Scanned, PDF, DOC, EPUB, XLS, and TXT | Keeps the approved format list; other kinds remain visible under All |
| 9 | Bulk Move is included with a destination picker | The user deferred Move to the folder model and then included it in the completed scope; external records remain unmoved |
| 10 | Recent's pencil action opens Scan Document or New Document | Makes the recorded FAB useful while keeping both routes in existing app flows |
| 11 | Scan drafts and nondestructive editing live in app-private storage | Prevents unfinished pages from appearing in device indexing and supports recovery after interruption |
| 12 | PDF password protection uses PDFKit's native write options | Avoids hand-rolled cryptography and preserves the existing PDF toolbox boundary |
| 13 | Release localization targets English only | The user requested English catalog infrastructure and plural handling before adding other locales |

## Approved feature expansion

The user approved these implementation boundaries on 2026-09-09. They are
implemented, with device checks and HTTPS service deployment remaining; current verification is recorded in
[`CURRENT_STATUS.md`](../analysis/CURRENT_STATUS.md).

- **Private Safe:** [encrypted-copy design](../analysis/PRIVATE_SAFE_PLAN.md),
  with Face ID/passcode and explicit plaintext export.
- **Office conversion:** [self-hosted service contract](../analysis/OFFICE_CONVERSION_PLAN.md),
  configured HTTPS endpoint and Java 21/Spring Boot with stable LibreOffice.
- **AI:** [on-device Option A](../analysis/ON_DEVICE_AI_PLAN.md), with reviewed
  chart/formula candidates and runtime availability explanations.

## Working agreements

- Edit a board frame and its mapping row together, then bump the board version
  in this file and in `screens.html`.
- Keep Android reference frames under `logs/frames-main/` and
  `logs/frames-scan/` as local, gitignored material.
- Keep the gallery camera chrome divergence: VisionKit supplies native camera
  UI, and a paired physical device is required for validation.
- Use `analysis/CURRENT_STATUS.md` for test evidence and release limits. Do not
  label a simulator result as camera or security-scoped grant validation.
