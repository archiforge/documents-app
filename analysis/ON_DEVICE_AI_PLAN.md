# On-device AI plan

Status: Option A is implemented in `Core/AI` and `Tools/AI`. The shipped
implementation is on-device only; physical-device model and language-asset
verification remains environment-dependent. No provider, network client,
package, or SwiftData schema change is used.

The 12 AI unit tests pass in the 361-test integrated suite. The Smart
Extraction review/discard/rename/save flow passes on phone and iPad simulators;
see [current evidence](CURRENT_STATUS.md) for device-only verification limits.

## Decision and privacy boundary

The implemented first increment is on-device only:

- **Document Summary:** Foundation Models when the system reports availability.
- **Document Translation:** Translation framework with explicit language-pair
  selection and consent before system-managed asset downloads.
- **Smart Extraction:** Vision document analysis/OCR with bounded field
  candidates; show source regions and confidence.
- **Extract Chart / Extract Formula:** remain in scope as assisted candidates.
  The source crop stays visible beside editable OCR/LaTeX or chart/table
  candidates, and the user reviews before export. Never invent numeric points,
  operators, cell references, or missing values.

Automatic structured chart/formula recognition is a separate, still-unapproved
multimodal server option. It would change privacy and require a new decision on
consent, account, retention, licensing, network, and regional processing. The
current increment sends no document bytes, OCR, prompt, or result to a server,
has no cloud fallback, and never mutates the source. The five Tools entries now
route to local adapters and a review flow. Summary capability reflects the
system model state; Translation validates the selected pair in its flow;
Vision-assisted extraction, chart, and formula candidates remain explicitly
review-only.

## Existing surface and persistence contract

`ToolItem.swift` exposes Summary, Translation, Smart Extraction, Chart, and
Formula entries; `ToolCapability.swift`/`ToolsTab.swift` own their current
status UI. The local adapter lives in `Core/AI`; it uses Vision directly for
OCR/document analysis and
`DocumentStore.saveGeneratedFile(name:data:provenance:)` for one final,
source-preserving output record. Do not pass `DocumentRecord`, `ModelContext`,
or actor-bound services into detached work. Supported first inputs:

- Text/Markdown/HTML: bounded readable text; HTML requires a parser.
- PDF: PDFKit page text, then Vision OCR for scanned pages.
- Images: `RecognizeDocumentsRequest`, with `RecognizeTextRequest` fallback.
- Office/EPUB/OFD/unknown: unavailable until a local extractor exists.
- Archives: require explicit selection of a safely extracted file; never ingest
  an archive recursively.

## iOS 26 capability limits

