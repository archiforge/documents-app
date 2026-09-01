# Design — Screen Board & Requirements Mapping

**Board:** [`screens.html`](screens.html) — open in a browser (self-contained, no build step; prints to PDF cleanly).
Every screen of the target app is drawn as a Figma-style frame with numbered spec pins and minted
requirement IDs (`R<phase>.<n>`). Use it as the visual source of truth so implementation follows one design.

**Plan-of-record:** the revised phased plan (three tabs, P0/P1 done, P3 = Recent parity) was approved in
session and currently lives only in the project memory file (`oneplus-docs-ios-clone-project.md`,
"Prioritized implementation sequence") — it is **not committed to this repo**. `analysis/IOS_PLAN.md` §6
phases describe the superseded five-tab plan. The IDs below were minted for this board on 2026-08-30.

**Caveats carried on the board:** Phase 2 has no recorded definition (do not link anything to "P2");
labels P4–P7 are inferred from the plan's sequence items 4–7. Recommended follow-up: commit the phase
list + this ID scheme under `analysis/` so the linkage survives without the memory store.

**Visual reference:** Android demo frames at `logs/frames-main/` and `logs/frames-scan/` (local,
gitignored). The board re-expresses those recordings with iOS-26-native styling (semantic colors, SF
symbols, system tab bar) — layout and behavior are parity targets; pixel style is iOS-native.

## Phase → screen coverage

| Phase | Scope (plan-of-record) | Screens | Status |
|---|---|---|---|
| P0 | Crash/data-safety hardening (scanTrace, deletion ownership, rollback, watermark page boxes, off-main processing) | no UI | ✅ done (113 tests) |
| Grant indexing *(unnumbered, between P0 and P1)* | `FolderGrant` + `FolderGrantService`, Settings "Indexed Folders", device-library sync | Settings frame | ✅ done on master (`30ab21d`); grant flow device-verification pending |
| P1 | Durable model: SchemaV1→V2 + migration, clock + 30-day trash, atomic rename, app-scope indexing, StartupRecovery, ThumbnailStore | Recently deleted frame (retro IDs R1.1–R1.6) | ✅ done, merged `c1f6772`, 159 tests |
| P2 | **Unrecorded on disk** — nothing may link here | — | ⚠ unknown |
| P3 | Three-tab shell + Recent visual/behavioral parity + rename UI | Shell, Recent ×4, Rename dialog, Tools frame | ▶ next |
| P4 *(inferred)* | Manage tab + Settings: Created by me, Sources, Private Safe (optional non-equivalent), Recently deleted | Manage, Folder browser, Recently deleted, Settings | planned |
| P5 *(inferred)* | Persistent scan bundles + save-chooser workflow + nondestructive edit/reorder/rotate/recrop + validated rename | Scan ×4 frames | planned |
| P6 *(inferred)* | Capability-gated Tools grid, PDF/viewer/archive reliability, then conversion/AI after backend/licensing decisions | Tools frame (R6.1), PDF Tools frame | planned |
| P7 *(inferred)* | Release assets, localization, VoiceOver, perf/interruption tests, reference-video visual acceptance | all frames re-audit | planned |

## Screen ↔ requirement ↔ code mapping

IDs in **bold** are implemented already; plain IDs are targets. Anchors: `analysis/REPORT.md` §, brief §,
or demo frame (`m_*` main, `sm_*` scan).

### Recent tab (P3)

