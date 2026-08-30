import XCTest
@testable import DocDeck

final class TextRecognitionTests: XCTestCase {
    /// Renders known text into an image and asserts Vision's OCR reads it
    /// back. Runs on the simulator — Vision supports text recognition there.
    func testRecognizesRenderedText() async throws {
        let image = TestPDF.textImage("DocDeck OCR")
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))

        let text = try await TextRecognition.recognizeText(in: jpeg)

        XCTAssertTrue(
            text.uppercased().contains("DOCDECK"),
            "Expected recognized text to contain the rendered word, got: \(text)"
        )
    }

    func testRejectsUndecodableData() async {
        do {
            _ = try await TextRecognition.recognizeText(in: Data("not an image".utf8))
            XCTFail("Expected TextRecognitionError.notReadable")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .notReadable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
