import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import GoodUseShell
import PrintMaeEngine

@main
struct PrintMaeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PrintMaeModel()

    var body: some Scene {
        WindowGroup {
            PrintMaeRoot(model: model)
                .environment(\.locale, Locale(identifier: "ja"))
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
    @State private var importing = false
    @State private var pendingImages: [URL] = []
    @State private var orderingImages = false
    @State private var password = ""
    @State private var confirmDelete = false
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
                label: { $0 },
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
                        Button { model.back() } label: { Label("戻る", systemImage: "chevron.left") }
                            .accessibilityIdentifier("nav.back")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.screen == .prepare {
                        Button { model.screen = .history } label: { Label("履歴", systemImage: "clock.arrow.circlepath") }
                        Button { model.screen = .settings } label: { Label("設定", systemImage: "gearshape") }
                    }
                }
            }
            .navigationTitle(title)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .jpeg, .png, .heic], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if urls.count > 1 && urls.allSatisfy({ $0.pathExtension.lowercased() != "pdf" }) {
                    pendingImages = urls
                    orderingImages = true
                } else if urls.count > 1 {
                    model.errorMessage = "PDFは1つずつ選んでください。画像は複数選んでまとめられます。"
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
        .alert("確認してください", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("このiPhone内の作業用書類と履歴をすべて削除します。購入情報は削除されません。", isPresented: $confirmDelete) {
            Button("すべての書類を削除", role: .destructive) { model.deleteAll() }
            Button("キャンセル", role: .cancel) { }
        }
        .tint(Skin.indigo)
        .onOpenURL { model.importFiles([$0]) }
    }

    private var title: String {
        switch model.screen {
        case .prepare: "プリント前"
        case .report: "印刷前チェック"
        case .fix: "自動修正の確認"
        case .preview: "実寸プレビュー"
        case .method: "印刷方法"
        case .result: "準備完了"
        case .history: "履歴"
        case .settings: "設定"
        }
    }

    @ViewBuilder private func slotContent(_ slot: GoodUseSlot) -> some View {
        switch (model.screen, slot) {
        case (.prepare, .header): header("印刷する前に、PDFを確認。", caption: "失敗しやすい余白・向き・サイズを先に確認します。")
        case (.prepare, .primaryContent): prepareContent
        case (.prepare, .footer): caption("書類はこのiPhone内で処理されます")
        case (.report, .header): header("印刷前チェック", caption: model.job?.source?.originalDisplayName)
        case (.report, .status): reportStatus
        case (.report, .primaryContent): reportContent
        case (.report, .footer): copierFooter
        case (.fix, .header): header("適用する修正", caption: "元のPDFは変更されません。")
        case (.fix, .primaryContent): fixesContent
        case (.preview, .header): header("実寸プレビュー", caption: "用紙の内側まで確認してください。")
        case (.preview, .primaryContent): previewContent
        case (.preview, .footer): caption("実際の仕上がりは店頭のコピー機でも確認してください。")
        case (.method, .header): header("どの方法で印刷しますか？", caption: nil)
        case (.method, .primaryContent): methodsContent
        case (.method, .footer): caption("選んだ方法の条件でもう一度確認します。")
        case (.result, .header): header("印刷用PDFの準備ができました", caption: nil)
        case (.result, .status): resultStatus
        case (.result, .primaryContent): resultContent
        case (.result, .footer): copierFooter
        case (.history, .header): header("履歴", caption: "書類を保持していない項目は、再度ファイルを選んでください。")
        case (.history, .primaryContent): historyContent
        case (.settings, .header): header("設定", caption: nil)
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
                GoodUsePrimaryButton("ファイルを選ぶ") { importing = true }
                    .accessibilityIdentifier("prepare.import")
            case .report:
                if model.job?.report?.issues.contains(where: { $0.suggestedFix != nil }) == true {
                    GoodUsePrimaryButton("まとめて自動で整える") { model.reviewFixes() }
                } else {
                    GoodUsePrimaryButton("実寸プレビューを見る") { model.openPreview() }
                }
            case .fix:
                GoodUsePrimaryButton("この内容で整える") { model.applyRecommendedFixes() }
            case .preview:
                GoodUsePrimaryButton("印刷用PDFを書き出す") {
                    if defaultProfile == ProfileCatalog.genericID { model.screen = .method }
                    else { model.chooseMethod(defaultProfile) }
                }
            case .method:
                GoodUsePrimaryButton("この方法で書き出す") { model.export() }
            case .result:
                GoodUsePrimaryButton("公式アプリまたはFilesへ共有") { model.openShare() }
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
            Text("PDF・JPEG・PNG・HEIC").font(.headline)
            Text("ファイルを読み込むと、印刷方法に合うか自動で確認します。")
                .font(.body).foregroundStyle(.secondary)
            GoodUseSecondaryButton("サンプルで試す") { model.trySample() }
            if let job = model.job, job.phase != .completed {
                Divider()
                Button { model.openHistory(job) } label: {
                    Label("前回の作業を開く", systemImage: "arrow.uturn.backward")
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
                Text(level == .ready ? "準備完了" : level == .review ? "確認が必要です" : "このままでは書き出せません")
                    .font(.headline)
                Text(level == .ready ? "プレビューで仕上がりを確認してください。" : "問題と対象ページを確認してから整えてください。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var reportContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let job = model.job, let report = job.report {
                HStack {
                    metric(paperName(model.effectivePaper), "用紙")
                    metric("\(report.pageCount)ページ", "ページ")
                    metric(ByteCountFormatter.string(fromByteCount: report.inputBytes, countStyle: .file), "ファイル")
                }
                Divider()
                if report.issues.isEmpty { Text("見つかった問題はありません。").font(.subheadline) }
                ForEach(report.issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizedIssue(issue.titleKey)).font(.headline)
                            Text(localizedIssue(issue.consequenceKey)).font(.subheadline).foregroundStyle(.secondary)
                            if let pages = issue.pages?.indexes, !pages.isEmpty {
                                Text(pages.map { String($0 + 1) }.joined(separator: "、") + "ページ目")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                if report.issues.contains(where: { $0.suggestedFix != nil }) {
                    Button("自分で調整") { model.openPreview() }.frame(minHeight: 44)
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
            if actions.isEmpty { Text("自動で適用できる修正はありません。") }
            ForEach(actions.indices, id: \.self) { index in
                Label(fixName(actions[index]), systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if actions.contains(where: { if case .flattenForPrint = $0 { return true }; return false }) {
                Text("レイアウトを安定させるため、リンクやしおりなどの画面用機能を除いた印刷用PDFを作成します。元のPDFは変更されません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("項目を変更") { model.openPreview() }.frame(minHeight: 44)
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
            Picker("表示", selection: $model.showOriginal) {
                Text("仕上がり").tag(false)
                Text("元のファイル").tag(true)
            }
            .pickerStyle(.segmented)
            PDFPaperPreview(url: model.showOriginal ? originalURL : model.previewURL,
                            pageIndex: model.previewPage, paper: model.effectivePaper,
                            showsSafeArea: model.showSafeArea)
            HStack {
                Button("前のページ") { model.previewPage -= 1 }.disabled(model.previewPage == 0)
                Spacer()
                Text("\(model.previewPage + 1) / \(max(1, model.job?.report?.pageCount ?? 1))")
                    .monospacedDigit().accessibilityLabel("\(model.previewPage + 1)ページ目")
                Spacer()
                Button("次のページ") { model.previewPage += 1 }
                    .disabled(model.previewPage + 1 >= (model.job?.report?.pageCount ?? 1))
            }
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private var previewOptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("印刷の安全範囲", isOn: $model.showSafeArea)
            Divider()
            if let job = model.job {
                Text("\(paperName(model.effectivePaper))｜\(job.report?.pageCount ?? 0)ページ")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("仕上がりを調整") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("用紙"); Spacer()
                        Button("A4") { model.apply(.normalizePaper(.a4Portrait)) }
                        Button("B5") { model.apply(.normalizePaper(.b5Portrait)) }
                    }.frame(minHeight: 44)
                    HStack {
                        Text("余白"); Spacer()
                        ForEach([3.0, 5.0, 10.0], id: \.self) { mm in
                            Button("\(Int(mm)) mm") {
                                model.apply(.addMargins(EdgeInsetsMM(top: mm, leading: mm, bottom: mm, trailing: mm)))
                            }
                        }
                    }.frame(minHeight: 44)
                    HStack {
                        Button("元に戻す") { model.undo() }.disabled(model.job?.undoRecipes.isEmpty != false)
                        Spacer()
                        Button("やり直す") { model.redo() }.disabled(model.job?.redoRecipes.isEmpty != false)
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
            method("jp.seven.upload.v1", "登録して印刷", "先にファイルを登録し、店頭で呼び出す方法")
            method("jp.sharp.local.v1", "店頭Wi‑Fiで送る", "コピー機のWi‑Fiに接続して、その場で送る方法")
            method(ProfileCatalog.genericID, "あとで選ぶ", "10 MB以下の汎用PDFとして保存")
            if let report = model.job?.report, report.readiness != .ready {
                Label("\(report.issues.count)点を確認してください", systemImage: "exclamationmark.triangle")
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
        Label("書き出したPDFを確認しました", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.headline)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = model.job, let parts = job.export?.parts {
                Text("\(parts.count)ファイル｜\(job.report?.pageCount ?? 0)ページ｜\(paperName(model.effectivePaper))")
                    .font(.headline)
                ForEach(parts.indices, id: \.self) { index in
                    Label("\(parts.count > 1 ? "パート\(index + 1)・" : "")\(ByteCountFormatter.string(fromByteCount: parts[index].byteCount, countStyle: .file))", systemImage: "doc.text")
                        .font(.subheadline)
                }
                Label("パスワードなし", systemImage: "lock.open").font(.subheadline)
            }
            Text("共有先で印刷アプリを選び、店頭の最終プレビューを確認してください。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("完了") { model.finish() }.frame(minHeight: 44)
        }
    }

    private var copierFooter: some View {
        caption("店頭のコピー機で、最終プレビューと印刷設定を確認してください。")
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.jobs.isEmpty { Text("まだ履歴がありません。") }
            ForEach(model.jobs, id: \.id) { job in
                Button { model.openHistory(job) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.source?.originalDisplayName ?? "書類").font(.body).lineLimit(1)
                            Text("\(job.updatedAt.formatted(date: .abbreviated, time: .shortened)) ・ \(paperName(job.targetPaper))")
                                .font(.footnote).foregroundStyle(.secondary)
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
            Picker("既定の用紙", selection: $defaultPaper) {
                Text("A4").tag("a4Portrait")
                Text("B5").tag("b5Portrait")
            }
            Picker("既定の印刷方法", selection: $defaultProfile) {
                Text("あとで選ぶ").tag(ProfileCatalog.genericID)
                Text("登録して印刷").tag("jp.seven.upload.v1")
                Text("店頭Wi‑Fiで送る").tag("jp.sharp.local.v1")
            }
            Picker("作業ファイルの自動削除", selection: $retentionDays) {
                Text("24時間後").tag(1)
                Text("書き出し後すぐ").tag(0)
                Text("7日後").tag(7)
            }
            Divider()
            Button("購入を復元") { model.restore() }.frame(minHeight: 44)
            Button("すべての書類を削除", role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
            Link("プライバシー", destination: URL(string: "https://lrodeveloperr.github.io/Printmae-ios/privacy/")!)
                .frame(minHeight: 44)
            Link("使い方・お問い合わせ", destination: URL(string: "https://lrodeveloperr.github.io/Printmae-ios/")!)
                .frame(minHeight: 44)
            Text("印刷条件の確認日：2026年9月25日").font(.footnote).foregroundStyle(.secondary)
            Text("バージョン \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDFのパスワード").font(.title2.bold())
            Text("このPDFを開くためにパスワードを入力してください。パスワードは保存されません。")
            SecureField("PDFのパスワード", text: $password).textContentType(.password)
                .textFieldStyle(.roundedBorder)
            GoodUsePrimaryButton("開く") { model.unlock(password); password = "" }
            Button("キャンセル") { password = ""; model.showPassword = false }
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
            .navigationTitle("画像の順番")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { orderingImages = false; pendingImages = [] }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("この順番で読み込む") {
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
            Text("書き出しの準備ができました").font(.subheadline).foregroundStyle(.secondary)
            Text("プリント前 Proを買い切りで利用").font(.title2.bold())
            Label("印刷用PDFを何度でも書き出し", systemImage: "checkmark")
            Label("自動調整・圧縮・分割を制限なく利用", systemImage: "checkmark")
            Label("広告なし・サブスクリプションなし", systemImage: "checkmark")
            if let price = model.productPrice {
                GoodUsePrimaryButton("買い切りでProにする — \(price)") { model.buy() }
            } else {
                GoodUseSecondaryButton("価格を再読み込み") { Task { await model.loadPrice() } }
            }
            Button("購入を復元") { model.restore() }.frame(minHeight: 44)
            Button("今はしない") { model.showPaywall = false }.frame(minHeight: 44)
            Text("お支払いはApple IDに請求されます。").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }

    private func localizedIssue(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func paperName(_ paper: PaperSpec) -> String {
        switch paper {
        case .a4Portrait: "A4・縦"
        case .a4Landscape: "A4・横"
        case .b5Portrait: "B5・縦"
        case .b5Landscape: "B5・横"
        }
    }

    private func fixName(_ action: FixAction) -> String {
        switch action {
        case .unlock: "パスワードを解除"
        case .rotate: "ページの向きを整える"
        case .normalizePaper(let paper): "用紙を\(paperName(paper))に統一"
        case .fitInsideSafeArea: "印刷の安全範囲に収める"
        case .addMargins: "白い余白を追加"
        case .compress: "ファイルを圧縮"
        case .split: "ページごとに分割"
        case .flattenForPrint: "印刷用PDFに変換"
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
                    Text("プレビューを表示できません").foregroundStyle(.secondary)
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
        .accessibilityLabel("\(paper.rawValue)の\(pageIndex + 1)ページ目のプレビュー")
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
