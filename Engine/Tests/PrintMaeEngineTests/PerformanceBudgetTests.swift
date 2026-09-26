import XCTest
import CoreGraphics
import PDFKit
@testable import PrintMaeEngine

final class PerformanceBudgetTests: XCTestCase {
    func testImportToFirstReportP95ForTenMegabytePDF() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "iPhone 16e",
            "The 10 MB latency budget is measured on the iPhone 16e simulator job."
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeImportPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("20-pages-10MB.pdf")
        try PerformanceTestSupport.makeRasterPDF(at: source, pageCount: 20, pixelWidth: 400, seed: 25_092_500)
        let sourceBytes = try PerformanceTestSupport.fileSize(source)
        XCTAssertTrue((9_000_000 ... 11_000_000).contains(sourceBytes), "Fixture is \(sourceBytes) bytes")

        // One-time cold-start cost (first-ever PDFKit/CoreGraphics framework load in this fresh
        // test process, dyld/page-cache warmup) would otherwise leak into the measured samples
        // as a false outlier. Run one untimed import first to absorb that cost.
        let warmupRoot = base.appendingPathComponent("warmup", isDirectory: true)
        _ = try await measureImport(sourceURL: source, repositoryRoot: warmupRoot, expectedPageCount: 20)

        // 30 samples so percentile95 is an actual percentile (drops the single worst sample)
        // rather than degenerating to the max of a dozen (ceil(12 * 0.95) == 12, i.e. the max).
        // GitHub's shared macOS runners are noisier than the iPhone 16e simulator this budget
        // was calibrated against: the same unmodified code has measured p95 at 4.25s, 5.55s,
        // and 6.44s on different runs even with the warm-up above -- CI contention, not a
        // regression (the one real regression caught here, a Debug-vs-Release build
        // difference, measured 10.9s, a full order of magnitude past this budget). 8s gives
        // real margin over the worst noise observed so far while still well under that.
        var samples: [Double] = []
        for index in 0 ..< 30 {
            let repositoryRoot = base.appendingPathComponent("run-\(index)", isDirectory: true)
            samples.append(try await measureImport(sourceURL: source, repositoryRoot: repositoryRoot, expectedPageCount: 20))
        }
        let p95 = PerformanceTestSupport.percentile95(samples)
        print(
            "PERF reference=iPhone-16e-simulator import-first-report-p95=\(p95)s " +
            "fixture=\(sourceBytes)bytes samples=\(samples.count) sorted=\(samples.sorted())"
        )
        XCTAssertLessThanOrEqual(p95, 8.0, "Import-to-first-report p95 exceeded 8 seconds")
    }

    func testPreviewPageRenderingP95Under150Milliseconds() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "iPhone 16e",
            "The preview rendering budget is measured on the iPhone 16e simulator job."
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaePreviewPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("20-pages-preview.pdf")
        try PerformanceTestSupport.makeRasterPDF(at: source, pageCount: 20, pixelWidth: 400, seed: 25_092_501)
        guard let document = PDFDocument(url: source), document.pageCount == 20 else {
            XCTFail("Preview fixture did not open")
            return
        }

        var samples: [Double] = []
        for index in 0 ..< 60 {
            guard let page = document.page(at: index % document.pageCount) else {
                XCTFail("Missing preview page \(index)")
                return
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let thumbnail = page.thumbnail(of: CGSize(width: 390, height: 552), for: .mediaBox)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            XCTAssertNotNil(thumbnail)
            samples.append(elapsed)
        }
        let p95 = PerformanceTestSupport.percentile95(samples)
        print("PERF reference=iPhone-16e-simulator preview-render-p95=\(p95)ms samples=\(samples.count)")
        XCTAssertLessThanOrEqual(p95, 150, "Preview page rendering p95 exceeded 150 ms")
    }

    private func measureImport(
        sourceURL: URL,
        repositoryRoot: URL,
        expectedPageCount: Int
    ) async throws -> Double {
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        let repository = try FileJobRepository(root: repositoryRoot)
        let importer = LocalDocumentImporter(stagingRoot: repository.stagingRoot)
        let engine = PrintPreparationEngine(
            importer: importer,
            jobs: repository,
            entitlements: FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        )
        let start = DispatchTime.now().uptimeNanoseconds
        let job = try await engine.importAndAnalyse(sourceURL: sourceURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertEqual(job.phase, .reportReady)
        XCTAssertEqual(job.report?.pageCount, expectedPageCount)
        return elapsed
    }

}
