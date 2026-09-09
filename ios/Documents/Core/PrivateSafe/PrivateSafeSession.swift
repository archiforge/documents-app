import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

enum PrivateSafeSceneActivation: Equatable, Sendable {
    case active
    case inactive
    case background
}

struct PrivateSafeSceneSnapshot: Equatable, Sendable {
    let id: String
    let activation: PrivateSafeSceneActivation
}

/// Main-actor boundary for the local Private Safe. The session owns the key
/// lifetime and delegates all file work to the actor-owned store.
@MainActor
@Observable
final class PrivateSafeSession {
    enum State: Equatable, Sendable {
        case locked
        case unlocking
        case unlocked
        case unavailable(String)
    }

    let store: PrivateSafeStore
    private let keychain: any PrivateSafeKeychainClient

    private(set) var state: State = .locked
    private(set) var items: [PrivateSafeItem] = []
    private(set) var errorMessage: String?
    private(set) var isPrivacyCovered = false

    private var rawKey: Data?
    private var authenticationContext: LAContext?
    private var sessionGeneration = UUID()
    private var scenePhases: [String: ScenePhase] = [:]
    private var disconnectedSceneIDs: Set<String> = []
    private let sceneSnapshotProvider: @MainActor () -> [PrivateSafeSceneSnapshot]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var plaintextURLs: Set<URL> = []
    private var destructiveResetInProgress = false
    private let notificationLifetime = PrivateSafeNotificationLifetime()

    init(
        store: PrivateSafeStore = PrivateSafeStore(),
        keychain: any PrivateSafeKeychainClient = PrivateSafeKeychain(),
        sceneSnapshot: @escaping @MainActor () -> [PrivateSafeSceneSnapshot] = {
            PrivateSafeSession.defaultSceneSnapshot()
        }
    ) {
        self.store = store
        self.keychain = keychain
        self.sceneSnapshotProvider = sceneSnapshot
        observeProtectedData()
        observeSceneBackgrounding()
    }

    var isUnlocked: Bool {
        if case .unlocked = state { return true }
        return false
    }

    /// Launch hook for DocumentsApp. It is safe to call before the first
    /// unlock and removes only explicitly marked plaintext cache entries.
    nonisolated static func sweepPlaintextCachesAtLaunch() {
        PrivateSafeStore.sweepPlaintextCaches()
    }

    static func defaultSceneSnapshot() -> [PrivateSafeSceneSnapshot] {
        UIApplication.shared.connectedScenes.compactMap { scene in
            let activation: PrivateSafeSceneActivation?
            switch scene.activationState {
            case .foregroundActive:
                activation = .active
            case .foregroundInactive:
                activation = .inactive
            case .background:
                activation = .background
            case .unattached:
                activation = nil
            @unknown default:
                activation = nil
            }
            guard let activation else { return nil }
            return PrivateSafeSceneSnapshot(
                id: scene.session.persistentIdentifier,
                activation: activation
            )
        }
    }

    func unlock() async {
        guard !destructiveResetInProgress, !isUnlocked, state != .unlocking else { return }
        state = .unlocking
        errorMessage = nil
        let generation = UUID()
        sessionGeneration = generation
        rawKey = nil
        items = []
        let context = LAContext()
        context.localizedReason = "Unlock Private Safe"
        // Publish the fresh context before Keychain can begin an auth prompt;
        // lock() can then invalidate this exact attempt immediately.
        authenticationContext?.invalidate()
        authenticationContext = context
        do {
            try Task.checkCancellation()
            let key: Data
            if let existing = try await keychainRead(context) {
                key = existing
            } else {
                guard !(await store.hasEncryptedState()) else {
                    throw PrivateSafeError.keyUnavailable
                }
                try checkUnlockLease(generation)
                _ = try await keychainCreate()
                try checkUnlockLease(generation)
                guard let authenticated = try await keychainRead(context) else {
                    throw PrivateSafeError.keyUnavailable
                }
                key = authenticated
            }
            try checkUnlockLease(generation)
            let loadedItems = try await listItems(rawKey: key)
            try checkUnlockLease(generation)
            rawKey = key
            items = loadedItems
            state = .unlocked
        } catch {
            guard sessionGeneration == generation, state == .unlocking else { return }
            rawKey = nil
            context.invalidate()
            authenticationContext = nil
            let mapped = map(error)
            // A synchronous Keychain implementation may report its own
            // cancellation/authentication status after LAContext.invalidate.
            // The task's cancellation flag is the authoritative result for a
            // sheet or scene that explicitly cancelled this unlock attempt.
            if error is CancellationError || Task.isCancelled {
                state = .locked
                errorMessage = nil
            } else {
                state = .unavailable(mapped.localizedDescription)
                errorMessage = mapped.localizedDescription
            }
        }
    }

