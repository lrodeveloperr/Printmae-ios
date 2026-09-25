import Foundation

public struct RatingPromptContext: Sendable, Hashable {
    public let completedJobOrdinal: Int
    public let installationDate: Date
    public let now: Date
    public let lastPromptDate: Date?
    public let jobHadError: Bool
    public let paywallWasJustDismissed: Bool

    public init(
        completedJobOrdinal: Int,
        installationDate: Date,
        now: Date,
        lastPromptDate: Date?,
        jobHadError: Bool,
        paywallWasJustDismissed: Bool
    ) {
        self.completedJobOrdinal = completedJobOrdinal
        self.installationDate = installationDate
        self.now = now
        self.lastPromptDate = lastPromptDate
        self.jobHadError = jobHadError
        self.paywallWasJustDismissed = paywallWasJustDismissed
    }
}

public enum RatingPromptPolicy {
    public static func shouldRequest(
        _ context: RatingPromptContext,
        calendar: Calendar = .iso8601UTC
    ) -> Bool {
        guard context.completedJobOrdinal >= 3,
              !context.jobHadError,
              !context.paywallWasJustDismissed,
              let sevenDays = calendar.date(byAdding: .day, value: 7, to: context.installationDate),
              context.now >= sevenDays else { return false }
        if let lastPromptDate = context.lastPromptDate,
           let nextEligible = calendar.date(byAdding: .day, value: 120, to: lastPromptDate),
           context.now < nextEligible {
            return false
        }
        return true
    }
}
