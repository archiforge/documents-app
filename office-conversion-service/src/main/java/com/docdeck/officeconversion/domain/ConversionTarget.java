package com.docdeck.officeconversion.domain;

import java.util.Locale;

public enum ConversionTarget {
    PDF("pdf", "application/pdf"),
    DOCX("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    XLSX("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
    PPTX("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation");

    private final String extension;
    private final String mediaType;

    ConversionTarget(String extension, String mediaType) {
        this.extension = extension;
        this.mediaType = mediaType;
    }

    public String extension() {
        return extension;
    }

    public String mediaType() {
        return mediaType;
    }

    public static ConversionTarget parse(String raw) {
        if (raw == null || raw.isBlank()) {
            throw new IllegalArgumentException("target is required");
        }
        String normalized = raw.trim().toLowerCase(Locale.ROOT);
        if (normalized.startsWith(".")) {
            normalized = normalized.substring(1);
        }
        return switch (normalized) {
            case "pdf" -> PDF;
            case "docx", "word" -> DOCX;
            case "xlsx", "excel" -> XLSX;
            case "pptx", "ppt", "powerpoint" -> PPTX;
            default -> throw new IllegalArgumentException("unsupported target");
        };
    }
}
