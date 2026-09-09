package com.docdeck.officeconversion.validation;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionTarget;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class InputValidatorTest {
    @TempDir
    Path temporaryDirectory;

    @Test
    void rejectsPdfToOfficeAndSameFormatBeforeReading() throws IOException {
        Path file = Files.writeString(temporaryDirectory.resolve("input.pdf"), "%PDF-1.7");
        InputValidator validator = new InputValidator(new OfficeConversionProperties());

        assertThatThrownBy(() -> validator.validate(file, "pdf", ConversionTarget.DOCX))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("not supported");
        assertThatThrownBy(() -> validator.validate(file, "docx", ConversionTarget.DOCX))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("same format");
    }

    @Test
    void rejectsUnsafeZipEntryAndMacroContent() throws IOException {
        Path traversal = zip("bad.docx", new Entry("../outside", "x"), new Entry("[Content_Types].xml", "x"));
        Path macro = zip("bad-macro.docx", new Entry("[Content_Types].xml", "x"),
                new Entry("word/document.xml", "x"), new Entry("word/vbaProject.bin", "x"));
        InputValidator validator = new InputValidator(new OfficeConversionProperties());

        assertThatThrownBy(() -> validator.validate(traversal, "docx", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("traversal");
        assertThatThrownBy(() -> validator.validate(macro, "docx", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("active");
    }

    @Test
    void validatesOpenDocumentMimetypeAndRequiredParts() throws IOException {
        Path file = zip("source.odt",
                new Entry("mimetype", "application/vnd.oasis.opendocument.text"),
                new Entry("content.xml", "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"/>"));
        new InputValidator(new OfficeConversionProperties()).validate(file, "odt", ConversionTarget.PDF);
    }

    @Test
    void rejectsMalformedRequiredXmlAndExternalObjectRelationships() throws IOException {
        Path malformed = zip("malformed.docx",
                new Entry("[Content_Types].xml", "not xml"),
                new Entry("word/document.xml", "<w:document/>"));
        Path externalObject = zip("external.docx",
                new Entry("[Content_Types].xml", "<Types/>"),
                new Entry("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>"),
                new Entry("word/_rels/document.xml.rels", """
                        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                          <Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject"
                            Target="https://example.test/payload" TargetMode="External"/>
                        </Relationships>
                        """));
        InputValidator validator = new InputValidator(new OfficeConversionProperties());

        assertThatThrownBy(() -> validator.validate(malformed, "docx", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("XML");
        assertThatThrownBy(() -> validator.validate(externalObject, "docx", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("external object");
    }

    @Test
    void rejectsActiveHtmlButAllowsOrdinaryLinks() throws IOException {
        InputValidator validator = new InputValidator(new OfficeConversionProperties());
        Path link = Files.writeString(temporaryDirectory.resolve("link.html"),
                "<a href=\"https://example.test\">link</a>");
        Path document = Files.writeString(temporaryDirectory.resolve("document.html"),
                "<!doctype html><html><body><p>Documents</p></body></html>");
        Path script = Files.writeString(temporaryDirectory.resolve("script.html"),
                "<script>alert(1)</script>");
        Path remoteImage = Files.writeString(temporaryDirectory.resolve("image.html"),
                "<p><img src=\"https://example.test/image.png\"></p>");
        Path unsafeAnchor = Files.writeString(temporaryDirectory.resolve("unsafe-link.html"),
                "<a href=\"javascript:alert(1)\">link</a>");

        validator.validate(link, "html", ConversionTarget.DOCX);
        validator.validate(document, "html", ConversionTarget.DOCX);
        assertThatThrownBy(() -> validator.validate(script, "html", ConversionTarget.DOCX))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("active");
        assertThatThrownBy(() -> validator.validate(remoteImage, "html", ConversionTarget.DOCX))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("active");
        assertThatThrownBy(() -> validator.validate(unsafeAnchor, "html", ConversionTarget.DOCX))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("active");
    }

    @Test
    void acceptsBoundedUtf8CommaCsvAndRejectsFormulaCells() throws IOException {
        InputValidator validator = new InputValidator(new OfficeConversionProperties());
        Path valid = Files.writeString(temporaryDirectory.resolve("table.csv"),
                "name,value\n\"A, B\",-12.5\n");
        validator.validate(valid, "csv", ConversionTarget.PDF);

        Path formula = Files.writeString(temporaryDirectory.resolve("formula.csv"),
                "name,value\nAlice,=SUM(1,2)\n");
        assertThatThrownBy(() -> validator.validate(formula, "csv", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("formulas");
    }

    @Test
    void rejectsLegacyOleMacrosAndRtfActiveControls() throws IOException {
        Path macro = temporaryDirectory.resolve("macro.doc");
        try (POIFSFileSystem filesystem = new POIFSFileSystem()) {
            filesystem.getRoot().createDocument(
                    "WordDocument",
                    new java.io.ByteArrayInputStream(new byte[] {1, 2, 3})
            );
            filesystem.getRoot().createDirectory("Macros");
            try (var output = Files.newOutputStream(macro)) {
                filesystem.writeFilesystem(output);
            }
        }
        InputValidator validator = new InputValidator(new OfficeConversionProperties());
        assertThatThrownBy(() -> validator.validate(macro, "doc", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("macros");

        Path plainRtf = Files.writeString(temporaryDirectory.resolve("plain.rtf"),
                "{\\rtf1\\ansi Hello Documents}");
        validator.validate(plainRtf, "rtf", ConversionTarget.PDF);
        Path rtf = Files.writeString(temporaryDirectory.resolve("active.rtf"),
                "{\\rtf1\\ansi{\\field{\\*\\fldinst HYPERLINK \"https://example.test\"}}}");
        assertThatThrownBy(() -> validator.validate(rtf, "rtf", ConversionTarget.PDF))
                .isInstanceOf(ConversionException.class)
                .hasMessageContaining("active");
    }

    private Path zip(String filename, Entry... entries) throws IOException {
        Path file = temporaryDirectory.resolve(filename);
        try (ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(file))) {
            for (Entry entry : entries) {
                output.putNextEntry(new ZipEntry(entry.name()));
                output.write(entry.content().getBytes(StandardCharsets.UTF_8));
                output.closeEntry();
            }
        }
        return file;
    }

    private record Entry(String name, String content) {
    }
}
