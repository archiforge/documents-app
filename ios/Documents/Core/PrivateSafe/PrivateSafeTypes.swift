import Foundation

/// Errors returned by the local-only Private Safe boundary.
enum PrivateSafeError: LocalizedError, Equatable, Sendable {
    case locked
    case keyUnavailable
    case authenticationUnavailable(String)
    case invalidSource
    case sourceChanged
    case itemNotFound
    case itemAlreadyExists
    case corruptManifest
    case corruptBlob
    case unsupportedVersion
    case malformedEnvelope
    case destinationExists
    case invalidDestination
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .locked:
            "Unlock Private Safe to continue."
        case .keyUnavailable:
            "Private Safe is unavailable on this device. Its encrypted files were kept."
        case .authenticationUnavailable(let message):
            message
        case .invalidSource:
            "The selected source is not a regular file."
        case .sourceChanged:
            "The source changed while it was being copied. Try again."
        case .itemNotFound:
            "That Private Safe item is no longer available."
        case .itemAlreadyExists:
            "That Private Safe item already exists."
        case .corruptManifest:
            "Private Safe could not authenticate its index. Encrypted files were kept."
        case .corruptBlob:
            "The Private Safe copy failed authentication or is incomplete."
        case .unsupportedVersion:
            "This Private Safe format version is not supported."
        case .malformedEnvelope:
            "The Private Safe data is malformed."
        case .destinationExists:
            "The export destination already exists."
        case .invalidDestination:
            "The export destination is not a Private Safe temporary file."
        case .operationFailed(let message):
            message
        }
    }
}

struct PrivateSafeItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let fileExtension: String
    let byteCount: Int64
    let createdAt: Date
    let sourceRecordID: UUID?
    let blobName: String
}

struct PrivateSafeManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let generation: UInt64
    var items: [PrivateSafeItem]

    init(generation: UInt64 = 0, items: [PrivateSafeItem] = []) {
        self.version = Self.currentVersion
        self.generation = generation
        self.items = items
    }
}

enum PrivateSafeTransactionKind: String, Codable, Sendable {
    case add
    case delete
}

enum PrivateSafeTransactionStage: String, Codable, Sendable {
    case prepared
    case blobCommitted
    case manifestCommitted
}

struct PrivateSafeTransaction: Codable, Equatable, Sendable {
    let operationID: UUID
    let kind: PrivateSafeTransactionKind
    let itemID: UUID
    let pendingPath: String?
    let finalBlobPath: String
    let stagedBlobPath: String?
    let expectedGeneration: UInt64
    var stage: PrivateSafeTransactionStage
}
