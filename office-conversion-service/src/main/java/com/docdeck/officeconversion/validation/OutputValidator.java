package com.docdeck.officeconversion.validation;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.springframework.stereotype.Component;

@Component
public class OutputValidator {
    private final OfficeConversionProperties properties;

    public OutputValidator(OfficeConversionProperties properties) {
        this.properties = properties;
    }

    public void validate(Path output, ConversionTarget target) {
        try {
            if (!Files.isRegularFile(output) || Files.isSymbolicLink(output)) {
                throw malformed("conversion output is not a regular file");
            }
            long size = Files.size(output);
            if (size == 0) {
                throw malformed("conversion output is empty");
            }
            if (size > properties.getMaxOutputBytes()) {
                throw new ConversionException(ServiceErrorCode.TOO_LARGE, 502,
                        "conversion output exceeds the configured limit");
            }
            if (target == ConversionTarget.PDF) {
                validatePDF(output);
            } else {
                ArchiveSafetyValidator.requireOpenDocumentParts(output, target.extension(), properties);
            }
        } catch (ConversionException error) {
            throw error;
        } catch (IOException error) {
            throw malformed("conversion output could not be read");
        }
    }

    private static void validatePDF(Path output) throws IOException {
        try (var input = Files.newInputStream(output)) {
            byte[] header = input.readNBytes(5);
            if (header.length < 5 || !new String(header, StandardCharsets.ISO_8859_1).equals("%PDF-")) {
                throw malformed("conversion output is not a readable PDF");
            }
        }
        try (var document = org.apache.pdfbox.Loader.loadPDF(output.toFile())) {
            int pageCount = document.getNumberOfPages();
            if (document.isEncrypted() || pageCount < 1 || pageCount > 10_000) {
                throw malformed("conversion output is not a readable PDF");
            }
        } catch (ConversionException error) {
            throw error;
        } catch (IOException | RuntimeException error) {
            throw malformed("conversion output is not a readable PDF");
        }
    }

    private static ConversionException malformed(String message) {
        return new ConversionException(ServiceErrorCode.MALFORMED_OUTPUT, 502, message);
    }
}
