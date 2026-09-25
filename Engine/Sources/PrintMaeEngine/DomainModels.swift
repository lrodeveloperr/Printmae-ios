import Foundation
import CoreGraphics

public enum PaperSpec: String, Codable, CaseIterable, Hashable, Sendable {
    case a4Portrait
    case a4Landscape
    case b5Portrait
    case b5Landscape

    public var millimetres: SizeMM {
        switch self {
        case .a4Portrait: return SizeMM(width: 210, height: 297)
        case .a4Landscape: return SizeMM(width: 297, height: 210)
        case .b5Portrait: return SizeMM(width: 182, height: 257)
        case .b5Landscape: return SizeMM(width: 257, height: 182)
        }
    }

    public var points: CGSize {
        CGSize(width: millimetres.width.pdfPoints, height: millimetres.height.pdfPoints)
    }

    public var isPortrait: Bool { millimetres.height >= millimetres.width }
}

public struct SizeMM: Codable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct EdgeInsetsMM: Codable, Hashable, Sendable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let conservative = EdgeInsetsMM(top: 5, leading: 5, bottom: 5, trailing: 5)
}

public struct RectPoints: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isFiniteAndPositive: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

public struct PrintProfile: Codable, Hashable, Sendable {
    public let id: String
    public let displayNameKey: String
    public let reviewedAt: Date
    public let reviewValidDays: Int
    public let sourceURLs: [URL]
    public let acceptedOutputTypes: Set<String>
    public let maxBytesPerFile: Int64
    public let maxPagesPerFile: Int
    public let allowedPaper: Set<PaperSpec>
    public let allowsEncryptedPDF: Bool
    public let requiresUniformPaperSize: Bool
    public let safeInsetMillimetres: EdgeInsetsMM

    public init(
        id: String,
        displayNameKey: String,
        reviewedAt: Date,
        reviewValidDays: Int,
        sourceURLs: [URL],
        acceptedOutputTypes: Set<String>,
        maxBytesPerFile: Int64,
        maxPagesPerFile: Int,
        allowedPaper: Set<PaperSpec>,
        allowsEncryptedPDF: Bool,
        requiresUniformPaperSize: Bool,
        safeInsetMillimetres: EdgeInsetsMM
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.reviewedAt = reviewedAt
        self.reviewValidDays = reviewValidDays
        self.sourceURLs = sourceURLs
        self.acceptedOutputTypes = acceptedOutputTypes
        self.maxBytesPerFile = maxBytesPerFile
        self.maxPagesPerFile = maxPagesPerFile
        self.allowedPaper = allowedPaper
        self.allowsEncryptedPDF = allowsEncryptedPDF
        self.requiresUniformPaperSize = requiresUniformPaperSize
        self.safeInsetMillimetres = safeInsetMillimetres
    }

    public func isReviewCurrent(at date: Date, calendar: Calendar = .iso8601UTC) -> Bool {
        guard reviewValidDays > 0,
              let expiry = calendar.date(byAdding: .day, value: reviewValidDays, to: reviewedAt)
        else { return false }
        return date < expiry
    }
}

public enum JobPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case importing
    case awaitingPassword
    case analysing
    case reportReady
    case repairing
    case previewReady
    case exportAuthorisation
    case exporting
    case exportVerified
    case sharing
    case completed
    case recoverableFailure
    case terminalFailure
}

public enum ReadinessLevel: String, Codable, Hashable, Sendable {
    case ready
    case review
    case blocked
}

public enum IssueSeverity: Int, Codable, Comparable, Hashable, Sendable {
    case information = 0
    case review = 1
    case blocking = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum IssueCode: String, Codable, CaseIterable, Hashable, Sendable {
    case encrypted
    case corrupt
    case empty
    case pageLimitExceeded
    case byteLimitExceeded
    case unsupportedPaper
    case mixedPaperSizes
    case mixedOrientations
    case contentOutsideSafeArea
    case lowImageResolution
    case flatteningRequired
    case profileNeedsReview
}

public struct PageRange: Codable, Hashable, Sendable {
    public let indexes: IndexSet
    public init(indexes: IndexSet) { self.indexes = indexes }
}

public struct PageAnalysis: Codable, Hashable, Sendable {
    public let index: Int
    public let mediaBox: RectPoints
    public let cropBox: RectPoints
    public let rotationDegrees: Int
    public let orientationPortrait: Bool
    public let inferredPaper: PaperSpec?
    public let visibleContentBounds: RectPoints?
    public let effectiveImageDPI: Double?

    public init(
        index: Int,
        mediaBox: RectPoints,
        cropBox: RectPoints,
        rotationDegrees: Int,
        orientationPortrait: Bool,
        inferredPaper: PaperSpec?,
        visibleContentBounds: RectPoints?,
        effectiveImageDPI: Double?
    ) {
        self.index = index
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotationDegrees = rotationDegrees
        self.orientationPortrait = orientationPortrait
        self.inferredPaper = inferredPaper
        self.visibleContentBounds = visibleContentBounds
        self.effectiveImageDPI = effectiveImageDPI
    }
}

public struct PreflightIssue: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let code: IssueCode
    public let severity: IssueSeverity
    public let pages: PageRange?
    public let titleKey: String
    public let consequenceKey: String
    public let suggestedFix: FixAction?

