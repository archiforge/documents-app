package com.docdeck.officeconversion.validation;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import java.io.IOException;
import java.io.InputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;
import org.xml.sax.ErrorHandler;
import org.xml.sax.SAXException;
import org.xml.sax.SAXParseException;

/** Bounded ZIP inspection used for OOXML and OpenDocument files. */
public final class ArchiveSafetyValidator {
    private static final int MAX_REQUIRED_XML_BYTES = 4 * 1024 * 1024;
    private ArchiveSafetyValidator() {
    }

    public static Set<String> inspect(Path file, OfficeConversionProperties properties) {
        return scan(file, properties, Set.of()).entries();
    }

    public static void requireOpenDocumentParts(Path file, String extension, OfficeConversionProperties properties) {
        String lower = extension.toLowerCase(Locale.ROOT);
        String expectedMain = switch (lower) {
            case "docx", "dotx" -> "word/document.xml";
            case "xlsx" -> "xl/workbook.xml";
            case "pptx", "ppsx" -> "ppt/presentation.xml";
            default -> null;
        };
        Set<String> requiredParts = new HashSet<>();
        if (Set.of("odt", "ods", "odp").contains(lower)) {
            requiredParts.add("mimetype");
            requiredParts.add("content.xml");
        } else {
            requiredParts.add("[Content_Types].xml");
            if (expectedMain != null) {
                requiredParts.add(expectedMain);
            }
        }
        ArchiveScan scan = scan(file, properties, requiredParts);
        Set<String> entries = scan.entries();
        if (Set.of("odt", "ods", "odp").contains(lower)) {
            require(entries, "mimetype");
            String expected = "application/vnd.oasis.opendocument." + switch (lower) {
                case "odt" -> "text";
                case "ods" -> "spreadsheet";
                default -> "presentation";
            };
            String mimetype = new String(scan.selectedParts().get("mimetype"), StandardCharsets.UTF_8);
            if (!expected.equals(mimetype)) {
                throw invalid("OpenDocument mimetype does not match its extension");
            }
            require(entries, "content.xml");
            validateXmlRoot(scan.selectedParts().get("content.xml"), "document-content");
            return;
        }

        require(entries, "[Content_Types].xml");
        if (expectedMain != null) {
            require(entries, expectedMain);
            validateXmlRoot(scan.selectedParts().get("[Content_Types].xml"), "Types");
            validateXmlRoot(scan.selectedParts().get(expectedMain), switch (lower) {
                case "docx", "dotx" -> "document";
                case "xlsx" -> "workbook";
                case "pptx", "ppsx" -> "presentation";
                default -> "";
            });
        }
    }

