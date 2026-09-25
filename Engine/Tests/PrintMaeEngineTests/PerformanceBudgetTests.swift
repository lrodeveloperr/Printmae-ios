import XCTest
import CoreFoundation
import CoreGraphics
import Darwin
import PDFKit
@testable import PrintMaeEngine

final class PerformanceBudgetTests: XCTestCase {
    func testImportToFirstReportP95ForTenMegabytePDF() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeImportPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("20-pages-10MB.pdf")
        try makeRasterPDF(at: source, pageCount: 20, pixelWidth: 400, seed: 25_092_500)
        let sourceBytes = try fileSize(source)
        XCTAssertTrue((9_000_000 ... 11_000_000).contains(sourceBytes), "Fixture is \(sourceBytes) bytes")

        var samples: [Double] = []
        for index in 0 ..< 12 {
            let repositoryRoot = base.appendingPathComponent("run-\(index)", isDirectory: true)
            samples.append(try await measureImport(sourceURL: source, repositoryRoot: repositoryRoot, expectedPageCount: 20))
        }
        let p95 = percentile95(samples)
        print("PERF reference=iPhone-SE-2-simulator import-first-report-p95=\(p95)s fixture=\(sourceBytes)bytes samples=\(samples.count)")
        XCTAssertLessThanOrEqual(p95, 3.0, "Import-to-first-report p95 exceeded 3 seconds")
    }

    func testPreviewPageRenderingP95Under150Milliseconds() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaePreviewPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("20-pages-preview.pdf")
        try makeRasterPDF(at: source, pageCount: 20, pixelWidth: 400, seed: 25_092_501)
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
        let p95 = percentile95(samples)
        print("PERF reference=iPhone-SE-2-simulator preview-render-p95=\(p95)ms samples=\(samples.count)")
        XCTAssertLessThanOrEqual(p95, 150, "Preview page rendering p95 exceeded 150 ms")
    }

    func testTwoHundredPageThirtyMegabyteImportMemoryAndTemporaryStorage() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeMemoryPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("200-pages-30MB.pdf")
        try makeRasterPDF(at: source, pageCount: 200, pixelWidth: 223, seed: 25_092_502)
        let sourceBytes = try fileSize(source)
        XCTAssertTrue((28_000_000 ... 32_000_000).contains(sourceBytes), "Fixture is \(sourceBytes) bytes")

        let repositoryRoot = base.appendingPathComponent("repository", isDirectory: true)
        let importer = LocalDocumentImporter(stagingRoot: repositoryRoot.appendingPathComponent("Staging", isDirectory: true))
        let staged = try await importer.stage(source)
        let profile = PrintProfile(
            id: "perf.stress",
            displayNameKey: "profile.generic",
            reviewedAt: Date(),
            reviewValidDays: 1,
            sourceURLs: [],
            acceptedOutputTypes: ["com.adobe.pdf"],
            maxBytesPerFile: 40_000_000,
            maxPagesPerFile: 250,
            allowedPaper: Set(PaperSpec.allCases),
            allowsEncryptedPDF: false,
            requiresUniformPaperSize: true,
            safeInsetMillimetres: .conservative
        )
        let report = try await NativePreflightAnalyser(now: { Date() }).analyse(
            document: staged,
            profile: profile,
            target: .a4Portrait
        )
        XCTAssertEqual(report.pageCount, 200)

        let storedBytes = try recursiveSize(repositoryRoot)
        let storageMultiplier = Double(storedBytes) / Double(sourceBytes)
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0, "Could not read peak resident memory")
        let peakMemoryMB = Double(usage.ru_maxrss) / (1024 * 1024)
        print("PERF reference=iPhone-SE-2-simulator peak-memory=\(peakMemoryMB)MB storage-multiplier=\(storageMultiplier) fixture=\(sourceBytes)bytes stored=\(storedBytes)bytes")
        XCTAssertLessThanOrEqual(peakMemoryMB, 350, "Peak resident memory exceeded 350 MB")
        XCTAssertLessThanOrEqual(storageMultiplier, 3.0, "Temporary storage exceeded 3x the source PDF")
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

    private func makeRasterPDF(at url: URL, pageCount: Int, pixelWidth: Int, seed: UInt64) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw AppError(.renderFailed)
        }

        var random = seed
        for pageIndex in 0 ..< pageCount {
            var pixels = [UInt8](repeating: 255, count: pixelWidth * pixelWidth * 4)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                pixels[offset] = UInt8(truncatingIfNeeded: random >> 32)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: random >> 40)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: random >> 48)
                pixels[offset + 3] = 255
            }
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: pixelWidth,
                    height: pixelWidth,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: pixelWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else {
                throw AppError(.renderFailed)
            }

            context.beginPDFPage([kCGPDFContextMediaBox: pageRect] as CFDictionary)
            context.draw(image, in: pageRect)
            context.setFillColor(CGColor(red: 0.11, green: 0.18, blue: 0.38, alpha: 1))
            context.fill(CGRect(x: 42, y: 64 + CGFloat(pageIndex % 20), width: pageRect.width - 84, height: 16))
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func recursiveSize(_ directory: URL) throws -> Int64 {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        )
        return try files.reduce(Int64(0)) { total, url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { return total + Int64(values.fileSize ?? 0) }
            if values.isDirectory == true { return total + (try recursiveSize(url)) }
            return total
        }
    }

    private func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }
}
