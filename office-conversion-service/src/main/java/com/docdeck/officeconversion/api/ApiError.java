package com.docdeck.officeconversion.api;

public record ApiError(String type, String title, String code, String detail, String requestId) {
}
