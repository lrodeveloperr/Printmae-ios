import Foundation

public struct ProfileLoadResult: Sendable {
    public let profile: PrintProfile
    public let usedFallback: Bool
    public let warningLocalizationKey: String?

    public init(profile: PrintProfile, usedFallback: Bool, warningLocalizationKey: String?) {
        self.profile = profile
        self.usedFallback = usedFallback
        self.warningLocalizationKey = warningLocalizationKey
    }
}

public struct ProfileCatalog: @unchecked Sendable {
    public static let genericID = "jp.generic.pdf.v1"
    private let resourceBundle: Bundle
    private let now: @Sendable () -> Date

    public init(resourceBundle: Bundle? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resourceBundle = resourceBundle ?? .module
        self.now = now
    }

    public func load(_ requestedID: String) -> ProfileLoadResult {
        do {
            let profile = try validatedProfile(id: requestedID)
            return ProfileLoadResult(profile: profile, usedFallback: false, warningLocalizationKey: nil)
        } catch {
            return ProfileLoadResult(
                profile: (try? validatedProfile(id: Self.genericID, allowExpired: true)) ?? Self.hardcodedGeneric,
                usedFallback: true,
                warningLocalizationKey: "profile.conditionsNeedReview"
            )
        }
    }

    public func loadAll() -> [ProfileLoadResult] {
        ["jp.seven.upload.v1", "jp.sharp.local.v1", Self.genericID].map(load)
    }

    private func validatedProfile(id: String, allowExpired: Bool = false) throws -> PrintProfile {
        guard id.range(of: #"^[a-z0-9.]+$"#, options: .regularExpression) != nil,
              let profileURL = resourceBundle.url(
                forResource: id,
                withExtension: "json",
                subdirectory: "PrintProfiles"
              ) ?? resourceBundle.url(forResource: id, withExtension: "json"),
              let manifestURL = resourceBundle.url(forResource: "profile_hashes", withExtension: "json")
        else { throw AppError(.profileUnavailable) }

        let manifestData = try Data(contentsOf: manifestURL)
        let expected = try JSONDecoder().decode([String: String].self, from: manifestData)
        let profileData = try Data(contentsOf: profileURL)
        guard expected[id] == FileHash.sha256(of: profileData) else {
            throw AppError(.profileIntegrityFailed, retryable: false)
        }

        let profile = try ISO8601Milliseconds.decoder().decode(PrintProfile.self, from: profileData)
        guard profile.id == id else { throw AppError(.profileIntegrityFailed, retryable: false) }
        guard allowExpired || profile.isReviewCurrent(at: now()) else {
            throw AppError(.profileExpired)
        }
        return profile
    }

    public static let hardcodedGeneric = PrintProfile(
        id: genericID,
        displayNameKey: "profile.generic",
        reviewedAt: Date(timeIntervalSince1970: 1_790_294_400),
        reviewValidDays: 180,
        sourceURLs: [],
        acceptedOutputTypes: ["com.adobe.pdf"],
        maxBytesPerFile: 10_000_000,
        maxPagesPerFile: 99,
        allowedPaper: Set(PaperSpec.allCases),
        allowsEncryptedPDF: false,
        requiresUniformPaperSize: true,
        safeInsetMillimetres: .conservative
    )
}