    public init(
        id: UUID = UUID(),
        code: IssueCode,
        severity: IssueSeverity,
        pages: PageRange? = nil,
        titleKey: String,
        consequenceKey: String,
        suggestedFix: FixAction? = nil
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.pages = pages
        self.titleKey = titleKey
        self.consequenceKey = consequenceKey
        self.suggestedFix = suggestedFix
    }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    public let profileID: String
    public let readiness: ReadinessLevel
    public let pageCount: Int
    public let inputBytes: Int64
    public let pages: [PageAnalysis]
    public let issues: [PreflightIssue]
    public let analysedAt: Date

    public init(
        profileID: String,
        readiness: ReadinessLevel,
        pageCount: Int,
        inputBytes: Int64,
        pages: [PageAnalysis],
        issues: [PreflightIssue],
        analysedAt: Date
    ) {
        self.profileID = profileID
        self.readiness = readiness
        self.pageCount = pageCount
        self.inputBytes = inputBytes
        self.pages = pages
        self.issues = issues
        self.analysedAt = analysedAt
    }
}

public struct CompressionPolicy: Codable, Hashable, Sendable {
    public let jpegQualitySteps: [Double]
    public let rasterDPI: Double
    public let minimumRasterDPI: Double

    public init(
        jpegQualitySteps: [Double] = [0.90, 0.80, 0.70, 0.60],
        rasterDPI: Double = 200,
        minimumRasterDPI: Double = 150
    ) {
        self.jpegQualitySteps = jpegQualitySteps
        self.rasterDPI = rasterDPI
        self.minimumRasterDPI = minimumRasterDPI
    }

    public var isValid: Bool {
        let descending = zip(jpegQualitySteps, jpegQualitySteps.dropFirst())
            .allSatisfy { current, next in current > next }
        return !jpegQualitySteps.isEmpty &&
        jpegQualitySteps.allSatisfy { (0 ... 1).contains($0) } &&
        descending &&
        rasterDPI >= minimumRasterDPI &&
        minimumRasterDPI >= 150
    }
}

public enum FixAction: Codable, Hashable, Sendable {
    case unlock
    case rotate(pageIndexes: IndexSet, quarterTurnsClockwise: Int)
    case normalizePaper(PaperSpec)
    case fitInsideSafeArea(EdgeInsetsMM)
    case addMargins(EdgeInsetsMM)
    case compress(CompressionPolicy)
    case split(maxPages: Int, maxBytes: Int64)
    case flattenForPrint

    public var isReversible: Bool { self != .unlock }
}

public struct EditRecipe: Codable, Hashable, Sendable {
    public var actions: [FixAction]
    public var revision: Int

    public init(actions: [FixAction] = [], revision: Int = 0) {
        self.actions = actions
        self.revision = revision
    }

    public func appending(_ action: FixAction) -> EditRecipe {
        var next = self
        next.actions.append(action)
        next.revision += 1
        return next
    }
}

public enum SourceKind: String, Codable, Hashable, Sendable {
    case pdf
    case imagePDF
}

public struct SourceDescriptor: Codable, Hashable, Sendable {
    public let kind: SourceKind
    public let stagedRelativePath: String
    public let originalDisplayName: String
    public let byteCount: Int64
    public let sha256: String
    public let isEncrypted: Bool
    public let effectiveImageDPIByPage: [Int: Double]

    public init(
        kind: SourceKind,
        stagedRelativePath: String,
        originalDisplayName: String,
        byteCount: Int64,
        sha256: String,
        isEncrypted: Bool = false,
        effectiveImageDPIByPage: [Int: Double] = [:]
    ) {
        self.kind = kind
        self.stagedRelativePath = stagedRelativePath
        self.originalDisplayName = originalDisplayName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.isEncrypted = isEncrypted
        self.effectiveImageDPIByPage = effectiveImageDPIByPage
    }
}

public struct StagedDocument: @unchecked Sendable {
    public let descriptor: SourceDescriptor
    public let url: URL
    public let unlockPassword: String?

    public init(descriptor: SourceDescriptor, url: URL, unlockPassword: String? = nil) {
        self.descriptor = descriptor
        self.url = url
        self.unlockPassword = unlockPassword
    }

    public func unlocked(with password: String) -> StagedDocument {
        StagedDocument(descriptor: descriptor, url: url, unlockPassword: password)
    }
}

public struct VerificationCheck: Codable, Hashable, Sendable {
    public let code: String
    public let passed: Bool
    public let detail: String

    public init(code: String, passed: Bool, detail: String) {
        self.code = code
        self.passed = passed
        self.detail = detail
    }
}

public struct VerificationReport: Codable, Hashable, Sendable {
    public let pass: Bool
    public let checks: [VerificationCheck]
    public let verifiedAt: Date

