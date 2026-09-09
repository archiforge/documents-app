import Foundation
import PDFKit
import Security
import ZIPFoundation

/// Supported service conversions. The coarse `DocumentKind` remains the
/// persisted model; exact extension checks prevent a same-format no-op and
/// keep Pages, Numbers, and Keynote outside the initial service boundary.
enum OfficeConversionMatrix {
    static func sourceExtensions(for kind: DocumentKind) -> Set<String> {
        switch kind {
        case .word: ["doc", "docx", "dot", "dotx", "rtf", "odt"]
        case .excel: ["xls", "xlsx", "csv", "ods"]
        case .powerpoint: ["ppt", "pptx", "pps", "ppsx", "odp"]
        case .text: ["txt", "log", "text"]
        case .markdown: ["md", "markdown", "mdown"]
        case .html: ["html", "htm", "xhtml"]
        default: []
        }
    }

    static func targets(for kind: DocumentKind) -> Set<ConversionTarget> {
        switch kind {
        case .word: [.pdf, .word]
        case .excel: [.pdf, .excel]
        case .powerpoint: [.pdf, .ppt]
        case .text, .markdown, .html: [.word]
        default: []
        }
    }

    static func supports(sourceExtension: String, target: ConversionTarget) -> Bool {
        let normalizedExtension = sourceExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let kind = DocumentKind(filename: "source.\(normalizedExtension)")
        guard targets(for: kind).contains(target) else { return false }
        return sourceExtensions(for: kind).contains(normalizedExtension)
            && normalizedExtension != target.fileExtension
    }
}

struct OfficeConversionConfiguration: Sendable, Equatable {
    let endpoint: URL?
    let token: String?

    init(endpoint: URL?, token: String? = nil) {
        self.endpoint = endpoint
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        guard let endpoint else { return false }
        return Self.isValidEndpoint(endpoint)
    }

    static func isValidEndpoint(_ endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else { return false }
        return true
    }
}

enum OfficeConfigurationError: LocalizedError, Equatable {
    case invalidEndpoint
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTPS conversion-service endpoint."
        case .keychainFailure: "The conversion-service token could not be saved securely."
        }
    }
}

/// User-facing configuration storage. The endpoint is not a secret; an
/// optional bearer token lives in Keychain rather than UserDefaults.
final class OfficeConversionConfigurationStore: @unchecked Sendable {
    static let shared = OfficeConversionConfigurationStore()

    private let defaults: UserDefaults
    private let service = "com.docdeck.app.office-conversion"
    private let tokenAccount = "bearer-token"
    private let endpointKey = "com.docdeck.app.office-conversion.endpoint"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: OfficeConversionConfiguration {
        let endpoint = defaults.string(forKey: endpointKey)
            .flatMap(URL.init(string:))
        let token = readToken()
        return OfficeConversionConfiguration(endpoint: endpoint, token: token)
    }

    func save(endpoint: String, token: String?) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              OfficeConversionConfiguration.isValidEndpoint(url) else {
            throw OfficeConfigurationError.invalidEndpoint
        }
        // Update the secret first. If Keychain rejects the change, leave the
        // previous endpoint in place so an old endpoint is never paired with
        // an old token unexpectedly.
        try writeToken(token)
        var normalizedEndpoint = url.absoluteString
        while normalizedEndpoint.hasSuffix("/") {
            normalizedEndpoint.removeLast()
        }
        defaults.set(normalizedEndpoint, forKey: endpointKey)
    }

    func clear() throws {
        try deleteToken()
        defaults.removeObject(forKey: endpointKey)
    }

    private func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToken(_ token: String?) throws {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            try deleteToken()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OfficeConfigurationError.keychainFailure(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = Data(token.utf8)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw OfficeConfigurationError.keychainFailure(addStatus) }
    }

    private func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OfficeConfigurationError.keychainFailure(status)
        }
    }
}

struct OfficeCapabilities: Decodable, Sendable, Equatable {
    struct Source: Decodable, Sendable, Equatable {
        let extensionName: String
        let targets: [String]

        enum CodingKeys: String, CodingKey {
            case extensionName = "extension"
            case targets
        }
    }

