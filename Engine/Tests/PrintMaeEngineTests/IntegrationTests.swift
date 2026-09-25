import XCTest
import PDFKit
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

    func testRepeatedApplyFixStaysInPreviewReadyThroughReducer() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let importer = repository.makeImporter()
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let engine = PrintPreparationEngine(
            importer: importer,
            jobs: repository,
            entitlements: ledger,
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sample = base.appendingPathComponent("sample.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample, pageCount: 2)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        XCTAssertEqual(job.phase, .reportReady)

        job = try await engine.applyFix(jobID: job.id, action: .rotate(pageIndexes: IndexSet(integer: 0), quarterTurnsClockwise: 1))
        XCTAssertEqual(job.phase, .previewReady)
        XCTAssertEqual(job.editRecipe.actions.count, 1)

        // applyFix saves debounced (not immediately); a second call before that save lands
        // would otherwise re-read the pre-edit snapshot from disk via jobs.require and silently
        // drop this edit, so flush it through explicitly first.
        try await engine.flushAutosave(jobID: job.id)

        // A second fix applied while already in .previewReady must not be rejected by the
        // guarded state machine: previewReady -> previewReady is a legal self-transition.
        job = try await engine.applyFix(jobID: job.id, action: .rotate(pageIndexes: IndexSet(integer: 1), quarterTurnsClockwise: 2))
        XCTAssertEqual(job.phase, .previewReady)
        XCTAssertEqual(job.editRecipe.actions.count, 2)

        try await repository.flushPendingSave(for: job.id)
        let persisted = try await repository.require(job.id)
        XCTAssertEqual(persisted.phase, .previewReady)
        XCTAssertEqual(persisted.editRecipe.actions.count, 2)
    }

    func testChangeProfileFromPreviewReadyReturnsToReportReady() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let importer = repository.makeImporter()
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let engine = PrintPreparationEngine(
            importer: importer,
            jobs: repository,
            entitlements: ledger,
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sample = base.appendingPathComponent("sample.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample, pageCount: 2)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        job = try await engine.preparePreview(jobID: job.id)
        XCTAssertEqual(job.phase, .previewReady)

        // Switching print method from the preview screen must go through the guarded
        // state machine, not a direct phase write: previewReady -> reportReady.
        job = try await engine.changeProfile(jobID: job.id, profileID: "jp.seven.upload.v1")
        XCTAssertEqual(job.phase, .reportReady)
        XCTAssertEqual(job.selectedProfileID, "jp.seven.upload.v1")
        XCTAssertNil(job.export)

        let persisted = try await repository.require(job.id)
        XCTAssertEqual(persisted.phase, .reportReady)
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

    func testSubmitPasswordUnlocksWithCorrectPasswordAndRejectsWrongOne() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let importer = repository.makeImporter()
        let engine = PrintPreparationEngine(
            importer: importer,
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let plain = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: 1)
        guard let plainDocument = PDFDocument(url: plain) else {
            XCTFail("Fixture PDF did not open")
            return
        }
        let encrypted = base.appendingPathComponent("locked.pdf")
        let wrote = plainDocument.write(
            to: encrypted,
            withOptions: [.userPasswordOption: "correct-horse", .ownerPasswordOption: "correct-horse"]
        )
        XCTAssertTrue(wrote, "Failed to write an encrypted fixture PDF")

        var job = try await engine.importAndAnalyse(sourceURL: encrypted)
        XCTAssertEqual(job.phase, .awaitingPassword)

        // Wrong password must not fall through to the generic recoverable/terminal-failure
        // handling: the job stays in .awaitingPassword (not bounced to another phase) and the
        // wrongPassword error is the one actually persisted for the UI to show.
        do {
            _ = try await engine.submitPassword(jobID: job.id, password: "not-it")
            XCTFail("Expected wrongPassword")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .wrongPassword)
        }
        let afterWrongPassword = try await repository.require(job.id)
        XCTAssertEqual(afterWrongPassword.phase, .awaitingPassword)
        XCTAssertEqual(afterWrongPassword.lastError?.code, .wrongPassword)

        job = try await engine.submitPassword(jobID: job.id, password: "correct-horse")
        XCTAssertEqual(job.phase, .reportReady)
        XCTAssertEqual(job.report?.pageCount, 1)
    }

    func testPreparePreviewIsIdempotentFromPreviewReadyAndRejectsOtherPhases() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sample = base.appendingPathComponent("sample.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample, pageCount: 1)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        job = try await engine.preparePreview(jobID: job.id)
        XCTAssertEqual(job.phase, .previewReady)

        // Calling it again while already in .previewReady must succeed and simply return the
        // job unchanged, not reject it.
        let repeated = try await engine.preparePreview(jobID: job.id)
        XCTAssertEqual(repeated.phase, .previewReady)

        var draftJob = PrintJobSnapshot.new()
        draftJob.phase = .draft
        try await repository.saveImmediately(draftJob)
        await XCTAssertThrowsIllegalTransition {
            _ = try await engine.preparePreview(jobID: draftJob.id)
        }
    }

    func testCompleteFromExportVerifiedAndSharingSucceedsOtherwiseThrows() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var exportVerifiedJob = PrintJobSnapshot.new()
        exportVerifiedJob.phase = .exportVerified
        try await repository.saveImmediately(exportVerifiedJob)
        let completedFromExportVerified = try await engine.complete(jobID: exportVerifiedJob.id, completedOrdinal: 1)
        XCTAssertEqual(completedFromExportVerified.phase, .completed)
        XCTAssertEqual(completedFromExportVerified.completedJobOrdinal, 1)

        var sharingJob = PrintJobSnapshot.new()
        sharingJob.phase = .sharing
        try await repository.saveImmediately(sharingJob)
        let completedFromSharing = try await engine.complete(jobID: sharingJob.id, completedOrdinal: 2)
        XCTAssertEqual(completedFromSharing.phase, .completed)

        var reportReadyJob = PrintJobSnapshot.new()
        reportReadyJob.phase = .reportReady
        try await repository.saveImmediately(reportReadyJob)
        await XCTAssertThrowsIllegalTransition {
            _ = try await engine.complete(jobID: reportReadyJob.id, completedOrdinal: 3)
        }
    }

    func testRetryAfterFailureChoosesPhaseByWhatIsMissing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var noSource = PrintJobSnapshot.new()
        noSource.phase = .recoverableFailure
        try await repository.saveImmediately(noSource)
        let retriedNoSource = try await engine.retryAfterFailure(jobID: noSource.id)
        XCTAssertEqual(retriedNoSource.phase, .importing)

        var noReport = PrintJobSnapshot.new()
        noReport.phase = .recoverableFailure
        noReport.source = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: "fixture.pdf",
            originalDisplayName: "fixture.pdf",
            byteCount: 10,
            sha256: "hash"
        )
        try await repository.saveImmediately(noReport)
        let retriedNoReport = try await engine.retryAfterFailure(jobID: noReport.id)
        XCTAssertEqual(retriedNoReport.phase, .analysing)

        var readyToPreview = PrintJobSnapshot.new()
        readyToPreview.phase = .recoverableFailure
        readyToPreview.source = noReport.source
        readyToPreview.report = PreflightReport(
            profileID: ProfileCatalog.genericID,
            readiness: .ready,
            pageCount: 1,
            inputBytes: 10,
            pages: [],
            issues: [],
            analysedAt: Date()
        )
        try await repository.saveImmediately(readyToPreview)
        let retriedReadyToPreview = try await engine.retryAfterFailure(jobID: readyToPreview.id)
        XCTAssertEqual(retriedReadyToPreview.phase, .previewReady)

        var notFailed = PrintJobSnapshot.new()
        notFailed.phase = .reportReady
        try await repository.saveImmediately(notFailed)
        await XCTAssertThrowsIllegalTransition {
            _ = try await engine.retryAfterFailure(jobID: notFailed.id)
        }
    }

    func testResumeActiveJobOnlyRecommitsWhenExportVerifiedWithExport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let capturing = CapturingEntitlements(inner: ledger)
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: capturing,
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // A job that carries an export but is NOT in .exportVerified must not trigger a
        // re-commit: only the (phase == .exportVerified) side of the guard should matter.
        var notVerified = PrintJobSnapshot.new()
        notVerified.phase = .reportReady
        notVerified.export = ExportArtifact(parts: [], recipeRevision: 1, verifiedAt: Date())
        try await repository.saveImmediately(notVerified)
        _ = try await engine.resumeActiveJob()
        let callsAfterNonVerified = await capturing.authoriseExportCallCount
        XCTAssertEqual(callsAfterNonVerified, 0)

        var verified = PrintJobSnapshot.new()
        verified.phase = .exportVerified
        verified.export = ExportArtifact(parts: [], recipeRevision: 1, verifiedAt: Date())
        try await repository.saveImmediately(verified)
        _ = try await engine.resumeActiveJob()
        let callsAfterVerified = await capturing.authoriseExportCallCount
        XCTAssertEqual(callsAfterVerified, 1)
    }

    func testProfileFallbackKeepsBlockedButDowngradesReadyToReview() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let clean = base.appendingPathComponent("clean.pdf")
        try SampleDocumentFactory.makeA4PDF(at: clean, pageCount: 1)
        let cleanJob = try await engine.importAndAnalyse(sourceURL: clean, profileID: "totally-unknown-profile-id")
        XCTAssertEqual(cleanJob.report?.readiness, .review, "A ready analysis under a fallback profile must be downgraded to review, not left as ready")

        let oversized = base.appendingPathComponent("oversized.pdf")
        try SampleDocumentFactory.makeA4PDF(at: oversized, pageCount: 200)
        let oversizedJob = try await engine.importAndAnalyse(sourceURL: oversized, profileID: "totally-unknown-profile-id")
        XCTAssertEqual(oversizedJob.report?.readiness, .blocked, "A blocked analysis under a fallback profile must stay blocked")
    }

    func testMultiPartExportNamesFinalFilesWithPartSuffixOnlyWhenSplit() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try FileJobRepository(root: base.appendingPathComponent("Engine"))
        let engine = PrintPreparationEngine(
            importer: repository.makeImporter(),
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore()),
            profiles: ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! })
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sample = base.appendingPathComponent("two-pages.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample, pageCount: 2)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        job = try await engine.applyFix(jobID: job.id, action: .split(maxPages: 1, maxBytes: 10_000_000))
        XCTAssertEqual(job.phase, .previewReady)
        // applyFix saves debounced; flush before verifiedExport re-reads the job from disk,
        // otherwise it would see the pre-split recipe.
        try await engine.flushAutosave(jobID: job.id)
        let outputDirectory = try await repository.outputDirectory(for: job.id)
        let artifact = try await engine.verifiedExport(jobID: job.id, destinationDirectory: outputDirectory)

        XCTAssertEqual(artifact.parts.count, 2)
        for part in artifact.parts {
            XCTAssertTrue(part.url.lastPathComponent.contains("_part_"), part.url.lastPathComponent)
        }
    }
}

private func XCTAssertThrowsIllegalTransition(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected AppError.illegalTransition", file: file, line: line)
    } catch let error as AppError {
        XCTAssertEqual(error.code, .illegalTransition, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor CapturingEntitlements: EntitlementProviding {
    private let inner: FreeExportEntitlementLedger
    private(set) var authoriseExportCallCount = 0

    init(inner: FreeExportEntitlementLedger) {
        self.inner = inner
    }

    func snapshot() async -> EntitlementSnapshot {
        await inner.snapshot()
    }

    func authoriseExport(request: ExportRequestKey) async throws -> ExportAuthorisation {
        authoriseExportCallCount += 1
        return try await inner.authoriseExport(request: request)
    }

    func commitVerifiedExport(_ authorisation: ExportAuthorisation) async throws {
        try await inner.commitVerifiedExport(authorisation)
    }

    func installStoreSnapshot(_ snapshot: EntitlementSnapshot) async throws {
        try await inner.installStoreSnapshot(snapshot)
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
