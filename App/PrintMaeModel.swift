import Foundation
import SwiftUI
import PDFKit
import PrintMaeEngine
import PrintMaeStoreKit

@MainActor
final class PrintMaeModel: ObservableObject {
    enum Screen: String { case prepare, report, fix, preview, method, result, history, settings }

    @Published var screen: Screen = .prepare
    @Published var importing = false
    @Published var job: PrintJobSnapshot?
    @Published var jobs: [PrintJobSnapshot] = []
    @Published var busyLabel: String?
    @Published var errorMessage: String?
    @Published var showPassword = false
    @Published var showPaywall = false
    @Published var showShare = false
    @Published var showFilesPicker = false
    @Published var selectedMethod = ProfileCatalog.genericID
    @Published var showOriginal = false
    @Published var showSafeArea = true
    @Published var previewPage = 0
    @Published var previewPageCount = 1
    @Published var previewURL: URL?
    @Published var isPro = false
    @Published var freeExportsRemaining = 3
    @Published var productPrice: String?

    let repository: FileJobRepository?
    let engine: PrintPreparationEngine?
    let ledger: FreeExportEntitlementLedger
    let purchase: StoreKitLifetimeController

    var activeID: UUID? { job?.id }
    var isBusy: Bool { busyLabel != nil }
    var effectivePaper: PaperSpec {
        let overrides = job?.editRecipe.actions.compactMap { action -> PaperSpec? in
            if case .normalizePaper(let paper) = action { return paper }
            return nil
        }
        return overrides?.last ?? job?.targetPaper ?? .a4Portrait
    }

