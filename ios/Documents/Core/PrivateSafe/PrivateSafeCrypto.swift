import CryptoKit
import Foundation

/// Versioned framing and CryptoKit operations for Private Safe. The format is
/// intentionally small and self-authenticating; it is not a password format.
enum PrivateSafeCrypto {
    static let formatVersion: UInt8 = 1
    static let chunkSize = 1_048_576
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    static let maximumTransactionBytes = 64 * 1_024
    static let maximumItems = 10_000
    static let maximumDisplayNameBytes = 1_024
    static let maximumExtensionBytes = 128
    static let manifestAAD = Data("com.docdeck.private-safe.manifest.v1".utf8)
    static let chunkAADPrefix = Data("com.docdeck.private-safe.chunk.v1".utf8)
    static let magic = Data("DOCSAFE1".utf8)

    static func deriveItemKey(rawKey: Data, itemID: UUID) -> SymmetricKey {
        let master = SymmetricKey(data: rawKey)
        let info = Data(itemID.uuidString.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data("com.docdeck.private-safe.item.v1".utf8),
            info: info,
            outputByteCount: 32
        )
    }

    static func sealManifest(_ manifest: PrivateSafeManifest, rawKey: Data) throws -> Data {
        guard manifest.items.count <= maximumItems,
              Set(manifest.items.map(\.id)).count == manifest.items.count,
              Set(manifest.items.map(\.blobName)).count == manifest.items.count,
              manifest.items.allSatisfy({ item in
                  item.byteCount >= 0 &&
                  item.displayName.utf8.count <= maximumDisplayNameBytes &&
                  item.fileExtension.utf8.count <= maximumExtensionBytes &&
                  item.createdAt.timeIntervalSince1970.isFinite &&
                  item.blobName == "\(item.id.uuidString).safe"
              })
        else { throw PrivateSafeError.corruptManifest }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        let plain = try encoder.encode(manifest)
        let key = SymmetricKey(data: rawKey)
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: manifestAAD).combined else {
            throw PrivateSafeError.operationFailed("Private Safe could not seal its index.")
        }
        return combined
    }

    static func openManifest(_ data: Data, rawKey: Data) throws -> PrivateSafeManifest {
        guard data.count <= maximumManifestBytes else {
            throw PrivateSafeError.corruptManifest
        }
        let key = SymmetricKey(data: rawKey)
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key, authenticating: manifestAAD)
        else {
            throw PrivateSafeError.corruptManifest
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let bits = try container.decode(UInt64.self)
                return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
            }
            let manifest = try decoder.decode(PrivateSafeManifest.self, from: plain)
            guard manifest.version == PrivateSafeManifest.currentVersion else {
                throw PrivateSafeError.unsupportedVersion
            }
            guard manifest.items.count <= maximumItems,
                  Set(manifest.items.map(\.id)).count == manifest.items.count,
                  Set(manifest.items.map(\.blobName)).count == manifest.items.count,
                  manifest.items.allSatisfy({ item in
                      item.byteCount >= 0 &&
                      item.displayName.utf8.count <= maximumDisplayNameBytes &&
                      item.fileExtension.utf8.count <= maximumExtensionBytes &&
                      item.createdAt.timeIntervalSince1970.isFinite &&
                      item.blobName == "\(item.id.uuidString).safe"
                  })
            else {
                throw PrivateSafeError.corruptManifest
            }
            return manifest
        } catch let error as PrivateSafeError {
            throw error
        } catch {
            throw PrivateSafeError.corruptManifest
        }
    }

    static func header(for itemID: UUID, originalSize: UInt64) -> Data {
        var result = Data()
        result.append(contentsOf: magic)
        result.append(formatVersion)
        result.append(contentsOf: uuidBytes(itemID))
        appendUInt32(UInt32(chunkSize), to: &result)
        appendUInt64(originalSize, to: &result)
        return result
    }

    static func parseHeader(_ data: Data) throws -> (itemID: UUID, originalSize: UInt64, offset: Int) {
        let minimum = magic.count + 1 + 16 + 4 + 8
        guard data.count >= minimum,
              data.prefix(magic.count) == magic,
              data[magic.count] == formatVersion
        else {
            if data.prefix(magic.count) == magic { throw PrivateSafeError.unsupportedVersion }
            throw PrivateSafeError.malformedEnvelope
        }
        var offset = magic.count + 1
        let id = try readUUID(data, offset: &offset)
        let chunkSizeValue = try readUInt32(data, offset: &offset)
        guard chunkSizeValue == UInt32(chunkSize) else { throw PrivateSafeError.malformedEnvelope }
        let originalSize = try readUInt64(data, offset: &offset)
        return (id, originalSize, offset)
    }

    static func chunkAAD(itemID: UUID, index: UInt64, plainLength: UInt32) -> Data {
        var result = chunkAADPrefix
        result.append(contentsOf: uuidBytes(itemID))
        appendUInt64(index, to: &result)
        appendUInt32(plainLength, to: &result)
        return result
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw PrivateSafeError.malformedEnvelope }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    static func readUInt64(_ data: Data, offset: inout Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { throw PrivateSafeError.malformedEnvelope }
        let value = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        offset += 8
        return value
    }

    static func uuidBytes(_ id: UUID) -> Data {
        var uuid = id.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    static func readUUID(_ data: Data, offset: inout Int) throws -> UUID {
        guard offset >= 0, offset <= data.count - 16 else { throw PrivateSafeError.malformedEnvelope }
        let bytes = Array(data[offset..<(offset + 16)])
        offset += 16
        guard bytes.count == 16 else { throw PrivateSafeError.malformedEnvelope }
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