**Foundation Models.** Query `SystemLanguageModel.default.availability` and
handle `.available`, `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, and
`.modelNotReady`. The local iOS 26.5 SDK exposes `LanguageModelSession`, guided
output, streaming, `contextSize` (currently 4096), and `tokenCount(for:)` on
newer availability boundaries. Use reported token limits where available; do
not assume character count or offer a fake model-download progress bar.
`modelNotReady` means system assets are preparing. Foundation Models is suitable
for bounded summaries and text fields, not a calculator, chart measurement,
formula parser, or source of spreadsheet truth. There is no public embeddings
API in the inspected SDK; semantic search stays out of this increment.

**Translation.** Check `LanguageAvailability.status(from:to:)` (`installed`,
`supported`, `unsupported`) and asynchronous `supportedLanguages`. Use
`TranslationSession.prepareTranslation()` only after the user approves a
system download; check `isReady`/`canRequestDownloads`, support cancellation,
and handle `notInstalled`, unsupported pairs, and cancelled downloads. A
translated result is a new artifact; layout, terminology, and line breaks are
not guaranteed, and the original remains unchanged.

**Vision.** `RecognizeDocumentsRequest` (iOS 26) returns `DocumentObservation`
containers with text, paragraphs, lists, barcodes, and structured tables. Table
rows/cells include ranges, normalized bounds, transcript, and detected data.
Use this API for table candidates and retain page/bounds provenance. Vision OCR
and document analysis do not promise chart-axis/series semantics or formula
operators/references; Chart and Formula therefore stay review-only candidates
under the local option.

## Chart and formula mode decision

**Option A, recommended:** local assisted candidates. Chart shows the source
crop, OCR labels, table cells/geometry/confidence, and an editable TSV/CSV/
Markdown candidate. It never interpolates a plotted point or claims exact
series fidelity. Formula shows the crop, OCR transcript, and optional editable
LaTeX candidate (possibly Foundation Models assisted); it promises no MathML,
OMML, spreadsheet object, or mathematical equivalence. Every export records
source document/page/crop, confidence when available, and “reviewed by user.”

**Option B:** a separately authorized multimodal server recognizer may later
produce structured chart/formula output, but requires explicit per-document
upload consent, authentication, transport/storage, retention/deletion terms,
provider/model provenance, licensing, limits, and failure handling. It still
needs source evidence and confidence. No server route or fallback is included.

## Bounded execution and safe saves

Summary and field extraction use a map/reduce worker: read incrementally,
split at paragraph/heading boundaries, retain page/chunk IDs, reserve prompt and
output budget, summarize chunks, then synthesize only bounded results. On iOS
26.4+ use `tokenCount(for:)` and `contextSize`; otherwise use conservative
local limits. Translation preserves ordered page/paragraph markers and uses
batch client identifiers so streaming responses cannot reorder output. There
is no fixed 200-page product guarantee.

Each job snapshots URL/name/options on the main actor, processes only Sendable
values off-main, and owns one cancellation handle. Use cancellation handlers
where framework APIs permit; check cancellation before/after every page, chunk,
model response, synthesis, and save. Keep bounded text intermediates in memory;
the app-private workspace is an empty cleanup scope for native framework
artifacts and never contains published plaintext chunks. Call
`saveGeneratedFile` once only after review. The source record and bytes remain
intact; errors/logs contain categories and IDs, never content or prompts.

Visual work decodes one page/image at a time with dimension/byte limits, then
discards pixels after small observations are retained. Review UI must expose
source crop/region, candidate status, editable output, confidence/provenance,
and a Cancel action compatible with VoiceOver and Dynamic Type.

## Availability and test boundary

Capability UI should distinguish device ineligibility, Apple Intelligence
being disabled, model preparation, unsupported language pairs, language
installation consent, unreadable input, and review-only extraction. A system
model that is preparing offers retry after the scene becomes active; it does
not trigger a network fallback. Translation downloads are view-bound and
cancelable.

Tests need deterministic fake providers and real local image/page fixtures:
chunk boundaries and token budgets; every availability/download state; Vision
text, document containers, table cells, bounds, confidence, and limits;
cancellation at each stage; temp cleanup; save failure/rollback; source bytes
unchanged; no partial generated record. Chart fixtures assert only reviewed
cells and provenance, and Formula fixtures only editable candidate text, never
plot-point inference or mathematical equivalence. UI tests cover disabled
reasons, progress/cancel, review-before-save, retry, and source retention.
Simulator tests cannot establish Foundation Models or Translation readiness.
Run integration checks on an eligible physical device with Apple Intelligence
both unavailable and ready, and with actual language assets installed or
installable; record observed `LanguageAvailability` instead of assuming it.

## Acceptance and repository evidence

Acceptance requires no network path in the local release, bounded/cancelable
processing, safe single-shot output save, honest capability states, and both
Chart and Formula present under an approved mode. The server option remains a
separate privacy/provider gate.

Relevant files: `ios/Documents/Tools/ToolItem.swift`,
`Tools/ToolCapability.swift`, `Tools/ToolsTab.swift`,
`Core/Scanning/TextRecognition.swift`,
`Core/DocumentStore/DocumentKind.swift`, and
`Core/DocumentStore/DocumentStore.swift`. The audited local SDK is iOS 26.5;
its FoundationModels, Translation, and Vision Swift interfaces supplied the
capability limits above.

Official references: [Foundation Models](https://developer.apple.com/documentation/foundationmodels), [SystemLanguageModel availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [Translation framework](https://developer.apple.com/documentation/translation), [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest), and [DocumentObservation tables](https://developer.apple.com/documentation/vision/documentobservation/container/table).
