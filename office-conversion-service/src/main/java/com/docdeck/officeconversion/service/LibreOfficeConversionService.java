package com.docdeck.officeconversion.service;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionResult;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import com.docdeck.officeconversion.domain.SourceFamily;
import com.docdeck.officeconversion.validation.InputValidator;
import com.docdeck.officeconversion.validation.OutputValidator;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

@Service
public class LibreOfficeConversionService {
    private static final Logger log = LoggerFactory.getLogger(LibreOfficeConversionService.class);

    private final OfficeConversionProperties properties;
    private final IsolationService isolationService;
    private final InputValidator inputValidator;
    private final OutputValidator outputValidator;
    private final JobCancellationRegistry cancellationRegistry;
    private final Semaphore slots;
    private final ExecutorService logReader = Executors.newVirtualThreadPerTaskExecutor();

    public LibreOfficeConversionService(
            OfficeConversionProperties properties,
            IsolationService isolationService,
            InputValidator inputValidator,
            OutputValidator outputValidator,
            JobCancellationRegistry cancellationRegistry
    ) {
        this.properties = properties;
        this.isolationService = isolationService;
        this.inputValidator = inputValidator;
        this.outputValidator = outputValidator;
        this.cancellationRegistry = cancellationRegistry;
        this.slots = new Semaphore(Math.max(1, properties.getMaxConcurrentJobs()));
    }

    /** Remove only abandoned job directories owned by this service instance. */
    @PostConstruct
    void cleanupAbandonedJobs() {
        Path root = isolationService.workspaceRoot();
        if (Files.isSymbolicLink(root) || !Files.isDirectory(root)) {
            return;
        }
        try (var children = Files.list(root)) {
            children.filter(path -> {
                        String name = path.getFileName().toString();
                        return name.startsWith("job-") || name.startsWith("p-");
                    })
                    .filter(path -> !Files.isSymbolicLink(path))
                    .forEach(LibreOfficeConversionService::deleteTree);
        } catch (IOException error) {
            log.warn("OFFICE_JOB_CLEANUP_ENUMERATION_FAILED");
        }
    }

    public ConversionResult convert(
            InputStream uploaded,
            String filename,
            String sourceExtension,
            ConversionTarget target,
            String requestId
    ) {
        if (!slots.tryAcquire()) {
            throw new ConversionException(ServiceErrorCode.BUSY, 429,
                    "The conversion service is busy; retry this file later.");
        }
        Path job = null;
        JobCancellationRegistry.Handle cancellation = null;
        try {
            job = isolationService.createJobDirectory();
            Path profile = isolationService.writeSandboxProfile(job);
            Path libreOfficeProfile = isolationService.createLibreOfficeProfile(job);
            Path input = writeBoundedInput(uploaded, job, sourceExtension);
            SourceFamily family = inputValidator.validate(input, sourceExtension, target);
            LibreOfficeRun run = runLibreOffice(job, profile, libreOfficeProfile, input, family, target, requestId);
            cancellation = run.cancellation();
            Path output = run.output();
            outputValidator.validate(output, target);
            if (cancellation.isCancelled()) {
                throw new ConversionException(ServiceErrorCode.CANCELLED, 499,
                        "The conversion was cancelled.");
            }
            byte[] bytes = readBounded(output, properties.getMaxOutputBytes());
            if (cancellation.isCancelled()) {
                throw new ConversionException(ServiceErrorCode.CANCELLED, 499,
                        "The conversion was cancelled.");
            }
            return new ConversionResult(bytes, target, suggestedName(filename, target));
        } catch (ConversionException error) {
            throw error;
        } catch (IOException error) {
            throw new ConversionException(ServiceErrorCode.CONVERSION_FAILED, 502,
                    "The conversion could not be completed.", error);
        } finally {
            if (cancellation != null) {
                cancellationRegistry.unregister(requestId, cancellation);
            }
            if (job != null) {
                deleteTree(job);
            }
            slots.release();
        }
    }

