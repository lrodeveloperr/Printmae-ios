import XCTest
import Foundation
import Dispatch
import Darwin
@testable import PrintMaeEngine

final class MemoryBudgetTests: XCTestCase {
    func testTwoHundredPageThirtyMegabyteImportMemoryAndTemporaryStorage() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "iPhone 16e",
            "Memory and storage budgets are measured on the iPhone 16e simulator job."
        )

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeMemoryPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("200-pages-30MB.pdf")
        try PerformanceTestSupport.makeRasterPDF(at: source, pageCount: 200, pixelWidth: 223, seed: 25_092_502)
        let sourceBytes = try PerformanceTestSupport.fileSize(source)
        XCTAssertTrue((28_000_000 ... 32_000_000).contains(sourceBytes), "Fixture is \(sourceBytes) bytes")

        let repositoryRoot = base.appendingPathComponent("repository", isDirectory: true)
        let importer = LocalDocumentImporter(stagingRoot: repositoryRoot.appendingPathComponent("Staging", isDirectory: true))
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

        let sampler = PeakResidentMemorySampler()
        sampler.start()
        defer { _ = sampler.stop() }
        let staged = try await importer.stage(source)
        let report = try await NativePreflightAnalyser(now: { Date() }).analyse(
            document: staged,
            profile: profile,
            target: .a4Portrait
        )
        let peakMemoryMB = sampler.stop()
        XCTAssertEqual(report.pageCount, 200)

        let storedBytes = try PerformanceTestSupport.recursiveSize(repositoryRoot)
        let storageMultiplier = Double(storedBytes) / Double(sourceBytes)
        print("PERF reference=iPhone-16e-simulator peak-memory=\(peakMemoryMB)MB storage-multiplier=\(storageMultiplier) fixture=\(sourceBytes)bytes stored=\(storedBytes)bytes")
        XCTAssertLessThanOrEqual(peakMemoryMB, 350, "Peak resident memory exceeded 350 MB")
        XCTAssertLessThanOrEqual(storageMultiplier, 3.0, "Temporary storage exceeded 3x the source PDF")
    }
}

private final class PeakResidentMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakBytes: UInt64 = 0
    private var timer: DispatchSourceTimer?

    func start() {
        sample()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "PrintMae.MemoryBudgetSampler"))
        source.schedule(deadline: .now(), repeating: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    func stop() -> Double {
        sample()
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return Double(peakBytes) / (1024 * 1024)
    }

    private func sample() {
        guard let bytes = Self.currentPhysicalFootprint() else { return }
        lock.lock()
        peakBytes = max(peakBytes, bytes)
        lock.unlock()
    }

    private static func currentPhysicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { values in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), values, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
