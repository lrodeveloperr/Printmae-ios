import XCTest
@testable import PrintMaeEngine

final class ProfileAndLocalizationTests: XCTestCase {
    func testAllBundledProfilesPassHashAndSchemaValidation() {
        let results = ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! }).loadAll()
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.usedFallback })
        XCTAssertEqual(Set(results.map(\.profile.id)), Set([
            "jp.seven.upload.v1",
            "jp.sharp.local.v1",
            "jp.generic.pdf.v1"
        ]))
    }

    func testProfileBoundariesAreInclusive() {
        let profiles = ProfileCatalog(now: { ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")! }).loadAll()
        let seven = profiles.first { $0.profile.id == "jp.seven.upload.v1" }!.profile
        XCTAssertEqual(seven.maxBytesPerFile, 10_000_000)
        XCTAssertEqual(seven.maxPagesPerFile, 99)
        XCTAssertTrue(seven.allowedPaper.contains(.a4Portrait))
        XCTAssertFalse(seven.allowsEncryptedPDF)
    }

    func testExpiredProfileFailsClosedToGenericWithWarning() {
        let future = Date(timeIntervalSince1970: 1_900_000_000)
        let result = ProfileCatalog(now: { future }).load("jp.seven.upload.v1")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.profile.id, ProfileCatalog.genericID)
        XCTAssertEqual(result.warningLocalizationKey, "profile.conditionsNeedReview")
    }

    func testEveryIssueCodeHasStableLocalizationKeys() {
        for code in IssueCode.allCases {
            XCTAssertFalse("issue.\(code.rawValue).title".isEmpty)
            XCTAssertFalse("issue.\(code.rawValue).consequence".isEmpty)
        }
    }
}
