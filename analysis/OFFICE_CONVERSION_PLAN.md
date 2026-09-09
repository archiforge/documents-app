# Office conversion implementation plan

**Status: approved and implemented behind a configured service boundary.** The
Java 21/Spring Boot service, sandboxed LibreOffice runner, iOS client seam, and
settings form are present. Stable runtime and iOS integration verification are
recorded separately; no generic Office fidelity is claimed.

## Current app boundary

Local text, Markdown, HTML, and image-to-PDF conversion remains in
`ConversionRegistry`. `ConversionCoordinator` routes the approved Office
matrix through capability negotiation and `OfficeConversionClient`, then saves
validated bytes as a new app-owned record while leaving the source unchanged.
Conversion is an explicit one-file action and does not synchronize the library.

## Proposed execution model

Use a Java 21/Maven Spring Boot service with a pinned stable LibreOffice
release. The local implementation needs no production host, deployment, or
credentials: the app uses a configurable HTTPS endpoint and an optional token
stored in Keychain when a service is configured. The material approval gate is
the self-hosted service/data boundary and the source/target fidelity scope.

Each job gets a private temporary directory and unique LibreOffice profile.
Workers are bounded, and the service enforces input/output sizes, CPU and
memory limits, a process timeout, termination of the child process, and
cleanup on success, error, disconnect, and restart. Concrete defaults are 50
MiB input, 100 MiB output, 120 seconds per job, and two concurrent workers;
tests may tighten them. The capability response publishes the effective
limits.

## Source and target matrix

The matrix starts from the extensions currently represented by
`DocumentKind`. Each extension needs signature validation in addition to its
coarse kind. A source and target with the same format is rejected as a no-op;
changing a filename extension is never conversion.

| Current source family | Initial service inputs | Initial targets | Boundary and validation |
|---|---|---|---|
| Word (`doc`, `docx`, `dot`, `dotx`, `rtf`, `odt`) | `doc`, `docx`, `dot`, `dotx`, `rtf`, `odt` | PDF, DOCX | Validate OLE/RTF/OOXML signatures and required parts. Map ODT through the ordinary `DocumentKind` extension table; exclude Pages. |
| Spreadsheet (`xls`, `xlsx`, `csv`, `ods`) | `xls`, `xlsx`, `csv`, `ods` | PDF, XLSX | Validate OLE/OOXML or bounded UTF-8 RFC 4180 CSV (comma/double-quote, 100,000 rows, 256 columns, no formula cells). Map ODS through `DocumentKind`; exclude Numbers. |
| Presentation (`ppt`, `pptx`, `pps`, `ppsx`, `odp`) | `ppt`, `pptx`, `pps`, `ppsx`, `odp` | PDF, PPTX | Validate legacy or OOXML signatures and slide count. Map ODP through `DocumentKind`; exclude Keynote. |
| Text and web (`txt`, `log`, `text`, `md`, `markdown`, `mdown`, `html`, `htm`, `xhtml`) | `txt`, `md`, `markdown`, `mdown`, `html`, `htm`, `xhtml` | DOCX; existing local PDF export remains | Bound text size. Sanitize HTML scripts, remote resources, and embedded content. Keep current local PDF conversion independent. |
| PDF | None | None | Reject PDF-to-Office. The probe demonstrated why a successful process exit is insufficient. |
| Images and other kinds | None | None | Existing image-to-PDF and OCR flows remain separate from this service matrix. |

The service must reject unsupported combinations before upload whenever the
cached capability response is authoritative, and the service must repeat the
check server-side. There is no generic PDF-to-Word, chart-to-spreadsheet, or
arbitrary document-to-presentation fidelity claim.

## Proposed service contract

- `GET /v1/capabilities` returns a versioned schema containing supported source
  extensions, targets, media types, signature rules, limits, timeout, and
  service build. The app treats it as data, not as permission to infer support
  for an unlisted extension.
- `POST /v1/conversions` accepts one multipart file, the source extension, and
  the target. It is stateless and returns one binary output with an explicit
  media type and suggested name; no conversion state is persisted. The request
  never exposes an app path or asks the server to read a client filesystem.
- Errors use `application/problem+json` with stable codes for unsupported,
  invalid, too large, timed out, cancelled, unauthorized, and unavailable
  requests. The client treats response headers, filenames, and media types as
  untrusted until the body passes validation.

