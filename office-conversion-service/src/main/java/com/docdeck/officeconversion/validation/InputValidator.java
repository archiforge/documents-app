package com.docdeck.officeconversion.validation;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import com.docdeck.officeconversion.domain.SourceFamily;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.apache.poi.poifs.filesystem.DirectoryEntry;
import org.apache.poi.poifs.filesystem.DirectoryNode;
import org.apache.poi.poifs.filesystem.DocumentNode;
import org.apache.poi.poifs.filesystem.Entry;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.springframework.stereotype.Component;

@Component
public class InputValidator {
    private static final byte[] OLE_MAGIC = {(byte) 0xD0, (byte) 0xCF, 0x11, (byte) 0xE0,
            (byte) 0xA1, (byte) 0xB1, 0x1A, (byte) 0xE1};
    private static final int MAX_CSV_ROWS = 100_000;
    private static final int MAX_CSV_COLUMNS = 256;
    private static final int MAX_CSV_FIELD_CHARS = 1_000_000;
    private static final Pattern HTML_TAG = Pattern.compile(
            "<\\s*(/?)\\s*([A-Za-z][A-Za-z0-9:-]*)([^>]*)>",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL
    );
    private static final Pattern HTML_ATTRIBUTE = Pattern.compile(
            "([A-Za-z_:][A-Za-z0-9:._-]*)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))",
            Pattern.CASE_INSENSITIVE
    );
    private static final Pattern RTF_ACTIVE_CONTROL = Pattern.compile(
            "\\\\(?:object|objdata|objclass|objautlink|objupdate|link|field|fldinst|dde|ddedata|include[A-Za-z0-9]*)\\b",
            Pattern.CASE_INSENSITIVE
    );
    private static final Set<String> SAFE_HTML_TAGS = Set.of(
            "html", "head", "body", "title", "meta", "p", "br", "div", "span",
            "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote",
            "pre", "code", "b", "i", "strong", "em", "u", "s", "small", "sub", "sup",
            "table", "caption", "colgroup", "col", "thead", "tbody", "tfoot", "tr", "th",
            "td", "a", "hr"
    );
    private static final Set<String> SAFE_HTML_ATTRIBUTES = Set.of(
            "id", "class", "title", "lang", "dir", "role", "colspan", "rowspan", "scope"
    );
    private final OfficeConversionProperties properties;

    public InputValidator(OfficeConversionProperties properties) {
        this.properties = properties;
    }

    public SourceFamily validate(Path file, String sourceExtension, ConversionTarget target) {
        String extension = SourceFamily.normalize(sourceExtension);
        if (!extension.matches("[a-z0-9]{1,12}")) {
            throw invalid("source extension is invalid");
        }
        SourceFamily family = SourceFamily.forExtension(extension);
        if (family == null || !family.targets().contains(target)) {
            throw new ConversionException(ServiceErrorCode.UNSUPPORTED, 422,
                    "The source and target combination is not supported.");
        }
        if (extension.equals(target.extension())) {
            throw new ConversionException(ServiceErrorCode.UNSUPPORTED, 422,
                    "Converting a file to the same format is not supported.");
        }
        try {
            if (!Files.isRegularFile(file) || Files.isSymbolicLink(file)) {
                throw invalid("input file is not a regular file");
            }
            if (Files.size(file) == 0) {
                throw invalid("input file is empty");
            }
            validateSignature(file, extension);
            return family;
        } catch (ConversionException error) {
            throw error;
        } catch (IOException error) {
            throw invalid("input file could not be read");
        }
    }

