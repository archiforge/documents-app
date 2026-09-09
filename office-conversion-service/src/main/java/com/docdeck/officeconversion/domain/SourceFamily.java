package com.docdeck.officeconversion.domain;

import java.util.Locale;
import java.util.Set;

public enum SourceFamily {
    WORD(Set.of("doc", "docx", "dot", "dotx", "rtf", "odt"), ConversionTarget.PDF, ConversionTarget.DOCX),
    SPREADSHEET(Set.of("xls", "xlsx", "csv", "ods"), ConversionTarget.PDF, ConversionTarget.XLSX),
    PRESENTATION(Set.of("ppt", "pptx", "pps", "ppsx", "odp"), ConversionTarget.PDF, ConversionTarget.PPTX),
    TEXT(Set.of("txt", "log", "text", "md", "markdown", "mdown", "html", "htm", "xhtml"), ConversionTarget.DOCX);

    private final Set<String> extensions;
    private final Set<ConversionTarget> targets;

    SourceFamily(Set<String> extensions, ConversionTarget... targets) {
        this.extensions = extensions;
        this.targets = Set.of(targets);
    }

    public Set<String> extensions() {
        return extensions;
    }

    public Set<ConversionTarget> targets() {
        return targets;
    }

    public static SourceFamily forExtension(String extension) {
        String normalized = normalize(extension);
        for (SourceFamily family : values()) {
            if (family.extensions.contains(normalized)) {
                return family;
            }
        }
        return null;
    }

    public static String normalize(String extension) {
        if (extension == null) {
            return "";
        }
        String normalized = extension.trim().toLowerCase(Locale.ROOT);
        return normalized.startsWith(".") ? normalized.substring(1) : normalized;
    }
}
