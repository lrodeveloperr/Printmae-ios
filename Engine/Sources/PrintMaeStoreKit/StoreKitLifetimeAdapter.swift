import Foundation
import StoreKit
import PrintMaeEngine

public struct LifetimeProductDisplay: Sendable, Hashable {
    public let productID: String
    public let displayName: String
    public let displayPrice: String

    public init(productID: String, displayName: String, displayPrice: String) {
        self.productID = productID
        self.displayName = displayName
        self.displayPrice = displayPrice
    }
}

public actor StoreKitLifetimeController {
    public static let defaultProductID = "com.worksbien.printmae.pro.lifetime"

    private let productID: String
    private let ledger: EntitlementProviding
    private var updatesTask: Task<Void, Never>?

    public init(
        productID: String = defaultProductID,
        ledger: EntitlementProviding
    ) {
        self.productID = productID
        self.ledger = ledger
    }

    deinit { updatesTask?.cancel() }

    public func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.consume(update)
            }
        }
    }

    public func productDisplay() async throws -> LifetimeProductDisplay {
        guard let product = try await Product.products(for: [productID]).first else {
            throw AppError(.storeUnavailable)
        }
        return LifetimeProductDisplay(
            productID: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice
        )
    }

    public func purchase() async throws -> EntitlementSnapshot {
        guard let product = try await Product.products(for: [productID]).first else {
            let unavailable = EntitlementSnapshot(status: .storeUnavailable, freeExportsRemaining: 0)
            try await ledger.installStoreSnapshot(unavailable)
            throw AppError(.storeUnavailable)
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            let snapshot = snapshot(from: transaction)
            try await ledger.installStoreSnapshot(snapshot)
            await transaction.finish()
            return snapshot
        case .pending:
            let pending = EntitlementSnapshot(status: .purchasePending, freeExportsRemaining: 0)
            try await ledger.installStoreSnapshot(pending)
            return pending
        case .userCancelled:
            let cancelled = EntitlementSnapshot(status: .purchaseCancelled, freeExportsRemaining: 0)
            try await ledger.installStoreSnapshot(cancelled)
            return cancelled
        @unknown default:
            let failed = EntitlementSnapshot(status: .purchaseFailed, freeExportsRemaining: 0)
            try await ledger.installStoreSnapshot(failed)
            return failed
        }
    }

    public func restore() async throws -> EntitlementSnapshot {
        try await AppStore.sync()
        return try await refreshCurrentEntitlement()
    }

    public func refreshCurrentEntitlement() async throws -> EntitlementSnapshot {
        var latest: Transaction?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result), transaction.productID == productID else { continue }
            if latest == nil || transaction.purchaseDate > latest!.purchaseDate { latest = transaction }
        }
        let current = await ledger.snapshot()
        let storeSnapshot: EntitlementSnapshot
        if let latest {
            storeSnapshot = snapshot(from: latest)
        } else if current.status == .lifetimeVerified {
            storeSnapshot = EntitlementSnapshot(
                status: .refundedOrRevoked,
                freeExportsRemaining: current.freeExportsRemaining
            )
        } else {
            storeSnapshot = EntitlementSnapshot(
                status: .free,
                freeExportsRemaining: current.freeExportsRemaining
            )
        }
        try await ledger.installStoreSnapshot(storeSnapshot)
        return storeSnapshot
    }

    private func consume(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? verified(result), transaction.productID == productID else { return }
        try? await ledger.installStoreSnapshot(snapshot(from: transaction))
        await transaction.finish()
    }

    private func snapshot(from transaction: Transaction) -> EntitlementSnapshot {
        if transaction.revocationDate != nil {
            return EntitlementSnapshot(status: .refundedOrRevoked, freeExportsRemaining: 0)
        }
        return EntitlementSnapshot(
            status: .lifetimeVerified,
            freeExportsRemaining: 3,
            lifetimeTransactionID: String(transaction.originalID)
        )
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw AppError(.purchasePending, localizationKey: "error.unverifiedPurchase")
        }
    }
}
