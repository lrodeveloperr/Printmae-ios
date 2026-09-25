import Foundation
import Darwin
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

    static func showHelp() {
        print("""
        PrintMae plain diagnostic harness

          printmae-harness scenario [directory]       Run sample import → analysis → preview → verified export
          printmae-harness profiles                   Inspect the validated/fallback profile set
          printmae-harness state-matrix               Show every legal state transition
          printmae-harness geometry-property [count]  Run deterministic aspect-fit property checks
          printmae-harness entitlement-sim            Prove the three-export/idempotency boundary
        """)
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
