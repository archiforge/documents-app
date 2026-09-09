package com.docdeck.officeconversion.api;

import com.docdeck.officeconversion.domain.CapabilitiesResponse;
import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ConversionResult;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import com.docdeck.officeconversion.service.CapabilityService;
import com.docdeck.officeconversion.service.JobCancellationRegistry;
import com.docdeck.officeconversion.service.LibreOfficeConversionService;
import java.util.UUID;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RequestPart;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/v1")
public class ConversionController {
    private final CapabilityService capabilityService;
    private final LibreOfficeConversionService conversionService;
    private final JobCancellationRegistry cancellationRegistry;
    private final String configuredToken;

    public ConversionController(
            CapabilityService capabilityService,
            LibreOfficeConversionService conversionService,
            com.docdeck.officeconversion.config.OfficeConversionProperties properties,
            JobCancellationRegistry cancellationRegistry
    ) {
        this.capabilityService = capabilityService;
        this.conversionService = conversionService;
        this.cancellationRegistry = cancellationRegistry;
        this.configuredToken = properties.getAuthToken() == null ? "" : properties.getAuthToken().trim();
    }

    @GetMapping("/capabilities")
    public CapabilitiesResponse capabilities(@RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization) {
        requireAuthorization(authorization);
        return capabilityService.current();
    }

    @PostMapping(value = "/conversions", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<byte[]> convert(
            @RequestPart("file") MultipartFile file,
            @RequestParam("sourceExtension") String sourceExtension,
            @RequestParam("target") String target,
            @RequestHeader(value = "X-Conversion-Request-Id", required = false) String requestId,
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization
    ) {
        requireAuthorization(authorization);
        if (file == null || file.isEmpty()) {
            throw new ConversionException(ServiceErrorCode.INVALID_INPUT, 422, "The input file is empty.");
        }
        ConversionTarget conversionTarget = ConversionTarget.parse(target);
        String operationId = normalizeRequestId(requestId);
        ConversionResult result;
        try {
            result = conversionService.convert(
                    file.getInputStream(),
                    file.getOriginalFilename(),
                    sourceExtension,
                    conversionTarget,
                    operationId
            );
        } catch (java.io.IOException error) {
            throw new ConversionException(ServiceErrorCode.INVALID_INPUT, 422, "The input file could not be read.", error);
        }
        return ResponseEntity.ok()
                .header("X-Request-Id", operationId)
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + result.suggestedName() + "\"")
                .contentType(MediaType.parseMediaType(result.target().mediaType()))
                .contentLength(result.bytes().length)
                .body(result.bytes());
    }

    @DeleteMapping("/conversions/{requestId}")
    public ResponseEntity<Void> cancel(
            @PathVariable String requestId,
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization
    ) {
        requireAuthorization(authorization);
        cancellationRegistry.cancel(normalizeRequestId(requestId));
        return ResponseEntity.accepted().build();
    }

    private static String normalizeRequestId(String requestId) {
        if (requestId == null || requestId.isBlank()) {
            return UUID.randomUUID().toString();
        }
        String trimmed = requestId.trim();
        if (!trimmed.matches("[A-Za-z0-9._:-]{1,128}")) {
            throw new ConversionException(ServiceErrorCode.INVALID_REQUEST, 400,
                    "The conversion request ID is invalid.");
        }
        return trimmed;
    }

    private void requireAuthorization(String authorization) {
        if (configuredToken.isBlank()) {
            return;
        }
        String expected = "Bearer " + configuredToken;
        if (authorization == null || !java.security.MessageDigest.isEqual(
                expected.getBytes(java.nio.charset.StandardCharsets.UTF_8),
                authorization.getBytes(java.nio.charset.StandardCharsets.UTF_8))) {
            throw new ConversionException(ServiceErrorCode.AUTHENTICATION, 401,
                    "The conversion service token is invalid.");
        }
    }
}
