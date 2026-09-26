import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import GoodUseShell
import PrintMaeEngine

@main
struct PrintMaeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PrintMaeModel()
    @AppStorage("uiLanguage") private var uiLanguage = "ja"

    var body: some Scene {
        WindowGroup {
            PrintMaeRoot(model: model)
                .environment(\.locale, Locale(identifier: uiLanguage == "en" ? "en" : "ja"))
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .inactive, let id = model.activeID, let engine = model.engine {
                        Task { try? await engine.flushAutosave(jobID: id) }
                    }
                    if phase == .active { Task { await model.refreshEntitlement() } }
                }
        }
    }
}

private enum Skin {
    static let config: GoodUseShellConfig = {
        guard let url = Bundle.main.url(forResource: "ShellConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? GoodUseShellConfigLoader.decode(data)
        else { preconditionFailure("PrintMae screen configuration is missing") }
        return config
    }()
    static let icons: GoodUseVectorRegistry = {
        guard let registry = try? GoodUseVectorRegistry.bundled() else {
            preconditionFailure("GoodUse icon registry is missing")
        }
        return registry
    }()
    static let indigo = Color(hex: "#304B91")
}

struct PrintMaeRoot: View {
    @ObservedObject var model: PrintMaeModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pendingImages: [URL] = []
    @State private var orderingImages = false
    @State private var password = ""
    @State private var confirmDelete = false
    @State private var customMargin = 5.0
    @AppStorage("uiLanguage") private var uiLanguage = "ja"
    @AppStorage("defaultPaper") private var defaultPaper = "a4Portrait"
    @AppStorage("defaultProfile") private var defaultProfile = ProfileCatalog.genericID
    @AppStorage("retentionDays") private var retentionDays = 1

