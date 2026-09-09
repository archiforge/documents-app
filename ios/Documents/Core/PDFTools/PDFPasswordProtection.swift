import Foundation
import PDFKit

/// Validation and PDFKit-backed password protection for a PDF copy.
enum PDFPasswordProtectionError: LocalizedError, Equatable {
    case unreadablePDF
    case sourceAlreadyLocked
    case emptyPassword
    case passwordMismatch
    case encryptionFailed
    case encryptedOutputInvalid

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "The file could not be read as a PDF."
        case .sourceAlreadyLocked:
            "This PDF is already password-protected."
        case .emptyPassword:
            "Enter a password before protecting the PDF."
        case .passwordMismatch:
            "The passwords do not match."
        case .encryptionFailed:
            "The protected PDF could not be written."
        case .encryptedOutputInvalid:
            "The protected PDF could not be verified."
        }
    }
}

/// Uses PDFKit's native PDF encryption options. The source bytes are read
/// into a PDFDocument and written to a short-lived encrypted temporary file;
/// the caller receives the protected bytes and owns the generated copy.
enum PDFPasswordProtection {
    /// Protects a new PDF copy with a user password.
    ///
    /// PDFKit requires a non-empty owner password for encryption. A random
    /// owner password is held only for the duration of this operation, while
    /// the user-entered password is the one needed to open the result.
    static func encrypt(
        _ data: Data,
        password: String,
        confirmation: String
    ) throws -> Data {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFPasswordProtectionError.emptyPassword
        }
        guard password == confirmation else {
            throw PDFPasswordProtectionError.passwordMismatch
        }
        guard let source = PDFDocument(data: data) else {
            throw PDFPasswordProtectionError.unreadablePDF
        }
        guard !source.isEncrypted, !source.isLocked else {
            throw PDFPasswordProtectionError.sourceAlreadyLocked
        }

        let ownerPassword = UUID().uuidString
        let options: [PDFDocumentWriteOption: Any] = [
            PDFDocumentWriteOption.ownerPasswordOption: ownerPassword,
            PDFDocumentWriteOption.userPasswordOption: password,
        ]
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Documents-Protected-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        guard source.write(to: temporaryURL, withOptions: options),
              let protectedData = try? Data(contentsOf: temporaryURL)
        else {
            throw PDFPasswordProtectionError.encryptionFailed
        }

        // Verify the exact output that will be handed to DocumentStore. This
        // catches a PDFKit write that returned successfully but did not
        // produce a password-locked document.
        guard let protected = PDFDocument(data: protectedData),
              protected.isEncrypted,
              protected.isLocked,
              protected.unlock(withPassword: password),
              !protected.isLocked,
              protected.pageCount == source.pageCount,
              protected.string == source.string
        else {
            throw PDFPasswordProtectionError.encryptedOutputInvalid
        }
        return protectedData
    }
}
