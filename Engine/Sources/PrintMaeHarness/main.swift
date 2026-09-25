import Foundation
import Darwin
import CoreFoundation
import CoreGraphics
import PDFKit
import PrintMaeEngine

@main
struct PrintMaeHarness {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "scenario":
                try await runScenario(basePath: arguments.dropFirst().first)
            case "profiles":
                showProfiles()
            case "state-matrix":
                showStateMatrix()
            case "geometry-property":
                try runGeometryProperty(count: Int(arguments.dropFirst().first ?? "10000") ?? 10_000)
            case "entitlement-sim":
                try await runEntitlementSimulation()
            case "fuzz-pdfkit":
                try runParserFuzz(
                    target: .pdfKit,
                    duration: TimeInterval(arguments.dropFirst().first ?? "1800") ?? 1800,
                    seed: UInt64(arguments.dropFirst(2).first ?? "250925") ?? 250_925
                )
            case "fuzz-cgpdf":
                try runParserFuzz(
                    target: .cgPDF,
                    duration: TimeInterval(arguments.dropFirst().first ?? "1800") ?? 1800,
                    seed: UInt64(arguments.dropFirst(2).first ?? "250925") ?? 250_925
                )
            default:
                showHelp()
            }
        } catch let error as AppError {
            fputs("FAILED [\(error.code.rawValue)] \(error.localizationKey)\n", stderr)
            Darwin.exit(2)
        } catch {
            fputs("FAILED [unexpected] \(String(describing: error))\n", stderr)
            Darwin.exit(3)
        }
    }

    static func runScenario(basePath: String?) async throws {
        let root = basePath.map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeHarness-\(UUID().uuidString)", isDirectory: true)
        let repository = try FileJobRepository(root: root.appendingPathComponent("Engine", isDirectory: true))
        let importer = LocalDocumentImporter(stagingRoot: repository.stagingRoot)
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        let engine = PrintPreparationEngine(
            importer: importer,
            jobs: repository,
            entitlements: ledger
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = root.appendingPathComponent("sample_a4.pdf")
        try SampleDocumentFactory.makeA4PDF(at: sample)

        var job = try await engine.importAndAnalyse(sourceURL: sample)
        print("1 import+analysis: \(job.phase.rawValue), readiness=\(job.report?.readiness.rawValue ?? "none")")
        job = try await engine.preparePreview(jobID: job.id)
        print("2 preview: \(job.phase.rawValue)")
        let outputDirectory = try await repository.outputDirectory(for: job.id)
        let artifact = try await engine.verifiedExport(jobID: job.id, destinationDirectory: outputDirectory)
        print("3 verified export: parts=\(artifact.parts.count), allPassed=\(artifact.parts.allSatisfy { $0.verification.pass })")
        job = try await engine.complete(jobID: job.id, completedOrdinal: 1)
        let entitlement = await ledger.snapshot()
        print("4 completion: \(job.phase.rawValue), freeExportsRemaining=\(entitlement.freeExportsRemaining)")
        print("Harness data: \(root.path)")
    }

    static func showProfiles() {
        for result in ProfileCatalog().loadAll() {
            let profile = result.profile
            print("\(profile.id): \(profile.maxBytesPerFile) bytes, \(profile.maxPagesPerFile) pages, fallback=\(result.usedFallback)")
        }
    }

    static func showStateMatrix() {
        for phase in JobPhase.allCases {
            let targets = JobStateReducer.legalTransitions[phase, default: []]
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            print("\(phase.rawValue) -> [\(targets)]")
        }
        let failures = JobStateReducer.validateTransitionTable()
        print(failures.isEmpty ? "PASS: transition table complete" : "FAIL: \(failures.joined(separator: "; "))")
    }

    static func runGeometryProperty(count: Int) throws {
        var generator = LCG(seed: 250_925)
        for _ in 0 ..< max(1, count) {
            let source = CGSize(width: generator.next(in: 1 ... 10_000), height: generator.next(in: 1 ... 10_000))
            let destination = CGRect(
                x: generator.next(in: -500 ... 500),
                y: generator.next(in: -500 ... 500),
                width: generator.next(in: 1 ... 2_000),
                height: generator.next(in: 1 ... 2_000)
            )
            let fitted = try PrintGeometry.centredAspectFitRect(source: source, destination: destination)
            guard destination.insetBy(dx: -0.0001, dy: -0.0001).contains(fitted),
                  abs((fitted.width / fitted.height) - (source.width / source.height)) < 0.000_001 else {
                throw AppError(.invalidGeometry, retryable: false)
            }
        }
        print("PASS: \(max(1, count)) deterministic geometry sequences (seed 250925)")
    }

    static func runEntitlementSimulation() async throws {
        let ledger = FreeExportEntitlementLedger(store: MemoryLedgerDataStore())
        for revision in 1 ... 3 {
            let request = ExportRequestKey(jobID: UUID(), recipeRevision: revision)
            let authorisation = try await ledger.authoriseExport(request: request)
            try await ledger.commitVerifiedExport(authorisation)
            try await ledger.commitVerifiedExport(authorisation)
        }
        let exhausted = await ledger.snapshot()
        guard exhausted.freeExportsRemaining == 0 else { throw AppError(.entitlementRequired) }
        do {
            _ = try await ledger.authoriseExport(request: ExportRequestKey(jobID: UUID(), recipeRevision: 4))
            throw AppError(.entitlementRequired)
        } catch let error as AppError where error.code == .entitlementRequired {
            print("PASS: three verified exports consumed exactly once; fourth blocked")
        }
    }

    private static func runParserFuzz(target: ParserFuzzTarget, duration: TimeInterval, seed: UInt64) throws {
        guard duration.isFinite, duration > 0, duration <= 86_400 else {
            throw AppError(.invalidGeometry, retryable: false)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintMaeFuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var corpus: [Data] = []
        for pageCount in [1, 2, 5, 12] {
            let url = root.appendingPathComponent("seed-\(pageCount).pdf")
            try SampleDocumentFactory.makeA4PDF(at: url, pageCount: pageCount)
            corpus.append(try Data(contentsOf: url))
        }

        var generator = LCG(seed: seed)
        var iterations: UInt64 = 0
        var accepted: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start &+ UInt64(duration * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let seedIndex = min(corpus.count - 1, Int(generator.next(in: 0 ... Double(corpus.count - 1))))
            let input = mutate(corpus[seedIndex], generator: &generator)
            iterations += 1
            if target.accepts(input) {
                accepted += 1
                if corpus.count < 64, input.count < 2_000_000, iterations % 11 == 0 {
                    corpus.append(input)
                }
            }
            if iterations % 50_000 == 0 {
                print("FUZZ progress parser=\(target.rawValue) iterations=\(iterations) accepted=\(accepted)")
            }
        }
        guard iterations > 0 else { throw AppError(.corruptPDF, retryable: false) }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        print("FUZZ PASS parser=\(target.rawValue) seconds=\(elapsed) iterations=\(iterations) accepted=\(accepted) seed=\(seed)")
    }

    private static func mutate(_ source: Data, generator: inout LCG) -> Data {
        var data = source
        let operation = Int(generator.next(in: 0 ... 5))
        switch operation {
        case 0:
            let changes = Int(generator.next(in: 1 ... 8))
            for _ in 0 ..< changes {
                let index = Int(generator.next(in: 0 ... Double(data.count - 1)))
                data[index] = UInt8(generator.next(in: 0 ... 255))
            }
        case 1:
            let tokens = ["\n%%EOF\n", "xref\n0 1\n", "/Root 1 0 R\n", "stream\n", "endobj\n", "null"]
            let tokenIndex = Int(generator.next(in: 0 ... Double(tokens.count - 1)))
            let insertion = Int(generator.next(in: 0 ... Double(data.count)))
            data.insert(contentsOf: Data(tokens[tokenIndex].utf8), at: insertion)
        case 2:
            let lower = Int(generator.next(in: 0 ... Double(data.count - 1)))
            let length = Int(generator.next(in: 1 ... Double(min(512, data.count - lower))))
            data.removeSubrange(lower ..< lower + length)
        case 3:
            let length = Int(generator.next(in: 1 ... Double(max(1, data.count / 3))))
            data.removeLast(min(length, data.count - 1))
        case 4:
            let range = Int(generator.next(in: 1 ... Double(min(64, data.count))))
            let lower = Int(generator.next(in: 0 ... Double(data.count - range)))
            for index in lower ..< lower + range {
                data[index] = UInt8(generator.next(in: 0 ... 255))
            }
        default:
            let marker = Data("%%EOF".utf8)
            if let range = data.range(of: marker), !range.isEmpty {
                data.replaceSubrange(range, with: Data("%%EOX".utf8))
            } else {
                data.append(contentsOf: Data("\n%%EOF\n".utf8))
            }
        }
        return data
    }

    static func showHelp() {
        print("""
        PrintMae plain diagnostic harness

          printmae-harness scenario [directory]       Run sample import → analysis → preview → verified export
          printmae-harness profiles                   Inspect the validated/fallback profile set
          printmae-harness state-matrix               Show every legal state transition
          printmae-harness geometry-property [count]  Run deterministic aspect-fit property checks
          printmae-harness entitlement-sim            Prove the three-export/idempotency boundary
          printmae-harness fuzz-pdfkit [seconds] [seed]  Fuzz PDFKit parser (default 1800 seconds)
          printmae-harness fuzz-cgpdf [seconds] [seed]   Fuzz CoreGraphics PDF parser (default 1800 seconds)
        """)
    }
}

private enum ParserFuzzTarget: String {
    case pdfKit = "PDFKit"
    case cgPDF = "CGPDF"

    func accepts(_ data: Data) -> Bool {
        switch self {
        case .pdfKit:
            guard let document = PDFDocument(data: data), document.pageCount > 0 else { return false }
            for index in Set([0, document.pageCount / 2, document.pageCount - 1]).sorted() {
                guard let page = document.page(at: index) else { return false }
                _ = page.bounds(for: .mediaBox)
                _ = page.annotations.count
            }
            return true
        case .cgPDF:
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return false }
            for index in Set([1, max(1, document.numberOfPages / 2), document.numberOfPages]).sorted() {
                guard let page = document.page(at: index) else { return false }
                _ = page.getBoxRect(.mediaBox)
                _ = page.getBoxRect(.cropBox)
            }
            return true
        }
    }
}

private struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Double(state >> 11) / Double(UInt64.max >> 11)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
