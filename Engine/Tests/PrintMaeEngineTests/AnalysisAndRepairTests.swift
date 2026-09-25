import XCTest
import PDFKit
@testable import PrintMaeEngine

final class AnalysisAndRepairTests: XCTestCase {
    private static let fixedDate = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    func testPageAndByteBoundariesAreBlockingOnlyWhenExceeded() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("boundary.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 100)
        let profile = ProfileCatalog(now: { Self.fixedDate }).load("jp.seven.upload.v1").profile
        let analyser = NativePreflightAnalyser(now: { Self.fixedDate })

        let overPages = StagedDocument(
            descriptor: SourceDescriptor(
                kind: .pdf,
                stagedRelativePath: source.lastPathComponent,
                originalDisplayName: "boundary.pdf",
                byteCount: 10_000_000,
                sha256: "fixture"
            ),
            url: source
        )
        let pageReport = try await analyser.analyse(document: overPages, profile: profile, target: .a4Portrait)
        XCTAssertTrue(pageReport.issues.contains { $0.code == .pageLimitExceeded && $0.severity == .blocking })
        XCTAssertFalse(pageReport.issues.contains { $0.code == .byteLimitExceeded })

        let overBytes = StagedDocument(
            descriptor: SourceDescriptor(
                kind: .pdf,
                stagedRelativePath: source.lastPathComponent,
                originalDisplayName: "boundary.pdf",
                byteCount: 10_000_001,
                sha256: "fixture"
            ),
            url: source
        )
        let byteReport = try await analyser.analyse(document: overBytes, profile: profile, target: .a4Portrait)
        XCTAssertTrue(byteReport.issues.contains { $0.code == .byteLimitExceeded && $0.severity == .blocking })
    }

    func testMixedPaperAndEdgeContentAreDetected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("mixed.pdf")
        try SampleDocumentFactory.makePDF(
            at: source,
            papers: [.a4Portrait, .b5Portrait],
            contentTouchesEdge: true
        )
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "mixed.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: "fixture"
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertTrue(report.issues.contains { $0.code == .mixedPaperSizes && $0.severity == .blocking })
        XCTAssertTrue(report.issues.contains { $0.code == .contentOutsideSafeArea })
    }

    func testKnownImageDPIUsesExact150Boundary() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("images.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 4)
        let descriptor = SourceDescriptor(
            kind: .imagePDF,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "images.pdf",
            byteCount: 1_000,
            sha256: "fixture",
            effectiveImageDPIByPage: [0: 72, 1: 149, 2: 150, 3: 300]
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        let pages = report.issues.first { $0.code == .lowImageResolution }?.pages?.indexes
        XCTAssertEqual(pages, IndexSet([0, 1]))
    }

    func testCorruptPDFFailsWithoutMutatingSource() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("corrupt.pdf")
        let bytes = Data("%PDF-truncated".utf8)
        try bytes.write(to: source)
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "corrupt.pdf",
            byteCount: Int64(bytes.count),
            sha256: FileHash.sha256(of: bytes)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        do {
            _ = try await NativePreflightAnalyser().analyse(
                document: StagedDocument(descriptor: descriptor, url: source),
                profile: profile,
                target: .a4Portrait
            )
            XCTFail("Expected corrupt PDF rejection")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .corruptPDF)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSplitCoversEveryPageExactlyOnceAndNamesParts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("five.pdf")
        let output = base.appendingPathComponent(".candidate.partial.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 5)
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "five.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let profile = PrintProfile(
            id: "fixture",
            displayNameKey: "fixture",
            reviewedAt: Self.fixedDate,
            reviewValidDays: 1,
            sourceURLs: [],
            acceptedOutputTypes: ["com.adobe.pdf"],
            maxBytesPerFile: 10_000_000,
            maxPagesPerFile: 2,
            allowedPaper: Set(PaperSpec.allCases),
            allowsEncryptedPDF: false,
            requiresUniformPaperSize: true,
            safeInsetMillimetres: .conservative
        )
        let recipe = EditRecipe(
            actions: [.split(maxPages: 2, maxBytes: 10_000_000)],
            revision: 1
        )
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: descriptor, url: source),
            recipe: recipe,
            profile: profile,
            target: .a4Portrait,
            destination: output
        )
        XCTAssertEqual(manifest.parts.count, 3)
        XCTAssertEqual(manifest.parts.flatMap(\.pageIndexes), Array(0 ..< 5))
        XCTAssertTrue(manifest.parts[0].temporaryURL.lastPathComponent.contains("part_01_of_03"))
    }

    func testVerifierRejectsWrongDimensions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("b5.pdf")
        try SampleDocumentFactory.makePDF(at: source, papers: [.b5Portrait], contentTouchesEdge: false)
        let expected = RenderedPart(
            temporaryURL: source,
            pageIndexes: [0],
            expectedPageBoxes: [RectPoints(CGRect(origin: .zero, size: PaperSpec.a4Portrait.points))],
            sourceURL: base.appendingPathComponent("original.pdf")
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let proof = try await NativeOutputVerifier(now: { Self.fixedDate }).verify(
            output: source,
            expected: expected,
            profile: profile
        )
        XCTAssertFalse(proof.pass)
        XCTAssertEqual(proof.checks.first { $0.code == "pages.dimensions" }?.passed, false)
    }
}
