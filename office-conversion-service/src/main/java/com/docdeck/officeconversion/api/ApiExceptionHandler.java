package com.docdeck.officeconversion.api;

import com.docdeck.officeconversion.domain.ConversionException;
import com.docdeck.officeconversion.domain.ServiceErrorCode;
import java.util.UUID;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.multipart.MaxUploadSizeExceededException;

@RestControllerAdvice
public class ApiExceptionHandler {
    @ExceptionHandler(ConversionException.class)
    public ResponseEntity<ApiError> conversion(ConversionException error) {
        return response(error.status(), error.code(), error.getMessage());
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<ApiError> tooLarge(MaxUploadSizeExceededException error) {
        return response(413, ServiceErrorCode.TOO_LARGE, "The input exceeds the configured limit.");
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<ApiError> invalidArgument(IllegalArgumentException error) {
        return response(400, ServiceErrorCode.INVALID_REQUEST, error.getMessage());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> unexpected(Exception error) {
        return response(500, ServiceErrorCode.CONVERSION_FAILED, "The conversion service failed unexpectedly.");
    }

    private static ResponseEntity<ApiError> response(int status, ServiceErrorCode code, String detail) {
        String requestId = UUID.randomUUID().toString();
        ApiError body = new ApiError(
                "https://documents.example/problems/" + code.name().toLowerCase(),
                code.name().replace('_', ' '),
                code.name().toLowerCase(),
                detail == null || detail.isBlank() ? code.name() : detail,
                requestId
        );
        return ResponseEntity.status(status)
                .contentType(MediaType.valueOf("application/problem+json"))
                .header("X-Request-Id", requestId)
                .body(body);
    }
}