    init() {
        let ledger = FreeExportEntitlementLedger()
        self.ledger = ledger
        purchase = StoreKitLifetimeController(ledger: ledger)
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("PrintMae", isDirectory: true)
            let repository = try FileJobRepository(root: support)
            self.repository = repository
            engine = PrintPreparationEngine(
                importer: LocalDocumentImporter(stagingRoot: repository.stagingRoot),
                jobs: repository, entitlements: ledger
            )
        } catch {
            repository = nil
            engine = nil
            errorMessage = L("作業フォルダを準備できませんでした。空き容量を確認して、もう一度起動してください。")
        }
    }

    func start() async {
        await purchase.startObservingTransactions()
        _ = try? await purchase.refreshCurrentEntitlement()
        await refreshEntitlement()
        guard let repository, let engine else { return }
        let days = UserDefaults.standard.object(forKey: "retentionDays") == nil
            ? 1 : UserDefaults.standard.integer(forKey: "retentionDays")
        _ = try? await repository.cleanupCompletedJobs(olderThan: Date().addingTimeInterval(-Double(days) * 24 * 3600))
        if let restored = try? await engine.resumeActiveJob() {
            accept(restored)
            if screen == .preview { await makePreview() }
        }
        await refreshHistory()
    }

    func refreshEntitlement() async {
        let state = await ledger.snapshot()
        isPro = state.permitsUnlimitedExports
        freeExportsRemaining = state.freeExportsRemaining
    }

    func importFiles(_ urls: [URL]) {
        guard let engine, !urls.isEmpty, !isBusy else { return }
        busyLabel = L("ページを確認しています")
        errorMessage = nil
        Task {
            do {
                let result: PrintJobSnapshot
                if urls.count == 1 && urls[0].pathExtension.lowercased() == "pdf" {
                    result = try await engine.importAndAnalyse(sourceURL: urls[0], profileID: defaultProfile, target: defaultPaper)
                } else {
                    result = try await engine.importImagesAndAnalyse(sourceURLs: urls, profileID: defaultProfile, target: defaultPaper)
                }
                accept(result)
                await refreshHistory()
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func trySample() {
        guard !isBusy else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("printmae-sample-\(UUID().uuidString).pdf")
            try SampleDocumentFactory.makeA4PDF(at: url)
            importFiles([url])
        } catch { show(error) }
    }

    func unlock(_ password: String) {
        guard let engine, let id = activeID, !isBusy else { return }
        busyLabel = L("ページを確認しています")
        Task {
            do {
                let result = try await engine.submitPassword(jobID: id, password: password)
                showPassword = false
                accept(result)
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func reviewFixes() { screen = .fix }

    func applyRecommendedFixes() {
        guard let engine, let job, !isBusy else { return }
        let actions = job.report?.issues.compactMap(\.suggestedFix) ?? []
        let unique = actions.reduce(into: [FixAction]()) { result, action in
            if !result.contains(action) { result.append(action) }
        }
        busyLabel = L("印刷用PDFを整えています")
        Task {
            do {
                var result = job
                for action in unique { result = try await engine.applyFix(jobID: job.id, action: action) }
                if result.phase == .reportReady { result = try await engine.preparePreview(jobID: job.id) }
                accept(result)
                await makePreview()
                screen = .preview
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func apply(_ action: FixAction) {
        guard let engine, let id = activeID, !isBusy else { return }
        busyLabel = L("プレビューを更新しています")
        Task {
            do {
                let result = try await engine.applyFix(jobID: id, action: action)
                accept(result)
                await makePreview()
                screen = .preview
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func undo() { editHistory { engine, id in try await engine.undo(jobID: id) } }
    func redo() { editHistory { engine, id in try await engine.redo(jobID: id) } }

    private func editHistory(_ action: @escaping (PrintPreparationEngine, UUID) async throws -> PrintJobSnapshot) {
        guard let engine, let id = activeID, !isBusy else { return }
        busyLabel = L("プレビューを更新しています")
        Task {
            do {
                accept(try await action(engine, id))
                await makePreview()
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func openPreview() {
        guard let engine, let id = activeID, !isBusy else { return }
        busyLabel = L("実寸プレビューを準備しています")
        Task {
            do {
                accept(try await engine.preparePreview(jobID: id))
                await makePreview()
                screen = .preview
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func makePreview() async {
        guard let repository, let job else { return }
        previewPage = 0
        do {
            let staged = try await repository.stagedDocument(for: job.id)
            if job.editRecipe.actions.isEmpty {
                previewURL = staged.url
                previewPageCount = job.report?.pageCount ?? 1
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("preview-\(job.id.uuidString)-\(job.editRecipe.revision).pdf")
            let manifest = try await NativePDFRepairer().render(
                document: staged, recipe: job.editRecipe,
                profile: ProfileCatalog().load(job.selectedProfileID).profile,
                target: job.targetPaper, destination: destination
            )
            previewURL = manifest.parts.first?.temporaryURL
            previewPageCount = manifest.parts.first?.pageIndexes.count ?? 1
        } catch {
            previewURL = nil
            show(error)
        }
    }

    func chooseMethod(_ id: String) {
        guard let engine, let job, !isBusy else { return }
        selectedMethod = id
        busyLabel = L("印刷方法の条件と照合しています")
        Task {
            do {
                let oldReadiness = job.report?.readiness
                let changed = try await engine.changeProfile(jobID: job.id, profileID: id)
                accept(changed)
                if changed.report?.readiness != oldReadiness && changed.report?.readiness != .ready {
                    screen = .report
                } else {
                    accept(try await engine.preparePreview(jobID: job.id))
                    await makePreview()
                    screen = .method
                }
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func export() {
        guard let engine, let repository, let id = activeID, !isBusy else { return }
        busyLabel = L("印刷用PDFを作成しています")
        Task {
            do {
                let directory = try await repository.outputDirectory(for: id)
                _ = try await engine.verifiedExport(jobID: id, destinationDirectory: directory)
                job = try await repository.require(id)
                screen = .result
                await refreshEntitlement()
                await refreshHistory()
            } catch let error as AppError where error.code == .entitlementRequired {
                showPaywall = true
                await loadPrice()
            } catch {
                if let failed = try? await repository.require(id), failed.phase == .recoverableFailure {
                    if let recovered = try? await engine.retryAfterFailure(jobID: id) {
                        accept(recovered)
                        await makePreview()
                    }
                }
                show(error)
            }
            busyLabel = nil
        }
    }

    func loadPrice() async {
        do {
            let product = try await purchase.productDisplay()
            productPrice = product.displayPrice
        }
        catch { show(error) }
    }

    func buy() {
        guard !isBusy else { return }
        busyLabel = L("購入を確認しています")
        Task {
            do {
                let state = try await purchase.purchase()
                await refreshEntitlement()
                if state.permitsUnlimitedExports {
                    showPaywall = false
                    busyLabel = nil
                    export()
                    return
                }
                else if state.status == .purchasePending { errorMessage = L("購入の承認を待っています。承認後に書き出せます。") }
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func restore() {
        guard !isBusy else { return }
        busyLabel = L("購入を確認しています")
        Task {
            do {
                let state = try await purchase.restore()
                await refreshEntitlement()
                if state.permitsUnlimitedExports { showPaywall = false }
                else { errorMessage = L("復元できる購入が見つかりませんでした。") }
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func openShare() {
        guard let engine, let id = activeID, job?.export != nil, !isBusy else { return }
        busyLabel = L("共有の準備をしています")
        Task {
            do { accept(try await engine.beginSharing(jobID: id)); showShare = true }
            catch { show(error) }
            busyLabel = nil
        }
    }

    func dismissShare() {
        guard let engine, let id = activeID else { return }
        Task {
            if let result = try? await engine.shareCancelled(jobID: id) { accept(result) }
            screen = .result
        }
    }

    func finish() {
        guard let engine, let id = activeID else { return }
        Task {
            do {
                accept(try await engine.complete(jobID: id, completedOrdinal: jobs.filter { $0.phase == .completed }.count + 1))
                if UserDefaults.standard.object(forKey: "retentionDays") != nil,
                   UserDefaults.standard.integer(forKey: "retentionDays") == 0, let repository {
                    _ = try? await repository.cleanupCompletedJobs(olderThan: Date())
                }
                await refreshHistory()
                screen = .prepare
            } catch { show(error) }
        }
    }

    func openHistory(_ item: PrintJobSnapshot) {
        guard let repository else { return }
        Task {
            if let export = item.export, export.parts.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) {
                job = item
                screen = .result
            } else if (try? await repository.stagedDocument(for: item.id)) != nil {
                accept(item)
                if screen == .preview { await makePreview() }
            } else {
                UserDefaults.standard.set(item.targetPaper.rawValue, forKey: "defaultPaper")
                UserDefaults.standard.set(item.selectedProfileID, forKey: "defaultProfile")
                screen = .prepare
                importing = true
            }
        }
    }

    func deleteAll() {
        guard let repository, !isBusy else { return }
        busyLabel = L("書類を削除しています")
        Task {
            do {
                try await repository.deleteAllDocumentsAndJobs()
                job = nil; jobs = []; previewURL = nil; screen = .prepare
            } catch { show(error) }
            busyLabel = nil
        }
    }

    func refreshHistory() async {
        if let repository { jobs = (try? await repository.history()) ?? [] }
    }

    func back() {
        switch screen {
        case .fix: screen = .report
        case .report: screen = .prepare
        case .preview: screen = .report
        case .method: screen = .preview
        case .result: screen = .prepare
        case .history, .settings: screen = .prepare
        case .prepare: break
        }
    }

    private func accept(_ value: PrintJobSnapshot) {
        job = value
        selectedMethod = value.selectedProfileID
        switch value.phase {
        case .awaitingPassword: showPassword = true
        case .reportReady: screen = .report
        case .previewReady: screen = .preview
        case .exportVerified, .sharing: screen = .result
        case .completed: screen = .prepare
        case .recoverableFailure: screen = value.report == nil ? .prepare : .preview
        default: break
        }
    }

    private func show(_ error: Error) {
        let mapped = AppError.map(error)
        let translated = L(mapped.localizationKey)
        errorMessage = translated == mapped.localizationKey ? L("処理を完了できませんでした。もう一度お試しください。") : translated
    }

    private var defaultPaper: PaperSpec {
        PaperSpec(rawValue: UserDefaults.standard.string(forKey: "defaultPaper") ?? "a4Portrait") ?? .a4Portrait
    }

    private var defaultProfile: String {
        UserDefaults.standard.string(forKey: "defaultProfile") ?? ProfileCatalog.genericID
    }
}