    struct Limits: Decodable, Sendable, Equatable {
        let maxInputBytes: Int64
        let maxOutputBytes: Int64
        let timeoutSeconds: Int64
        let maxConcurrentJobs: Int
    }

    let schemaVersion: String
    let serviceBuild: String
    let ready: Bool
    let sources: [Source]
    let targetMediaTypes: [String: String]
    let limits: Limits

    func supports(sourceExtension: String, target: ConversionTarget) -> Bool {
        let normalized = sourceExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard OfficeConversionMatrix.supports(sourceExtension: normalized, target: target) else { return false }
        return sources.first(where: { $0.extensionName.lowercased() == normalized })?.targets.contains(target.fileExtension) == true
    }
}

struct OfficeConversionResponse: Sendable, Equatable {
    let data: Data
    let filename: String
    let target: ConversionTarget
}

enum OfficeConversionError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unsupportedCombination
    case serviceUnavailable
    case unauthorized
    case responseTooLarge
    case malformedResponse
    case malformedOutput
    case cancelled
    case timedOut
    case server(code: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Configure an HTTPS Office conversion service in Settings."
        case .unsupportedCombination: "This Office source and target combination is not supported."
        case .serviceUnavailable: "The Office conversion service is unavailable."
        case .unauthorized: "The Office conversion service rejected its token."
        case .responseTooLarge: "The conversion service returned an oversized response."
        case .malformedResponse: "The conversion service returned an invalid response."
        case .malformedOutput: "The conversion service returned an invalid document."
        case .cancelled: "The conversion was cancelled."
        case .timedOut: "The conversion exceeded its time limit."
        case .server(_, let detail): detail
        }
    }
}

protocol OfficeConversionServicing: Sendable {
    func fetchCapabilities(forceRefresh: Bool) async throws -> OfficeCapabilities
    func convert(data: Data, filename: String, sourceExtension: String, target: ConversionTarget) async throws -> OfficeConversionResponse
}

private actor OfficeCapabilitiesCache {
    private var value: OfficeCapabilities?
    private var expiresAt: Date = .distantPast

    func get() -> OfficeCapabilities? {
        guard Date() < expiresAt else { return nil }
        return value
    }

    func set(_ value: OfficeCapabilities) {
        self.value = value
        expiresAt = Date().addingTimeInterval(300)
    }

    func clear() {
        value = nil
        expiresAt = .distantPast
    }
}

/// URLSession client for the stateless service. Redirects are rejected so a
/// document body or bearer token cannot be forwarded to another origin.
final class OfficeConversionClient: OfficeConversionServicing, @unchecked Sendable {
    private static let hardInputLimit: Int64 = 50 * 1024 * 1024
    private static let hardOutputLimit: Int64 = 100 * 1024 * 1024
    private static let hardCapabilitiesLimit: Int64 = 1 * 1024 * 1024
    private static let hardTimeoutSeconds: Int64 = 120
    private static let hardConcurrentJobs = 8

    let configuration: OfficeConversionConfiguration
    private let session: URLSession
    private let cache = OfficeCapabilitiesCache()

    /// Tests may inject a URLProtocol-backed configuration. Production callers
    /// use the private ephemeral configuration below.
    init(
        configuration: OfficeConversionConfiguration = OfficeConversionConfigurationStore.shared.configuration,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.configuration = configuration
        let delegate = NoRedirectDelegate()
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 130
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func fetchCapabilities(forceRefresh: Bool = false) async throws -> OfficeCapabilities {
        guard let endpoint = configuration.endpoint, configuration.isConfigured else {
            throw OfficeConversionError.notConfigured
        }
        if !forceRefresh, let cached = await cache.get() { return cached }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/capabilities"))
        request.httpMethod = "GET"
        addHeaders(to: &request)
        let (response, data) = try await boundedResponse(request, maximumBytes: Self.hardCapabilitiesLimit)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw mapServerError(response: response, data: data) }
        do {
            let capabilities = try JSONDecoder().decode(OfficeCapabilities.self, from: data)
            let limits = capabilities.limits
            guard capabilities.schemaVersion == "1", limits.maxInputBytes > 0,
                  limits.maxOutputBytes > 0, limits.maxInputBytes <= Self.hardInputLimit,
                  limits.maxOutputBytes <= Self.hardOutputLimit,
                  limits.timeoutSeconds > 0, limits.timeoutSeconds <= Self.hardTimeoutSeconds,
                  limits.maxConcurrentJobs > 0, limits.maxConcurrentJobs <= Self.hardConcurrentJobs else {
                throw OfficeConversionError.malformedResponse
            }
            await cache.set(capabilities)
            return capabilities
        } catch let error as OfficeConversionError {
            throw error
        } catch {
            throw OfficeConversionError.malformedResponse
        }
    }

