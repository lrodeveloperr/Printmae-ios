import XCTest
@testable import PrintMaeEngine

final class IntegrationTests: XCTestCase {
    func testSampleCompletesVerifiedExportAndConsumesOne() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let staging = repository.stagingRoot
        let importer = LocalDocumentImporter(stagingRoot: staging)
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let verifier = CapturingVerifier()
        let engine = PrintPreparationEngine(
            importer: importer,
            verifier: verifier,
            jobs: repository,
            entitlements: ledger,
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sample = base.appendingPathComponent("サンプル📄.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample, pageCount: 2)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        XCTAssertEqual(job.phase, .reportReady)
        XCTAssertEqual(job.report?.pageCount, 2)
        job = try await engine.preparePreview(jobID: job.id)
        let outputDirectory = try await repository.outputDirectory(for: job.id)
        let artifact: ExportArtifact
        do {
            artifact = try await engine.verifiedExport(jobID: job.id, destinationDirectory: outputDirectory)
        } catch {
            let failures = await verifier.failedChecks()
            XCTFail("Export failed: \(error); verification failures: \(failures.map { "\($0.code)=\($0.detail)" })")
            return
        }
        XCTAssertEqual(artifact.parts.count, 1)
        XCTAssertTrue(artifact.parts[0].verification.pass)
        let entitlement = await ledger.snapshot()
        XCTAssertEqual(entitlement.freeExportsRemaining, 2)
        let stored = try await repository.require(job.id)
        XCTAssertEqual(stored.phase, .exportVerified)
    }

    func testInterruptedExportRecoveryDeletesPartialAndPreservesRecipe() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base)
        var job = PrintJobSnapshot.new()
        job.phase = .exporting
        job.editRecipe = EditRecipe(actions: [.normalizePaper(.a4Portrait)], revision: 1)
        try await repository.saveImmediately(job)
        let recovered = try await repository.activeJob()
        XCTAssertEqual(recovered?.phase, .previewReady)
        XCTAssertEqual(recovered?.editRecipe, job.editRecipe)
    }

    func testCleanupDeletesExpiredUnkeptSourceButNotKeptProject() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base)
        let staging = repository.stagingRoot
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let source = staging.appendingPathComponent("source.pdf")
        try Data("%PDF-stub".utf8).write(to: source)
        var job = PrintJobSnapshot(
            phase: .completed,
            source: SourceDescriptor(
                kind: .pdf,
                stagedRelativePath: source.lastPathComponent,
                originalDisplayName: "private.pdf",
                byteCount: 9,
                sha256: "hash"
            ),
            selectedProfileID: ProfileCatalog.genericID,
            targetPaper: .a4Portrait,
            createdAt: old,
            updatedAt: old
        )
        try await repository.saveImmediately(job)
        let removed = try await repository.cleanupCompletedJobs(olderThan: old.addingTimeInterval(86_400))
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        job = PrintJobSnapshot(
            phase: .completed,
            selectedProfileID: ProfileCatalog.genericID,
            targetPaper: .a4Portrait,
            keepProject: true,
            createdAt: old,
            updatedAt: old
        )
        try await repository.saveImmediately(job)
        let kept = try await repository.cleanupCompletedJobs(olderThan: old.addingTimeInterval(86_400))
        XCTAssertEqual(kept, 0)
    }
}

private actor CapturingVerifier: OutputVerifying {
    private let verifier = NativeOutputVerifier()
    private var lastReport: VerificationReport?

    func verify(
        output: URL,
        expected: RenderedPart,
        profile: PrintProfile
    ) async throws -> VerificationReport {
        let report = try await verifier.verify(output: output, expected: expected, profile: profile)
        lastReport = report
        return report
    }

    func failedChecks() -> [VerificationCheck] {
        lastReport?.checks.filter { !$0.passed } ?? []
    }
}