| ID | Requirement | Anchor | Code today |
|---|---|---|---|
| **R3.1** | Three tabs Recent/Tools/Manage; Favorites→context action, Cloud dropped, Browse→Manage▸Sources | demo `m_1`; plan item 3 | `Home/HomeView.swift:6` still 5 tabs — rebase target |
| R3.2 | Toolbar icons: search · sort · settings | `m_1` | partial (settings gear exists in Settings flow, not on Recent toolbar) |
| R3.3 | Large title "Recent" + "N in total" | `m_1` | `Home/RecentTab.swift` (count section exists) |
| **R3.4** | Chips All/Scanned/DOC/XLS/PPT/PDF/OFD/TXT, bold+underline selected, per-filter empty states | `m_1/m_2` | `Core/DocumentStore/FormatFilter.swift`, `Home/FormatFilterRow.swift` (underline style pending) |
| **R3.5** | Collapsible date groups "Today \| 1 item" | `m_1` | `Core/DocumentStore/DateGrouping.swift` |
| **R3.6** | Row: 48pt thumb, name, meta (rel time · size · N pages), provenance "From “Scan document”", star | `m_1` | `Home/DocumentRow.swift`, `Core/Thumbnails/ThumbnailView.swift` |
| R3.7 | FAB (pencil) → scan / new document (action TBD, see ⚠ below) | `m_1` | none |
| R3.8 | Selection mode: Cancel/Select all, checkboxes, "N selected", bulk bar Share·Move·Delete·More | `sm_5` | none |
| R3.9 | Rename dialog, 50-char counter, Cancel/Confirm → `DocumentStore.rename` | `sm_4`; brief P1 §3 | backend only (`DocumentStore.swift:177`); scanner alert at `ScannerFlowView.swift:118` |
| R3.10 | Swipe: leading Favorite, trailing Trash; context menu (PDF rows → PDF Tools) | Increment 1 §1 | exists in Recent/Favorites lists |
| R3.11 | Tools tab = Scan hero + Convert to PDF + Summarise/Translate cards, only functional entries | `m_1`; REPORT §3.2 | `Tools/ToolsTab.swift` (17 items incl. stubs → prune) |
| R3.12 ⚠ | Search UI + FAB action — **no recorded demo UI; decide before P3 UI work** (sort decided 2026-09-01, ledger #7) | ledger #7 | sort shipped: `Core/DocumentStore/DocumentSort.swift` + Recent toolbar menu; search/FAB none |

### Manage (P4)

| ID | Requirement | Anchor | Code today |
|---|---|---|---|
| R4.1 | Groups: Created by me / Sources / Private Safe (optional ⚠) / Recently deleted + count | `m_1`; plan item 4 | none (tab absent) |
| **R4.2** | Sources = Files imports + granted folders (replaces Android Messenger/WhatsApp/Download/Bluetooth) | plan item 4 | `FolderGrantService`, `DeviceLibraryService` shipped |
| **R4.3** | Folder browsing under Manage (reuse, no redesign) | Increment 1 §1 | `Home/BrowseTab.swift` (`DirectoryContentsView`) |
| **R4.4** | Recently deleted: "Deletes in N days/today", Restore/Delete-forever swipes, Empty Trash, 30-day purge | `m_1`; brief P1 §2 | `Settings/TrashView.swift`, `Core/DocumentStore/TrashPolicy.swift` |
| R4.5 | Settings keeps Indexed Folders/Storage/About; Manage becomes primary browse surface | grant indexing work | `Settings/SettingsView.swift` |

### Scan (P5)

| ID | Requirement | Anchor | Code today |
|---|---|---|---|
| R5.1 | Capture: full-bleed camera, hint pill, shutter, gallery import, single exit | `sm_1–sm_3` | `Tools/ScannerFlowView.swift` (VisionKit wrapper in `Core/Scanning/`) |
| R5.2 | Multi-page: 52×68 strip + count badge, Done pill, per-page retake/delete | `sm_3` | exists in flow |
| **R5.3 ⚠** | Save chooser Image/PDF (+ Text for test papers) before save; Cancel → preview. **Diverges from Android auto-save (approved decision)** | plan item 5 | flow currently auto-saves |
| R5.4 | Result: "Saved to Documents" banner, N/M page grid + Processing, toolbar Add·Edit·Rename·Share; nondestructive edit ops | `sm_3–sm_4`; plan item 5 | partial (banner/toolbar exist; edit ops missing) |
| R5.5 | Scan bundle persists across launches until finished/discarded | plan item 5 | missing (memory-only) |
| R5.6 | Shared rename dialog (same component as R3.9) | `sm_4` | scanner-local alert |

### Cross-cutting

| ID | Requirement | Code today |
|---|---|---|
| R6.1 | Tools grid shows only capability-gated functional tools; deferred EnumIds (`ID_SCAN_ID_CARD`, `ID_TEST_PAPER`, `ID_EXTRACT_CHART/FORMULA`, `ID_SMART_EXTRACTION`) appear when shipped; `ToolStubView` tiles removed at P3 rebase | `Tools/ToolItem.swift`, `Tools/ToolStubView.swift` |
| R6.2 | PDF/viewer/archive reliability (Encrypt deferred "P2b" of the old plan) | `Tools/PDFTools/*` |
| **R1.1–R1.6** | Schema/migration, trash policy+clock, atomic rename, app-scope indexing, StartupRecovery, ThumbnailStore (retro-IDs) | `Core/DocumentStore/*`, `Core/Thumbnails/*`, `Core/Support/StartupRecovery.swift` |
| **GI-1..3** | Granted-folder indexing, Settings Indexed Folders, format chips list all docs of a type | `Core/DeviceLibrary/*`, `Settings/SettingsView.swift` |

## Divergence ledger (iOS decision vs Android recording)

| # | Decision | Rationale |
|---|---|---|
| 1 | Save chooser before scan save (R5.3) vs Android auto-save | approved product decision; prevents accidental saves, enables OCR-text target |
| 2 | Three tabs; Favorites as action, no Cloud tab, Browse under Manage (R3.1) | recorded APK truth; five-tab plan superseded |
| 3 | Private Safe shown only if product says go; labeled non-equivalent (R4.1) | no iOS Keychain-style vault parity; explicit plan note |
| 4 | Sources = Files imports + granted folders instead of Messenger/WhatsApp/Download/Bluetooth (R4.2) | Android source apps don't map to iOS; grants shipped |
| 5 | VisionKit native camera chrome replaces external scanner package (R5.1) | no third-party scanner app on iOS; platform substitution |
| 6 | Underline-selected chips, iOS glass tab bar, system fonts (all frames) | iOS-native styling over Android pixel copy; clean-room rule |
| 7 | Sort menu (R3.12): Sort By Date / Name / Size / Type + Descending/Ascending, default Date ↓ where **Date = the file's actual creation date** (`createdAt` from file metadata, backfilled at launch, falls back to `importedAt`); day groups only while sorting by date | no recorded demo UI; product decision 2026-09-01, refined same day from last-opened → import time → real file creation date; row hints show the same date |

## Working agreements

- **Changing the design:** edit `screens.html` frame + this mapping row together; bump the board version
  in the header. Any decision that overrides the Android recording gets a ledger row.
- **Implementation order:** P3 next (frames §01–03) → P4 (§04) → P5 (§05); as-built frames (§06) are
  reference only — don't redesign them while re-skinning.
- **Verification:** visual acceptance for P7 re-audits the board against reference frames; device-only
  flows (camera, grants) verify on hardware per `AGENTS.md`.