    func convert(data: Data, filename: String, sourceExtension: String, target: ConversionTarget) async throws -> OfficeConversionResponse {
        guard configuration.isConfigured else { throw OfficeConversionError.notConfigured }
        let capabilities = try await fetchCapabilities(forceRefresh: false)
        let extensionName = sourceExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard capabilities.ready, capabilities.supports(sourceExtension: extensionName, target: target) else {
            throw capabilities.ready ? OfficeConversionError.unsupportedCombination : OfficeConversionError.serviceUnavailable
        }
        let maximumInput = min(Self.hardInputLimit, capabilities.limits.maxInputBytes)
        guard Int64(data.count) <= maximumInput else { throw OfficeConversionError.responseTooLarge }
        let requestID = UUID().uuidString
        do {
            return try await withTaskCancellationHandler(operation: {
                try await self.performConversion(
                    data: data,
                    filename: filename,
                    sourceExtension: extensionName,
                    target: target,
                    requestID: requestID,
                    maximumOutput: min(Self.hardOutputLimit, capabilities.limits.maxOutputBytes)
                )
            }, onCancel: {
                Task.detached { [client = self] in
                    await client.cancel(requestID: requestID)
                }
            })
        } catch is CancellationError {
            throw OfficeConversionError.cancelled
        }
    }

