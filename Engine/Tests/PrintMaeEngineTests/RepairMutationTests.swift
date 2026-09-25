import XCTest
import CoreGraphics
import PDFKit
@testable import PrintMaeEngine

final class RepairMutationTests: XCTestCase {
    private static let fixedDate = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func descriptor(for url: URL, byteCount: Int64? = nil) throws -> SourceDescriptor {
        SourceDescriptor(
            kind: .pdf,
            stagedRelativePath: url.lastPathComponent,
            originalDisplayName: url.lastPathComponent,
            byteCount: byteCount ?? Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try FileHash.sha256(of: url)
        )
    }

    func testOutlineAloneCountsAsAnInteractiveFeature() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: 1)
        guard let document = PDFDocument(url: plain), let page = document.page(at: 0) else {
            XCTFail("Fixture PDF did not open")
            return
        }
        // No annotations anywhere on this document, but a non-empty outline. This alone must
        // be enough to trip hasInteractiveFeatures (the other side of the `||`), independent
        // of whatever the annotations check contributes.
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Section 1"
        child.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(child, at: 0)
        document.outlineRoot = root
        let source = base.appendingPathComponent("outlined.pdf")
        XCTAssertTrue(document.write(to: source))

        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let output = base.appendingPathComponent(".outline-copy.partial.pdf")
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: output
        )
        XCTAssertEqual(manifest.parts.count, 1)
        XCTAssertFalse(manifest.flattened)
        // Only the copy-through path preserves the outline byte-for-byte; the generic redraw
        // path (which would run if hasInteractiveFeatures were wrongly computed as false here)
        // draws page content only and produces no outline at all.
        guard let outputDocument = PDFDocument(url: output) else {
            XCTFail("Rendered output did not open")
            return
        }
        XCTAssertNotNil(outputDocument.outlineRoot)
        XCTAssertEqual(outputDocument.outlineRoot?.numberOfChildren, 1)
    }

    func testInteractiveFeaturesExceedingPageLimitRequiresFlatteningApproval() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = PrintProfile(
            id: "fixture.page-limit",
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

        func annotated(pageCount: Int, name: String) throws -> URL {
            let plain = base.appendingPathComponent("\(name)-plain.pdf")
            try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: pageCount)
            guard let document = PDFDocument(url: plain), let page = document.page(at: 0) else {
                throw AppError(.corruptPDF, retryable: false)
            }
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil))
            let source = base.appendingPathComponent("\(name).pdf")
            XCTAssertTrue(document.write(to: source))
            return source
        }

        // Exactly at the page-count limit: the copy-through path must still be taken.
        let atLimit = try annotated(pageCount: 2, name: "at-limit")
        let atLimitOutput = base.appendingPathComponent(".at-limit.partial.pdf")
        let atLimitManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: atLimit), url: atLimit),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: atLimitOutput
        )
        XCTAssertEqual(atLimitManifest.parts.count, 1)
        XCTAssertFalse(atLimitManifest.flattened)

        // One page over the limit: flattening (or an explicit recipe action) must now be
        // required instead of a silent copy-through.
        let overLimit = try annotated(pageCount: 3, name: "over-limit")
        let overLimitOutput = base.appendingPathComponent(".over-limit.partial.pdf")
        do {
            _ = try await NativePDFRepairer().render(
                document: StagedDocument(descriptor: try descriptor(for: overLimit), url: overLimit),
                recipe: EditRecipe(),
                profile: profile,
                target: .a4Portrait,
                destination: overLimitOutput
            )
            XCTFail("Expected flattening-approval-required error")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .renderFailed)
            XCTAssertEqual(error.localizationKey, "error.flatteningApprovalRequired")
        }
    }

    func testInteractiveFeaturesExceedingByteLimitRequiresFlatteningApproval() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = PrintProfile(
            id: "fixture.byte-limit",
            displayNameKey: "fixture",
            reviewedAt: Self.fixedDate,
            reviewValidDays: 1,
            sourceURLs: [],
            acceptedOutputTypes: ["com.adobe.pdf"],
            maxBytesPerFile: 500_000,
            maxPagesPerFile: 99,
            allowedPaper: Set(PaperSpec.allCases),
            allowsEncryptedPDF: false,
            requiresUniformPaperSize: true,
            safeInsetMillimetres: .conservative
        )
        let plain = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: plain, pageCount: 1)
        guard let document = PDFDocument(url: plain), let page = document.page(at: 0) else {
            XCTFail("Fixture PDF did not open")
            return
        }
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil))
        let source = base.appendingPathComponent("annotated.pdf")
        XCTAssertTrue(document.write(to: source))

        // The declared byte count, not the actual file size, is what's compared against the
        // profile limit, so the boundary can be hit exactly regardless of real fixture size.
        let atLimitOutput = base.appendingPathComponent(".byte-at-limit.partial.pdf")
        let atLimitManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source, byteCount: 500_000), url: source),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: atLimitOutput
        )
        XCTAssertEqual(atLimitManifest.parts.count, 1)

        let overLimitOutput = base.appendingPathComponent(".byte-over-limit.partial.pdf")
        do {
            _ = try await NativePDFRepairer().render(
                document: StagedDocument(descriptor: try descriptor(for: source, byteCount: 500_001), url: source),
                recipe: EditRecipe(),
                profile: profile,
                target: .a4Portrait,
                destination: overLimitOutput
            )
            XCTFail("Expected flattening-approval-required error")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .renderFailed)
            XCTAssertEqual(error.localizationKey, "error.flatteningApprovalRequired")
        }
    }

    func testFlattenedFlagReflectsFlattenAndCompressIndependently() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile

        let baseline = base.appendingPathComponent(".baseline.partial.pdf")
        let baselineManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(),
            profile: profile,
            target: .a4Portrait,
            destination: baseline
        )
        XCTAssertFalse(baselineManifest.flattened, "Neither flattening nor compression was requested")
        XCTAssertEqual(baselineManifest.parts[0].temporaryURL, baseline, "A single part must not carry a _part_ suffix")

        let flattenOnly = base.appendingPathComponent(".flatten-only.partial.pdf")
        let flattenManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(actions: [.flattenForPrint], revision: 1),
            profile: profile,
            target: .a4Portrait,
            destination: flattenOnly
        )
        XCTAssertTrue(flattenManifest.flattened, "flattenForPrint alone must set flattened")

        let compressOnly = base.appendingPathComponent(".compress-only.partial.pdf")
        let compressManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(actions: [.compress(CompressionPolicy())], revision: 1),
            profile: profile,
            target: .a4Portrait,
            destination: compressOnly
        )
        XCTAssertTrue(compressManifest.flattened, "A compression policy alone must also set flattened")
    }

    func testSinglePageStillExceedingBudgetThrowsSinglePageExceedsError() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = PrintProfile(
            id: "fixture.impossible-budget",
            displayNameKey: "fixture",
            reviewedAt: Self.fixedDate,
            reviewValidDays: 1,
            sourceURLs: [],
            acceptedOutputTypes: ["com.adobe.pdf"],
            maxBytesPerFile: 100,
            maxPagesPerFile: 99,
            allowedPaper: Set(PaperSpec.allCases),
            allowsEncryptedPDF: false,
            requiresUniformPaperSize: true,
            safeInsetMillimetres: .conservative
        )
        let source = base.appendingPathComponent("plain.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let output = base.appendingPathComponent(".impossible.partial.pdf")
        do {
            _ = try await NativePDFRepairer().render(
                document: StagedDocument(descriptor: try descriptor(for: source), url: source),
                recipe: EditRecipe(),
                profile: profile,
                target: .a4Portrait,
                destination: output
            )
            XCTFail("A 100-byte budget can never fit a real rendered PDF page")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .verificationFailed)
            XCTAssertEqual(error.localizationKey, "error.singlePageExceedsProfile")
        }
    }

    func testSizeExceedingBudgetTriggersAutomaticResplitIntoSmallerGroups() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("two-pages.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 2)
        let generousProfile = PrintProfile(
            id: "fixture.resplit",
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

        // Self-calibrate against the real renderer's own output rather than guessing byte
        // sizes: measure what a single page costs and what both pages together cost, then
        // pick a budget strictly between the two.
        let onePageProbe = base.appendingPathComponent(".one-page-probe.partial.pdf")
        let onePageManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(actions: [.split(maxPages: 1, maxBytes: 10_000_000)], revision: 1),
            profile: generousProfile,
            target: .a4Portrait,
            destination: onePageProbe
        )
        guard let onePagePart = onePageManifest.parts.first else {
            XCTFail("Expected at least one probed part")
            return
        }
        let onePageBytes = Int64((try onePagePart.temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let twoPageProbe = base.appendingPathComponent(".two-page-probe.partial.pdf")
        let twoPageManifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(),
            profile: generousProfile,
            target: .a4Portrait,
            destination: twoPageProbe
        )
        guard let twoPagePart = twoPageManifest.parts.first else {
            XCTFail("Expected a combined two-page part")
            return
        }
        let twoPageBytes = Int64((try twoPagePart.temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        try XCTSkipUnless(
            twoPageBytes > onePageBytes,
            "Fixture assumption failed: a two-page render (\(twoPageBytes)b) must be larger than a one-page render (\(onePageBytes)b)"
        )
        let threshold = (onePageBytes + twoPageBytes) / 2

        let output = base.appendingPathComponent(".resplit.partial.pdf")
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(actions: [.split(maxPages: 2, maxBytes: threshold)], revision: 1),
            profile: generousProfile,
            target: .a4Portrait,
            destination: output
        )
        // A budget between the one- and two-page costs can only be satisfied by the engine
        // automatically halving the oversized two-page group into two one-page parts.
        XCTAssertEqual(manifest.parts.count, 2, "threshold=\(threshold) one=\(onePageBytes) two=\(twoPageBytes)")
        XCTAssertEqual(manifest.parts.flatMap(\.pageIndexes).sorted(), [0, 1])
        XCTAssertTrue(manifest.parts.allSatisfy { $0.temporaryURL.lastPathComponent.contains("_part_0") })
    }

    func testRasterizedOutputActuallyContainsPageContent() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("content.pdf")
        try SampleDocumentFactory.makeA4PDF(at: source, pageCount: 1)
        let profile = ProfileCatalog(now: { Self.fixedDate }).load(ProfileCatalog.genericID).profile
        let output = base.appendingPathComponent(".flattened.partial.pdf")
        let manifest = try await NativePDFRepairer().render(
            document: StagedDocument(descriptor: try descriptor(for: source), url: source),
            recipe: EditRecipe(actions: [.flattenForPrint], revision: 1),
            profile: profile,
            target: .a4Portrait,
            destination: output
        )
        XCTAssertTrue(manifest.flattened)
        guard let part = manifest.parts.first,
              let cg = CGPDFDocument(part.temporaryURL as CFURL),
              let page = cg.page(at: 1) else {
            XCTFail("Expected a readable rasterized output page")
            return
        }
        // If the rasterization steps (scaling, filling, transforming, drawing the source page,
        // or embedding the JPEG image) were silently skipped, this would render as a blank
        // (all-white) page and the content-bounds detector would find nothing.
        let bounds = PDFContentBoundsDetector.detect(page: page, cropBox: page.getBoxRect(.cropBox))
        XCTAssertNotNil(bounds, "Rasterized output page must not be blank")
    }
}