    public init(pass: Bool, checks: [VerificationCheck], verifiedAt: Date) {
        self.pass = pass
        self.checks = checks
        self.verifiedAt = verifiedAt
    }
}

public struct RenderedPart: Codable, Hashable, Sendable {
    public let temporaryURL: URL
    public let pageIndexes: [Int]
    public let expectedPageBoxes: [RectPoints]
    public let sourceURL: URL

    public init(
        temporaryURL: URL,
        pageIndexes: [Int],
        expectedPageBoxes: [RectPoints],
        sourceURL: URL
    ) {
        self.temporaryURL = temporaryURL
        self.pageIndexes = pageIndexes
        self.expectedPageBoxes = expectedPageBoxes
        self.sourceURL = sourceURL
    }
}

public struct RenderManifest: Codable, Hashable, Sendable {
    public let parts: [RenderedPart]
    public let flattened: Bool
    public let recipeRevision: Int

    public init(parts: [RenderedPart], flattened: Bool, recipeRevision: Int) {
        self.parts = parts
        self.flattened = flattened
        self.recipeRevision = recipeRevision
    }
}

public struct ExportPart: Codable, Hashable, Sendable {
    public let url: URL
    public let pageIndexes: [Int]
    public let byteCount: Int64
    public let sha256: String
    public let verification: VerificationReport

    public init(
        url: URL,
        pageIndexes: [Int],
        byteCount: Int64,
        sha256: String,
        verification: VerificationReport
    ) {
        self.url = url
        self.pageIndexes = pageIndexes
        self.byteCount = byteCount
        self.sha256 = sha256
        self.verification = verification
    }
}

public struct ExportArtifact: Codable, Hashable, Sendable {
    public let parts: [ExportPart]
    public let recipeRevision: Int
    public let verifiedAt: Date

    public init(parts: [ExportPart], recipeRevision: Int, verifiedAt: Date) {
        self.parts = parts
        self.recipeRevision = recipeRevision
        self.verifiedAt = verifiedAt
    }
}

public enum AppErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
    case illegalTransition
    case unsupportedFormat
    case securityScopeDenied
    case stagingFailed
    case protectedPDF
    case wrongPassword
    case corruptPDF
    case emptyPDF
    case invalidGeometry
    case profileUnavailable
    case profileIntegrityFailed
    case profileExpired
    case renderFailed
    case verificationFailed
    case insufficientStorage
    case entitlementRequired
    case purchasePending
    case storeUnavailable
    case jobNotFound
    case persistenceFailed
    case cancelled
}

public struct AppError: Error, Codable, Hashable, Sendable {
    public let code: AppErrorCode
    public let localizationKey: String
    public let retryable: Bool
    public let requiredFreeBytes: Int64?

    public init(
        _ code: AppErrorCode,
        localizationKey: String? = nil,
        retryable: Bool = true,
        requiredFreeBytes: Int64? = nil
    ) {
        self.code = code
        self.localizationKey = localizationKey ?? "error.\(code.rawValue)"
        self.retryable = retryable
        self.requiredFreeBytes = requiredFreeBytes
    }

    public static func map(_ error: any Error) -> AppError {
        if let appError = error as? AppError { return appError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteOutOfSpaceError {
            return AppError(.insufficientStorage, requiredFreeBytes: nil)
        }
        return AppError(.persistenceFailed)
    }
}

public struct PrintJobSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var phase: JobPhase
    public var source: SourceDescriptor?
    public var selectedProfileID: String
    public var targetPaper: PaperSpec
    public var report: PreflightReport?
    public var editRecipe: EditRecipe
    public var undoRecipes: [EditRecipe]
    public var redoRecipes: [EditRecipe]
    public var export: ExportArtifact?
    public var lastError: AppError?
    public var keepProject: Bool
    public var completedJobOrdinal: Int?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        phase: JobPhase = .draft,
        source: SourceDescriptor? = nil,
        selectedProfileID: String,
        targetPaper: PaperSpec,
        report: PreflightReport? = nil,
        editRecipe: EditRecipe = EditRecipe(),
        undoRecipes: [EditRecipe] = [],
        redoRecipes: [EditRecipe] = [],
        export: ExportArtifact? = nil,
        lastError: AppError? = nil,
        keepProject: Bool = false,
        completedJobOrdinal: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.phase = phase
        self.source = source
        self.selectedProfileID = selectedProfileID
        self.targetPaper = targetPaper
        self.report = report
        self.editRecipe = editRecipe
        self.undoRecipes = undoRecipes
        self.redoRecipes = redoRecipes
        self.export = export
        self.lastError = lastError
        self.keepProject = keepProject
        self.completedJobOrdinal = completedJobOrdinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func new(
        profileID: String = ProfileCatalog.genericID,
        targetPaper: PaperSpec = .a4Portrait,
        now: Date = Date()
    ) -> PrintJobSnapshot {
        PrintJobSnapshot(
            selectedProfileID: profileID,
            targetPaper: targetPaper,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension Double {
    public var pdfPoints: Double { self / 25.4 * 72.0 }
}

extension Calendar {
    public static var iso8601UTC: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
