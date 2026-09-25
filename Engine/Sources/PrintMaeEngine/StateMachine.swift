import Foundation

public enum JobEvent: Hashable, Sendable {
    case beginImport
    case requirePassword
    case beginAnalysis
    case analysisReady
    case beginRepair
    case repairReady
    case preview
    case requestExport
    case exportAuthorised
    case exportAuthorisationDenied
    case exportVerified
    case beginSharing
    case shareCancelled
    case complete
    case reset
    case recoverableFailure(AppError)
    case terminalFailure(AppError)
    case retry(JobPhase)
}

public struct JobStateReducer: Sendable {
    public static let legalTransitions: [JobPhase: Set<JobPhase>] = [
        .draft: [.importing],
        .importing: [.awaitingPassword, .analysing, .recoverableFailure, .terminalFailure],
        .awaitingPassword: [.analysing, .draft, .terminalFailure],
        .analysing: [.reportReady, .recoverableFailure, .terminalFailure],
        .reportReady: [.repairing, .previewReady, .draft, .reportReady],
        .repairing: [.reportReady, .previewReady, .recoverableFailure],
        .previewReady: [.exportAuthorisation, .repairing, .draft, .reportReady, .previewReady],
        .exportAuthorisation: [.exporting, .previewReady],
        .exporting: [.exportVerified, .recoverableFailure],
        .exportVerified: [.sharing, .completed, .recoverableFailure],
        .sharing: [.completed, .exportVerified],
        .completed: [.draft],
        .recoverableFailure: [.importing, .analysing, .repairing, .exporting, .draft, .previewReady],
        .terminalFailure: [.draft]
    ]

    public init() {}

    public func reduce(
        _ snapshot: PrintJobSnapshot,
        event: JobEvent,
        now: Date = Date()
    ) throws -> PrintJobSnapshot {
        let target: JobPhase
        var error: AppError?

        switch event {
        case .beginImport: target = .importing
        case .requirePassword: target = .awaitingPassword
        case .beginAnalysis: target = .analysing
        case .analysisReady: target = .reportReady
        case .beginRepair: target = .repairing
        case .repairReady, .preview: target = .previewReady
        case .requestExport: target = .exportAuthorisation
        case .exportAuthorised: target = .exporting
        case .exportAuthorisationDenied: target = .previewReady
        case .exportVerified: target = .exportVerified
        case .beginSharing: target = .sharing
        case .shareCancelled: target = .exportVerified
        case .complete: target = .completed
        case .reset: target = .draft
        case .recoverableFailure(let appError):
            target = .recoverableFailure
            error = appError
        case .terminalFailure(let appError):
            target = .terminalFailure
            error = appError
        case .retry(let retryTarget):
            target = retryTarget
        }

        guard Self.legalTransitions[snapshot.phase, default: []].contains(target) else {
            throw AppError(.illegalTransition, retryable: false)
        }

        var next = snapshot
        next.phase = target
        next.lastError = error
        next.updatedAt = now

        if target == .draft {
            next.source = nil
            next.report = nil
            next.editRecipe = EditRecipe()
            next.undoRecipes = []
            next.redoRecipes = []
            next.export = nil
        }
        return next
    }

    public func recoveredAfterUncleanTermination(
        _ snapshot: PrintJobSnapshot,
        now: Date = Date()
    ) -> PrintJobSnapshot {
        var recovered = snapshot
        switch snapshot.phase {
        case .importing:
            recovered.phase = snapshot.source == nil ? .draft : .analysing
        case .analysing:
            recovered.phase = .analysing
        case .repairing:
            recovered.phase = snapshot.report == nil ? .analysing : .reportReady
        case .exportAuthorisation:
            recovered.phase = .previewReady
        case .exporting:
            recovered.phase = .previewReady
            recovered.lastError = AppError(
                .verificationFailed,
                localizationKey: "error.exportInterrupted"
            )
            recovered.export = nil
        case .sharing:
            recovered.phase = .exportVerified
        default:
            break
        }
        recovered.updatedAt = now
        return recovered
    }

    public static func validateTransitionTable() -> [String] {
        var failures: [String] = []
        for phase in JobPhase.allCases where legalTransitions[phase] == nil {
            failures.append("Missing transition row for \(phase.rawValue)")
        }
        let allTargets = Set(legalTransitions.values.flatMap { $0 })
        for target in allTargets where !JobPhase.allCases.contains(target) {
            failures.append("Unknown transition target \(target.rawValue)")
        }
        return failures
    }
}

public struct RecipeHistory: Sendable {
    public init() {}

    public func apply(_ action: FixAction, to snapshot: PrintJobSnapshot, now: Date = Date()) -> PrintJobSnapshot {
        var next = snapshot
        next.undoRecipes.append(snapshot.editRecipe)
        next.editRecipe = snapshot.editRecipe.appending(action)
        next.redoRecipes.removeAll()
        next.export = nil
        next.updatedAt = now
        return next
    }

    public func undo(_ snapshot: PrintJobSnapshot, now: Date = Date()) -> PrintJobSnapshot {
        guard let prior = snapshot.undoRecipes.last else { return snapshot }
        var next = snapshot
        next.undoRecipes.removeLast()
        next.redoRecipes.append(snapshot.editRecipe)
        next.editRecipe = prior
        next.export = nil
        next.updatedAt = now
        return next
    }

    public func redo(_ snapshot: PrintJobSnapshot, now: Date = Date()) -> PrintJobSnapshot {
        guard let future = snapshot.redoRecipes.last else { return snapshot }
        var next = snapshot
        next.redoRecipes.removeLast()
        next.undoRecipes.append(snapshot.editRecipe)
        next.editRecipe = future
        next.export = nil
        next.updatedAt = now
        return next
    }
}
