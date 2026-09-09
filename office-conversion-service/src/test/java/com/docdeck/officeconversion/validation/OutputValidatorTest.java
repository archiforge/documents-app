package com.docdeck.officeconversion.validation;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionTarget;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class OutputValidatorTest {
    @TempDir
    Path temporaryDirectory;

    @Test
    void requiresReadablePdfPageAndEof() throws Exception {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        OutputValidator validator = new OutputValidator(properties);
        Path valid = temporaryDirectory.resolve("result.pdf");
        try (PDDocument document = new PDDocument()) {
            document.addPage(new PDPage());
            document.save(valid.toFile());
        }
        validator.validate(valid, ConversionTarget.PDF);

        Path malformed = Files.writeString(temporaryDirectory.resolve("bad.pdf"), "%PDF-1.7\n%%EOF");
        assertThatThrownBy(() -> validator.validate(malformed, ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("readable PDF");
    }

    @Test
    void acceptsTheStableLibreOfficePdfFixture() throws Exception {
        Path fixture = Path.of(getClass().getResource("/fixtures/stable-lo-sample.pdf").toURI());
        new OutputValidator(new OfficeConversionProperties()).validate(fixture, ConversionTarget.PDF);
    }

    @Test
    void rejectsOversizedOutputBeforeFormatTrust() throws Exception {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setMaxOutputBytes(4);
        OutputValidator validator = new OutputValidator(properties);
        Path file = Files.write(temporaryDirectory.resolve("result.pdf"),
                "%PDF-1.7\n%%EOF".getBytes(StandardCharsets.UTF_8));

        assertThatThrownBy(() -> validator.validate(file, ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("exceeds");
    }
}
