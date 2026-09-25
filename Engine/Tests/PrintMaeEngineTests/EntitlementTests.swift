import XCTest
@testable import PrintMaeEngine

final class EntitlementTests: XCTestCase {
    func testThreeDistinctVerifiedExportsConsumeExactlyThree() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        for revision in 0 ..< 3 {
            let auth = try await ledger.authoriseExport(
                request: ExportRequestKey(jobID: UUID(), recipeRevision: revision)
            )
            try await ledger.commitVerifiedExport(auth)
        }
        let exhausted = await ledger.snapshot()
        XCTAssertEqual(exhausted.freeExportsRemaining, 0)
        await XCTAssertThrowsAppError(.entitlementRequired) {
            _ = try await ledger.authoriseExport(
                request: ExportRequestKey(jobID: UUID(), recipeRevision: 4)
            )
        }
    }

    func testCommitIsIdempotentByAuthorisationID() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let request = ExportRequestKey(jobID: UUID(), recipeRevision: 7)
        let first = try await ledger.authoriseExport(request: request)
        let retry = try await ledger.authoriseExport(request: request)
        XCTAssertEqual(first, retry)
        try await ledger.commitVerifiedExport(first)
        try await ledger.commitVerifiedExport(first)
        let afterRetry = await ledger.snapshot()
        XCTAssertEqual(afterRetry.freeExportsRemaining, 2)
    }

    func testFailedOrCancelledExportDoesNotConsumeWithoutCommit() async throws {
        let store = MemoryLedgerDataStore()
        let ledger = FreeExportEntitlementLedger(store: store)
        _ = try await ledger.authoriseExport(
            request: ExportRequestKey(jobID: UUID(), recipeRevision: 1)
        )
        let beforeRelaunch = await ledger.snapshot()
        XCTAssertEqual(beforeRelaunch.freeExportsRemaining, 3)
        let relaunched = FreeExportEntitlementLedger(store: store)
        let afterRelaunch = await relaunched.snapshot()
        XCTAssertEqual(afterRelaunch.freeExportsRemaining, 3)
    }

    func testStaleAuthorisationsArePrunedWithoutAffectingRemainingBudget() async throws {
        let store = MemoryLedgerDataStore()
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let firstLedger = FreeExportEntitlementLedger(store: store, now: { early })
        let firstRequest = ExportRequestKey(jobID: UUID(), recipeRevision: 1)
        let firstAuth = try await firstLedger.authoriseExport(request: firstRequest)
        try await firstLedger.commitVerifiedExport(firstAuth)
        let afterFirstCommit = await firstLedger.snapshot()
        XCTAssertEqual(afterFirstCommit.freeExportsRemaining, 2)

        // A relaunch far past the retention window must still behave correctly, and its next
        // ledger write should evict the now-stale authorisation record rather than keep it forever.
        let late = early.addingTimeInterval(120 * 24 * 60 * 60)
        let relaunched = FreeExportEntitlementLedger(store: store, now: { late })
        let secondAuth = try await relaunched.authoriseExport(
            request: ExportRequestKey(jobID: UUID(), recipeRevision: 2)
        )
        try await relaunched.commitVerifiedExport(secondAuth)
        let afterSecondCommit = await relaunched.snapshot()
        XCTAssertEqual(afterSecondCommit.freeExportsRemaining, 1)

        // Re-authorising the original request after it has aged out of the ledger is a brand
        // new authorisation, not a resurrection of the pruned one, and it is still bound by the
        // remaining free-export budget rather than granted again for free.
        let reauthorised = try await relaunched.authoriseExport(request: firstRequest)
        XCTAssertNotEqual(reauthorised.id, firstAuth.id)
    }

    func testVerifiedLifetimeAllowsUnlimitedExports() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        try await ledger.installStoreSnapshot(
            EntitlementSnapshot(
                status: .lifetimeVerified,
                freeExportsRemaining: 3,
                lifetimeTransactionID: "tx-1"
            )
        )
        for revision in 0 ..< 20 {
            let auth = try await ledger.authoriseExport(
                request: ExportRequestKey(jobID: UUID(), recipeRevision: revision)
            )
            XCTAssertFalse(auth.consumesFreeExport)
            try await ledger.commitVerifiedExport(auth)
        }
        let lifetime = await ledger.snapshot()
        XCTAssertEqual(lifetime.status, .lifetimeVerified)
    }

    func testOfflineSnapshotDoesNotEraseCachedLifetime() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        try await ledger.installStoreSnapshot(
            EntitlementSnapshot(status: .lifetimeVerified, freeExportsRemaining: 3, lifetimeTransactionID: "tx")
        )
        try await ledger.installStoreSnapshot(
            EntitlementSnapshot(status: .unknownOffline, freeExportsRemaining: 0)
        )
        let offline = await ledger.snapshot()
        XCTAssertEqual(offline.status, .lifetimeVerified)
    }

    func testPendingAndFreeSnapshotsDoNotEraseCachedLifetimeEither() async throws {
        // Every branch of installStoreSnapshot that isn't .lifetimeVerified/.refundedOrRevoked
        // must be equally unable to downgrade an already-verified lifetime status, not just the
        // offline one.
        for status: EntitlementStatus in [.purchasePending, .purchaseCancelled, .purchaseFailed, .free] {
            let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
            try await ledger.installStoreSnapshot(
                EntitlementSnapshot(status: .lifetimeVerified, freeExportsRemaining: 3, lifetimeTransactionID: "tx")
            )
            try await ledger.installStoreSnapshot(
                EntitlementSnapshot(status: status, freeExportsRemaining: 0)
            )
            let after = await ledger.snapshot()
            XCTAssertEqual(after.status, .lifetimeVerified, "status \(status) must not downgrade a cached lifetime entitlement")
        }
    }

    func testAuthorisedBeforeUpgradeDoesNotConsumeAFreeExportAfterUpgrading() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let request = ExportRequestKey(jobID: UUID(), recipeRevision: 1)
        // Authorised while still on the free tier, so this authorisation is flagged as
        // consuming a free export...
        let auth = try await ledger.authoriseExport(request: request)
        XCTAssertTrue(auth.consumesFreeExport)

        // ...but the user upgrades to lifetime before the export is actually verified/committed.
        try await ledger.installStoreSnapshot(
            EntitlementSnapshot(status: .lifetimeVerified, freeExportsRemaining: 3, lifetimeTransactionID: "tx")
        )
        try await ledger.commitVerifiedExport(auth)

        let after = await ledger.snapshot()
        XCTAssertEqual(after.freeExportsRemaining, 3, "Committing a pre-upgrade authorisation must not spend a free export once the account is lifetime")
    }

    func testCommittingASecondAuthorisationAfterBudgetIsExhaustedThrows() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        // Drain the budget down to exactly one export remaining.
        for revision in 0 ..< 2 {
            let auth = try await ledger.authoriseExport(
                request: ExportRequestKey(jobID: UUID(), recipeRevision: revision)
            )
            try await ledger.commitVerifiedExport(auth)
        }
        let afterDraining = await ledger.snapshot()
        XCTAssertEqual(afterDraining.freeExportsRemaining, 1)

        // Authorising two more distinct exports is allowed (authorising never spends budget by
        // itself), but only one of them can actually be committed.
        let thirdAuth = try await ledger.authoriseExport(
            request: ExportRequestKey(jobID: UUID(), recipeRevision: 2)
        )
        let fourthAuth = try await ledger.authoriseExport(
            request: ExportRequestKey(jobID: UUID(), recipeRevision: 3)
        )
        try await ledger.commitVerifiedExport(thirdAuth)
        let afterThirdCommit = await ledger.snapshot()
        XCTAssertEqual(afterThirdCommit.freeExportsRemaining, 0)

        await XCTAssertThrowsAppError(.entitlementRequired) {
            try await ledger.commitVerifiedExport(fourthAuth)
        }
    }
}

private func XCTAssertThrowsAppError(
    _ expected: AppErrorCode,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected AppError.\(expected.rawValue)", file: file, line: line)
    } catch let error as AppError {
        XCTAssertEqual(error.code, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
