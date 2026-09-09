package com.docdeck.officeconversion.domain;

import java.util.List;
import java.util.Map;

public record CapabilitiesResponse(
        String schemaVersion,
        String serviceBuild,
        boolean ready,
        List<SourceCapability> sources,
        Map<String, String> targetMediaTypes,
        Limits limits
) {
    public record SourceCapability(String extension, List<String> targets, String mediaType, String signature) {
    }

    public record Limits(long maxInputBytes, long maxOutputBytes, long timeoutSeconds, int maxConcurrentJobs) {
    }
}