    /// Locks the session after cancelling and awaiting all registered work.
    /// Callers should await this on actual background/protected-data events.
    func lock() async {
        await quiesce(nextState: nil)
    }

    /// Clears all authenticated state immediately, then waits for cooperative
    /// child work to finish before a caller mutates or removes vault files.
    private func quiesce(nextState: State?) async {
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        operations.removeAll()
        let temporary = Array(plaintextURLs)
        plaintextURLs.removeAll()
        rawKey = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
        items = []
        sessionGeneration = UUID()
        if let nextState {
            state = nextState
            errorMessage = nil
        } else if case .unavailable = state {
            // Keep an unavailable explanation while still clearing all
            // authenticated state. A later explicit unlock can retry.
        } else {
            state = .locked
            errorMessage = nil
        }
        // The generation and key are cleared before awaiting cancellation;
        // late workers therefore cannot publish into this session.
        for operation in pending { await operation.value }
        await store.removeTemporaryFiles(temporary)
    }

    func refresh() async throws {
        let (key, generation) = try lease()
        let loaded = try await listItems(rawKey: key)
        try checkLease(generation)
        items = loaded
    }

    func addCopy(
        from sourceURL: URL,
        displayName: String? = nil,
        sourceRecordID: UUID? = nil
    ) async throws -> PrivateSafeItem {
        let (key, generation) = try lease()
        let operationID = UUID()
        let worker = Task.detached(priority: .userInitiated) { [store] in
            try await store.addCopy(
                from: sourceURL,
                displayName: displayName,
                sourceRecordID: sourceRecordID,
                rawKey: key
            )
        }
        operations[operationID] = tracker(for: worker)
        defer { operations.removeValue(forKey: operationID) }
        do {
            let item = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try checkLease(generation)
            let loaded = try await listItems(rawKey: key)
            try checkLease(generation)
            items = loaded
            return item
        } catch {
            throw map(error)
        }
    }

    func delete(itemID: UUID) async throws {
        let (key, generation) = try lease()
        let operationID = UUID()
        let worker = Task.detached(priority: .userInitiated) { [store] in
            try await store.delete(id: itemID, rawKey: key)
        }
        operations[operationID] = tracker(for: worker)
        defer { operations.removeValue(forKey: operationID) }
        do {
            try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try checkLease(generation)
            let loaded = try await listItems(rawKey: key)
            try checkLease(generation)
            items = loaded
        } catch {
            throw map(error)
        }
    }

    /// Creates a protected plaintext export URL. The caller must eventually
    /// call `releaseTemporaryFile`; lock also removes every tracked URL.
    func export(itemID: UUID) async throws -> URL {
        try await makePlaintextLease(itemID: itemID, kind: .export)
    }

    /// Creates a short-lived local preview file. The preview surface owns the
    /// lease and has no share/export toolbar, so plaintext cannot bypass the
    /// explicit export warning.
    func preview(itemID: UUID) async throws -> URL {
        try await makePlaintextLease(itemID: itemID, kind: .view)
    }

    private func makePlaintextLease(
        itemID: UUID,
        kind: PrivateSafeTemporaryKind
    ) async throws -> URL {
        let (key, generation) = try lease()
        let item = items.first(where: { $0.id == itemID })
        let fileName = item?.displayName ?? "PrivateSafe-\(itemID.uuidString)"
        var destination: URL?
        do {
            let allocated = try await store.makeTemporaryURL(fileName: fileName, kind: kind)
            destination = allocated
            try checkLease(generation)
            let worker = Task.detached(priority: .userInitiated) { [store] in
                try await store.decryptItem(id: itemID, rawKey: key, destination: allocated, kind: kind)
            }
            let operationID = UUID()
            operations[operationID] = tracker(for: worker)
            defer { operations.removeValue(forKey: operationID) }
            let result = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try checkLease(generation)
            plaintextURLs.insert(result)
            return result
        } catch {
            if let destination {
                await store.removeTemporaryFiles([destination])
            }
            throw map(error)
        }
    }

    func releaseTemporaryFile(_ url: URL) async {
        plaintextURLs.remove(url)
        await store.removeTemporaryFiles([url])
    }

