import Foundation

public protocol DocumentImporter: Sendable {
    func stage(_ sourceURL: URL) async throws -> StagedDocument
    func stageImages(_ sourceURLs: [URL], target: PaperSpec) async throws -> StagedDocument
    func unlock(_ document: StagedDocument, password: String) async throws -> StagedDocument
}

public protocol PreflightAnalysing: Sendable {
    func analyse(
        document: StagedDocument,
        profile: PrintProfile,
        target: PaperSpec
    ) async throws -> PreflightReport
}

public protocol PrintRepairing: Sendable {
    func render(
        document: StagedDocument,
        recipe: EditRecipe,
        profile: PrintProfile,
        target: PaperSpec,
        destination: URL
    ) async throws -> RenderManifest
}

public protocol OutputVerifying: Sendable {
    func verify(
        output: URL,
        expected: RenderedPart,
        profile: PrintProfile
    ) async throws -> VerificationReport
}

public protocol JobRepository: Sendable {
    func saveImmediately(_ job: PrintJobSnapshot) async throws
    func saveDebounced(_ job: PrintJobSnapshot) async
    func flushPendingSave(for id: UUID) async throws
    func require(_ id: UUID) async throws -> PrintJobSnapshot
    func activeJob() async throws -> PrintJobSnapshot?
    func stagedDocument(for id: UUID) async throws -> StagedDocument
    func registerStagedDocument(_ document: StagedDocument, for id: UUID) async throws
    func deleteIncompleteOutputs(for id: UUID) async
}

public enum EntitlementStatus: String, Codable, Hashable, Sendable {
    case unknownOffline
    case free
    case lifetimeVerified
    case purchasePending
    case purchaseCancelled
    case purchaseFailed
    case refundedOrRevoked
    case storeUnavailable
}

public struct EntitlementSnapshot: Codable, Hashable, Sendable {
    public let status: EntitlementStatus
    public let freeExportsRemaining: Int
    public let lifetimeTransactionID: String?
    public let checkedAt: Date

    public init(
        status: EntitlementStatus,
        freeExportsRemaining: Int,
        lifetimeTransactionID: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.status = status
        self.freeExportsRemaining = max(0, min(3, freeExportsRemaining))
        self.lifetimeTransactionID = lifetimeTransactionID
        self.checkedAt = checkedAt
    }

    public var permitsUnlimitedExports: Bool { status == .lifetimeVerified }
}

public struct ExportRequestKey: Codable, Hashable, Sendable {
    public let jobID: UUID
    public let recipeRevision: Int

    public init(jobID: UUID, recipeRevision: Int) {
        self.jobID = jobID
        self.recipeRevision = recipeRevision
    }
}

public struct ExportAuthorisation: Codable, Hashable, Sendable {
    public let id: UUID
    public let request: ExportRequestKey
    public let consumesFreeExport: Bool
    public let issuedAt: Date

    public init(
        id: UUID = UUID(),
        request: ExportRequestKey,
        consumesFreeExport: Bool,
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.consumesFreeExport = consumesFreeExport
        self.issuedAt = issuedAt
    }
}

public protocol EntitlementProviding: Sendable {
    func snapshot() async -> EntitlementSnapshot
    func authoriseExport(request: ExportRequestKey) async throws -> ExportAuthorisation
    func commitVerifiedExport(_ authorisation: ExportAuthorisation) async throws
    func installStoreSnapshot(_ snapshot: EntitlementSnapshot) async throws
}
