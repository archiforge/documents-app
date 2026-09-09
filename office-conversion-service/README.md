# Documents Office Conversion Service

This service is the approved self-hosted boundary for one-file Office
conversion. It runs Java 21, Spring Boot 4.1.1, and a pinned stable
LibreOffice release. The iOS app sends immutable bytes and receives one
validated output; the service never receives an app path and does not persist
conversion jobs.

## Runtime contract

`GET /v1/capabilities` returns the versioned source-extension matrix, output
media types, and effective input/output, timeout, and concurrency limits.

`POST /v1/conversions` accepts one `multipart/form-data` request:

- `file`: one source file
- `sourceExtension`: the lower-case source extension, without a dot
- `target`: `pdf`, `docx`, `xlsx`, or `pptx`

The response is one binary body with `Content-Type`, a safe
`Content-Disposition` filename, and `X-Request-Id`. Errors are
`application/problem+json` problem objects with stable lower-case `code` values. When
`OFFICE_CONVERSION_TOKEN` is set, every endpoint requires
`Authorization: Bearer <token>`.

The client sends `X-Conversion-Request-Id` with its conversion and uses
`DELETE /v1/conversions/{requestId}` to cancel it. Cancellation also accepts
an ID before its POST arrives. A disconnected client that cannot deliver
DELETE leaves a bounded job running until completion or the 120-second
timeout; a silent network loss is not immediate server cancellation.

The client must configure an HTTPS endpoint. TLS termination belongs in the
self-hosted deployment boundary; this process does not silently upgrade or
follow an HTTP endpoint.

## Isolation requirement

The service fails closed unless all of these are configured and executable:

- `LIBREOFFICE_EXECUTABLE`
- `OFFICE_SANDBOX_EXECUTABLE` (for the local macOS setup, `/usr/bin/sandbox-exec`)
- `OFFICE_RESOURCE_LAUNCHER` (`scripts/office-job-launcher.sh`)
- `OFFICE_SANDBOX_PROFILE` (`config/mac-sandbox.sb`)
- `LIBREOFFICE_RUNTIME_ROOT` (the LibreOffice `.app` directory)
- `OFFICE_WORKSPACE_ROOT` (a dedicated, short absolute directory)

Every request gets a unique job directory and LibreOffice profile. The
runner pins LibreOffice's macOS OSL Unix socket path and temporary files to
that job directory before launch. The launcher applies a CPU rlimit and
supervises aggregate resident memory for the
sandbox process and its descendants. Memory is sampled every 100 ms, so the
configured memory bound permits one sampling interval of growth before the
launcher terminates the process tree. The generated sandbox policy restricts
writes and Unix socket access to that job and denies TCP/UDP access. The Java service adds the
wall-clock timeout, input/output and archive-expansion limits, worker
semaphore, child-process termination, output-format checks, and recursive
cleanup. A temporary profile alone is not treated as isolation.

If the host cannot apply the CPU rlimit, inspect the child process tree, or run
the configured sandbox, the launcher/probe exits closed and the capability
response remains unavailable; provide an equivalent resource wrapper or
container before enabling conversions on that host.

The macOS profile allows runtime/system/font reads needed by LibreOffice,
including a literal read of the filesystem root directory required by dyld,
and only job-directory writes. Adapt the profile and launcher for another host
only when the replacement provides equivalent no-network, filesystem, CPU,
memory, and child-process controls.

## Local run

```sh
export JAVA_HOME=/path/to/jdk-21
export LIBREOFFICE_EXECUTABLE=/path/to/LibreOffice.app/Contents/MacOS/soffice
export LIBREOFFICE_RUNTIME_ROOT=/path/to/LibreOffice.app
export OFFICE_SANDBOX_EXECUTABLE=/usr/bin/sandbox-exec
export OFFICE_RESOURCE_LAUNCHER="$PWD/scripts/office-job-launcher.sh"
export OFFICE_SANDBOX_PROFILE="$PWD/config/mac-sandbox.sb"
# Generated job/probe paths must fit the UID-aware macOS OSL path budget.
# Use a dedicated root for this service instance; startup clears its old jobs.
export OFFICE_WORKSPACE_ROOT=/private/tmp/o
export SERVER_ADDRESS=127.0.0.1
mvn spring-boot:run
```

Keep the service behind HTTPS and set `OFFICE_CONVERSION_TOKEN` outside source
control. The default limits are 50 MiB input, 100 MiB output, 120 seconds per
job, 1 GiB process memory, and two concurrent workers. They are deliberately
bounded and may be tightened by deployment configuration or tests.

The initial matrix supports Word-family (`doc`, `docx`, `dot`, `dotx`, `rtf`,
`odt`) to PDF/DOCX, spreadsheet-family (`xls`, `xlsx`, `csv`, `ods`) to
PDF/XLSX, presentation-family (`ppt`, `pptx`, `pps`, `ppsx`, `odp`) to
PDF/PPTX, and bounded text/Markdown/HTML to DOCX. Same-format conversions,
PDF-to-Office, Pages/Numbers/Keynote, macros, unsafe archive entries, active
HTML, malformed signatures, and unsupported embeds are rejected.

PDF responses are parsed with Apache PDFBox 3.0.8, the current stable 3.x
release, and must contain at least one unencrypted page within the service's
size and page-count bounds.