    /// Destructive reset used only by settings after an explicit confirmation.
    func resetVault() async throws {
        guard isUnlocked else { throw PrivateSafeError.locked }
        guard !destructiveResetInProgress else { throw PrivateSafeError.locked }
        destructiveResetInProgress = true
        defer { destructiveResetInProgress = false }
        // Quiesce before touching either the vault or its key. This clears
        // the in-memory key and invalidates authentication even when reset
        // itself or Keychain deletion later fails.
        await quiesce(nextState: .locked)
        do {
            try await store.reset()
            try keychain.delete()
        } catch {
            throw map(error)
        }
    }

    /// Explicitly destructive recovery for an unavailable/corrupt vault. It
    /// is intentionally unavailable while authenticated so normal settings
    /// flows cannot silently erase encrypted copies.
    func resetUnavailableVault() async throws {
        guard case .unavailable(let message) = state else { throw PrivateSafeError.locked }
        guard !destructiveResetInProgress else { throw PrivateSafeError.locked }
        destructiveResetInProgress = true
        defer { destructiveResetInProgress = false }
        await quiesce(nextState: .unavailable(message))
        do {
            try await store.reset()
            try keychain.delete()
            state = .locked
            errorMessage = nil
        } catch {
            // Keep the unavailable state so the user can retry a destructive
            // reset without ever retaining an authenticated key or index.
            throw map(error)
        }
    }

    /// Root integration hook. An inactive scene only covers Safe content;
    /// actual backgrounding locks once every connected scene is backgrounded.
    func sceneDidChange(_ phase: ScenePhase, sceneID: String = "main") {
        // Keep this hook useful for SwiftUI callers that report their scene
        // transition before UIKit has updated activationState. Once UIKit has
        // a connected scene snapshot, that snapshot is authoritative so a
        // stale sceneID entry cannot keep the vault unlocked.
        scenePhases[sceneID] = phase
        disconnectedSceneIDs.remove(sceneID)
        updatePrivacyCover(forceInactive: phase == .inactive)
        guard phase == .background else { return }
        guard allScenesAreBackground else { return }
        Task { await lock() }
    }

    func protectedDataBecameUnavailable() {
        isPrivacyCovered = true
        Task { await lock() }
    }

    func protectedDataBecameAvailable() {
        // Protected data can become available while a scene remains inactive
        // or backgrounded. Recompute from the aggregate scene snapshot so a
        // prior cover does not remain stuck after the next activation.
        updatePrivacyCover()
    }

    private func lease() throws -> (Data, UUID) {
        guard isUnlocked, let rawKey else { throw PrivateSafeError.locked }
        return (rawKey, sessionGeneration)
    }

    private func checkUnlockLease(_ generation: UUID) throws {
        guard generation == sessionGeneration, state == .unlocking else {
            throw PrivateSafeError.locked
        }
        try Task.checkCancellation()
    }

    private func checkLease(_ generation: UUID) throws {
        guard isUnlocked, generation == sessionGeneration else { throw PrivateSafeError.locked }
        try Task.checkCancellation()
    }

