import Foundation
import LocalAuthentication
import Security

protocol PrivateSafeKeychainClient: AnyObject {
    func read(context: LAContext?) throws -> Data?
    func create() throws -> Data
    func delete() throws
}

enum PrivateSafeKeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
    case accessControlUnavailable
}

final class PrivateSafeKeychain: PrivateSafeKeychainClient {
    static let service = "com.docdeck.app.private-safe"
    static let account = "master-key-v1"

    func read(context: LAContext?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PrivateSafeKeychainError.status(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw PrivateSafeKeychainError.status(errSecDecode)
        }
        return data
    }

    func create() throws -> Data {
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            throw PrivateSafeKeychainError.accessControlUnavailable
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: key
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            if let existing = try read(context: nil) {
                return existing
            }
            throw PrivateSafeKeychainError.status(errSecItemNotFound)
        }
        guard status == errSecSuccess else { throw PrivateSafeKeychainError.status(status) }
        return key
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PrivateSafeKeychainError.status(status)
        }
    }
}
