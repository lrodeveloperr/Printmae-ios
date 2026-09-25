import Foundation

public actor PrintPreparationEngine {
    private let importer: DocumentImporter
    private let analyser: PreflightAnalysing
    private let repairer: PrintRepairing
    private let verifier: OutputVerifying
    private let jobs: JobRepository
    private let entitlements: EntitlementProviding
    private let profiles: ProfileCatalog
    private let diagnostics: PrivacySafeDiagnosticLog
    private let reducer = JobStateReducer()
    private let recipeHistory = RecipeHistory()

    public init(
        importer: DocumentImporter,
        analyser: PreflightAnalysing = NativePreflightAnalyser(),
        repairer: PrintRepairing = NativePDFRepairer(),
        verifier: OutputVerifying = NativeOutputVerifier(),
        jobs: JobRepository,
        entitlements: EntitlementProviding,
        profiles: ProfileCatalog = ProfileCatalog(),
        diagnostics: PrivacySafeDiagnosticLog = PrivacySafeDiagnosticLog()
    ) {
        self.importer = importer
        self.analyser = analyser
        self.repairer = repairer
        self.verifier = verifier
        self.jobs = jobs
        self.entitlements = entitlements
        self.profiles = profiles
        self.diagnostics = diagnostics
    }

    public func importAndAnalyse(
        sourceURL: URL,
        profileID: String = ProfileCatalog.genericID,
        target: PaperSpec = .a4Portrait
    ) async throws -> PrintJobSnapshot {
        try await createAndAnalyse(
            profileID: profileID,
            target: target,
            stage: { try await self.importer.stage(sourceURL) }
        )
    }

    public func importImagesAndAnalyse(
        sourceURLs: [URL],
        profileID: String = ProfileCatalog.genericID,
        target: PaperSpec = .a4Portrait
    ) async throws -> PrintJobSnapshot {
        try await createAndAnalyse(
            profileID: profileID,
            target: target,
            stage: { try await self.importer.stageImages(sourceURLs, target: target) }
        )
    }

    public func submitPassword(jobID: UUID, password: String) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard job.phase == .awaitingPassword else { throw AppError(.illegalTransition, retryable: false) }
        let normalized = normalizePassword(password)
        guard !normalized.isEmpty else { throw AppError(.wrongPassword) }
        let encrypted = try await jobs.stagedDocument(for: jobID)
        do {
            let staged = try await importer.unlock(encrypted, password: normalized)
            try await jobs.registerStagedDocument(staged, for: jobID)
            job.source = staged.descriptor
            job = try reducer.reduce(job, event: .beginAnalysis)
            try await jobs.saveImmediately(job)
            let loaded = profiles.load(job.selectedProfileID)
            let report = try await analysedReport(
                staged: staged,
                profileResult: loaded,
                target: job.targetPaper
            )
            job.report = report
            job = try reducer.reduce(job, event: .analysisReady)
            try await jobs.saveImmediately(job)
            return job
        } catch let error as AppError where error.code == .wrongPassword {
            job.phase = .awaitingPassword
            job.lastError = error
            try await jobs.saveImmediately(job)
            throw error
        } catch let error as AppError {
            let event: JobEvent = error.retryable
                ? .recoverableFailure(error)
                : .terminalFailure(error)
            if let failed = try? reducer.reduce(job, event: event) {
                job = failed
                try? await jobs.saveImmediately(job)
            }
            await diagnostics.record(.analysisFailed, error: error, jobID: jobID)
            throw error
        }
    }

    public func changeProfile(jobID: UUID, profileID: String) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard [.reportReady, .previewReady].contains(job.phase) else {
            throw AppError(.illegalTransition, retryable: false)
        }
        let staged = try await jobs.stagedDocument(for: jobID)
        let loaded = profiles.load(profileID)
        let report = try await analysedReport(staged: staged, profileResult: loaded, target: job.targetPaper)
        job.selectedProfileID = profileID
        job.export = nil
        job.report = report
        job.phase = .reportReady
        job.updatedAt = Date()
        try await jobs.saveImmediately(job)
        return job
    }

    public func applyFix(jobID: UUID, action: FixAction) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard [.reportReady, .previewReady].contains(job.phase) else {
            throw AppError(.illegalTransition, retryable: false)
        }
        job = recipeHistory.apply(action, to: job)
        job.phase = .previewReady
        await jobs.saveDebounced(job)
        return job
    }

    public func undo(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard [.reportReady, .previewReady].contains(job.phase) else {
            throw AppError(.illegalTransition, retryable: false)
        }
        job = recipeHistory.undo(job)
        await jobs.saveDebounced(job)
        return job
    }

    public func redo(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard [.reportReady, .previewReady].contains(job.phase) else {
            throw AppError(.illegalTransition, retryable: false)
        }
        job = recipeHistory.redo(job)
        await jobs.saveDebounced(job)
        return job
    }

    public func preparePreview(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard job.phase == .reportReady else {
            if job.phase == .previewReady { return job }
            throw AppError(.illegalTransition, retryable: false)
        }
        job = try reducer.reduce(job, event: .preview)
        try await jobs.saveImmediately(job)
        return job
    }

    public func flushAutosave(jobID: UUID) async throws {
        try await jobs.flushPendingSave(for: jobID)
    }

    public func verifiedExport(
        jobID: UUID,
        destinationDirectory: URL
    ) async throws -> ExportArtifact {
        var job = try await jobs.require(jobID)
        guard job.phase == .previewReady else { throw AppError(.illegalTransition, retryable: false) }
        let loaded = profiles.load(job.selectedProfileID)
        let request = ExportRequestKey(jobID: jobID, recipeRevision: job.editRecipe.revision)
        let authorisation: ExportAuthorisation
        do {
            job = try reducer.reduce(job, event: .requestExport)
            try await jobs.saveImmediately(job)
            authorisation = try await entitlements.authoriseExport(request: request)
            job = try reducer.reduce(job, event: .exportAuthorised)
            try await jobs.saveImmediately(job)
        } catch let appError as AppError {
            job.phase = .previewReady
            job.lastError = appError
            try? await jobs.saveImmediately(job)
            await diagnostics.record(.entitlementDenied, error: appError, jobID: jobID)
            throw appError
        }

        let baseTemporary = destinationDirectory.appendingPathComponent(".\(job.id.uuidString).partial.pdf")
        var createdFinalURLs: [URL] = []
        do {
            let staged = try await jobs.stagedDocument(for: jobID)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try StorageBudget.assertAvailable(
                at: destinationDirectory,
                inputBytes: staged.descriptor.byteCount
            )
            let manifest = try await repairer.render(
                document: staged,
                recipe: job.editRecipe,
                profile: loaded.profile,
                target: job.targetPaper,
                destination: baseTemporary
            )
            var proofs: [VerificationReport] = []
            for part in manifest.parts {
                let proof = try await verifier.verify(
                    output: part.temporaryURL,
                    expected: part,
                    profile: loaded.profile
                )
                guard proof.pass else { throw AppError(.verificationFailed) }
                proofs.append(proof)
            }

            var finalParts: [ExportPart] = []
            for (index, part) in manifest.parts.enumerated() {
                let final = finalURL(
                    jobID: job.id,
                    partIndex: index,
                    partCount: manifest.parts.count,
                    directory: destinationDirectory
                )
                try AtomicFileMover.replaceItem(at: final, with: part.temporaryURL)
                createdFinalURLs.append(final)
                let bytes = Int64((try final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                finalParts.append(
                    ExportPart(
                        url: final,
                        pageIndexes: part.pageIndexes,
                        byteCount: bytes,
                        sha256: try FileHash.sha256(of: final),
                        verification: proofs[index]
                    )
                )
            }
            let artifact = ExportArtifact(
                parts: finalParts,
                recipeRevision: manifest.recipeRevision,
                verifiedAt: Date()
            )
            job.export = artifact
            job = try reducer.reduce(job, event: .exportVerified)
            try await jobs.saveImmediately(job)
            try await entitlements.commitVerifiedExport(authorisation)
            return artifact
        } catch {
            await jobs.deleteIncompleteOutputs(for: jobID)
            try? FileManager.default.removeItem(at: baseTemporary)
            createdFinalURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            if let files = try? FileManager.default.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.contains(job.id.uuidString) && file.lastPathComponent.contains("partial") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            let appError = AppError.map(error)
            job.phase = .recoverableFailure
            job.export = nil
            job.lastError = appError
            try? await jobs.saveImmediately(job)
            await diagnostics.record(.verificationFailed, error: appError, jobID: jobID)
            throw error
        }
    }

    public func beginSharing(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        job = try reducer.reduce(job, event: .beginSharing)
        try await jobs.saveImmediately(job)
        return job
    }

    public func shareCancelled(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        job = try reducer.reduce(job, event: .shareCancelled)
        try await jobs.saveImmediately(job)
        return job
    }

    public func complete(jobID: UUID, completedOrdinal: Int) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        if job.phase == .exportVerified {
            job = try reducer.reduce(job, event: .complete)
        } else if job.phase == .sharing {
            job = try reducer.reduce(job, event: .complete)
        } else {
            throw AppError(.illegalTransition, retryable: false)
        }
        job.completedJobOrdinal = completedOrdinal
        try await jobs.saveImmediately(job)
        return job
    }

    public func retryAfterFailure(jobID: UUID) async throws -> PrintJobSnapshot {
        var job = try await jobs.require(jobID)
        guard job.phase == .recoverableFailure else { throw AppError(.illegalTransition, retryable: false) }
        let target: JobPhase
        if job.source == nil { target = .importing }
        else if job.report == nil { target = .analysing }
        else { target = .previewReady }
        job = try reducer.reduce(job, event: .retry(target))
        try await jobs.saveImmediately(job)
        return job
    }

    public func resumeActiveJob() async throws -> PrintJobSnapshot? {
        guard let job = try await jobs.activeJob() else { return nil }
        if job.phase == .exportVerified, let export = job.export {
            let request = ExportRequestKey(jobID: job.id, recipeRevision: export.recipeRevision)
            let authorisation = try await entitlements.authoriseExport(request: request)
            try await entitlements.commitVerifiedExport(authorisation)
        }
        return job
    }

    private func createAndAnalyse(
        profileID: String,
        target: PaperSpec,
        stage: () async throws -> StagedDocument
    ) async throws -> PrintJobSnapshot {
        var job = PrintJobSnapshot.new(profileID: profileID, targetPaper: target)
        job = try reducer.reduce(job, event: .beginImport)
        try await jobs.saveImmediately(job)
        do {
            let staged = try await stage()
            try await jobs.registerStagedDocument(staged, for: job.id)
            job.source = staged.descriptor
            if staged.descriptor.isEncrypted {
                job = try reducer.reduce(job, event: .requirePassword)
                try await jobs.saveImmediately(job)
                return job
            }
            job = try reducer.reduce(job, event: .beginAnalysis)
            try await jobs.saveImmediately(job)
            let loaded = profiles.load(profileID)
            job.report = try await analysedReport(staged: staged, profileResult: loaded, target: target)
            job = try reducer.reduce(job, event: .analysisReady)
            try await jobs.saveImmediately(job)
            return job
        } catch let appError as AppError {
            let event: JobEvent = appError.retryable
                ? .recoverableFailure(appError)
                : .terminalFailure(appError)
            if let failed = try? reducer.reduce(job, event: event) {
                job = failed
                try? await jobs.saveImmediately(job)
            }
            await diagnostics.record(.analysisFailed, error: appError, jobID: job.id)
            throw appError
        }
    }

    private func analysedReport(
        staged: StagedDocument,
        profileResult: ProfileLoadResult,
        target: PaperSpec
    ) async throws -> PreflightReport {
        let original = try await analyser.analyse(
            document: staged,
            profile: profileResult.profile,
            target: target
        )
        guard profileResult.usedFallback else { return original }
        let warning = PreflightIssue(
            code: .profileNeedsReview,
            severity: .review,
            titleKey: "issue.profileNeedsReview.title",
            consequenceKey: "issue.profileNeedsReview.consequence"
        )
        return PreflightReport(
            profileID: profileResult.profile.id,
            readiness: original.readiness == .blocked ? .blocked : .review,
            pageCount: original.pageCount,
            inputBytes: original.inputBytes,
            pages: original.pages,
            issues: [warning] + original.issues,
            analysedAt: original.analysedAt
        )
    }

    private func normalizePassword(_ value: String) -> String {
        value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
    }

    private func finalURL(jobID: UUID, partIndex: Int, partCount: Int, directory: URL) -> URL {
        let prefix = "print_ready_\(jobID.uuidString.prefix(8))"
        if partCount == 1 { return directory.appendingPathComponent(prefix + ".pdf") }
        let suffix = String(format: "_part_%02d_of_%02d.pdf", partIndex + 1, partCount)
        return directory.appendingPathComponent(prefix + suffix)
    }
}