    private func tracker<T: Sendable>(for worker: Task<T, Error>) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler(operation: {
                _ = try? await worker.value
            }, onCancel: {
                worker.cancel()
            })
        }
    }

    /// Await a detached child through the same lifecycle registry used by
    /// add/delete/decrypt. Lock can therefore cancel and await authentication
    /// and index work before a reset or other destructive transition.
    private func trackedValue<T: Sendable>(
        _ worker: Task<T, Error>,
        onCancel: (@Sendable () -> Void)? = nil
    ) async throws -> T {
        let operationID = UUID()
        operations[operationID] = tracker(for: worker)
        defer { operations.removeValue(forKey: operationID) }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            onCancel?()
            worker.cancel()
        })
    }

    private func listItems(rawKey: Data) async throws -> [PrivateSafeItem] {
        let worker = Task.detached(priority: .userInitiated) { [store] in
            try await store.listItems(rawKey: rawKey)
        }
        return try await trackedValue(worker)
    }

    private func keychainRead(_ context: LAContext) async throws -> Data? {
        let box = PrivateSafeKeychainCallBox(client: keychain, context: context)
        let worker: Task<Data?, Error> = Task.detached(priority: .userInitiated) {
            try box.client.read(context: box.context)
        }
        return try await trackedValue(worker, onCancel: {
            box.context?.invalidate()
        })
    }

    private func keychainCreate() async throws -> Data {
        let box = PrivateSafeKeychainCallBox(client: keychain, context: nil)
        let worker: Task<Data, Error> = Task.detached(priority: .userInitiated) {
            try box.client.create()
        }
        return try await trackedValue(worker)
    }

    private func map(_ error: Error) -> PrivateSafeError {
        if let error = error as? PrivateSafeError { return error }
        if error is CancellationError { return .locked }
        if let keyError = error as? PrivateSafeKeychainError {
            switch keyError {
            case .status(let status):
                return .authenticationUnavailable("Private Safe authentication failed (status \(status)).")
            case .accessControlUnavailable:
                return .authenticationUnavailable("This device cannot protect Private Safe with a passcode.")
            }
        }
        return .operationFailed(error.localizedDescription)
    }

    private func observeProtectedData() {
        let center = NotificationCenter.default
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.protectedDataBecameUnavailable() }
        })
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.protectedDataBecameAvailable() }
        })
    }

    private func observeSceneBackgrounding() {
        let center = NotificationCenter.default
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let scene = notification.object as? UIScene
            Task { @MainActor in
                let id = scene?.session.persistentIdentifier
                guard let self, let id else { return }
                self.disconnectedSceneIDs.remove(id)
                self.scenePhases[id] = .inactive
                self.updatePrivacyCover(forceInactive: true)
            }
        })
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let scene = notification.object as? UIScene
            Task { @MainActor in
                guard let self else { return }
                let id = scene?.session.persistentIdentifier
                if let id {
                    self.disconnectedSceneIDs.remove(id)
                    self.scenePhases[id] = .background
                }
                self.updatePrivacyCover()
                if self.allScenesAreBackground {
                    await self.lock()
                }
            }
        })
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let scene = notification.object as? UIScene
            Task { @MainActor in
                guard let self else { return }
                let id = scene?.session.persistentIdentifier
                if let id {
                    self.disconnectedSceneIDs.remove(id)
                    self.scenePhases[id] = .active
                }
                self.updatePrivacyCover()
            }
        })
        notificationLifetime.tokens.append(center.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let scene = notification.object as? UIScene
            Task { @MainActor in
                let id = scene?.session.persistentIdentifier
                guard let self, let id else { return }
                self.scenePhases.removeValue(forKey: id)
                self.disconnectedSceneIDs.insert(id)
                self.updatePrivacyCover()
                if self.sceneSnapshots().isEmpty {
                    await self.lock()
                }
            }
        })
    }

    private func sceneSnapshots() -> [PrivateSafeSceneSnapshot] {
        let reported = sceneSnapshotProvider()
        // A test seam may intentionally provide an empty snapshot while
        // driving sceneDidChange callbacks. In production a nonempty UIKit
        // snapshot is authoritative; never infer that an arbitrary callback
        // ID is synthetic because stale IDs could otherwise override a real
        // connected-scene state.
        if reported.isEmpty {
            return scenePhases.compactMap { id, phase in
                guard !disconnectedSceneIDs.contains(id) else { return nil }
                let activation: PrivateSafeSceneActivation
                switch phase {
                case .active: activation = .active
                case .inactive: activation = .inactive
                case .background: activation = .background
                @unknown default: return nil
                }
                return PrivateSafeSceneSnapshot(id: id, activation: activation)
            }
        }
        var snapshots = Dictionary(uniqueKeysWithValues: reported.map { ($0.id, $0) })
        for (id, phase) in scenePhases where snapshots[id] != nil {
            let activation: PrivateSafeSceneActivation
            switch phase {
            case .active: activation = .active
            case .inactive: activation = .inactive
            case .background: activation = .background
            @unknown default: continue
            }
            snapshots[id] = PrivateSafeSceneSnapshot(id: id, activation: activation)
        }
        return snapshots.values.filter { !disconnectedSceneIDs.contains($0.id) }
    }

    private func updatePrivacyCover(forceInactive: Bool = false) {
        let snapshots = sceneSnapshots()
        guard !snapshots.isEmpty else {
            isPrivacyCovered = forceInactive
            return
        }
        let hasActiveScene = snapshots.contains { $0.activation == .active }
        let hasInactiveScene = snapshots.contains { $0.activation == .inactive }
        let allBackground = snapshots.allSatisfy { $0.activation == .background }
        // A foreground-inactive scene indicates a system sheet or transition
        // over Safe, so cover immediately. Background-only windows do not
        // cover an active window; they only participate in auto-locking.
        isPrivacyCovered = forceInactive || hasInactiveScene || (!hasActiveScene && allBackground)
    }

    private var allScenesAreBackground: Bool {
        let snapshots = sceneSnapshots()
        return !snapshots.isEmpty && snapshots.allSatisfy { $0.activation == .background }
    }

}

private final class PrivateSafeKeychainCallBox: @unchecked Sendable {
    let client: any PrivateSafeKeychainClient
    let context: LAContext?

    init(client: any PrivateSafeKeychainClient, context: LAContext?) {
        self.client = client
        self.context = context
    }
}

private final class PrivateSafeNotificationLifetime: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
