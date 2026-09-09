package com.docdeck.officeconversion.service;

import static org.assertj.core.api.Assertions.assertThat;

import com.docdeck.officeconversion.config.OfficeConversionProperties;
import com.docdeck.officeconversion.domain.CapabilitiesResponse;
import com.docdeck.officeconversion.domain.ConversionTarget;
import com.docdeck.officeconversion.domain.SourceFamily;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class CapabilityServiceTest {
    @Test
    void matrixIncludesOpenDocumentFormatsAndDoesNotAdvertisePdfToOffice() {
        assertThat(SourceFamily.forExtension("odt")).isEqualTo(SourceFamily.WORD);
        assertThat(SourceFamily.forExtension("ods")).isEqualTo(SourceFamily.SPREADSHEET);
        assertThat(SourceFamily.forExtension("odp")).isEqualTo(SourceFamily.PRESENTATION);
        assertThat(SourceFamily.WORD.targets()).contains(ConversionTarget.PDF, ConversionTarget.DOCX);
        assertThat(SourceFamily.forExtension("pdf")).isNull();
    }

    @Test
    void targetParserDoesNotRemoveEmbeddedPunctuation() {
        assertThat(ConversionTarget.parse(".docx")).isEqualTo(ConversionTarget.DOCX);
        Assertions.assertThrows(IllegalArgumentException.class, () -> ConversionTarget.parse("d.ocx"));
    }

    @Test
    void capabilityResponsePublishesTheConfiguredLimits() {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        properties.setMaxInputBytes(123);
        properties.setMaxOutputBytes(456);
        properties.setMaxConcurrentJobs(2);
        CapabilitiesResponse response = new CapabilityService(
                properties,
                new IsolationService(properties)
        ).current();

        assertThat(response.limits().maxInputBytes()).isEqualTo(123);
        assertThat(response.limits().maxOutputBytes()).isEqualTo(456);
        assertThat(response.sources()).anyMatch(source -> source.extension().equals("odt"));
        assertThat(response.sources()).noneMatch(source -> source.extension().equals("pdf"));
    }

    @Test
    void capabilityResponseUsesExactSourceMediaTypes() {
        OfficeConversionProperties properties = new OfficeConversionProperties();
        CapabilitiesResponse response = new CapabilityService(
                properties,
                new IsolationService(properties)
        ).current();

        assertThat(response.sources()).filteredOn(source -> source.extension().equals("odt"))
                .singleElement()
                .extracting(CapabilitiesResponse.SourceCapability::mediaType)
                .isEqualTo("application/vnd.oasis.opendocument.text");
        assertThat(response.sources()).filteredOn(source -> source.extension().equals("dotx"))
                .singleElement()
                .extracting(CapabilitiesResponse.SourceCapability::mediaType)
                .isEqualTo("application/vnd.openxmlformats-officedocument.wordprocessingml.template");
        assertThat(response.sources()).filteredOn(source -> source.extension().equals("ppsx"))
                .singleElement()
                .extracting(CapabilitiesResponse.SourceCapability::mediaType)
                .isEqualTo("application/vnd.openxmlformats-officedocument.presentationml.slideshow");
    }
}