Validate output size and extension, then validate the format: PDF must open
with a bounded, unencrypted page parser (PDFBox in the service and PDFKit in
the client); OOXML must be a safe ZIP containing parsed `[Content_Types].xml`,
the expected main part, valid CRCs, and permitted relationship types. The app
reopens an Office result and checks required content before saving. A zero
exit status from LibreOffice is never sufficient.

## iOS file, scope, and transaction integration

Resolve app-owned files through the injected `FileBridge`, rather than
`DocumentRecord.fileURL`, so tests and production use the same container root.
For a granted folder, resolve the persisted security-scoped bookmark through
`FolderGrantService`, hold the scope while copying the input, and do not treat
the cached `absolutePath` as permission. Upload immutable bytes or a private
temporary copy; never send a local path to the service.

Register request and response files with the existing temporary-artifact
cleanup path. Release the security scope after the copy and remove temporary
data on success, error, timeout, cancellation, disconnect, or relaunch. A
cancellation must cancel the request, prevent a later save, and clean up.
After validation, call `saveGeneratedFile`; if persistence fails, retain the
source and metadata and remove the generated artifact. Existing name collision
handling remains the store's responsibility. The UI should surface endpoint
configuration, unsupported format, timeout, authentication, and malformed
response errors and should not enable a destination merely because a card is
visible.

## Input safety and LibreOffice boundary

For OOXML, verify the ZIP central directory, reject path traversal, require the
expected content types and main parts, and reject macros, active content, or
unsupported embeds. Ordinary external hyperlinks are not rejected solely
because relationships exist: disable external resource loading and network
access during conversion. Check legacy OLE headers, RTF's structural prefix,
bounded CSV input, and sanitized HTML. Do not infer a filter from a filename
alone.

Invoke LibreOffice headlessly with explicit import/export filters, a private
profile, and a private output directory. Disable macros and external-link
updates, restrict filesystem access, and deny outbound network access. Logs
should contain request IDs and stable error codes, never uploaded content or
local paths.

## Verification plan

Service tests should cover the capability matrix, every accepted and rejected
extension, malformed signatures, unsafe ZIP entries, macros and external
links, size limits, output validation, and the explicit PDF-to-Office reject.
Synthetic DOCX, XLSX, PPTX, RTF, CSV, Markdown, and HTML fixtures should be
checked for recognizable content and PDF page, spreadsheet, or slide counts.
Exercise timeout, process termination, disconnect, cancellation, concurrency,
restart cleanup, authentication, and malformed output.

iOS tests should use a mock client to cover stale or missing capabilities,
injected-bridge reads, security-scope copy and release, cancellation before
and after response, timeout cleanup, service errors, malformed responses,
save-failure rollback, and collision-safe output. Run one iOS-to-local-service
flow only after the client seam exists. A real Files-provider grant still
requires physical-device verification.

## Probe evidence and open decisions

The local capability probe on 2026-09-09 used the bundled LibreOffice 26.8
alpha investigation build. A synthetic Writer fixture converted to DOCX and
PDF. Sending the resulting PDF through the Writer DOCX export path returned
exit code zero but produced a DOCX containing decoded PDF bytes rather than
the source text. The result supports strict input/filter validation and a
PDF-to-Office rejection; it is not a production compatibility claim. Probe
artifacts are under
`/private/tmp/documents-app-completion/office-capability-probe/`.

The self-hosted service/data boundary and source/target fidelity scope are approved.
`office-conversion-service/` implements the contract, bounded input/output
validation, HTTPS/token authentication, cancellation, cleanup, resource limits,
and fail-closed sandbox/resource-launcher requirements. `Core/Conversion/
OfficeConversionClient.swift` sends immutable bytes through the injected
source-access seam and validates the returned document before `saveGeneratedFile`;
`Settings/OfficeConversionSettingsView.swift` stores the HTTPS endpoint and
optional token. A stable LibreOffice 26.2.6.3 Writer fixture conversion under
the short-path sandbox produced a readable one-page PDF; native RSS aggregate,
outside-job read, and TCP network-denial probes also passed. The final packaged service passed 24 Java tests and 51 independent HTTP
checks, including ten conversions with parsed outputs and preserved text
markers; see [current evidence](CURRENT_STATUS.md). HTTPS deployment is
separate from local verification. Unsupported combinations remain
rejected by design.
