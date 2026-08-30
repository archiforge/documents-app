import Foundation
import ImageIO
import UIKit
import Vision

enum TextRecognitionError: LocalizedError, Equatable {
    case notReadable
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .notReadable: "The image could not be decoded."
        case .recognitionFailed: "Text recognition failed."
        }
    }
}

/// On-device OCR on top of Vision's `VNRecognizeTextRequest`.
///
/// The entry point takes raw image bytes (`Data` is `Sendable`) so the work
/// can hop off the main actor cleanly; decoding happens inside via ImageIO.
enum TextRecognition {
    /// Recognizes every line of text in the image, joined with newlines,
    /// top-to-bottom.
    static func recognizeText(in imageData: Data) async throws -> String {
        guard
            let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TextRecognitionError.notReadable }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TextRecognitionError.recognitionFailed
        }
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