    private void validateSignature(Path file, String extension) throws IOException {
        if (SetLike.ZIP_EXTENSIONS.contains(extension)) {
            ArchiveSafetyValidator.requireOpenDocumentParts(file, extension, properties);
            return;
        }
        if (SetLike.OLE_EXTENSIONS.contains(extension)) {
            byte[] header = readPrefix(file, OLE_MAGIC.length);
            if (!matches(header, OLE_MAGIC)) {
                throw invalid("legacy Office input has an invalid signature");
            }
            validateOle(file);
            return;
        }
        if (extension.equals("rtf")) {
            byte[] data = Files.readAllBytes(file);
            String prefix = new String(data, 0, Math.min(data.length, 32), StandardCharsets.US_ASCII);
            if (!prefix.startsWith("{\\rtf")) {
                throw invalid("RTF input has an invalid signature");
            }
            validateRtf(new String(data, StandardCharsets.ISO_8859_1));
            return;
        }
        byte[] data = Files.readAllBytes(file);
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(data)).toString();
        } catch (CharacterCodingException error) {
            throw invalid("text input is not valid UTF-8");
        }
        if (extension.equals("csv")) {
            validateCsv(text);
            return;
        }
        if (extension.equals("html") || extension.equals("htm") || extension.equals("xhtml")) {
            validateHtml(text);
        }
    }

    private static void validateOle(Path file) throws IOException {
        long totalStreamBytes = 0;
        int[] entryCount = {0};
        try (POIFSFileSystem filesystem = new POIFSFileSystem(file.toFile(), true)) {
            if (filesystem.getRoot() == null) {
                throw invalid("legacy Office input has no compound root");
            }
            totalStreamBytes = inspectOleDirectory(filesystem.getRoot(), 0, entryCount, totalStreamBytes);
        } catch (ConversionException error) {
            throw error;
        } catch (IOException | RuntimeException error) {
            throw invalid("legacy Office input is not a readable compound file");
        }
    }

    private static long inspectOleDirectory(
            DirectoryNode directory,
            int depth,
            int[] entryCount,
            long totalStreamBytes
    ) throws IOException {
        if (depth > 64) {
            throw invalid("legacy Office compound nesting is too deep");
        }
        var entries = directory.getEntries();
        while (entries.hasNext()) {
            Entry entry = entries.next();
            entryCount[0]++;
            if (entryCount[0] > 10_000) {
                throw invalid("legacy Office compound file contains too many streams");
            }
            String name = entry.getName().toLowerCase(Locale.ROOT);
            if (isUnsafeOleEntry(name)) {
                throw invalid("legacy Office input contains macros or embedded content");
            }
            if (entry instanceof DirectoryEntry child) {
                totalStreamBytes = inspectOleDirectory((DirectoryNode) child, depth + 1, entryCount, totalStreamBytes);
            } else if (entry instanceof DocumentNode document) {
                long size = document.getSize();
                if (size < 0 || size > 100L * 1024L * 1024L
                        || totalStreamBytes > 100L * 1024L * 1024L - size) {
                    throw invalid("legacy Office compound streams exceed the configured bound");
                }
                totalStreamBytes += size;
            }
        }
        return totalStreamBytes;
    }

    private static boolean isUnsafeOleEntry(String name) {
        return name.contains("vba") || name.contains("macro") || name.contains("objectpool")
                || name.contains("embedding") || name.contains("ole10native")
                || name.contains("linkinfo") || name.equals("package")
                || name.contains("encryptedpackage") || name.contains("encryptioninfo")
                || name.contains("dataspaces");
    }

    private static void validateRtf(String rtf) {
        if (RTF_ACTIVE_CONTROL.matcher(rtf).find()
                || rtf.toLowerCase(Locale.ROOT).contains("http://")
                || rtf.toLowerCase(Locale.ROOT).contains("https://")
                || rtf.toLowerCase(Locale.ROOT).contains("file://")) {
            throw invalid("RTF contains embedded or external active content");
        }
        int depth = 0;
        int maximumDepth = 0;
        for (int index = 0; index < rtf.length(); index++) {
            char character = rtf.charAt(index);
            if (character == '\\' && index + 1 < rtf.length()) {
                index++;
                continue;
            }
            if (character == '{') {
                depth++;
                maximumDepth = Math.max(maximumDepth, depth);
                if (maximumDepth > 1_000) {
                    throw invalid("RTF nesting is too deep");
                }
            } else if (character == '}' && --depth < 0) {
                throw invalid("RTF braces are unbalanced");
            }
        }
        if (depth != 0) {
            throw invalid("RTF braces are unbalanced");
        }
    }

    private static void validateHtml(String html) {
        String normalized = html.replaceAll("(?is)<!doctype\\s+html\\s*>", "");
        String lower = normalized.toLowerCase(Locale.ROOT);
        if (lower.contains("<!doctype") || lower.contains("<?xml") || lower.contains("url(")
                || lower.contains("javascript:") || lower.contains("vbscript:")
                || lower.contains("data:") || lower.contains("file://")) {
            throw invalid("HTML contains active or local resource content");
        }
        Matcher tags = HTML_TAG.matcher(normalized);
        int end = 0;
        while (tags.find()) {
            if (normalized.substring(end, tags.start()).indexOf('<') >= 0) {
                throw invalid("HTML contains malformed markup");
            }
            String tag = tags.group(2).toLowerCase(Locale.ROOT);
            if (!SAFE_HTML_TAGS.contains(tag)) {
                throw invalid("HTML contains an active or unsupported element");
            }
            String attributes = tags.group(3).trim();
            if (attributes.endsWith("/")) {
                attributes = attributes.substring(0, attributes.length() - 1).trim();
            }
            Matcher values = HTML_ATTRIBUTE.matcher(attributes);
            int attributeEnd = 0;
            while (values.find()) {
                String name = values.group(1).toLowerCase(Locale.ROOT);
                String value = firstNonNull(values.group(2), values.group(3), values.group(4));
                if (!SAFE_HTML_ATTRIBUTES.contains(name) && !(tag.equals("a") && name.equals("href"))) {
                    throw invalid("HTML contains an active or unsupported attribute");
                }
                if (tag.equals("a") && name.equals("href") && !safeAnchor(value)) {
                    throw invalid("HTML contains an unsafe link");
                }
                attributeEnd = values.end();
            }
            if (!attributes.substring(attributeEnd).trim().isEmpty()) {
                throw invalid("HTML contains a malformed attribute");
            }
            end = tags.end();
        }
        // A dangerous or malformed tag without a closing `>` must not pass
        // through to the converter as inert text by accident.
        if (normalized.substring(end).contains("<") || lower.substring(end).contains("<script")
                || lower.substring(end).contains("<img") || lower.substring(end).contains("<iframe")
                || lower.substring(end).contains("<object") || lower.substring(end).contains("<embed")
                || lower.substring(end).contains("<svg")) {
            throw invalid("HTML contains an active or unsupported element");
        }
    }

    private static String firstNonNull(String... values) {
        for (String value : values) {
            if (value != null) {
                return value;
            }
        }
        return "";
    }

    private static boolean safeAnchor(String value) {
        String trimmed = value.trim();
        if (trimmed.startsWith("#")) {
            return true;
        }
        try {
            java.net.URI uri = java.net.URI.create(trimmed);
            String scheme = uri.getScheme();
            if (scheme == null) {
                return !trimmed.startsWith("//") && !trimmed.contains("\\");
            }
            return (scheme.equalsIgnoreCase("https") || scheme.equalsIgnoreCase("http"))
                    && uri.getHost() != null && uri.getUserInfo() == null;
        } catch (IllegalArgumentException error) {
            return false;
        }
    }

    /**
     * Supports RFC 4180-style UTF-8 CSV only: comma field separator, double
     * quote text delimiter, CRLF/LF rows, and no formula evaluation. Bounds
     * apply before LibreOffice sees the file, and formula-looking cells are
     * rejected rather than relying on an importer option alone.
     */
    private static void validateCsv(String input) {
        int index = input.startsWith("\uFEFF") ? 1 : 0;
        int rows = 0;
        int columns = 0;
        StringBuilder field = new StringBuilder();
        boolean quoted = false;
        boolean quotedFieldClosed = false;
        boolean atFieldStart = true;
        while (index < input.length()) {
            char character = input.charAt(index++);
            if (quoted) {
                if (character == '"') {
                    if (index < input.length() && input.charAt(index) == '"') {
                        field.append('"');
                        index++;
                    } else {
                        quoted = false;
                        quotedFieldClosed = true;
                        atFieldStart = false;
                    }
                } else {
                    appendCsvCharacter(field, character);
                }
                continue;
            }
            if (quotedFieldClosed && character != ',' && character != '\r' && character != '\n') {
                throw invalid("CSV contains data after a closing quote");
            }
            if (character == '"') {
                if (!atFieldStart) {
                    throw invalid("CSV contains an unescaped quote");
                }
                quoted = true;
                atFieldStart = false;
            } else if (character == ',') {
                validateCsvField(field);
                columns++;
                if (columns > MAX_CSV_COLUMNS) {
                    throw invalid("CSV contains too many columns");
                }
                field.setLength(0);
                quotedFieldClosed = false;
                atFieldStart = true;
            } else if (character == '\r' || character == '\n') {
                if (character == '\r' && index < input.length() && input.charAt(index) == '\n') {
                    index++;
                }
                validateCsvField(field);
                columns++;
                if (columns > MAX_CSV_COLUMNS) {
                    throw invalid("CSV contains too many columns");
                }
                rows++;
                if (rows > MAX_CSV_ROWS) {
                    throw invalid("CSV contains too many rows");
                }
                columns = 0;
                field.setLength(0);
                quotedFieldClosed = false;
                atFieldStart = true;
            } else {
                if (character == '\0') {
                    throw invalid("CSV contains a NUL character");
                }
                appendCsvCharacter(field, character);
                atFieldStart = false;
            }
        }
        if (quoted) {
            throw invalid("CSV contains an unterminated quoted field");
        }
        if (!atFieldStart || field.length() > 0 || columns > 0) {
            validateCsvField(field);
            columns++;
            if (columns > MAX_CSV_COLUMNS) {
                throw invalid("CSV contains too many columns");
            }
            rows++;
            if (rows > MAX_CSV_ROWS) {
                throw invalid("CSV contains too many rows");
            }
        }
    }

    private static void appendCsvCharacter(StringBuilder field, char character) {
        field.append(character);
        if (field.length() > MAX_CSV_FIELD_CHARS) {
            throw invalid("CSV contains an oversized field");
        }
    }

    private static void validateCsvField(StringBuilder field) {
        String value = field.toString().stripLeading();
        if (value.startsWith("=") || value.startsWith("@")
                || (value.startsWith("+") && !value.matches("\\+?\\d+(?:\\.\\d+)?"))
                || (value.startsWith("-") && !value.matches("-?\\d+(?:\\.\\d+)?"))) {
            throw invalid("CSV formulas are not supported");
        }
    }

    private static byte[] readPrefix(Path file, int length) throws IOException {
        try (InputStream input = Files.newInputStream(file)) {
            return input.readNBytes(length);
        }
    }

    private static boolean matches(byte[] actual, byte[] expected) {
        if (actual.length < expected.length) {
            return false;
        }
        for (int index = 0; index < expected.length; index++) {
            if (actual[index] != expected[index]) {
                return false;
            }
        }
        return true;
    }

    private static ConversionException invalid(String message) {
        return new ConversionException(ServiceErrorCode.INVALID_INPUT, 422, message);
    }

    private static final class SetLike {
        private static final java.util.Set<String> ZIP_EXTENSIONS = java.util.Set.of(
                "docx", "dotx", "xlsx", "pptx", "ppsx", "odt", "ods", "odp"
        );
        private static final java.util.Set<String> OLE_EXTENSIONS = java.util.Set.of(
                "doc", "dot", "xls", "ppt", "pps"
        );
    }
}
