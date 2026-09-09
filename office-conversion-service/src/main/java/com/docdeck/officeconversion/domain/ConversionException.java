package com.docdeck.officeconversion.domain;

public class ConversionException extends RuntimeException {
    private final ServiceErrorCode code;
    private final int status;

    public ConversionException(ServiceErrorCode code, int status, String message) {
        super(message);
        this.code = code;
        this.status = status;
    }

    public ConversionException(ServiceErrorCode code, int status, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
        this.status = status;
    }

    public ServiceErrorCode code() {
        return code;
    }

    public int status() {
        return status;
    }
}
