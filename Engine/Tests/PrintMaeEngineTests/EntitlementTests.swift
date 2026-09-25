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
