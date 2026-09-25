import XCTest
@testable import PrintMaeEngine

final class StateMachineTests: XCTestCase {
    func testTransitionTableMatchesLockedContract() {
        XCTAssertEqual(JobStateReducer.validateTransitionTable(), [])
        XCTAssertEqual(JobStateReducer.legalTransitions[.draft], [.importing])
        XCTAssertEqual(JobStateReducer.legalTransitions[.exporting], [.exportVerified, .recoverableFailure])
        XCTAssertEqual(JobStateReducer.legalTransitions[.sharing], [.completed, .exportVerified])
        XCTAssertEqual(JobStateReducer.legalTransitions[.terminalFailure], [.draft])
    }

    func testEveryLegalTransitionCanBeCommitted() throws {
        let reducer = JobStateReducer()
        for (source, targets) in JobStateReducer.legalTransitions {
            for target in targets {
                var snapshot = PrintJobSnapshot.new()
                snapshot.phase = source
                let event: JobEvent
                switch target {
                case .importing: event = source == .recoverableFailure ? .retry(.importing) : .beginImport
                case .awaitingPassword: event = .requirePassword
                case .analysing: event = source == .recoverableFailure ? .retry(.analysing) : .beginAnalysis
                case .reportReady: event = .analysisReady
                case .repairing: event = source == .recoverableFailure ? .retry(.repairing) : .beginRepair
                case .previewReady: event = source == .recoverableFailure ? .retry(.previewReady) : .preview
                case .exportAuthorisation: event = .requestExport
                case .exporting: event = source == .recoverableFailure ? .retry(.exporting) : .exportAuthorised
                case .exportVerified: event = source == .sharing ? .shareCancelled : .exportVerified
                case .sharing: event = .beginSharing
                case .completed: event = .complete
                case .recoverableFailure: event = .recoverableFailure(AppError(.renderFailed))
                case .terminalFailure: event = .terminalFailure(AppError(.corruptPDF, retryable: false))
                case .draft: event = .reset
                }
                XCTAssertEqual(try reducer.reduce(snapshot, event: event).phase, target)
            }
        }
    }

    func testIllegalTransitionDoesNotMutateSnapshot() {
        let reducer = JobStateReducer()
        let original = PrintJobSnapshot.new()
        XCTAssertThrowsError(try reducer.reduce(original, event: .complete))
        XCTAssertEqual(original.phase, .draft)
    }

    func testInterruptedExportRecoversToPreviewAndDropsArtifact() {
        var snapshot = PrintJobSnapshot.new()
        snapshot.phase = .exporting
        snapshot.export = ExportArtifact(parts: [], recipeRevision: 2, verifiedAt: Date())
        let recovered = JobStateReducer().recoveredAfterUncleanTermination(snapshot)
        XCTAssertEqual(recovered.phase, .previewReady)
        XCTAssertNil(recovered.export)
        XCTAssertEqual(recovered.lastError?.localizationKey, "error.exportInterrupted")
    }

    func testSharingInterruptionPreservesVerifiedOutputState() {
        var snapshot = PrintJobSnapshot.new()
        snapshot.phase = .sharing
        XCTAssertEqual(JobStateReducer().recoveredAfterUncleanTermination(snapshot).phase, .exportVerified)
    }

    func testInterruptedImportRecoversByWhetherSourceWasStaged() {
        var withoutSource = PrintJobSnapshot.new()
        withoutSource.phase = .importing
        withoutSource.source = nil
        XCTAssertEqual(
            JobStateReducer().recoveredAfterUncleanTermination(withoutSource).phase,
            .draft
        )

        var withSource = PrintJobSnapshot.new()
        withSource.phase = .importing
        withSource.source = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: "fixture.pdf",
            originalDisplayName: "fixture.pdf",
            byteCount: 10,
            sha256: "hash"
        )
        XCTAssertEqual(
            JobStateReducer().recoveredAfterUncleanTermination(withSource).phase,
            .analysing
        )
    }

    func testInterruptedRepairRecoversByWhetherReportExisted() {
        var withoutReport = PrintJobSnapshot.new()
        withoutReport.phase = .repairing
        withoutReport.report = nil
        XCTAssertEqual(
            JobStateReducer().recoveredAfterUncleanTermination(withoutReport).phase,
            .analysing
        )

        var withReport = PrintJobSnapshot.new()
        withReport.phase = .repairing
        withReport.report = PreflightReport(
            profileID: ProfileCatalog.genericID,
            readiness: .ready,
            pageCount: 1,
            inputBytes: 10,
            pages: [],
            issues: [],
            analysedAt: Date()
        )
        XCTAssertEqual(
            JobStateReducer().recoveredAfterUncleanTermination(withReport).phase,
            .reportReady
        )
    }
}
