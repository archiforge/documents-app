package com.docdeck.officeconversion.service;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import com.sun.security.auth.module.UnixSystem;
import org.springframework.stereotype.Service;

/**
 * Owns the process isolation boundary. A unique LibreOffice profile is not a
 * sandbox, so production conversion refuses to run unless the configured
 * resource launcher and sandbox profile are executable and present.
 */
@Service
public class IsolationService {
    private static final long READINESS_CACHE_NANOS = java.util.concurrent.TimeUnit.SECONDS.toNanos(30);
    // macOS sockaddr_un.sun_path is 104 bytes. LibreOffice's secured pipe
    // name is `/OSL_PIPE_<uid>_SingleOfficeIPC_<32 hex bytes>`; its native
    // implementation rejects names whose length is >= 104. Derive the UID
    // component at runtime so the guard remains correct for the host user.
    private static final int MAX_OSL_SOCKET_NAME_BYTES = 103;
    private static final int MAX_OSL_SOCKET_DIRECTORY_BYTES = calculateMaxOslSocketDirectoryBytes();
    private final OfficeConversionProperties properties;
    private volatile Boolean cachedReadiness;
    private volatile long readinessExpiresAtNanos;

    public IsolationService(OfficeConversionProperties properties) {
        this.properties = properties;
    }

    public boolean isReady() {
        long now = System.nanoTime();
        Boolean cached = cachedReadiness;
        if (cached != null && now < readinessExpiresAtNanos) {
            return cached;
        }
        synchronized (this) {
            now = System.nanoTime();
            cached = cachedReadiness;
            if (cached != null && now < readinessExpiresAtNanos) {
                return cached;
            }
            boolean ready = computeReadiness();
            cachedReadiness = ready;
            readinessExpiresAtNanos = now + READINESS_CACHE_NANOS;
            return ready;
        }
    }

    /** Clear a cached probe after a launch or runtime boundary failure. */
    public void invalidateReadiness() {
        synchronized (this) {
            cachedReadiness = null;
            readinessExpiresAtNanos = 0;
        }
    }

    private boolean computeReadiness() {
        if (!executableAvailable(properties.getLibreOfficeExecutable())) {
            return false;
        }
        if (!executableAvailable(properties.getSandboxExecutable())
                || !executableAvailable(properties.getResourceLauncherExecutable())
                || !regularFile(properties.getSandboxProfileTemplate())
                || !directory(properties.getRuntimeReadRoot())) {
            return false;
        }
        return probeIsolationBoundary();
    }

    public Path workspaceRoot() {
        String configured = properties.getWorkspaceRoot();
        if (configured == null || configured.isBlank()) {
            return Path.of(System.getProperty("java.io.tmpdir"), "oc");
        }
        return Path.of(configured).toAbsolutePath().normalize();
    }

    public Path createJobDirectory() {
        if (!isReady()) {
            throw new ConversionException(
                    ServiceErrorCode.SANDBOX_UNAVAILABLE,
                    503,
                    "The conversion runtime isolation is not configured."
            );
        }
        try {
            Path root = workspaceRoot();
            Files.createDirectories(root);
            if (Files.isSymbolicLink(root)) {
                throw new IOException("workspace root is a symbolic link");
            }
            Path job = Files.createTempDirectory(root, "job-");
            try {
                validateSocketDirectory(job);
                return job;
            } catch (RuntimeException error) {
                Files.deleteIfExists(job);
                throw error;
            }
        } catch (IOException error) {
            throw new ConversionException(
                    ServiceErrorCode.RUNTIME_UNAVAILABLE,
                    503,
                    "The conversion workspace is unavailable.",
                    error
            );
        }
    }

    public Path writeSandboxProfile(Path jobDirectory) {
        try {
            String template = Files.readString(Path.of(properties.getSandboxProfileTemplate()));
            String profile = template
                    .replace("${JOB_DIR}", escape(jobDirectory.toAbsolutePath().normalize().toString()))
                    .replace("${LIBREOFFICE_ROOT}", escape(runtimeReadRoot()))
                    .replace("${JOB_ANCESTOR_RULES}", ancestorReadRules(jobDirectory))
                    .replace("${RUNTIME_ANCESTOR_RULES}", ancestorReadRules(Path.of(runtimeReadRoot())));
            Path profilePath = jobDirectory.resolve("sandbox.sb");
            Files.writeString(
                    profilePath,
                    profile,
                    StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE
            );
            return profilePath;
        } catch (IOException | RuntimeException error) {
            throw new ConversionException(
                    ServiceErrorCode.SANDBOX_UNAVAILABLE,
                    503,
                    "The conversion sandbox profile is unavailable.",
                    error
            );
        }
    }