    var body: some View {
        NavigationStack {
            GoodUseAppShell(
                config: Skin.config,
                currentRoute: "prepare",
                currentScreenID: model.screen.rawValue,
                onNavigate: { _ in },
                label: { L($0) },
                icon: { key, _ in AnyView(GoodUseVectorIcon(iconKey: key, registry: Skin.icons)) },
                bottomPrimaryAction: (model.screen == .history || model.screen == .settings) ? nil : { AnyView(primaryAction) }
            ) { _ in
                GoodUseScreenHost(screen: Skin.config.screen(for: "prepare", screenID: model.screen.rawValue)) { slot in
                    slotContent(slot)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.screen != .prepare {
                        Button { model.back() } label: { Label(L("戻る"), systemImage: "chevron.left") }
                            .accessibilityIdentifier("nav.back")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.screen == .prepare {
                        Button { model.screen = .history } label: { Label(L("履歴"), systemImage: "clock.arrow.circlepath") }
                        Button { model.screen = .settings } label: { Label(L("設定"), systemImage: "gearshape") }
                    }
                }
            }
            .navigationTitle(title)
        }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.pdf, .jpeg, .png, .heic], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if urls.count > 1 && urls.allSatisfy({ $0.pathExtension.lowercased() != "pdf" }) {
                    pendingImages = urls
                    orderingImages = true
                } else if urls.count > 1 {
                    model.errorMessage = L("PDFは1つずつ選んでください。画像は複数選んでまとめられます。")
                } else { model.importFiles(urls) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $orderingImages) { imageOrderSheet }
        .sheet(isPresented: $model.showPassword) { passwordSheet }
        .sheet(isPresented: $model.showPaywall) { paywall }
        .sheet(isPresented: $model.showShare, onDismiss: model.dismissShare) {
            ActivitySheet(urls: model.job?.export?.parts.map(\.url) ?? [])
        }
        .sheet(isPresented: $model.showFilesPicker) {
            FilesExportSheet(urls: model.job?.export?.parts.map(\.url) ?? [])
        }
        .alert(L("確認してください"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L("閉じる"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(L("この端末内の作業用書類と履歴をすべて削除します。購入情報は削除されません。"), isPresented: $confirmDelete) {
            Button(L("すべての書類を削除"), role: .destructive) { model.deleteAll() }
            Button(L("キャンセル"), role: .cancel) { }
        }
        .tint(Skin.indigo)
        .onOpenURL { model.importFiles([$0]) }
    }

    private var title: String {
        switch model.screen {
        case .prepare: L("プリント前")
        case .report: L("印刷前チェック")
        case .fix: L("自動修正の確認")
        case .preview: L("実寸プレビュー")
        case .method: L("印刷方法")
        case .result: L("準備完了")
        case .history: L("履歴")
        case .settings: L("設定")
        }
    }

    @ViewBuilder private func slotContent(_ slot: GoodUseSlot) -> some View {
        switch (model.screen, slot) {
        case (.prepare, .header): header(L("印刷する前に、PDFを確認。"), caption: L("失敗しやすい余白・向き・サイズを先に確認します。"))
        case (.prepare, .primaryContent): prepareContent
        case (.prepare, .footer): caption(L("書類はこの端末内で処理されます"))
        case (.report, .header): header(L("印刷前チェック"), caption: model.job?.source?.originalDisplayName)
        case (.report, .status): reportStatus
        case (.report, .primaryContent): reportContent
        case (.report, .footer): copierFooter
        case (.fix, .header): header(L("適用する修正"), caption: L("元のPDFは変更されません。"))
        case (.fix, .primaryContent): fixesContent
        case (.preview, .header): header(L("実寸プレビュー"), caption: L("用紙の内側まで確認してください。"))
        case (.preview, .primaryContent): previewContent
        case (.preview, .footer): caption(L("実際の仕上がりは店頭のコピー機でも確認してください。"))
        case (.method, .header): header(L("どの方法で印刷しますか？"), caption: nil)
        case (.method, .primaryContent): methodsContent
        case (.method, .footer): caption(L("選んだ方法の条件でもう一度確認します。"))
        case (.result, .header): header(L("印刷用PDFの準備ができました"), caption: nil)
        case (.result, .status): resultStatus
        case (.result, .primaryContent): resultContent
        case (.result, .footer): copierFooter
        case (.history, .header): header(L("履歴"), caption: L("書類を保持していない項目は、再度ファイルを選んでください。"))
        case (.history, .primaryContent): historyContent
        case (.settings, .header): header(L("設定"), caption: nil)
        case (.settings, .primaryContent): settingsContent
        default: EmptyView()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if let busy = model.busyLabel {
            HStack { ProgressView(); Text(busy).font(.subheadline) }
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityElement(children: .combine)
        } else {
            switch model.screen {
            case .prepare:
                GoodUsePrimaryButton(L("ファイルを選ぶ")) { model.importing = true }
                    .accessibilityIdentifier("prepare.import")
            case .report:
                if model.job?.report?.issues.contains(where: { $0.suggestedFix != nil }) == true {
                    GoodUsePrimaryButton(L("まとめて自動で整える")) { model.reviewFixes() }
                } else {
                    GoodUsePrimaryButton(L("実寸プレビューを見る")) { model.openPreview() }
                }
            case .fix:
                GoodUsePrimaryButton(L("この内容で整える")) { model.applyRecommendedFixes() }
            case .preview:
                GoodUsePrimaryButton(L("印刷用PDFを書き出す")) {
                    if defaultProfile == ProfileCatalog.genericID { model.screen = .method }
                    else { model.chooseMethod(defaultProfile) }
                }
            case .method:
                GoodUsePrimaryButton(L("この方法で書き出す")) { model.export() }
            case .result:
                GoodUsePrimaryButton(L("公式アプリまたはFilesへ共有")) { model.openShare() }
            case .history, .settings: EmptyView()
            }
        }
    }

    private func header(_ title: String, caption detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var prepareContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Skin.indigo)
                .accessibilityHidden(true)
            Text(L("PDF・JPEG・PNG・HEIC")).font(.headline)
            Text(L("ファイルを読み込むと、印刷方法に合うか自動で確認します。"))
                .font(.body).foregroundStyle(.secondary)
            GoodUseSecondaryButton(L("サンプルで試す")) { model.trySample() }
            if let job = model.job, job.phase != .completed {
                Divider()
                Button { model.openHistory(job) } label: {
                    Label(L("前回の作業を開く"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var reportStatus: some View {
        let level = model.job?.report?.readiness ?? .review
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: level == .ready ? "checkmark.circle.fill" : level == .review ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(level == .ready ? .green : level == .review ? .orange : .red)
            VStack(alignment: .leading, spacing: 4) {
                Text(level == .ready ? L("準備完了") : level == .review ? L("確認が必要です") : L("このままでは書き出せません"))
                    .font(.headline)
                Text(level == .ready ? L("プレビューで仕上がりを確認してください。") : L("問題と対象ページを確認してから整えてください。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var reportContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let job = model.job, let report = job.report {
                HStack {
                    metric(paperName(model.effectivePaper), L("用紙"))
                    metric(String(format: L("%dページ"), report.pageCount), L("ページ"))
                    metric(formattedBytes(report.inputBytes), L("ファイル"))
                }
                Divider()
                if report.issues.isEmpty { Text(L("見つかった問題はありません。")).font(.subheadline) }
                ForEach(report.issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizedIssue(issue.titleKey)).font(.headline)
                            Text(localizedIssue(issue.consequenceKey)).font(.subheadline).foregroundStyle(.secondary)
                            if let pages = issue.pages?.indexes, !pages.isEmpty {
                                Text(String(format: L("対象ページ: %@"), pages.map { String($0 + 1) }.joined(separator: uiLanguage == "en" ? ", " : "、")))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                if report.issues.contains(where: { $0.suggestedFix != nil }) {
                    Button(L("自分で調整")) { model.openPreview() }.frame(minHeight: 44)
                }
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.subheadline.bold()).lineLimit(2).minimumScaleFactor(0.8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fixesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let actions = model.job?.report?.issues.compactMap(\.suggestedFix) ?? []
            if actions.isEmpty { Text(L("自動で適用できる修正はありません。")) }
            ForEach(actions.indices, id: \.self) { index in
                Label(fixName(actions[index]), systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if actions.contains(where: { if case .flattenForPrint = $0 { return true }; return false }) {
                Text(L("レイアウトを安定させるため、リンクやしおりなどの画面用機能を除いた印刷用PDFを作成します。元のPDFは変更されません。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(L("項目を変更")) { model.openPreview() }.frame(minHeight: 44)
        }
    }

    @ViewBuilder private var previewContent: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 24) {
                previewPaperPane.frame(maxWidth: .infinity)
                previewOptions.frame(maxWidth: 320)
            }
        } else {
            VStack(spacing: 15) { previewPaperPane; previewOptions }
        }
    }

    private var previewPaperPane: some View {
        VStack(spacing: 12) {
            Picker(L("表示"), selection: $model.showOriginal) {
                Text(L("仕上がり")).tag(false)
                Text(L("元のファイル")).tag(true)
            }
            .pickerStyle(.segmented)
            PDFPaperPreview(url: model.showOriginal ? originalURL : model.previewURL,
                            pageIndex: model.previewPage, paper: model.effectivePaper,
                            showsSafeArea: model.showSafeArea)
            HStack {
                Button(L("前のページ")) { model.previewPage -= 1 }.disabled(model.previewPage == 0)
                Spacer()
                Text("\(model.previewPage + 1) / \(model.showOriginal ? (model.job?.report?.pageCount ?? 1) : model.previewPageCount)")
                    .monospacedDigit().accessibilityLabel(String(format: L("%dページ目"), model.previewPage + 1))
                Spacer()
                Button(L("次のページ")) { model.previewPage += 1 }
                    .disabled(model.previewPage + 1 >= (model.showOriginal ? (model.job?.report?.pageCount ?? 1) : model.previewPageCount))
            }
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: model.showOriginal) { _, _ in model.previewPage = 0 }
    }

    private var previewOptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle(L("印刷の安全範囲"), isOn: $model.showSafeArea)
            Divider()
            if let job = model.job {
                Text(String(format: L("%@｜%dページ"), paperName(model.effectivePaper), job.report?.pageCount ?? 0))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup(L("仕上がりを調整")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("用紙と向き")).font(.subheadline.bold())
                    ForEach(PaperSpec.allCases, id: \.self) { paper in
                        Button {
                            model.apply(.normalizePaper(paper))
                        } label: {
                            Label(paperName(paper), systemImage: model.effectivePaper == paper ? "largecircle.fill.circle" : "circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    Divider()
                    Button(L("このページを右に90°回転")) {
                        model.apply(.rotate(pageIndexes: IndexSet(integer: model.previewPage), quarterTurnsClockwise: 1))
                    }.frame(minHeight: 44)
                    Button(L("印刷の安全範囲に収める")) {
                        let inset = ProfileCatalog().load(model.selectedMethod).profile.safeInsetMillimetres
                        model.apply(.fitInsideSafeArea(inset))
                    }.frame(minHeight: 44)
                    Text(L("余白")).font(.subheadline.bold())
                    HStack {
                        Spacer(minLength: 0)
                        ForEach([3.0, 5.0, 10.0], id: \.self) { mm in
                            Button("\(Int(mm)) mm") {
                                model.apply(.addMargins(EdgeInsetsMM(top: mm, leading: mm, bottom: mm, trailing: mm)))
                            }
                        }
                    }.frame(minHeight: 44)
                    Stepper(String(format: L("カスタム：%d mm"), Int(customMargin)), value: $customMargin, in: 0...30, step: 1)
                    Button(L("カスタム余白を適用")) {
                        let mm = customMargin
                        model.apply(.addMargins(EdgeInsetsMM(top: mm, leading: mm, bottom: mm, trailing: mm)))
                    }.frame(minHeight: 44)
                    Button(L("印刷方法の上限を目標に圧縮")) { model.apply(.compress(CompressionPolicy())) }
                        .frame(minHeight: 44)
                    Button(L("印刷方法の上限で分割")) {
                        let profile = ProfileCatalog().load(model.selectedMethod).profile
                        model.apply(.split(maxPages: profile.maxPagesPerFile, maxBytes: profile.maxBytesPerFile))
                    }.frame(minHeight: 44)
                    HStack {
                        Button(L("元に戻す")) { model.undo() }.disabled(model.job?.undoRecipes.isEmpty != false)
                        Spacer()
                        Button(L("やり直す")) { model.redo() }.disabled(model.job?.redoRecipes.isEmpty != false)
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var originalURL: URL? {
        guard let name = model.job?.source?.stagedRelativePath, let repository = model.repository else { return nil }
        return repository.stagingRoot.appendingPathComponent(name)
    }

    private var methodsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            method("jp.seven.upload.v1", L("登録して印刷"), L("先にファイルを登録し、店頭で呼び出す方法"))
            method("jp.sharp.local.v1", L("店頭Wi‑Fiで送る"), L("コピー機のWi‑Fiに接続して、その場で送る方法"))
            method(ProfileCatalog.genericID, L("あとで選ぶ"), L("10 MB以下の汎用PDFとして保存"))
            if let report = model.job?.report, report.readiness != .ready {
                Label(String(format: L("%d点を確認してください"), report.issues.count), systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
    }

    private func method(_ id: String, _ title: String, _ subtitle: String) -> some View {
        Button { model.chooseMethod(id) } label: {
            HStack(spacing: 12) {
                Image(systemName: model.selectedMethod == id ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedMethod == id ? .isSelected : [])
    }

    private var resultStatus: some View {
        Label(L("書き出したPDFを確認しました"), systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.headline)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = model.job, let parts = job.export?.parts {
                Text(String(format: L("%dファイル｜%dページ｜%@"), parts.count, job.report?.pageCount ?? 0, paperName(model.effectivePaper)))
                    .font(.headline)
                ForEach(parts.indices, id: \.self) { index in
                    Label("\(parts.count > 1 ? String(format: L("パート%d・"), index + 1) : "")\(formattedBytes(parts[index].byteCount))", systemImage: "doc.text")
                        .font(.subheadline)
                }
                Label(L("パスワードなし"), systemImage: "lock.open").font(.subheadline)
            }
            Text(L("共有先で印刷アプリを選び、店頭の最終プレビューを確認してください。"))
                .font(.subheadline).foregroundStyle(.secondary)
            Button(L("ファイルに保存")) { model.showFilesPicker = true }
                .frame(minHeight: 44)
            Button(L("完了")) { model.finish() }.frame(minHeight: 44)
        }
    }

    private var copierFooter: some View {
        caption(L("店頭のコピー機で、最終プレビューと印刷設定を確認してください。"))
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.jobs.isEmpty { Text(L("まだ履歴がありません。")) }
            ForEach(model.jobs, id: \.id) { job in
                Button { model.openHistory(job) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.source?.originalDisplayName ?? L("書類")).font(.body).lineLimit(1)
                            Text(String(format: L("%@ ・ %@ ・ %@"), job.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: uiLanguage == "en" ? "en_US" : "ja_JP"))), paperName(job.targetPaper), historyStatus(job)))
                                .font(.footnote).foregroundStyle(.secondary)
                            if !hasLocalFile(job) {
                                Text(L("再利用するにはファイルを選び直してください"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 60).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("表示言語"), selection: $uiLanguage) {
                Text("日本語").tag("ja")
                Text("English").tag("en")
            }
            Picker(L("既定の用紙"), selection: $defaultPaper) {
                Text("A4").tag("a4Portrait")
                Text("B5").tag("b5Portrait")
            }
            Picker(L("既定の印刷方法"), selection: $defaultProfile) {
                Text(L("あとで選ぶ")).tag(ProfileCatalog.genericID)
                Text(L("登録して印刷")).tag("jp.seven.upload.v1")
                Text(L("店頭Wi‑Fiで送る")).tag("jp.sharp.local.v1")
            }
            Picker(L("作業ファイルの自動削除"), selection: $retentionDays) {
                Text(L("24時間後")).tag(1)
                Text(L("書き出し後すぐ")).tag(0)
                Text(L("7日後")).tag(7)
            }
            Divider()
            Button(L("購入を復元")) { model.restore() }.frame(minHeight: 44)
            Button(L("すべての書類を削除"), role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
            Link(L("プライバシー"), destination: URL(string: "https://lrodeveloperr.github.io/Printmae-ios/privacy/")!)
                .frame(minHeight: 44)
            Link(L("使い方・お問い合わせ"), destination: URL(string: "https://lrodeveloperr.github.io/Printmae-ios/")!)
                .frame(minHeight: 44)
            Text(L("印刷条件の確認日：2026年9月25日")).font(.footnote).foregroundStyle(.secondary)
            Text(String(format: L("バージョン %@"), Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("PDFのパスワード")).font(.title2.bold())
            Text(L("このPDFを開くためにパスワードを入力してください。パスワードは保存されません。"))
            SecureField(L("PDFのパスワード"), text: $password).textContentType(.password)
                .textFieldStyle(.roundedBorder)
            GoodUsePrimaryButton(L("開く")) { model.unlock(password); password = "" }
            Button(L("キャンセル")) { password = ""; model.showPassword = false }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private var imageOrderSheet: some View {
        NavigationStack {
            List {
                ForEach(pendingImages, id: \.absoluteString) { url in
                    Label(url.lastPathComponent, systemImage: "photo")
                }
                .onMove { from, to in pendingImages.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L("画像の順番"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("キャンセル")) { orderingImages = false; pendingImages = [] }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("この順番で読み込む")) {
                        let selected = pendingImages
                        orderingImages = false
                        pendingImages = []
                        model.importFiles(selected)
                    }
                }
            }
        }
    }

    private var paywall: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("書き出しの準備ができました")).font(.subheadline).foregroundStyle(.secondary)
            Text(L("プリント前 Proを買い切りで利用")).font(.title2.bold())
            Label(L("印刷用PDFを何度でも書き出し"), systemImage: "checkmark")
            Label(L("自動調整・圧縮・分割を制限なく利用"), systemImage: "checkmark")
            Label(L("広告なし・サブスクリプションなし"), systemImage: "checkmark")
            if let price = model.productPrice {
                GoodUsePrimaryButton(String(format: L("買い切りでProにする — %@"), price)) { model.buy() }
            } else {
                GoodUseSecondaryButton(L("価格を再読み込み")) { Task { await model.loadPrice() } }
            }
            Button(L("購入を復元")) { model.restore() }.frame(minHeight: 44)
            Button(L("今はしない")) { model.showPaywall = false }.frame(minHeight: 44)
            Text(L("お支払いはApple IDに請求されます。")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }

    private func localizedIssue(_ key: String) -> String { L(key) }

    private func formattedBytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    private func hasLocalFile(_ job: PrintJobSnapshot) -> Bool {
        if job.export?.parts.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) == true {
            return true
        }
        guard let name = job.source?.stagedRelativePath,
              name == URL(fileURLWithPath: name).lastPathComponent,
              let repository = model.repository else { return false }
        return FileManager.default.fileExists(atPath: repository.stagingRoot.appendingPathComponent(name).path)
    }

    private func historyStatus(_ job: PrintJobSnapshot) -> String {
        if job.phase == .completed || job.phase == .exportVerified { return L("完了") }
        if job.report?.readiness == .blocked { return L("要確認") }
        return L("作業中")
    }

    private func paperName(_ paper: PaperSpec) -> String {
        switch paper {
        case .a4Portrait: L("A4・縦")
        case .a4Landscape: L("A4・横")
        case .b5Portrait: L("B5・縦")
        case .b5Landscape: L("B5・横")
        }
    }

    private func fixName(_ action: FixAction) -> String {
        switch action {
        case .unlock: L("パスワードを解除")
        case .rotate: L("ページの向きを整える")
        case .normalizePaper(let paper): String(format: L("用紙を%@に統一"), paperName(paper))
        case .fitInsideSafeArea: L("印刷の安全範囲に収める")
        case .addMargins: L("白い余白を追加")
        case .compress: L("ファイルを圧縮")
        case .split: L("ページごとに分割")
        case .flattenForPrint: L("印刷用PDFに変換")
        }
    }
}

private struct PDFPaperPreview: View {
    let url: URL?
    let pageIndex: Int
    let paper: PaperSpec
    let showsSafeArea: Bool
    @State private var zoom: CGFloat = 1

    var body: some View {
        let size = paper.points
        let ratio = size.width / size.height
        GeometryReader { geometry in
            let width = min(geometry.size.width, 600)
            let height = width / ratio
            ZStack {
                Rectangle().fill(.white)
                if let url, let document = PDFDocument(url: url),
                   let page = document.page(at: min(pageIndex, max(0, document.pageCount - 1))) {
                    Image(uiImage: page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox))
                        .resizable().scaledToFit()
                } else {
                    Text(L("プレビューを表示できません")).foregroundStyle(.secondary)
                }
                if showsSafeArea {
                    Rectangle().strokeBorder(Skin.indigo.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .padding(.horizontal, width * 5 / CGFloat(paper.millimetres.width))
                        .padding(.vertical, height * 5 / CGFloat(paper.millimetres.height))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: width, height: height)
            .overlay(Rectangle().stroke(Color(uiColor: .separator), lineWidth: 1))
            .scaleEffect(zoom)
            .gesture(MagnificationGesture().onChanged { zoom = min(max($0, 1), 3) }.onEnded { _ in zoom = 1 })
            .frame(maxWidth: .infinity)
        }
        .frame(height: min(UIScreen.main.bounds.width - 32, 600) / ratio)
        .accessibilityLabel(String(format: L("%@の%dページ目のプレビュー"), paperLabel, pageIndex + 1))
    }

    private var paperLabel: String {
        switch paper {
        case .a4Portrait: L("A4・縦")
        case .a4Landscape: L("A4・横")
        case .b5Portrait: L("B5・縦")
        case .b5Landscape: L("B5・横")
        }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct FilesExportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
}