    private func performConversion(
            data: Data,
            filename: String,
            sourceExtension: String,
            target: ConversionTarget,
            requestID: String,
            maximumOutput: Int64
    ) async throws -> OfficeConversionResponse {
        guard let endpoint = configuration.endpoint else { throw OfficeConversionError.notConfigured }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/conversions"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Conversion-Request-Id")
        addHeaders(to: &request)
        request.httpBody = MultipartForm.body(
            file: data,
            filename: filename,
            sourceExtension: sourceExtension,
            target: target.fileExtension,
            boundary: boundary
        )
        let (response, body) = try await boundedResponse(request, maximumBytes: maximumOutput)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw mapServerError(response: response, data: body) }
        guard let mediaType = response.mimeType,
              mediaType.lowercased() == Self.targetMediaType(target).lowercased() else {
            throw OfficeConversionError.malformedResponse
        }
        try OfficeOutputValidator.validate(body, target: target)
        try Task.checkCancellation()
        let filename = response.value(forHTTPHeaderField: "Content-Disposition")
            .flatMap(Self.filename(from:))
            .flatMap { Self.filename($0, matches: target) }
            ?? "Converted.\(target.fileExtension)"
        return OfficeConversionResponse(data: body, filename: filename, target: target)
    }

    private func cancel(requestID: String) async {
        guard let endpoint = configuration.endpoint else { return }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/conversions/\(requestID)"))
        request.httpMethod = "DELETE"
        addHeaders(to: &request)
        _ = try? await boundedResponse(request, maximumBytes: 8 * 1024)
    }

    private func boundedResponse(_ request: URLRequest, maximumBytes: Int64) async throws -> (HTTPURLResponse, Data) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OfficeConversionError.malformedResponse }
            if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
                guard length >= 0 else { throw OfficeConversionError.malformedResponse }
                if length > maximumBytes {
                    throw OfficeConversionError.responseTooLarge
                }
            }
            var data = Data()
            if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
               let capacity = Int(exactly: length), capacity > 0 {
                data.reserveCapacity(min(capacity, Int(maximumBytes)))
            }
            for try await byte in bytes {
                if Int64(data.count) >= maximumBytes {
                    throw OfficeConversionError.responseTooLarge
                }
                data.append(byte)
            }
            return (http, data)
        } catch is CancellationError {
            throw OfficeConversionError.cancelled
        } catch let error as OfficeConversionError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw OfficeConversionError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw OfficeConversionError.timedOut
        } catch {
            throw OfficeConversionError.serviceUnavailable
        }
    }

    private func addHeaders(to request: inout URLRequest) {
        if let token = configuration.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func mapServerError(response: HTTPURLResponse, data: Data) -> OfficeConversionError {
        if response.statusCode == 401 { return .unauthorized }
        if response.statusCode == 504 { return .timedOut }
        if let problem = try? JSONDecoder().decode(OfficeProblem.self, from: data) {
            return .server(code: problem.code, detail: problem.detail)
        }
        return .serviceUnavailable
    }

    private static func targetMediaType(_ target: ConversionTarget) -> String {
        switch target {
        case .pdf: "application/pdf"
        case .word: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .excel: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .ppt: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        }
    }

    private static func filename(from header: String) -> String? {
        guard let value = header.split(separator: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("filename=") }) else { return nil }
        let name = value.split(separator: "=", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let name, !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let leaf = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        guard let leaf, !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        return leaf
    }

    private static func filename(_ filename: String, matches target: ConversionTarget) -> String? {
        let suffix = filename.split(separator: ".", omittingEmptySubsequences: true).last.map(String.init)?.lowercased()
        return suffix == target.fileExtension ? filename : nil
    }

    private struct OfficeProblem: Decodable {
        let code: String
        let detail: String
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum MultipartForm {
    static func body(file: Data, filename: String, sourceExtension: String, target: String, boundary: String) -> Data {
        var data = Data()
        append("--\(boundary)\r\n", to: &data)
        append("Content-Disposition: form-data; name=\"sourceExtension\"\r\n\r\n\(sourceExtension)\r\n", to: &data)
        append("--\(boundary)\r\n", to: &data)
        append("Content-Disposition: form-data; name=\"target\"\r\n\r\n\(target)\r\n", to: &data)
        append("--\(boundary)\r\n", to: &data)
        let filenameLeaf = filename
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? "source"
        let safeFilename = filenameLeaf
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\nContent-Type: application/octet-stream\r\n\r\n", to: &data)
        data.append(file)
        append("\r\n--\(boundary)--\r\n", to: &data)
        return data
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }
}

enum OfficeOutputValidator {
    private static let maxArchiveEntries = 10_000
    private static let maxExpandedArchiveBytes: UInt64 = 100 * 1024 * 1024
    private static let maxXMLPartBytes = 4 * 1024 * 1024

    static func validate(_ data: Data, target: ConversionTarget) throws {
        guard !data.isEmpty else { throw OfficeConversionError.malformedOutput }
        switch target {
        case .pdf:
            guard let document = PDFDocument(data: data),
                  !document.isEncrypted,
                  document.pageCount >= 1,
                  document.pageCount <= 10_000 else {
                throw OfficeConversionError.malformedOutput
            }
        case .word, .excel, .ppt:
            guard let archive = Archive(data: data, accessMode: .read) else { throw OfficeConversionError.malformedOutput }
            var names = Set<String>()
            var expandedBytes: UInt64 = 0
            var entries: [Entry] = []
            for entry in archive {
                let path = entry.path
                var components = path.split(separator: "/", omittingEmptySubsequences: false)
                if entry.type == .directory, components.last?.isEmpty == true {
                    components.removeLast()
                }
                guard entry.type != .symlink,
                      !path.hasPrefix("/"), !components.contains(""), !components.contains(".."), !path.contains("\\") else {
                    throw OfficeConversionError.malformedOutput
                }
                guard !path.lowercased().contains("vbaproject.bin"),
                      !path.lowercased().contains("/embeddings/"),
                      !path.lowercased().hasPrefix("embeddings/"),
                      !path.lowercased().contains("externallinks") else {
                    throw OfficeConversionError.malformedOutput
                }
                guard names.insert(path).inserted else { throw OfficeConversionError.malformedOutput }
                guard names.count <= Self.maxArchiveEntries else { throw OfficeConversionError.malformedOutput }
                let size = entry.uncompressedSize
                guard size <= Self.maxExpandedArchiveBytes,
                      expandedBytes <= Self.maxExpandedArchiveBytes - size else {
                    throw OfficeConversionError.malformedOutput
                }
                expandedBytes += size
                entries.append(entry)
            }
            guard names.contains("[Content_Types].xml") else { throw OfficeConversionError.malformedOutput }
            let required = switch target {
            case .word: "word/document.xml"
            case .excel: "xl/workbook.xml"
            case .ppt: "ppt/presentation.xml"
            case .pdf: ""
            }
            guard names.contains(required) else { throw OfficeConversionError.malformedOutput }

            // Extract every entry with ZIPFoundation's default CRC check. This
            // keeps a corrupt compressed payload from being accepted based on
            // central-directory metadata alone, while the bounded declarations
            // above prevent decompression bombs.
            for entry in entries {
                if entry.type == .directory { continue }
                if entry.path.hasSuffix(".rels") {
                    let relationships = try readEntry(entry, from: archive, maximumBytes: Self.maxXMLPartBytes)
                    try validateRelationships(relationships)
                } else if entry.path == "[Content_Types].xml" || entry.path == required {
                    let xml = try readEntry(entry, from: archive, maximumBytes: Self.maxXMLPartBytes)
                    let expectedRoot = entry.path == "[Content_Types].xml"
                        ? "Types"
                        : (target == .word ? "document" : target == .excel ? "workbook" : "presentation")
                    try validateXML(xml, root: expectedRoot)
                } else {
                    _ = try archive.extract(entry, bufferSize: defaultReadChunkSize, consumer: { _ in })
                }
            }
        }
    }

    private static func readEntry(
        _ entry: Entry,
        from archive: Archive,
        maximumBytes: Int
    ) throws -> Data {
        guard entry.type == .file,
              entry.uncompressedSize <= UInt64(maximumBytes) else {
            throw OfficeConversionError.malformedOutput
        }
        var data = Data()
        if let capacity = Int(exactly: entry.uncompressedSize), capacity > 0 {
            data.reserveCapacity(capacity)
        }
        _ = try archive.extract(entry, bufferSize: defaultReadChunkSize, consumer: { chunk in
            guard data.count <= maximumBytes - chunk.count else {
                throw OfficeConversionError.malformedOutput
            }
            data.append(chunk)
        })
        guard data.count <= maximumBytes else { throw OfficeConversionError.malformedOutput }
        return data
    }

    private static func validateXML(_ data: Data, root expectedRoot: String) throws {
        let delegate = XMLRootDelegate(expectedRoot: expectedRoot)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.rootMatched else {
            throw OfficeConversionError.malformedOutput
        }
    }

    private static func validateRelationships(_ data: Data) throws {
        let delegate = RelationshipDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.unsupportedExternalRelationship else {
            throw OfficeConversionError.malformedOutput
        }
    }

    private final class XMLRootDelegate: NSObject, XMLParserDelegate {
        let expectedRoot: String
        var rootMatched = false
        private var sawRoot = false

        init(expectedRoot: String) {
            self.expectedRoot = expectedRoot
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard !sawRoot else { return }
            sawRoot = true
            let localName = (qName ?? elementName).split(separator: ":").last.map(String.init)
            rootMatched = localName == expectedRoot
        }

        func parser(
            _ parser: XMLParser,
            resolveExternalEntityName name: String,
            systemID: String?
        ) -> Data? {
            nil
        }
    }

    private final class RelationshipDelegate: NSObject, XMLParserDelegate {
        var unsupportedExternalRelationship = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let localName = (qName ?? elementName).split(separator: ":").last.map(String.init)
            guard localName == "Relationship",
                  attributeDict["TargetMode"]?.lowercased() == "external" else { return }
            // Ordinary hyperlinks are inert document data. External object,
            // image, and package relationships would make the output fetch or
            // activate content outside the validated archive.
            let type = attributeDict["Type"]?.lowercased() ?? ""
            unsupportedExternalRelationship = !type.hasSuffix("/hyperlink")
        }

        func parser(
            _ parser: XMLParser,
            resolveExternalEntityName name: String,
            systemID: String?
        ) -> Data? {
            nil
        }
    }
}
