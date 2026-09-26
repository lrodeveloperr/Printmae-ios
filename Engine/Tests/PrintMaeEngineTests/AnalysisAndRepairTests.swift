import XCTest
import CoreGraphics
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
        XCTAssertTrue(
            report.issues.contains { $0.code == .mixedPaperSizes && $0.severity == .blocking },
            "issues=\(report.issues.map { $0.code.rawValue }); " +
                "cropBoxes=\(report.pages.map { String(describing: $0.cropBox.cgRect.size) }); " +
                "inferred=\(report.pages.map { $0.inferredPaper?.rawValue ?? "unknown" })"
        )
        if !report.issues.contains(where: { $0.code == .contentOutsideSafeArea }) {
            let bounds = report.pages.map { page -> String in
                guard let rect = page.visibleContentBounds else { return "nil" }
                return String(describing: rect)
            }
            XCTFail(
                "issues=\(report.issues.map { $0.code.rawValue }); " +
                "visibleBounds=\(bounds)"
            )
        }
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

    func testInteractiveFeaturesWithinLimitsCopyThroughUnflattened() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let plain = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: 1)
        guard let document = PDFDocument(url: plain), let page = document.page(at: 0) else {
            XCTFail("Fixture PDF did not open")
            return
        }
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        page.addAnnotation(annotation)
        let source = base.appendingPathComponent("annotated.pdf")
        XCTAssertTrue(document.write(to: source))

        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "annotated.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let output = base.appendingPathComponent(".copy-through.partial.pdf")
        // An empty recipe on a document with interactive features (here, an annotation) that
        // is within every profile limit must copy through unflattened rather than demand
        // flattening approval.
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: descriptor, url: source),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: output
        )
        XCTAssertEqual(manifest.parts.count, 1)
        XCTAssertFalse(manifest.flattened)
        XCTAssertEqual(manifest.parts[0].pageIndexes, [0])
        // Only the copy-through path preserves annotations byte-for-byte; the generic redraw
        // path (which would run if hasInteractiveFeatures were wrongly computed as false here,
        // since this fixture has an annotation but no outline) draws page content only and
        // would silently drop the annotation.
        guard let outputDocument = PDFDocument(url: output) else {
            XCTFail("Rendered output did not open")
            return
        }
        // PDFKit adds its own companion Popup annotation when a .text annotation is saved, so
        // this checks presence of the original annotation type rather than an exact count.
        XCTAssertTrue(
            outputDocument.page(at: 0)?.annotations.contains { $0.type == "Text" } ?? false,
            "annotations=\(outputDocument.page(at: 0)?.annotations.map { $0.type ?? "nil" } ?? [])"
        )
    }

    func testCleanPDFHasNoIssuesAndIsReady() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("clean.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "clean.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        // A page with no outline, no annotations and nothing exceeding any limit must not be
        // flagged as needing review for any reason (in particular, not for interactive
        // features it doesn't have).
        XCTAssertEqual(report.readiness, .ready, "issues=\(report.issues.map(\.code.rawValue))")
        XCTAssertTrue(report.issues.isEmpty, "issues=\(report.issues.map(\.code.rawValue))")
    }

    func testMixedOrientationsAcrossPagesIsReviewNotBlocking() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let plain = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: 2)
        // Rotate only the second page. This changes its effective (portrait/landscape)
        // orientation without changing its raw crop-box dimensions, so it triggers
        // mixedOrientations without also triggering the (blocking) mixedPaperSizes check.
        guard let document = PDFDocument(url: plain), let secondPage = document.page(at: 1) else {
            XCTFail("Fixture PDF did not open")
            return
        }
        secondPage.rotation = 90
        let source = base.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(document.write(to: source))

        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "rotated.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertFalse(report.issues.contains { $0.code == .mixedPaperSizes }, "issues=\(report.issues.map(\.code.rawValue))")
        XCTAssertTrue(report.issues.contains { $0.code == .mixedOrientations && $0.severity == .review })
        // No other issue on this fixture is blocking, so the overall readiness must land on
        // .review, not be pushed all the way to .blocked or left at .ready.
        XCTAssertEqual(report.readiness, .review, "issues=\(report.issues.map(\.code.rawValue))")
    }

    func testBlockingIssueSortsAheadOfReviewIssues() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("mixed-and-oversized.pdf")
        try SampleDocumentFactory.makePDF(
            at: source,
            papers: [.a4Portrait, .a4Landscape],
            contentTouchesEdge: false
        )
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "mixed-and-oversized.pdf",
            // Force a blocking byteLimitExceeded issue alongside the review-level
            // mixedOrientations issue this fixture already produces.
            byteCount: 999_000_000,
            sha256: try FileHash.sha256(of: source)
        )
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertTrue(report.issues.count >= 2, "issues=\(report.issues.map(\.code.rawValue))")
        XCTAssertEqual(report.issues.first?.severity, .blocking, "issues=\(report.issues.map { "\($0.code.rawValue)=\($0.severity)" })")
        XCTAssertEqual(report.readiness, .blocked)
    }

    func testLowImageResolutionBoundaryIsExactly150DPIInIsolation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("single.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile

        // Exactly at 150 DPI, isolated from any other page: must not be flagged as low
        // resolution.
        let atBoundary = SourceDescriptor(
            kind: .imagePDF,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "single.pdf",
            byteCount: 1_000,
            sha256: "fixture",
            effectiveImageDPIByPage: [0: 150]
        )
        let atReport = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: atBoundary, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertFalse(atReport.issues.contains { $0.code == .lowImageResolution }, "issues=\(atReport.issues.map(\.code.rawValue))")

        // Just under 150 DPI, isolated: must be flagged.
        let underBoundary = SourceDescriptor(
            kind: .imagePDF,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "single.pdf",
            byteCount: 1_000,
            sha256: "fixture",
            effectiveImageDPIByPage: [0: 149.9]
        )
        let underReport = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: underBoundary, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertTrue(underReport.issues.contains { $0.code == .lowImageResolution }, "issues=\(underReport.issues.map(\.code.rawValue))")

        // Well above 150 DPI, isolated: must not be flagged either. Without this third point, a
        // boundary shift and an inequality flip (`<` -> `!=`) look identical at only the 150/149.9
        // pair, since neither differs from `<` at exactly those two values.
        let wellAbove = SourceDescriptor(
            kind: .imagePDF,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "single.pdf",
            byteCount: 1_000,
            sha256: "fixture",
            effectiveImageDPIByPage: [0: 1_000]
        )
        let wellAboveReport = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: wellAbove, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertFalse(wellAboveReport.issues.contains { $0.code == .lowImageResolution }, "issues=\(wellAboveReport.issues.map(\.code.rawValue))")
    }

    func testSingleBlockingIssueAloneYieldsBlockedReadiness() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("three.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 3)
        let profile = PrintProfile(
            id: "fixture.single-blocking",
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
        let descriptor = SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: source.lastPathComponent,
            originalDisplayName: "three.pdf",
            byteCount: Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: source)
        )
        let report = try await NativePreflightAnalyser(now: { Self.fixedDate }).analyse(
            document: StagedDocument(descriptor: descriptor, url: source),
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertEqual(report.issues.map(\.code), [.pageLimitExceeded], "issues=\(report.issues.map(\.code.rawValue))")
        XCTAssertEqual(report.readiness, .blocked)
    }

    func testContentBoundsDetectorTreats248AsWhiteAndAnySingleChannelBelowAsContent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        func solidFillPage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGPDFPage {
            let url = base.appendingPathComponent("\(UUID().uuidString).pdf")
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                throw AppError(.renderFailed)
            }
            let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
            var mediaBox = rect
            let mediaBoxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBoxData] as CFDictionary)
            context.setFillColor(CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1))
            context.fill(rect)
            context.endPDFPage()
            context.closePDF()
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
                throw AppError(.corruptPDF, retryable: false)
            }
            return page
        }

        // Every existing blank/non-blank test fixture used colors where every RGB channel
        // crossed the 248 threshold together, which can never distinguish the `||` from a `&&`,
        // nor tell which channel's `< 248` comparison (if any) actually drives the result. These
        // isolate one channel at a time.

        // Exactly at the threshold in every channel: must read as white (no content detected).
        let atThreshold = try solidFillPage(red: 248, green: 248, blue: 248)
        XCTAssertNil(PDFContentBoundsDetector.detect(page: atThreshold, cropBox: atThreshold.getBoxRect(.cropBox)))

        // Only the red channel dips below 248; green and blue stay at pure white (255). The
        // `||` alone must still flag this as content.
        let redOnly = try solidFillPage(red: 247, green: 255, blue: 255)
        XCTAssertNotNil(PDFContentBoundsDetector.detect(page: redOnly, cropBox: redOnly.getBoxRect(.cropBox)))

        // Only the green channel.
        let greenOnly = try solidFillPage(red: 255, green: 247, blue: 255)
        XCTAssertNotNil(PDFContentBoundsDetector.detect(page: greenOnly, cropBox: greenOnly.getBoxRect(.cropBox)))

        // Only the blue channel.
        let blueOnly = try solidFillPage(red: 255, green: 255, blue: 247)
        XCTAssertNotNil(PDFContentBoundsDetector.detect(page: blueOnly, cropBox: blueOnly.getBoxRect(.cropBox)))
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
