import Foundation
import Security

public protocol LedgerDataStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

public final class KeychainLedgerDataStore: LedgerDataStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.worksbien.printmae.entitlements",
        account: String = "free-export-ledger-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError(.persistenceFailed, retryable: false)
        }
        return data
    }

    public func write(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError(.persistenceFailed, retryable: false) }
    }
}

public final class MemoryLedgerDataStore: LedgerDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func read() -> Data? { lock.withLock { data } }
    public func write(_ data: Data) { lock.withLock { self.data = data } }
}

private struct LedgerState: Codable, Sendable {
    var status: EntitlementStatus = .free
    var remaining: Int = 3
    var lifetimeTransactionID: String?
    var authorisations: [UUID: ExportAuthorisation] = [:]
    var committedAuthorisationIDs: Set<UUID> = []
    var checkedAt: Date = Date()
}

public actor FreeExportEntitlementLedger: EntitlementProviding {
    private let store: LedgerDataStore
    private var state: LedgerState?

    public init(store: LedgerDataStore = KeychainLedgerDataStore()) {
        self.store = store
    }

    public func snapshot() async -> EntitlementSnapshot {
        do {
            let current = try load()
            return EntitlementSnapshot(
                status: current.status,
                freeExportsRemaining: current.remaining,
                lifetimeTransactionID: current.lifetimeTransactionID,
                checkedAt: current.checkedAt
            )
        } catch {
            return EntitlementSnapshot(status: .unknownOffline, freeExportsRemaining: 0)
        }
    }

    public func authoriseExport(request: ExportRequestKey) async throws -> ExportAuthorisation {
        var current = try load()
        if let existing = current.authorisations.values.first(where: { $0.request == request }) {
            return existing
        }
        let unlimited = current.status == .lifetimeVerified
        guard unlimited || current.remaining > 0 else {
            throw AppError(.entitlementRequired, retryable: false)
        }
        let authorisation = ExportAuthorisation(
            request: request,
            consumesFreeExport: !unlimited
        )
        current.authorisations[authorisation.id] = authorisation
        try persist(current)
        return authorisation
    }

    public func commitVerifiedExport(_ authorisation: ExportAuthorisation) async throws {
        var current = try load()
        guard current.authorisations[authorisation.id] == authorisation else {
            throw AppError(.entitlementRequired, retryable: false)
        }
        if current.committedAuthorisationIDs.contains(authorisation.id) { return }
        if authorisation.consumesFreeExport && current.status != .lifetimeVerified {
            guard current.remaining > 0 else { throw AppError(.entitlementRequired, retryable: false) }
            current.remaining -= 1
        }
        current.committedAuthorisationIDs.insert(authorisation.id)
        current.checkedAt = Date()
        try persist(current)
    }

    public func installStoreSnapshot(_ snapshot: EntitlementSnapshot) async throws {
        var current = try load()
        switch snapshot.status {
        case .lifetimeVerified:
            current.status = .lifetimeVerified
            current.lifetimeTransactionID = snapshot.lifetimeTransactionID
        case .refundedOrRevoked:
            current.status = .refundedOrRevoked
            current.lifetimeTransactionID = nil
        case .unknownOffline, .storeUnavailable:
            if current.status != .lifetimeVerified { current.status = snapshot.status }
        case .purchasePending, .purchaseCancelled, .purchaseFailed:
            if current.status != .lifetimeVerified { current.status = snapshot.status }
        case .free:
            if current.status != .lifetimeVerified { current.status = .free }
        }
        current.checkedAt = snapshot.checkedAt
        try persist(current)
    }

    private func load() throws -> LedgerState {
        if let state { return state }
        let loaded: LedgerState
        if let data = try store.read() {
            loaded = try ISO8601Milliseconds.decoder().decode(LedgerState.self, from: data)
        } else {
            loaded = LedgerState()
        }
        state = loaded
        return loaded
    }

    private func persist(_ newState: LedgerState) throws {
        try store.write(ISO8601Milliseconds.encoder().encode(newState))
        state = newState
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
