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
    /// Committed authorisation records older than this are dropped on the next write so the
    /// ledger does not grow without bound over the lifetime of a "lifetime purchase" install.
    /// This is deliberately much longer than the 24-hour job-cleanup window in
    /// `FileJobRepository` so a legitimately delayed resume can never be double-charged.
    private static let authorisationRetention: TimeInterval = 90 * 24 * 60 * 60

    private let store: LedgerDataStore
    private let now: @Sendable () -> Date
    private var state: LedgerState?

    public init(
        store: LedgerDataStore = KeychainLedgerDataStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
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
            consumesFreeExport: !unlimited,
            issuedAt: now()
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
        let bounded = pruned(newState, now: now())
        try store.write(ISO8601Milliseconds.encoder().encode(bounded))
        state = bounded
    }

    private func pruned(_ ledgerState: LedgerState, now: Date) -> LedgerState {
        let cutoff = now.addingTimeInterval(-Self.authorisationRetention)
        let expiredIDs = ledgerState.authorisations.values
            .filter { $0.issuedAt < cutoff }
            .map(\.id)
        guard !expiredIDs.isEmpty else { return ledgerState }
        var next = ledgerState
        for id in expiredIDs {
            next.authorisations.removeValue(forKey: id)
            next.committedAuthorisationIDs.remove(id)
        }
        return next
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
