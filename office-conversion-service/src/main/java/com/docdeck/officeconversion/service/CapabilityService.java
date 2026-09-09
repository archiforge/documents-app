package com.docdeck.officeconversion.service;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.CapabilitiesResponse;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.SourceFamily;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;

@Service
public class CapabilityService {
    private final OfficeConversionProperties properties;
    private final IsolationService isolationService;

    public CapabilityService(OfficeConversionProperties properties, IsolationService isolationService) {
        this.properties = properties;
        this.isolationService = isolationService;
    }

    public CapabilitiesResponse current() {
        List<CapabilitiesResponse.SourceCapability> sources = new ArrayList<>();
        Arrays.stream(SourceFamily.values())
                .sorted(Comparator.comparing(Enum::name))
                .forEach(family -> family.extensions().stream().sorted().forEach(extension ->
                        sources.add(new CapabilitiesResponse.SourceCapability(
                                extension,
                                family.targets().stream().map(ConversionTarget::extension).sorted().toList(),
                                mediaTypeFor(extension),
                                signatureFor(extension)
                        ))));

        Map<String, String> targetMediaTypes = new java.util.TreeMap<>();
        for (ConversionTarget target : ConversionTarget.values()) {
            targetMediaTypes.put(target.extension(), target.mediaType());
        }
        return new CapabilitiesResponse(
                "1",
                "documents-office-conversion-0.1",
                isolationService.isReady(),
                List.copyOf(sources),
                Map.copyOf(targetMediaTypes),
                new CapabilitiesResponse.Limits(
                        properties.getMaxInputBytes(),
                        properties.getMaxOutputBytes(),
                        properties.getTimeout().toSeconds(),
                        properties.getMaxConcurrentJobs()
                )
        );
    }

    private static String mediaTypeFor(String extension) {
        return switch (extension) {
            case "doc", "dot" -> "application/msword";
            case "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
            case "dotx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.template";
            case "odt" -> "application/vnd.oasis.opendocument.text";
            case "rtf" -> "application/rtf";
            case "xls" -> "application/vnd.ms-excel";
            case "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            case "ods" -> "application/vnd.oasis.opendocument.spreadsheet";
            case "csv" -> "text/csv";
            case "ppt", "pps" -> "application/vnd.ms-powerpoint";
            case "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation";
            case "ppsx" -> "application/vnd.openxmlformats-officedocument.presentationml.slideshow";
            case "odp" -> "application/vnd.oasis.opendocument.presentation";
            case "html", "htm", "xhtml" -> "text/html";
            default -> "text/plain";
        };
    }

    private static String signatureFor(String extension) {
        return switch (extension) {
            case "doc", "dot", "xls", "ppt", "pps" -> "ole2";
            case "rtf" -> "rtf-prefix";
            case "csv", "txt", "log", "text", "md", "markdown", "mdown", "html", "htm", "xhtml" -> "bounded-text";
            case "odt", "ods", "odp" -> "zip-mimetype";
            default -> "zip-content-types";
        };
    }
}
