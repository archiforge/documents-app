import Foundation

/// Runtime readiness exposed by a tool tile. Deferred tools remain visible so
/// users can see the product surface, while the current product boundary is
/// explicit instead of being hidden behind a generic phase placeholder.
enum ToolCapability: Equatable, Hashable, Sendable {
    case available
    case unavailable(ToolCapabilityReason)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var statusLabel: String {
        isAvailable ? "Available" : "Unavailable"
    }

    var reason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason.message
    }

    var reasonTitle: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason.title
    }

    static func ai(_ tool: AIToolKind) -> ToolCapability {
        switch tool {
        case .summary:
            switch AIService.live.availability(for: .summary) {
            case .available:
                .available
            case .unavailable(let reason):
                .unavailable(reason.toolCapabilityReason)
            }
        case .translation, .smartExtraction, .chart, .formula:
            // Translation checks the selected language pair in its flow. The
            // Vision-assisted tools run locally on every supported iOS 26
            // device, then expose review/input errors inside the flow.
            .available
        }
    }
}

enum ToolCapabilityReason: String, Equatable, Hashable, Sendable {
    case officeConversionUnavailable
    case extractionUnavailable
    case summaryUnavailable
    case translationUnavailable
    case modelDeviceNotEligible
    case modelDisabled
    case modelPreparing

    var title: String {
        switch self {
        case .officeConversionUnavailable:
            "Office conversion unavailable"
        case .extractionUnavailable:
            "Extraction unavailable"
        case .summaryUnavailable:
            "Summary unavailable"
        case .translationUnavailable:
            "Translation unavailable"
        case .modelDeviceNotEligible:
            "On-device model unavailable"
        case .modelDisabled:
            "On-device model is turned off"
        case .modelPreparing:
            "On-device model is preparing"
        }
    }

    var message: String {
        switch self {
        case .officeConversionUnavailable:
            "Office conversion is not available yet."
        case .extractionUnavailable:
            "Extraction is not available yet."
        case .summaryUnavailable:
            "Document summary is not available yet."
        case .translationUnavailable:
            "Document translation is not available yet."
        case .modelDeviceNotEligible:
            "This device does not support the on-device language model."
        case .modelDisabled:
            "Turn on Apple Intelligence in Settings to use summaries."
        case .modelPreparing:
            "The on-device language model is preparing. Try again shortly."
        }
    }
}

private extension AIUnavailableReason {
    var toolCapabilityReason: ToolCapabilityReason {
        switch self {
        case .deviceNotEligible:
            .modelDeviceNotEligible
        case .appleIntelligenceDisabled:
            .modelDisabled
        case .modelPreparing:
            .modelPreparing
        default:
            .summaryUnavailable
        }
    }
}
