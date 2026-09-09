package com.docdeck.officeconversion.domain;

public record ConversionResult(byte[] bytes, ConversionTarget target, String suggestedName) {
}