    private Path writeBoundedInput(InputStream uploaded, Path job, String sourceExtension) throws IOException {
        String extension = SourceFamily.normalize(sourceExtension);
        Path input = job.resolve("input." + extension).normalize();
        if (!input.getParent().equals(job)) {
            throw new ConversionException(ServiceErrorCode.INVALID_REQUEST, 400,
                    "The source extension is invalid.");
        }
        long max = properties.getMaxInputBytes();
        long count = 0;
        byte[] buffer = new byte[16 * 1024];
        try (InputStream stream = uploaded) {
            try (var output = Files.newOutputStream(input, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                int read;
                while ((read = stream.read(buffer)) != -1) {
                    count += read;
                    if (count > max) {
                        throw new ConversionException(ServiceErrorCode.TOO_LARGE, 413,
                                "The input exceeds the configured limit.");
                    }
                    output.write(buffer, 0, read);
                }
            }
        }
        if (count == 0) {
            throw new ConversionException(ServiceErrorCode.INVALID_INPUT, 422, "The input file is empty.");
        }
        return input;
    }

    private LibreOfficeRun runLibreOffice(
            Path job,
            Path sandboxProfile,
            Path libreOfficeProfile,
            Path input,
            SourceFamily family,
            ConversionTarget target,
            String requestId
    )
            throws IOException {
        isolationService.validateSocketDirectory(job);
        Path outputDirectory = job.resolve("output");
        Files.createDirectory(outputDirectory);
        List<String> libreOfficeArguments = new ArrayList<>(List.of(
                "-env:UserInstallation=" + libreOfficeProfile.toUri(),
                // LibreOffice's macOS OSL pipe chooses /tmp and /var/tmp
                // before consulting this bootstrap value. Both defaults are
                // outside the job sandbox, so pin the per-request socket
                // directory explicitly before starting the process.
                "-env:OSL_SOCKET_PATH=" + job.toAbsolutePath().normalize(),
                "--headless",
                "--nologo",
                "--nodefault",
                "--nofirststartwizard",
                "--nolockcheck",
                "--norestore",
                "--invisible",
                "--convert-to", filterFor(family, target),
                "--outdir", outputDirectory.toString(),
                input.toString()
        ));
        String importFilter = importFilterFor(input.getFileName().toString());
        if (importFilter != null) {
            libreOfficeArguments.add(1, "--infilter=" + importFilter);
        }
        Process process;
        try {
            ProcessBuilder builder = new ProcessBuilder(isolationService.command(sandboxProfile, libreOfficeArguments))
                    .directory(job.toFile())
                    .redirectErrorStream(true);
            // Force LibreOffice's headless VCL backend so startup does not
            // register AppKit windows, pasteboard, or LaunchServices objects
            // outside the job sandbox.
            builder.environment().put("SAL_USE_VCLPLUGIN", "svp");
            builder.environment().put("HOME", job.toString());
            // LibreOffice creates its OSL pipes and transient lock files under
            // TMPDIR during startup. Keep those artifacts inside the same
            // per-request sandbox as the input/profile/output files instead
            // of allowing the process to fall back to the host temp folder.
            builder.environment().put("TMPDIR", job.toString());
            process = builder.start();
        } catch (IOException error) {
            isolationService.invalidateReadiness();
            throw new ConversionException(ServiceErrorCode.RUNTIME_UNAVAILABLE, 503,
                    "LibreOffice could not be started.", error);
        }

        JobCancellationRegistry.Handle cancellation = null;
        boolean handedOff = false;
        try {
            // Registration can reject a duplicate request ID. Keep the
            // already-started process inside this try/finally so every
            // post-launch failure terminates and reaps it.
            try {
                cancellation = cancellationRegistry.register(
                        requestId,
                        () -> destroyTree(process)
                );
            } catch (IllegalStateException error) {
                throw new ConversionException(ServiceErrorCode.BUSY, 429,
                        "The conversion request is already active.", error);
            }
            var outputFuture = logReader.submit(() -> readProcessOutput(process.getInputStream()));
            if (cancellation.isCancelled()) {
                destroyTree(process);
                throw new ConversionException(ServiceErrorCode.CANCELLED, 499,
                        "The conversion was cancelled.");
            }
            boolean finished = process.waitFor(properties.getTimeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!finished) {
                destroyTree(process);
                throw new ConversionException(ServiceErrorCode.TIMED_OUT, 504,
                        "The conversion exceeded its time limit.");
            }
            outputFuture.get(2, TimeUnit.SECONDS);
            if (cancellation.isCancelled()) {
                throw new ConversionException(ServiceErrorCode.CANCELLED, 499,
                        "The conversion was cancelled.");
            }
            if (process.exitValue() != 0) {
                if (process.exitValue() == 64) {
                    isolationService.invalidateReadiness();
                }
                // Do not log LibreOffice's output: it may contain the private
                // job path or source metadata. The request ID is enough to
                // correlate a stable failure without leaking local paths.
                log.warn("LibreOffice failed for request {} with exit {}", requestId, process.exitValue());
                throw new ConversionException(ServiceErrorCode.CONVERSION_FAILED, 422,
                        "LibreOffice rejected the source file.");
            }

            String expectedName = input.getFileName().toString().replaceFirst("\\.[^.]+$", "")
                    + "." + target.extension();
            Path expected = outputDirectory.resolve(expectedName).normalize();
            if (!expected.startsWith(outputDirectory) || !Files.exists(expected)) {
                throw new ConversionException(ServiceErrorCode.MALFORMED_OUTPUT, 502,
                        "LibreOffice did not produce the expected output format.");
            }
            handedOff = true;
            return new LibreOfficeRun(expected, cancellation);
        } catch (InterruptedException error) {
            destroyTree(process);
            Thread.currentThread().interrupt();
            throw new ConversionException(ServiceErrorCode.CANCELLED, 499,
                    "The conversion was cancelled.", error);
        } catch (java.util.concurrent.TimeoutException error) {
            destroyTree(process);
            throw new ConversionException(ServiceErrorCode.CONVERSION_FAILED, 502,
                    "LibreOffice did not close its output stream.", error);
        } catch (java.util.concurrent.ExecutionException error) {
            destroyTree(process);
            throw new ConversionException(ServiceErrorCode.CONVERSION_FAILED, 502,
                    "LibreOffice output could not be read.", error.getCause());
        } finally {
            if (!handedOff && cancellation != null) {
                cancellationRegistry.unregister(requestId, cancellation);
            }
            if (!handedOff && process.isAlive()) {
                destroyTree(process);
            }
        }
    }

    private record LibreOfficeRun(Path output, JobCancellationRegistry.Handle cancellation) {
    }

    private static String filterFor(SourceFamily family, ConversionTarget target) {
        return switch (target) {
            case PDF -> "pdf:" + switch (family) {
                case SPREADSHEET -> "calc_pdf_Export";
                case PRESENTATION -> "impress_pdf_Export";
                default -> "writer_pdf_Export";
            };
            case DOCX -> "docx:Office Open XML Text";
            case XLSX -> "xlsx:Calc MS Excel 2007 XML";
            case PPTX -> "pptx:Impress MS PowerPoint 2007 XML";
        };
    }

    private static String importFilterFor(String filename) {
        String extension = filename.substring(filename.lastIndexOf('.') + 1).toLowerCase(java.util.Locale.ROOT);
        return switch (extension) {
            // Comma/quote/UTF-8, row 1, text-quoted fields, no special-number
            // inference, and formula import disabled. InputValidator applies
            // the same dialect and bounds before LibreOffice sees the file.
            case "csv" -> "Text - txt - csv (StarCalc):44,34,76,1,,1033,true,false,false,false,false,false,false";
            case "txt", "log", "text" -> "Text - Choose Encoding";
            case "md", "markdown", "mdown" -> "Markdown";
            case "html", "htm", "xhtml" -> "HTML (StarWriter)";
            default -> null;
        };
    }

    private static byte[] readBounded(Path output, long maxBytes) throws IOException {
        long size = Files.size(output);
        if (size > maxBytes) {
            throw new ConversionException(ServiceErrorCode.TOO_LARGE, 502,
                    "The conversion output exceeds the configured limit.");
        }
        return Files.readAllBytes(output);
    }

    private static String readProcessOutput(InputStream stream) throws IOException {
        try (InputStream input = stream; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int read;
            long count = 0;
            while ((read = input.read(buffer)) != -1) {
                count += read;
                if (count <= 64 * 1024) {
                    output.write(buffer, 0, read);
                }
            }
            return output.toString(java.nio.charset.StandardCharsets.UTF_8);
        }
    }

    private static void destroyTree(Process process) {
        List<ProcessHandle> descendants = process.descendants().toList();
        descendants.forEach(child -> {
            child.destroy();
        });
        process.destroy();
        descendants.forEach(child -> {
            try {
                child.onExit().get(500, TimeUnit.MILLISECONDS);
            } catch (Exception ignored) {
                if (child.isAlive()) {
                    child.destroyForcibly();
                }
            }
        });
        if (process.isAlive()) {
            process.destroyForcibly();
        }
        try {
            process.waitFor(2, TimeUnit.SECONDS);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        }
    }

    private static String suggestedName(String filename, ConversionTarget target) {
        String safe = filename == null ? "Converted" : filename.replace('\\', '/');
        int separator = safe.lastIndexOf('/');
        if (separator >= 0) {
            safe = safe.substring(separator + 1);
        }
        String base = safe.replaceFirst("\\.[^.]+$", "");
        base = base.replaceAll("[^A-Za-z0-9._ -]", "_").trim();
        if (base.isBlank() || base.equals(".") || base.equals("..")) {
            base = "Converted";
        }
        return base + "." + target.extension();
    }

    private static void deleteTree(Path root) {
        if (root == null || Files.isSymbolicLink(root) || !Files.exists(root)) {
            return;
        }
        try (var paths = Files.walk(root)) {
            paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                try {
                    Files.deleteIfExists(path);
                } catch (IOException error) {
                    log.warn("OFFICE_JOB_CLEANUP_DELETE_FAILED");
                }
            });
        } catch (IOException error) {
            log.warn("OFFICE_JOB_CLEANUP_WALK_FAILED");
        }
    }

    @PreDestroy
    void shutdown() {
        cancellationRegistry.cancelAll();
        logReader.shutdownNow();
    }
}