    private static ArchiveScan scan(
            Path file,
            OfficeConversionProperties properties,
            Set<String> selectedNames
    ) {
        Set<String> entries = new HashSet<>();
        Map<String, byte[]> selectedParts = new HashMap<>();
        long[] totalBytes = {0};
        try (InputStream input = Files.newInputStream(file); ZipInputStream zip = new ZipInputStream(input)) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                String name = entry.getName();
                validateEntryName(name, entry.isDirectory());
                if (!entries.add(name)) {
                    throw invalid("duplicate archive entry");
                }
                if (entries.size() > properties.getMaxZipEntries()) {
                    throw tooLarge("archive contains too many entries");
                }
                if (isActiveContent(name)) {
                    throw invalid("active or macro content is not supported");
                }
                if (entry.isDirectory()) {
                    drainEntry(zip, totalBytes, properties.getMaxUncompressedArchiveBytes());
                } else if (selectedNames.contains(name) || name.toLowerCase(Locale.ROOT).endsWith(".rels")) {
                    byte[] bytes = readEntryBounded(
                            zip,
                            MAX_REQUIRED_XML_BYTES,
                            totalBytes,
                            properties.getMaxUncompressedArchiveBytes()
                    );
                    if (name.toLowerCase(Locale.ROOT).endsWith(".rels")) {
                        validateExternalRelationships(bytes);
                    } else if (selectedNames.contains(name)) {
                        selectedParts.put(name, bytes);
                    }
                } else {
                    drainEntry(zip, totalBytes, properties.getMaxUncompressedArchiveBytes());
                }
            }
            if (entries.isEmpty()) {
                throw invalid("archive is empty");
            }
            return new ArchiveScan(Set.copyOf(entries), Map.copyOf(selectedParts));
        } catch (ConversionException error) {
            throw error;
        } catch (IOException | RuntimeException error) {
            throw invalid("archive is malformed");
        }
    }

    private static byte[] readEntryBounded(
            InputStream input,
            int maximumBytes,
            long[] totalBytes,
            long maximumArchiveBytes
    ) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(maximumBytes, 64 * 1024));
        byte[] buffer = new byte[16 * 1024];
        int read;
        while ((read = input.read(buffer)) != -1) {
            addToTotal(totalBytes, read, maximumArchiveBytes);
            if (output.size() > maximumBytes - read) {
                throw invalid("archive entry is too large");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    private static void drainEntry(InputStream input, long[] totalBytes, long maximumArchiveBytes) throws IOException {
        byte[] buffer = new byte[16 * 1024];
        int read;
        while ((read = input.read(buffer)) != -1) {
            addToTotal(totalBytes, read, maximumArchiveBytes);
        }
    }

    private static void addToTotal(long[] totalBytes, int read, long maximumArchiveBytes) {
        if (read < 0 || totalBytes[0] > maximumArchiveBytes - read) {
            throw tooLarge("archive expands beyond the configured limit");
        }
        totalBytes[0] += read;
    }

    private static void validateXmlRoot(byte[] bytes, String expectedRoot) {
        try {
            if (bytes.length == 0) {
                throw invalid("required XML part is empty");
            }
            var factory = secureFactory();
            var builder = factory.newDocumentBuilder();
            builder.setErrorHandler(THROWING_ERROR_HANDLER);
            var document = builder.parse(new ByteArrayInputStream(bytes));
            Element root = document.getDocumentElement();
            String localName = root.getLocalName();
            if (localName == null || localName.isBlank()) {
                localName = root.getNodeName();
                int separator = localName.lastIndexOf(':');
                if (separator >= 0) {
                    localName = localName.substring(separator + 1);
                }
            }
            if (!expectedRoot.equals(localName)) {
                throw invalid("required XML part has the wrong root");
            }
        } catch (ConversionException error) {
            throw error;
        } catch (Exception error) {
            throw invalid("required XML part is malformed");
        }
    }

    private static void validateExternalRelationships(byte[] bytes) {
        try {
            var builder = secureFactory().newDocumentBuilder();
            builder.setErrorHandler(THROWING_ERROR_HANDLER);
            var document = builder.parse(new ByteArrayInputStream(bytes));
            NodeList relationships = document.getElementsByTagNameNS("*", "Relationship");
            for (int index = 0; index < relationships.getLength(); index++) {
                Element relationship = (Element) relationships.item(index);
                if (!"external".equalsIgnoreCase(relationship.getAttribute("TargetMode"))) {
                    continue;
                }
                String type = relationship.getAttribute("Type").toLowerCase(Locale.ROOT);
                if (!type.endsWith("/hyperlink")) {
                    throw invalid("external object relationships are not supported");
                }
            }
        } catch (ConversionException error) {
            throw error;
        } catch (Exception error) {
            throw invalid("relationships part is malformed");
        }
    }

    private static DocumentBuilderFactory secureFactory() throws Exception {
        var factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        factory.setXIncludeAware(false);
        factory.setExpandEntityReferences(false);
        return factory;
    }

    private static final ErrorHandler THROWING_ERROR_HANDLER = new ErrorHandler() {
        @Override
        public void warning(SAXParseException exception) throws SAXException {
            throw exception;
        }

        @Override
        public void error(SAXParseException exception) throws SAXException {
            throw exception;
        }

        @Override
        public void fatalError(SAXParseException exception) throws SAXException {
            throw exception;
        }
    };

    private static void require(Set<String> entries, String required) {
        if (!entries.contains(required)) {
            throw invalid("archive is missing " + required);
        }
    }

    private static void validateEntryName(String name, boolean directory) {
        if (name == null || name.isBlank() || name.startsWith("/") || name.startsWith("\\")
                || name.contains("\\") || name.split("/", -1).length == 0) {
            throw invalid("archive contains an unsafe entry path");
        }
        String normalized = directory && name.endsWith("/")
                ? name.substring(0, name.length() - 1)
                : name;
        for (String component : normalized.split("/", -1)) {
            if (component.isBlank() || component.equals(".") || component.equals("..")) {
                throw invalid("archive contains a traversal entry path");
            }
        }
    }

    private record ArchiveScan(Set<String> entries, Map<String, byte[]> selectedParts) {
    }

    private static boolean isActiveContent(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        return lower.equals("vba/project.bin") || lower.endsWith("/vbaproject.bin")
                || lower.contains("/embeddings/") || lower.startsWith("embeddings/")
                || lower.contains("externallinks")
                || lower.endsWith(".exe") || lower.endsWith(".dll") || lower.endsWith(".com");
    }

    private static ConversionException invalid(String message) {
        return new ConversionException(ServiceErrorCode.INVALID_INPUT, 422, message);
    }

    private static ConversionException tooLarge(String message) {
        return new ConversionException(ServiceErrorCode.TOO_LARGE, 413, message);
    }
}
