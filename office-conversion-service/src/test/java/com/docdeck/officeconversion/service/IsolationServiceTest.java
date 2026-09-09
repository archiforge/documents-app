package com.docdeck.officeconversion.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import java.time.Duration;
import java.util.List;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class IsolationServiceTest {
    @TempDir
    Path temporaryDirectory;

    @Test
    void refusesToAdvertiseReadyWhenSandboxOrResourceLauncherIsMissing() {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setLibreOfficeExecutable("missing-libreoffice");
        properties.setRuntimeReadRoot(temporaryDirectory.toString());
        properties.setSandboxProfileTemplate(temporaryDirectory.resolve("profile.sb").toString());
        assertThat(new IsolationService(properties).isReady()).isFalse();
    }

    @Test
    void profileTemplateRequiresAConfiguredRuntimeRoot() throws Exception {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setSandboxProfileTemplate(Files.writeString(
                temporaryDirectory.resolve("profile.sb"),
                "(allow file-read* (subpath \"${LIBREOFFICE_ROOT}\"))\n"
        ).toString());
        properties.setRuntimeReadRoot(temporaryDirectory.toString());
        assertThat(new IsolationService(properties).isReady()).isFalse();
    }

    @Test
    void commandCarriesIndependentCpuAndMemoryBounds() {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setTimeout(Duration.ofSeconds(90));
        properties.setMaxProcessMemoryBytes(768L * 1024L * 1024L);
        List<String> command = new IsolationService(properties).command(
                temporaryDirectory.resolve("profile.sb"),
                List.of("/usr/bin/true")
        );

        assertThat(command).containsSubsequence(
                "--cpu-seconds", "90",
                "--memory-bytes", Long.toString(768L * 1024L * 1024L),
                "--sandbox-executable"
        );
    }

    @Test
    void generatedLibreOfficeProfileDisablesMacrosAndLinkUpdates() throws Exception {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        Path profile = new IsolationService(properties).createLibreOfficeProfile(temporaryDirectory);

        String settings = Files.readString(profile.resolve("registrymodifications.xcu"));
        assertThat(settings).contains("MacroSecurityLevel").contains("UpdateDocMode");
    }

    @Test
    void generatedSandboxScopesWritesAndDeniesNetwork() throws Exception {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setSandboxProfileTemplate(Files.writeString(
                temporaryDirectory.resolve("profile.sb"),
                """
                (version 1)
                (deny default)
                (allow file-read* (subpath "${JOB_DIR}"))
                (allow file-write* (subpath "${JOB_DIR}"))
                (deny network*)
                """
        ).toString());
        Path profile = new IsolationService(properties).writeSandboxProfile(temporaryDirectory);
        String generated = Files.readString(profile);

        assertThat(generated).contains("(allow file-write* (subpath \"" + temporaryDirectory + "\"))");
        assertThat(generated).contains("(deny network*)");
        assertThat(generated).doesNotContain("workspace-root");
    }

    @Test
    void enforcesLibreOfficeSocketDirectoryBudget() {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        IsolationService service = new IsolationService(properties);
        int budget = IsolationService.maxOslSocketDirectoryBytes();
        assertThat(budget).isGreaterThan("/tmp/".getBytes(java.nio.charset.StandardCharsets.UTF_8).length);
        Path maximumPath = Path.of("/tmp/" + "x".repeat(budget - "/tmp/".length()));
        assertThat(maximumPath.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length)
                .isEqualTo(budget);
        org.assertj.core.api.Assertions.assertThatCode(() -> service.validateSocketDirectory(maximumPath))
                .doesNotThrowAnyException();

        Path longPath = Path.of(maximumPath + "x");

        assertThatThrownBy(() -> service.validateSocketDirectory(longPath))
                .isInstanceOf(com.docdeck.officeconversion.domain.ConversionException.class)
                .hasMessageContaining("path is too long");
    }
}
