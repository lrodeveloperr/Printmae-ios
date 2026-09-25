import XCTest
import CoreGraphics
import PDFKit
@testable import PrintMaeEngine

final class VerificationTests: XCTestCase {
    private static let fixedDate = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    func testSuccessfulVerificationReportsEveryCheckAsPassed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "source.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let output = base.appendingPathComponent(".output.partial.pdf")
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: descriptor, url: source),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: output
        )
        guard let part = manifest.parts.first else {
            XCTFail("Expected a rendered part")
            return
        }
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: part.temporaryURL,
            expected: part,
            profile: profile
        )
        let expectedCodes: Set<String> = [
            "file.nonempty", "path.notSource", "parser.cgpdf", "parser.pdfkit",
            "encryption.none", "pages.count", "profile.bytes", "profile.pages",
            "pages.dimensions", "profile.paper", "profile.uniformPaper", "pages.sampleRender"
        ]
        let actualCodes = Set(report.checks.map(\.code))
        XCTAssertEqual(
            actualCodes,
            expectedCodes,
            "checks=\(report.checks.map { "\($0.code)=\($0.passed)" })"
        )
        XCTAssertTrue(
            report.checks.allSatisfy(\.passed),
            "checks=\(report.checks.map { "\($0.code)=\($0.passed)" })"
        )
        XCTAssertTrue(report.pass)
    }

    func testFileNonemptyCheckRequiresBothExistenceAndNonzeroSize() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let emptyOutput = base.appendingPathComponent("empty.pdf")
        try Data().write(to: emptyOutput)
        let expected = RenderedPart(
            temporaryURL: emptyOutput,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: emptyOutput,
            expected: expected,
            profile: profile
        )
        // The file exists but is zero bytes: "exists" alone must not be enough to pass.
        XCTAssertEqual(report.checks.first { $0.code == "file.nonempty" }?.passed, false)
    }

    func testDimensionCheckFailsWhenEitherWidthOrHeightExceedsTolerance() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("a4.pdf")
        try SampleDocumentFactory.makePDF(at: source, papers: [.a4Portrait], contentTouchesEdge: false)
        let a4 = PaperSpec.a4Portrait.points
        // Width matches the real page exactly; only height is pushed out of tolerance.
        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width), height: Double(a4.height) + 5)],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertEqual(report.checks.first { $0.code == "pages.dimensions" }?.passed, false)

        // And the reverse: height matches exactly, only width is out of tolerance. Both
        // directions need to be checked independently of each other.
        let widthOffExpected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width) + 5, height: Double(a4.height))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let widthOffReport = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: widthOffExpected,
            profile: profile
        )
        XCTAssertEqual(widthOffReport.checks.first { $0.code == "pages.dimensions" }?.passed, false)
    }

    func testDimensionToleranceBoundaryIsExactlyHalfPoint() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("a4.pdf")
        try SampleDocumentFactory.makePDF(at: source, papers: [.a4Portrait], contentTouchesEdge: false)
        let a4 = PaperSpec.a4Portrait.points
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile

        let atTolerance = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width) + 0.5, height: Double(a4.height))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let atReport = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: atTolerance,
            profile: profile
        )
        XCTAssertEqual(atReport.checks.first { $0.code == "pages.dimensions" }?.passed, true)

        let overTolerance = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width) + 0.51, height: Double(a4.height))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let overReport = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: overTolerance,
            profile: profile
        )
        XCTAssertEqual(overReport.checks.first { $0.code == "pages.dimensions" }?.passed, false)

        let heightAtTolerance = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width), height: Double(a4.height) + 0.5)],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let heightAtReport = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: heightAtTolerance,
            profile: profile
        )
        XCTAssertEqual(heightAtReport.checks.first { $0.code == "pages.dimensions" }?.passed, true)

        let heightOverTolerance = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(x: 0, y: 0, width: Double(a4.width), height: Double(a4.height) + 0.51)],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let heightOverReport = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: heightOverTolerance,
            profile: profile
        )
        XCTAssertEqual(heightOverReport.checks.first { $0.code == "pages.dimensions" }?.passed, false)
    }

    func testPaperSupportCheckFailsWhenAPageIsNotASupportedSize() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("nonstandard.pdf")
        try Self.makeSinglePagePDF(at: source, size: CGSize(width: 400, height: 400))

        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(CGRect(x: 0, y: 0, width: 400, height: 400))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertEqual(report.checks.first { $0.code == "profile.paper" }?.passed, false)
    }

    func testPagesCountCheckFailsWhenExpectedCountDoesNotMatchActual() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("a4.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        // The output genuinely has 1 page, but the expected part claims 2: this must fail
        // regardless of every other check (dimensions, paper support, etc.) passing.
        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0, 1],
            expectedPageBoxes: [
                RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points)),
                RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points))
            ],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertEqual(report.checks.first { $0.code == "pages.count" }?.passed, false)
        XCTAssertFalse(report.pass)
    }

    func testUniformPaperCheckFailsWhenPageSizesDiffer() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("mixed.pdf")
        try SampleDocumentFactory.makePDF(at: source, papers: [.a4Portrait, .b5Portrait], contentTouchesEdge: false)

        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0, 1],
            expectedPageBoxes: [
                RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points)),
                RectPoints(CGRect(origin: .zero, size: PaperSpec.b5Portrait.points))
            ],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        XCTAssertTrue(profile.requiresUniformPaperSize, "This test needs a profile that requires uniform paper size")
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertEqual(report.checks.first { $0.code == "profile.uniformPaper" }?.passed, false)
    }

    func testSampleRenderCheckFailsWhenASampledPageIsBlank() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("blank.pdf")
        try Self.makeSinglePagePDF(at: source, size: PaperSpec.a4Portrait.points, blank: true)

        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertEqual(report.checks.first { $0.code == "pages.sampleRender" }?.passed, false)
    }

    private static func makeSinglePagePDF(at url: URL, size: CGSize, blank: Bool = false) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw AppError(.renderFailed) }
        var mediaBox = CGRect(origin: .zero, size: size)
        let mediaBoxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBoxData] as CFDictionary)
        if !blank {
            context.setFillColor(CGColor(red: 0.11, green: 0.18, blue: 0.38, alpha: 1))
            context.fill(CGRect(x: size.width * 0.25, y: size.height * 0.25, width: size.width * 0.5, height: size.height * 0.5))
        }
        context.endPDFPage()
        context.closePDF()
    }
}
