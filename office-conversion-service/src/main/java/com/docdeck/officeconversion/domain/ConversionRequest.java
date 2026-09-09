package com.docdeck.officeconversion.domain;

import java.nio.file.Path;

public record ConversionRequest(Path input, String sourceExtension, ConversionTarget target) {
}
