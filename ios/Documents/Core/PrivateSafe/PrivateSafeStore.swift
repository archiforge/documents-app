import CryptoKit
import Darwin
import Foundation

/// Actor-owned file store for encrypted Private Safe copies. No SwiftData
/// records are created here; the manifest is the authenticated index.
actor PrivateSafeStore {
    enum Fault: Sendable, Equatable {
        /// Test seam used to prove that a post-commit journal failure cannot
        /// roll back an already authenticated manifest and blob.
        case beforeAddEncryption
        case afterAddManifestCommit
        case afterDeleteManifestCommit
    }

    static let defaultRoot: URL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("PrivateSafe/v1", isDirectory: true)

    static let defaultCacheRoot: URL = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("PrivateSafe", isDirectory: true)

    let root: URL
    let blobs: URL
    let transactions: URL
    let pending: URL
    let cacheRoot: URL
    let views: URL
    let exports: URL

    private let fileManager: FileManager
    private let fault: Fault?
    /// Keep the caller-supplied paths as well as their resolved forms. The
    /// resolved URLs are useful for trusted platform aliases such as /var,
    /// but they must never hide a symlink in an app-controlled parent.
    private let rawRoot: URL
    private let rawCacheRoot: URL
    private let rootWasSymlink: Bool
    private let cacheRootWasSymlink: Bool

    private struct RecoveredTransaction {
        let transaction: PrivateSafeTransaction
        let url: URL
        let isBoundToAuthenticatedItem: Bool
    }

    init(
        root: URL = PrivateSafeStore.defaultRoot,
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default,
        fault: Fault? = nil
    ) {
        let rawRoot = root.standardizedFileURL
        let rawCacheRoot = (cacheRoot ?? Self.defaultCacheRoot).standardizedFileURL
        // App container parents can contain platform-managed aliases. Resolve
        // those trusted parents first; reject a symlink at the vault/cache
        // root itself and inspect every component inside the resolved root.
        self.rootWasSymlink = Self.isSymbolicLinkStatic(rawRoot, fileManager: fileManager)
        self.cacheRootWasSymlink = Self.isSymbolicLinkStatic(rawCacheRoot, fileManager: fileManager)
        self.rawRoot = rawRoot
        self.rawCacheRoot = rawCacheRoot
        // Resolve trusted system aliases such as /var and /tmp once. Any
        // symlink at the vault/cache root itself remains a fail-closed state.
        self.root = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        self.blobs = self.root.appendingPathComponent("blobs", isDirectory: true)
        self.transactions = self.root.appendingPathComponent("transactions", isDirectory: true)
        self.pending = self.root.appendingPathComponent("pending", isDirectory: true)
        self.cacheRoot = rawCacheRoot.resolvingSymlinksInPath().standardizedFileURL
        self.views = self.cacheRoot.appendingPathComponent("views", isDirectory: true)
        self.exports = self.cacheRoot.appendingPathComponent("exports", isDirectory: true)
        self.fileManager = fileManager
        self.fault = fault
    }

    private var manifestURL: URL { root.appendingPathComponent("manifest.safe") }
    private var pendingManifestURL: URL { root.appendingPathComponent("manifest.safe.pending") }
    private var previousManifestURL: URL { root.appendingPathComponent("manifest.safe.previous") }

    /// True when encrypted vault state exists. This check intentionally does
    /// not decrypt or clean anything and is used to refuse key replacement.
    func hasEncryptedState() -> Bool {
        guard rootStorageIsSafe else { return true }
        guard fileManager.fileExists(atPath: root.path) else { return false }
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return true
        }
        // Unknown entries or unreadable layout directories are ambiguous until
        // authenticated. Empty, known layout directories are the harmless
        // result of a cancelled first operation and do not represent state.
        guard let entries = safeDirectoryEntries(at: root) else { return true }
        let knownDirectories = Set([blobs, transactions, pending].map(\.lastPathComponent))
        guard entries.allSatisfy({ knownDirectories.contains($0.lastPathComponent) }) else {
            return true
        }
        for directory in [blobs, transactions, pending]
            where fileManager.fileExists(atPath: directory.path) {
            guard let children = safeDirectoryEntries(at: directory) else { return true }
            if !children.isEmpty { return true }
        }
        return false
    }

    func listItems(rawKey: Data) throws -> [PrivateSafeItem] {
        try recover(rawKey: rawKey).items
    }

    /// Copies and encrypts a source directly into a pending blob, then commits
    /// the authenticated manifest. The source is never rewritten or deleted.
    func addCopy(
        from sourceURL: URL,
        displayName: String? = nil,
        sourceRecordID: UUID? = nil,
        rawKey: Data
    ) throws -> PrivateSafeItem {
        try Task.checkCancellation()
        let source = sourceURL.standardizedFileURL
        guard isRegularFile(source) else { throw PrivateSafeError.invalidSource }
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        let expectedSize = Int64(sourceValues.fileSize ?? -1)
        guard expectedSize >= 0 else { throw PrivateSafeError.invalidSource }

        try makeDirectories()
        let manifest = try recover(rawKey: rawKey)
        // Establish an authenticated generation before the first journal is
        // written. A crash during the first add must remain recoverable.
        if !hasManifestCandidate() {
            try commitManifest(PrivateSafeManifest(), rawKey: rawKey)
        }
        let itemID = UUID()
        let finalBlobName = "\(itemID.uuidString).safe"
        let finalBlobURL = blobs.appendingPathComponent(finalBlobName)
        let pendingURL = pending.appendingPathComponent("add-\(itemID.uuidString).blob")
        let operationURL = transactions.appendingPathComponent("\(itemID.uuidString).json")
        var transaction = PrivateSafeTransaction(
            operationID: itemID,
            kind: .add,
            itemID: itemID,
            pendingPath: pendingURL.path,
            finalBlobPath: finalBlobURL.path,
            stagedBlobPath: nil,
            expectedGeneration: manifest.generation,
            stage: .prepared
        )
        try writeTransaction(transaction, to: operationURL)
        if fault == .beforeAddEncryption {
            cleanupUncommittedAdd(
                transaction,
                operationURL: operationURL,
                pendingCreated: false,
                finalMoved: false
            )
            throw PrivateSafeError.operationFailed("Injected add failure.")
        }

        var manifestCommitted = false
        var committedManifest: PrivateSafeManifest?
        var pendingCreated = false
        var finalMoved = false
        do {
            let actualSize = try encrypt(
                source: source,
                to: pendingURL,
                itemID: itemID,
                rawKey: rawKey,
                created: &pendingCreated
            )
            guard actualSize == expectedSize else { throw PrivateSafeError.sourceChanged }
            try Task.checkCancellation()
            try moveNewFile(pendingURL, to: finalBlobURL)
            finalMoved = true
            pendingCreated = false
            transaction.stage = .blobCommitted
            try writeTransaction(transaction, to: operationURL)

            let baseName = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (baseName?.isEmpty == false ? baseName! : source.lastPathComponent)
            guard resolvedName.utf8.count <= PrivateSafeCrypto.maximumDisplayNameBytes,
                  source.pathExtension.utf8.count <= PrivateSafeCrypto.maximumExtensionBytes
            else { throw PrivateSafeError.operationFailed("The Private Safe name is too long.") }
            let item = PrivateSafeItem(
                id: itemID,
                displayName: resolvedName,
                fileExtension: source.pathExtension.lowercased(),
                byteCount: actualSize,
                createdAt: Date(),
                sourceRecordID: sourceRecordID,
                blobName: finalBlobName
            )
            guard manifest.generation < UInt64.max else { throw PrivateSafeError.operationFailed("Private Safe generation limit reached.") }
            var next = PrivateSafeManifest(generation: manifest.generation + 1, items: manifest.items)
            next.items.append(item)
            try Task.checkCancellation()
            committedManifest = next
            try commitManifest(next, rawKey: rawKey)
            manifestCommitted = true

            // Manifest commit is the durable success boundary. Cleanup/journal
            // failures must not report a failed add or delete a committed blob.
            transaction.stage = .manifestCommitted
            if fault == .afterAddManifestCommit {
                throw PrivateSafeError.operationFailed("Injected post-commit failure.")
            }
            try? writeTransaction(transaction, to: operationURL)
            try? removeOwnedFile(operationURL)
            return item
        } catch is CancellationError {
            if !manifestCommitted, let committedManifest,
               activeManifestMatches(committedManifest, rawKey: rawKey) {
                manifestCommitted = true
            }
            if !manifestCommitted {
                cleanupUncommittedAdd(
                    transaction,
                    operationURL: operationURL,
                    pendingCreated: pendingCreated,
                    finalMoved: finalMoved
                )
            }
            throw CancellationError()
        } catch {
            if !manifestCommitted, let committedManifest,
               activeManifestMatches(committedManifest, rawKey: rawKey) {
                manifestCommitted = true
            }
            if !manifestCommitted {
                cleanupUncommittedAdd(
                    transaction,
                    operationURL: operationURL,
                    pendingCreated: pendingCreated,
                    finalMoved: finalMoved
                )
            }
            throw error
        }
    }

    /// Decrypts one item to a new temporary URL. The caller owns the URL until
    /// it releases the export/view lease; this method never overwrites a file.
    func decryptItem(
        id: UUID,
        rawKey: Data,
        destination: URL,
        kind: PrivateSafeTemporaryKind
    ) throws -> URL {
        try Task.checkCancellation()
        guard isTemporaryDestination(destination, kind: kind),
              !fileManager.fileExists(atPath: destination.path)
        else { throw PrivateSafeError.invalidDestination }

        let manifest = try recover(rawKey: rawKey)
        guard let item = manifest.items.first(where: { $0.id == id }) else {
            throw PrivateSafeError.itemNotFound
        }
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent)
        let temporary = destination.appendingPathExtension("tmp")
        try? removeTemporaryFile(temporary)

        do {
            let blobURL = blobs.appendingPathComponent(item.blobName)
            try decrypt(blob: blobURL, item: item, rawKey: rawKey, to: temporary)
            try protect(temporary)
            try moveNewFile(temporary, to: destination)
            try protect(destination)
            return destination
        } catch is CancellationError {
            try? removeTemporaryFile(temporary)
            try? removeTemporaryFile(destination)
            try? removeOwnedDirectory(parent)
            throw CancellationError()
        } catch {
            try? removeTemporaryFile(temporary)
            try? removeTemporaryFile(destination)
            try? removeOwnedDirectory(parent)
            throw error
        }
    }

    func delete(id: UUID, rawKey: Data) throws {
        try Task.checkCancellation()
        try makeDirectories()
        let manifest = try recover(rawKey: rawKey)
        guard let item = manifest.items.first(where: { $0.id == id }) else {
            throw PrivateSafeError.itemNotFound
        }
        let finalURL = blobs.appendingPathComponent(item.blobName)
        guard finalURL.lastPathComponent == "\(id.uuidString).safe" else {
            throw PrivateSafeError.corruptManifest
        }

        let operationID = UUID()
        let stagedURL = transactions.appendingPathComponent("delete-\(operationID.uuidString).blob")
        let operationURL = transactions.appendingPathComponent("\(operationID.uuidString).json")
        var transaction = PrivateSafeTransaction(
            operationID: operationID,
            kind: .delete,
            itemID: id,
            pendingPath: nil,
            finalBlobPath: finalURL.path,
            stagedBlobPath: stagedURL.path,
            expectedGeneration: manifest.generation,
            stage: .prepared
        )
        try writeTransaction(transaction, to: operationURL)

        var manifestCommitted = false
        var committedManifest: PrivateSafeManifest?
        var stagedMoved = false
        do {
            try moveNewFile(finalURL, to: stagedURL)
            stagedMoved = true
            transaction.stage = .blobCommitted
            try writeTransaction(transaction, to: operationURL)
            guard manifest.generation < UInt64.max else { throw PrivateSafeError.operationFailed("Private Safe generation limit reached.") }
            let next = PrivateSafeManifest(
                generation: manifest.generation + 1,
                items: manifest.items.filter { $0.id != id }
            )
            try Task.checkCancellation()
            committedManifest = next
            try commitManifest(next, rawKey: rawKey)
            manifestCommitted = true

            transaction.stage = .manifestCommitted
            if fault == .afterDeleteManifestCommit {
                throw PrivateSafeError.operationFailed("Injected post-commit failure.")
            }
            try? writeTransaction(transaction, to: operationURL)
            try? removeOwnedFile(stagedURL)
            try? removeOwnedFile(operationURL)
        } catch is CancellationError {
            if !manifestCommitted, let committedManifest,
               activeManifestMatches(committedManifest, rawKey: rawKey) {
                manifestCommitted = true
            }
            if !manifestCommitted { restoreDeleteIfNeeded(transaction, stagedMoved: stagedMoved) }
            if !manifestCommitted { try? removeOwnedFile(operationURL) }
            throw CancellationError()
        } catch {
            if !manifestCommitted, let committedManifest,
               activeManifestMatches(committedManifest, rawKey: rawKey) {
                manifestCommitted = true
            }
            if !manifestCommitted { restoreDeleteIfNeeded(transaction, stagedMoved: stagedMoved) }
            if !manifestCommitted { try? removeOwnedFile(operationURL) }
            throw error
        }
    }

    /// Deletes only app-owned plaintext cache entries whose names carry the
    /// explicit plaintext marker. It never traverses outside the cache root.
    nonisolated static func sweepPlaintextCaches(
        fileManager: FileManager = .default,
        cacheRoot: URL = PrivateSafeStore.defaultCacheRoot
    ) {
        let rawCacheRoot = cacheRoot.standardizedFileURL
        guard !hasSymbolicLinkInPathStatic(rawCacheRoot, fileManager: fileManager) else { return }
        for root in [
            rawCacheRoot.appendingPathComponent("views", isDirectory: true),
            rawCacheRoot.appendingPathComponent("exports", isDirectory: true)
        ] {
            guard !hasSymbolicLinkInPathStatic(root, fileManager: fileManager),
                  let entries = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for entry in entries where isPlaintextMarker(entry.lastPathComponent) {
                guard !hasSymbolicLinkInPathStatic(entry, fileManager: fileManager) else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    func removeTemporaryFiles(_ urls: [URL]) {
        guard cacheStorageIsSafe else { return }
        for url in urls where isTemporaryURL(url) {
            try? removeTemporaryFile(url)
            let directory = url.deletingLastPathComponent()
            if Self.isPlaintextMarker(directory.lastPathComponent) {
                try? removeOwnedDirectory(directory)
            }
        }
    }

    func makeTemporaryURL(fileName: String, kind: PrivateSafeTemporaryKind) throws -> URL {
        guard cacheStorageIsSafe else { throw PrivateSafeError.invalidDestination }
        let rootURL: URL
        switch kind {
        case .view:
            rootURL = views
        case .export:
            rootURL = exports
        case .any:
            throw PrivateSafeError.invalidDestination
        }
        try ensureDirectory(rootURL)
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw PrivateSafeError.invalidDestination
        }
        let directory = rootURL.appendingPathComponent("plaintext-\(UUID().uuidString)", isDirectory: true)
        do {
            try ensureDirectory(directory)
            return directory.appendingPathComponent(safeName)
        } catch {
            // Directory creation can succeed before protection fails. Remove
            // only this operation's marker directory on that path.
            try? removeOwnedDirectory(directory)
            throw error
        }
    }

    func reset() throws {
        guard rootStorageIsSafe, cacheStorageIsSafe else {
            throw PrivateSafeError.operationFailed("Private Safe storage path is unsafe.")
        }
        if fileManager.fileExists(atPath: root.path) {
            guard !isSymbolicLink(root),
                  (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw PrivateSafeError.operationFailed("Private Safe root is not a regular directory.") }
            try fileManager.removeItem(at: root)
        }
        if fileManager.fileExists(atPath: cacheRoot.path) {
            guard !isSymbolicLink(cacheRoot),
                  (try? cacheRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw PrivateSafeError.operationFailed("Private Safe cache root is not a regular directory.") }
            try fileManager.removeItem(at: cacheRoot)
        }
    }

    // MARK: - Authenticated manifest recovery

    private func hasManifestCandidate() -> Bool {
        [manifestURL, pendingManifestURL, previousManifestURL].contains { isRegularFile($0) }
    }

    private func activeManifestMatches(
        _ expected: PrivateSafeManifest,
        rawKey: Data
    ) -> Bool {
        guard isRegularFile(manifestURL),
              let values = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= PrivateSafeCrypto.maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL),
              let actual = try? PrivateSafeCrypto.openManifest(data, rawKey: rawKey)
        else { return false }
        return actual == expected
    }

    private func recover(rawKey: Data) throws -> PrivateSafeManifest {
        guard rootStorageIsSafe else { throw PrivateSafeError.corruptManifest }
        for directory in [blobs, transactions, pending] where fileManager.fileExists(atPath: directory.path) {
            guard !hasSymbolicLinkInPath(directory),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw PrivateSafeError.corruptManifest }
        }
        let candidates = [manifestURL, pendingManifestURL, previousManifestURL].compactMap {
            (url: URL) -> (url: URL, data: Data, manifest: PrivateSafeManifest)? in
            guard isRegularFile(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size <= PrivateSafeCrypto.maximumManifestBytes,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? PrivateSafeCrypto.openManifest(data, rawKey: rawKey)
            else { return nil }
            return (url, data, manifest)
        }
        guard let selected = candidates.max(by: { $0.manifest.generation < $1.manifest.generation }) else {
            if hasEncryptedState() { throw PrivateSafeError.corruptManifest }
            return PrivateSafeManifest()
        }

        if selected.url.standardizedFileURL.path != manifestURL.standardizedFileURL.path {
            guard !isSymbolicLink(manifestURL) else { throw PrivateSafeError.corruptManifest }
            try writeData(selected.data, to: manifestURL)
            try protect(manifestURL)
        }
        let authenticatedItems = candidates
            .flatMap { $0.manifest.items }
            .reduce(into: [UUID: PrivateSafeItem]()) { result, item in
                result[item.id] = item
            }
        try reconcile(
            selected: selected.manifest,
            authenticatedItems: authenticatedItems,
            rawKey: rawKey
        )

        // Only authenticated candidates are disposable. Malformed or unknown
        // artifacts remain for diagnostics and are never followed/deleted.
        for candidate in candidates where candidate.url.path != manifestURL.path {
            try? removeOwnedFile(candidate.url)
        }
        return selected.manifest
    }

    private func reconcile(
        selected: PrivateSafeManifest,
        authenticatedItems: [UUID: PrivateSafeItem],
        rawKey: Data
    ) throws {
        let transactions = loadValidatedTransactions(authenticatedItems: authenticatedItems)

        for entry in transactions where entry.isBoundToAuthenticatedItem {
            let transaction = entry.transaction
            let journalURL = entry.url
            let finalURL = blobs.appendingPathComponent("\(transaction.itemID.uuidString).safe")
            guard let authenticatedItem = authenticatedItems[transaction.itemID] else { continue }
            switch transaction.kind {
            case .add:
                let item = selected.items.first { $0.id == transaction.itemID }
                let pendingURL = pending.appendingPathComponent("add-\(transaction.itemID.uuidString).blob")
                if item != nil {
                    if !fileManager.fileExists(atPath: finalURL.path),
                       isValidEncryptedBlob(pendingURL, item: authenticatedItem, rawKey: rawKey) {
                        try moveNewFile(pendingURL, to: finalURL)
                        try? removeOwnedFile(journalURL)
                    } else if isRegularFile(finalURL),
                              isValidEncryptedBlob(finalURL, item: authenticatedItem, rawKey: rawKey) {
                        if isRegularFile(pendingURL),
                           isValidEncryptedBlob(pendingURL, item: authenticatedItem, rawKey: rawKey) {
                            try? removeOwnedFile(pendingURL)
                        }
                        try? removeOwnedFile(journalURL)
                    }
                }
            case .delete:
                let stagedURL = transactionsURL(for: transaction)
                let itemIsReferenced = selected.items.contains {
                    $0.id == transaction.itemID &&
                    $0.blobName == finalURL.lastPathComponent
                }
                if itemIsReferenced {
                    if !fileManager.fileExists(atPath: finalURL.path),
                       isValidEncryptedBlob(stagedURL, item: authenticatedItem, rawKey: rawKey) {
                        try moveNewFile(stagedURL, to: finalURL)
                        try? removeOwnedFile(journalURL)
                    } else if isRegularFile(finalURL),
                              isValidEncryptedBlob(finalURL, item: authenticatedItem, rawKey: rawKey) {
                        if isValidEncryptedBlob(stagedURL, item: authenticatedItem, rawKey: rawKey) {
                            try? removeOwnedFile(stagedURL)
                            try? removeOwnedFile(journalURL)
                        }
                    }
                } else if isValidEncryptedBlob(stagedURL, item: authenticatedItem, rawKey: rawKey) {
                    try? removeOwnedFile(stagedURL)
                    try? removeOwnedFile(journalURL)
                }
            }
        }
    }

    private func loadValidatedTransactions(
        authenticatedItems: [UUID: PrivateSafeItem]
    ) -> [RecoveredTransaction] {
        guard let entries = safeDirectoryEntries(at: transactions) else { return [] }
        return entries.compactMap { url in
            guard url.pathExtension == "json",
                  !isSymbolicLink(url),
                  url.lastPathComponent != "manifest.json",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size <= PrivateSafeCrypto.maximumTransactionBytes,
                  let data = try? Data(contentsOf: url),
                  let transaction = try? JSONDecoder().decode(PrivateSafeTransaction.self, from: data),
                  url.lastPathComponent == "\(transaction.operationID.uuidString).json",
                  validTransaction(transaction)
            else { return nil }
            let expectedBlobName = "\(transaction.itemID.uuidString).safe"
            let isBound = authenticatedItems[transaction.itemID]?.blobName == expectedBlobName
            return RecoveredTransaction(
                transaction: transaction,
                url: url,
                isBoundToAuthenticatedItem: isBound
            )
        }
    }

    private func validTransaction(_ transaction: PrivateSafeTransaction) -> Bool {
        let final = blobs.appendingPathComponent("\(transaction.itemID.uuidString).safe")
        guard transaction.finalBlobPath == final.path else { return false }
        switch transaction.kind {
        case .add:
            return transaction.operationID == transaction.itemID &&
                transaction.pendingPath == pending.appendingPathComponent("add-\(transaction.itemID.uuidString).blob").path &&
                transaction.stagedBlobPath == nil
        case .delete:
            return transaction.pendingPath == nil &&
                transaction.stagedBlobPath == transactions.appendingPathComponent("delete-\(transaction.operationID.uuidString).blob").path
        }
    }

    private func transactionsURL(for transaction: PrivateSafeTransaction) -> URL {
        transactions.appendingPathComponent("delete-\(transaction.operationID.uuidString).blob")
    }

    private func commitManifest(_ manifest: PrivateSafeManifest, rawKey: Data) throws {
        let data = try PrivateSafeCrypto.sealManifest(manifest, rawKey: rawKey)
        guard !isSymbolicLink(pendingManifestURL), !isSymbolicLink(manifestURL) else {
            throw PrivateSafeError.corruptManifest
        }
        try writeData(data, to: pendingManifestURL)
        try protect(pendingManifestURL)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try? removeOwnedFile(previousManifestURL)
            try fileManager.copyItem(at: manifestURL, to: previousManifestURL)
            try protect(previousManifestURL)
            _ = try fileManager.replaceItemAt(manifestURL, withItemAt: pendingManifestURL)
        } else {
            try fileManager.moveItem(at: pendingManifestURL, to: manifestURL)
        }
        try protect(manifestURL)
    }

    private func makeDirectories() throws {
        guard rootStorageIsSafe else {
            throw PrivateSafeError.operationFailed("Private Safe storage path is unsafe.")
        }
        for directory in [root, blobs, transactions, pending] {
            try ensureDirectory(directory)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw PrivateSafeError.operationFailed("Private Safe storage path is not a directory.") }
        } else {
            guard !hasSymbolicLinkInPath(url.deletingLastPathComponent()) else {
                throw PrivateSafeError.operationFailed("Private Safe storage path is unsafe.")
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            guard !hasSymbolicLinkInPath(url) else {
                throw PrivateSafeError.operationFailed("Private Safe storage path is unsafe.")
            }
        }
        try protect(url)
    }

    private func writeTransaction(_ transaction: PrivateSafeTransaction, to url: URL) throws {
        let data = try JSONEncoder().encode(transaction)
        guard !isSymbolicLink(url) else { throw PrivateSafeError.operationFailed("Transaction path is unsafe.") }
        try writeData(data, to: url)
        try protect(url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        guard !hasSymbolicLinkInPath(url) else { throw PrivateSafeError.operationFailed("Storage path is unsafe.") }
        try data.write(to: url, options: .atomic)
    }

    private func createExclusiveFile(at url: URL) throws -> FileHandle {
        guard !hasSymbolicLinkInPath(url),
              !fileManager.fileExists(atPath: url.path)
        else { throw PrivateSafeError.itemAlreadyExists }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PrivateSafeError.operationFailed("Private Safe could not create its protected file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try protect(url)
            return handle
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private func protect(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func encrypt(
        source: URL,
        to destination: URL,
        itemID: UUID,
        rawKey: Data,
        created: inout Bool
    ) throws -> Int64 {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        let sourceSize = UInt64(values.fileSize ?? 0)
        let key = PrivateSafeCrypto.deriveItemKey(rawKey: rawKey, itemID: itemID)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try createExclusiveFile(at: destination)
        created = true
        defer { try? output.close() }
        try output.write(contentsOf: PrivateSafeCrypto.header(for: itemID, originalSize: sourceSize))
        var index: UInt64 = 0
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: PrivateSafeCrypto.chunkSize), !bytes.isEmpty else { break }
            let plainLength = UInt32(bytes.count)
            let sealed = try AES.GCM.seal(
                bytes,
                using: key,
                authenticating: PrivateSafeCrypto.chunkAAD(itemID: itemID, index: index, plainLength: plainLength)
            )
            guard let combined = sealed.combined, combined.count <= Int(UInt32.max) else {
                throw PrivateSafeError.operationFailed("The encrypted chunk is too large.")
            }
            var record = Data()
            PrivateSafeCrypto.appendUInt64(index, to: &record)
            PrivateSafeCrypto.appendUInt32(plainLength, to: &record)
            PrivateSafeCrypto.appendUInt32(UInt32(combined.count), to: &record)
            record.append(combined)
            try output.write(contentsOf: record)
            index += 1
            total += Int64(bytes.count)
        }
        guard UInt64(total) == sourceSize else { throw PrivateSafeError.sourceChanged }
        return total
    }

    private func decrypt(blob: URL, item: PrivateSafeItem, rawKey: Data, to destination: URL) throws {
        guard isRegularFile(blob) else { throw PrivateSafeError.corruptBlob }
        let input = try FileHandle(forReadingFrom: blob)
        defer { try? input.close() }
        let headerLength = PrivateSafeCrypto.magic.count + 1 + 16 + 4 + 8
        guard let headerData = try readExact(input, count: headerLength) else {
            throw PrivateSafeError.corruptBlob
        }
        let header = try PrivateSafeCrypto.parseHeader(headerData)
        guard header.itemID == item.id else { throw PrivateSafeError.corruptBlob }
        let key = PrivateSafeCrypto.deriveItemKey(rawKey: rawKey, itemID: item.id)
        var expectedIndex: UInt64 = 0
        var total: Int64 = 0
        let output = try createExclusiveFile(at: destination)
        defer { try? output.close() }

        while true {
            try Task.checkCancellation()
            guard let recordHeader = try readExact(input, count: 16, allowEOF: true) else { break }
            var offset = 0
            let index = try PrivateSafeCrypto.readUInt64(recordHeader, offset: &offset)
            let plainLength = try PrivateSafeCrypto.readUInt32(recordHeader, offset: &offset)
            let sealedLength = try PrivateSafeCrypto.readUInt32(recordHeader, offset: &offset)
            guard index == expectedIndex,
                  plainLength > 0,
                  plainLength <= UInt32(PrivateSafeCrypto.chunkSize),
                  sealedLength >= plainLength,
                  sealedLength <= plainLength + 64
            else { throw PrivateSafeError.corruptBlob }
            guard let combined = try readExact(input, count: Int(sealedLength)) else {
                throw PrivateSafeError.corruptBlob
            }
            guard let box = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(
                    box,
                    using: key,
                    authenticating: PrivateSafeCrypto.chunkAAD(itemID: item.id, index: index, plainLength: plainLength)
                  ),
                  plain.count == Int(plainLength)
            else { throw PrivateSafeError.corruptBlob }
            try output.write(contentsOf: plain)
            expectedIndex += 1
            total += Int64(plain.count)
        }
        guard UInt64(total) == header.originalSize,
              total == item.byteCount
        else { throw PrivateSafeError.corruptBlob }
    }

    /// Recovery uses the same AEAD checks as decryption before it moves or
    /// removes a transaction payload. A filename and journal UUID alone never
    /// authorize a destructive operation.
    private func isValidEncryptedBlob(
        _ blob: URL,
        item: PrivateSafeItem,
        rawKey: Data
    ) -> Bool {
        guard isRegularFile(blob) else { return false }
        do {
            let input = try FileHandle(forReadingFrom: blob)
            defer { try? input.close() }
            let headerLength = PrivateSafeCrypto.magic.count + 1 + 16 + 4 + 8
            guard let headerData = try readExact(input, count: headerLength) else { return false }
            let header = try PrivateSafeCrypto.parseHeader(headerData)
            guard header.itemID == item.id,
                  header.originalSize == UInt64(item.byteCount) else { return false }
            let key = PrivateSafeCrypto.deriveItemKey(rawKey: rawKey, itemID: item.id)
            var expectedIndex: UInt64 = 0
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let recordHeader = try readExact(input, count: 16, allowEOF: true) else { break }
                var offset = 0
                let index = try PrivateSafeCrypto.readUInt64(recordHeader, offset: &offset)
                let plainLength = try PrivateSafeCrypto.readUInt32(recordHeader, offset: &offset)
                let sealedLength = try PrivateSafeCrypto.readUInt32(recordHeader, offset: &offset)
                guard index == expectedIndex,
                      plainLength > 0,
                      plainLength <= UInt32(PrivateSafeCrypto.chunkSize),
                      sealedLength >= plainLength,
                      sealedLength <= plainLength + 64,
                      let combined = try readExact(input, count: Int(sealedLength)),
                      let box = try? AES.GCM.SealedBox(combined: combined),
                      let plain = try? AES.GCM.open(
                        box,
                        using: key,
                        authenticating: PrivateSafeCrypto.chunkAAD(
                            itemID: item.id,
                            index: index,
                            plainLength: plainLength
                        )
                      ),
                      plain.count == Int(plainLength)
                else { return false }
                expectedIndex += 1
                total += Int64(plain.count)
            }
            return UInt64(total) == header.originalSize && total == item.byteCount
        } catch {
            return false
        }
    }

    private func readExact(_ handle: FileHandle, count: Int, allowEOF: Bool = false) throws -> Data? {
        guard count > 0 else { return Data() }
        guard let data = try handle.read(upToCount: count) else {
            if allowEOF { return nil }
            throw PrivateSafeError.corruptBlob
        }
        if data.isEmpty, allowEOF { return nil }
        guard data.count == count else { throw PrivateSafeError.corruptBlob }
        return data
    }

    private func cleanupUncommittedAdd(
        _ transaction: PrivateSafeTransaction,
        operationURL: URL,
        pendingCreated: Bool,
        finalMoved: Bool
    ) {
        guard transaction.stage != .manifestCommitted else { return }
        guard validTransaction(transaction), transaction.operationID == transaction.itemID else { return }
        let pendingURL = pending.appendingPathComponent("add-\(transaction.itemID.uuidString).blob")
        let finalURL = blobs.appendingPathComponent("\(transaction.itemID.uuidString).safe")
        if pendingCreated { try? removeOwnedFile(pendingURL) }
        if finalMoved { try? removeOwnedFile(finalURL) }
        try? removeOwnedFile(operationURL)
    }

    private func restoreDeleteIfNeeded(_ transaction: PrivateSafeTransaction, stagedMoved: Bool) {
        guard transaction.stage != .manifestCommitted,
              stagedMoved,
              validTransaction(transaction),
              transaction.kind == .delete else { return }
        let staged = transactions.appendingPathComponent("delete-\(transaction.operationID.uuidString).blob")
        let final = blobs.appendingPathComponent("\(transaction.itemID.uuidString).safe")
        if isRegularFile(staged), !fileManager.fileExists(atPath: final.path) {
            try? moveNewFile(staged, to: final)
        }
    }

    private func moveNewFile(_ source: URL, to destination: URL) throws {
        guard isOwnedRegularOrMissing(source),
              !fileManager.fileExists(atPath: destination.path)
        else { throw PrivateSafeError.itemAlreadyExists }
        try ensureDirectory(destination.deletingLastPathComponent())
        try fileManager.moveItem(at: source, to: destination)
        // A rename can drop file protection and backup attributes. Apply them
        // only after the move, while preserving the moved bytes if this
        // post-rename step fails so recovery can authenticate them later.
        try protect(destination)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard !hasSymbolicLinkInPath(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        else { return false }
        return values.isRegularFile == true
    }

    private func isOwnedRegularOrMissing(_ url: URL) -> Bool {
        if !fileManager.fileExists(atPath: url.path) { return true }
        return isRegularFile(url)
    }

    private func isTemporaryDestination(_ url: URL, kind: PrivateSafeTemporaryKind) -> Bool {
        guard cacheStorageIsSafe else { return false }
        guard kind != .any else { return isTemporaryURL(url) }
        let base = (kind == .view ? views : exports).standardizedFileURL.path
        let marker = url.standardizedFileURL.deletingLastPathComponent().lastPathComponent
        return isPath(url, under: base) &&
            !hasSymbolicLinkInPath(url) &&
            Self.isPlaintextMarker(marker)
    }

    private func isTemporaryURL(_ url: URL) -> Bool {
        guard cacheStorageIsSafe else { return false }
        let standardized = url.standardizedFileURL
        let marker = standardized.deletingLastPathComponent().lastPathComponent
        guard Self.isPlaintextMarker(marker),
              !hasSymbolicLinkInPath(standardized)
        else { return false }
        return isPath(standardized, under: views.standardizedFileURL.path) ||
            isPath(standardized, under: exports.standardizedFileURL.path)
    }

    private func isPath(_ url: URL, under base: String) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }

    private func removeOwnedFile(_ url: URL) throws {
        guard rootStorageIsSafe,
              isPath(url, under: root.standardizedFileURL.path),
              url.standardizedFileURL.path != root.standardizedFileURL.path,
              !hasSymbolicLinkInPath(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return }
        try fileManager.removeItem(at: url)
    }

    private func removeTemporaryFile(_ url: URL) throws {
        guard cacheStorageIsSafe,
              isTemporaryURL(url),
              !hasSymbolicLinkInPath(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return }
        try fileManager.removeItem(at: url)
    }

    private func removeOwnedDirectory(_ url: URL) throws {
        guard cacheStorageIsSafe,
              isPath(url, under: cacheRoot.standardizedFileURL.path),
              Self.isPlaintextMarker(url.lastPathComponent),
              !hasSymbolicLinkInPath(url),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }
        try fileManager.removeItem(at: url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        hasSymbolicLinkInPath(url)
    }

    private var rootStorageIsSafe: Bool {
        !rootWasSymlink && !Self.hasSymbolicLinkInPathStatic(rawRoot, fileManager: fileManager)
    }

    private var cacheStorageIsSafe: Bool {
        !cacheRootWasSymlink && !Self.hasSymbolicLinkInPathStatic(rawCacheRoot, fileManager: fileManager)
    }

    /// `URL.resourceValues` only answers for the final component. Every
    /// destructive/read path is checked component by component so a hostile
    /// directory symlink cannot redirect a vault operation outside its root.
    private func hasSymbolicLinkInPath(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if Self.isSymbolicLinkStatic(current, fileManager: fileManager),
               !Self.isAllowedSystemAlias(current.path) {
                return true
            }
            if !fileManager.fileExists(atPath: current.path) {
                break
            }
        }
        return false
    }

    private static func isAllowedSystemAlias(_ path: String) -> Bool {
        path == "/var" || path == "/tmp"
    }

    private static func hasSymbolicLinkInPathStatic(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if isSymbolicLinkStatic(current, fileManager: fileManager),
               !isAllowedSystemAlias(current.path) {
                return true
            }
            if !fileManager.fileExists(atPath: current.path) {
                break
            }
        }
        return false
    }

    private static func isPlaintextMarker(_ name: String) -> Bool {
        guard name.hasPrefix("plaintext-") else { return false }
        let suffix = String(name.dropFirst("plaintext-".count))
        guard let id = UUID(uuidString: suffix) else { return false }
        return id.uuidString == suffix.uppercased()
    }

    private func safeDirectoryEntries(at url: URL) -> [URL]? {
        guard !hasSymbolicLinkInPath(url),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
    }

    private static func isSymbolicLinkStatic(_ url: URL, fileManager: FileManager = .default) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

}

enum PrivateSafeTemporaryKind: Sendable, Equatable {
    case view
    case export
    case any
}