    public Path createLibreOfficeProfile(Path jobDirectory) {
        try {
            Path profile = Files.createDirectory(jobDirectory.resolve("lo-profile"));
            Files.writeString(
                    profile.resolve("registrymodifications.xcu"),
                    """
                            <?xml version="1.0" encoding="UTF-8"?>
                            <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema">
                              <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
                                <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
                              </item>
                              <item oor:path="/org.openoffice.Office.Common/Load">
                                <prop oor:name="UpdateDocMode" oor:op="fuse"><value>0</value></prop>
                              </item>
                            </oor:items>
                            """,
                    StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE
            );
            return profile;
        } catch (IOException error) {
            throw new ConversionException(
                    ServiceErrorCode.RUNTIME_UNAVAILABLE,
                    503,
                    "The LibreOffice profile could not be created.",
                    error
            );
        }
    }

    public void validateSocketDirectory(Path jobDirectory) {
        Path normalized = jobDirectory.toAbsolutePath().normalize();
        try {
            int bytes = normalized.toString().getBytes(StandardCharsets.UTF_8).length;
            if (bytes > MAX_OSL_SOCKET_DIRECTORY_BYTES) {
                throw new ConversionException(
                        ServiceErrorCode.RUNTIME_UNAVAILABLE,
                        503,
                        "The conversion workspace path is too long for LibreOffice's local socket."
                );
            }
        } catch (RuntimeException error) {
            if (error instanceof ConversionException conversionError) {
                throw conversionError;
            }
            throw new ConversionException(
                    ServiceErrorCode.RUNTIME_UNAVAILABLE,
                    503,
                    "The conversion workspace path is invalid.",
                    error
            );
        }
    }

    static int maxOslSocketDirectoryBytes() {
        return MAX_OSL_SOCKET_DIRECTORY_BYTES;
    }

    public List<String> command(Path profile, List<String> libreOfficeArguments) {
        return isolatedCommand(
                profile,
                properties.getLibreOfficeExecutable(),
                libreOfficeArguments
        );
    }

    private List<String> isolatedCommand(Path profile, String executable, List<String> arguments) {
        List<String> command = new ArrayList<>();
        command.add(properties.getResourceLauncherExecutable());
        command.add("--cpu-seconds");
        command.add(Long.toString(Math.max(1, properties.getTimeout().toSeconds())));
        command.add("--memory-bytes");
        command.add(Long.toString(Math.max(properties.getMaxProcessMemoryBytes(), 256L * 1024L * 1024L)));
        command.add("--sandbox-executable");
        command.add(properties.getSandboxExecutable());
        command.add("--profile");
        command.add(profile.toString());
        command.add("--");
        command.add(executable);
        command.addAll(arguments);
        return List.copyOf(command);
    }

    private static boolean regularFile(String value) {
        if (value == null || value.isBlank()) {
            return false;
        }
        try {
            Path path = Path.of(value);
            return !Files.isSymbolicLink(path) && Files.isRegularFile(path);
        } catch (RuntimeException error) {
            return false;
        }
    }

    private static boolean directory(String value) {
        if (value == null || value.isBlank()) {
            return false;
        }
        try {
            Path path = Path.of(value);
            return !Files.isSymbolicLink(path) && Files.isDirectory(path);
        } catch (RuntimeException error) {
            return false;
        }
    }

    private String runtimeReadRoot() {
        return Path.of(properties.getRuntimeReadRoot()).toAbsolutePath().normalize().toString();
    }

    private static String ancestorReadRules(Path path) {
        List<String> rules = new ArrayList<>();
        Path current = path.toAbsolutePath().normalize().getParent();
        while (current != null && !current.equals(current.getRoot())) {
            rules.add("(allow file-read* (literal \"" + escape(current.toString()) + "\"))");
            current = current.getParent();
        }
        return String.join("\n", rules);
    }

    private boolean probeIsolationBoundary() {
        Path probe = null;
        Path outside = null;
        try {
            Path root = workspaceRoot();
            Files.createDirectories(root);
            if (Files.isSymbolicLink(root)) {
                return false;
            }
            // Keep the readiness directory short enough for LibreOffice's
            // fixed OSL socket suffix just like a real job directory.
            probe = Files.createTempDirectory(root, "p-");
            validateSocketDirectory(probe);
            Path profile = writeSandboxProfile(probe);
            // Probe the actual sandbox/resource boundary with a standalone
            // executable. `command(...)` always launches LibreOffice and is
            // therefore not a valid readiness probe.
            Process process = new ProcessBuilder(isolatedCommand(profile, "/usr/bin/true", List.of()))
                    .directory(probe.toFile())
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .start();
            boolean finished = process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                process.waitFor(1, java.util.concurrent.TimeUnit.SECONDS);
                return false;
            }
            if (process.exitValue() != 0) {
                return false;
            }

            // A successful launch is not sufficient: prove that the policy
            // actually denies a readable file beside the job directory.
            outside = root.resolve("probe-outside-" + java.util.UUID.randomUUID());
            Files.writeString(outside, "probe");
            Process deniedRead = new ProcessBuilder(isolatedCommand(
                    profile,
                    "/bin/sh",
                    List.of("-c", "cat " + shellQuote(outside) + " >/dev/null")
            ))
                    .directory(probe.toFile())
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .start();
            boolean deniedFinished = deniedRead.waitFor(5, java.util.concurrent.TimeUnit.SECONDS);
            if (!deniedFinished) {
                deniedRead.destroyForcibly();
                deniedRead.waitFor(1, java.util.concurrent.TimeUnit.SECONDS);
                return false;
            }
            return deniedRead.exitValue() != 0;
        } catch (IOException error) {
            return false;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return false;
        } catch (RuntimeException error) {
            return false;
        } finally {
            if (outside != null) {
                try {
                    Files.deleteIfExists(outside);
                } catch (IOException ignored) {
                    // The owned workspace sweep handles a failed probe cleanup.
                }
            }
            if (probe != null) {
                try (var paths = Files.walk(probe)) {
                    paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                        try {
                            Files.deleteIfExists(path);
                        } catch (IOException ignored) {
                            // A failed cleanup keeps readiness conservative;
                            // the owned workspace sweep handles it later.
                        }
                    });
                } catch (IOException ignored) {
                    // Leave the owned probe for the next workspace sweep.
                }
            }
        }
    }

    private static boolean executableAvailable(String configured) {
        if (configured == null || configured.isBlank()) {
            return false;
        }
        try {
            Path direct = Path.of(configured);
            if (configured.contains("/")) {
                return !Files.isSymbolicLink(direct)
                        && Files.isRegularFile(direct) && Files.isExecutable(direct);
            }
            String path = System.getenv().getOrDefault("PATH", "");
            for (String entry : path.split(java.io.File.pathSeparator)) {
                if (entry.isBlank()) {
                    continue;
                }
                Path candidate = Path.of(entry).resolve(configured);
                if (!Files.isSymbolicLink(candidate)
                        && Files.isRegularFile(candidate) && Files.isExecutable(candidate)) {
                    return true;
                }
            }
            return false;
        } catch (RuntimeException error) {
            return false;
        }
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static String shellQuote(Path path) {
        return "'" + path.toAbsolutePath().normalize().toString().replace("'", "'\\''") + "'";
    }

    private static int calculateMaxOslSocketDirectoryBytes() {
        String uid = currentUnixUid();
        String pipeName = "SingleOfficeIPC_" + "0".repeat(32);
        int suffixBytes = ("/OSL_PIPE_" + uid + "_" + pipeName)
                .getBytes(StandardCharsets.UTF_8)
                .length;
        return Math.max(1, MAX_OSL_SOCKET_NAME_BYTES - suffixBytes);
    }

    private static String currentUnixUid() {
        try {
            return Long.toUnsignedString(new UnixSystem().getUid());
        } catch (RuntimeException | LinkageError error) {
            // A host that cannot expose its UID gets the maximum decimal
            // width as a conservative fallback rather than an overlong path.
            return "9".repeat(Long.toString(Long.MAX_VALUE).length());
        }
    }
}
