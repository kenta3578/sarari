import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ReplacementsSettingsView()
                .tabItem { Label("辞書置換", systemImage: "character.book.closed") }
            SuggestionsSettingsView()
                .tabItem { Label("候補", systemImage: "text.badge.plus") }
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}

/// サウンド・ホットキーなど基本設定。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var loginItem = LoginItem.shared
    /// エンジンの切り替えを録音中・処理中だけ止めるために見る（Issue #77）。
    @ObservedObject private var appState = AppState.shared
    /// ホットキーの録り中か（AppState の録音状態とは無関係）。
    /// ウィンドウを閉じても監視が残らないよう、状態は View の外に置く（Issue #78）。
    @ObservedObject private var hotKeyCapture = HotKeyCapture.shared
    /// 履歴の全削除は取り消せないので必ず確認する（Issue #81）。
    @State private var isConfirmingDeleteAll = false
    /// 取り込んだ音の一覧（Issue #124）。取り込み・削除の直後に選択肢へ反映するため
    /// ディレクトリを毎回読み直さず、ここに持って明示的に更新する。
    @State private var customSounds: [String] = SoundPlayer.customSounds()
    /// 取り込みに失敗したファイルの理由（成功したら消す）。
    @State private var soundImportError: String?

    var body: some View {
        Form {
            Section("起動") {
                Toggle("ログイン時に sarari を起動", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                // どちらも押しても必ず失敗する。`requiresApproval` はアプリ側から解除
                // できず（下の「ログイン項目を開く」が唯一の手段）、`/Applications` の外
                // からの登録は壊れたログイン項目を作るだけ（Issue #84）。
                .disabled(loginItem.requiresApproval || loginItem.isOutsideApplications)

                Text("ログイン時にメニューバーへ常駐します（Dock には出ません）。"
                     + "この設定はシステム設定の「一般 > ログイン項目と機能拡張」と同じものなので、"
                     + "そちらで切り替えても構いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if loginItem.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text("システム設定の「ログイン項目」でオフにされています。"
                             + "アプリ側からは解除できません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("ログイン項目を開く") { loginItem.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                }

                if loginItem.isOutsideApplications {
                    Text("いま動いている sarari が /Applications の外にあります"
                         + "（\(Bundle.main.bundleURL.path)）。"
                         + "ここで登録するとそのパスがログイン項目になるので、"
                         + "scripts/install-local.sh で /Applications に入れてから設定してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = loginItem.lastError {
                    Text("設定できませんでした: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("サウンド") {
                soundRow("録音開始音", selection: $settings.startSound)
                soundRow("録音停止音", selection: $settings.stopSound)

                HStack {
                    Button("音を追加…") { importSounds() }
                    Button("フォルダを開く") { SoundPlayer.revealCustomDirectory() }
                    Spacer()
                }

                if !customSounds.isEmpty {
                    DisclosureGroup("自分の音（\(customSounds.count)）") {
                        ForEach(customSounds, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button {
                                    preview(name)
                                } label: {
                                    Image(systemName: "play.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("試聴")
                                .accessibilityLabel("\(name)を試聴")
                                Button {
                                    deleteSound(name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("ゴミ箱に入れる")
                                .accessibilityLabel("\(name)を削除")
                            }
                        }
                    }
                }

                if let soundImportError {
                    Text(soundImportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("選び直すと鳴ります。試聴ボタンでいまの音を聞き直せます。"
                     + "「sarari の音」はアプリに入っている音です。"
                     + "「音を追加…」で選んだ音声ファイル（aiff / wav / mp3 / m4a / caf）は "
                     + "\((SoundPlayer.customDirectory.path as NSString).abbreviatingWithTildeInPath) にコピーされ、「自分の音」に出ます。"
                     + "削除はゴミ箱に入れるだけなので戻せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("音声認識") {
                Picker("エンジン", selection: $settings.speechEngine) {
                    ForEach(SpeechEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                            .disabled(!kind.isSupported)
                    }
                }
                .onChange(of: settings.speechEngine) { _, _ in
                    AppController.shared.loadSpeechEngine()
                }
                // 録音中・文字起こし中の載せ替えはマイクを開いたままにする（Issue #77）。
                .disabled(!appState.canSwitchEngine)

                if !appState.canSwitchEngine {
                    Text("録音・処理が終わるまでエンジンは切り替えられません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("既定は Apple 音声認識です。OS 内蔵なのでアプリ側のダウンロードも"
                     + "常駐メモリもなく、句読点も認識側が付けます（\(EngineSupport.requiresMacOS26)。"
                     + "満たさない Mac では自動的に WhisperKit になります）。"
                     + "WhisperKit に切り替えると初回に約630MB をダウンロードして常駐させます。"
                     + "切り替えると使わない方をメモリから降ろします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !SpeechEngineKind.apple.isSupported {
                    Text("この Mac では Apple 音声認識を選べません（\(EngineSupport.requiresMacOS26)）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("録音HUD") {
                Picker("表示サイズ", selection: $settings.hudSize) {
                    ForEach(HUDSize.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.hudSize) { _, _ in
                    AppController.shared.refreshHUDLayout(positionChanged: false)
                }

                Picker("表示位置", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.hudSize == .hidden)
                .onChange(of: settings.hudPosition) { _, _ in
                    AppController.shared.refreshHUDLayout(positionChanged: true)
                }

                Toggle("録音中は画面の縁を光らせる", isOn: $settings.edgeGlowEnabled)

                Text("「最小」は声の大きさと経過時間だけの細いバーで、マウスを乗せると停止・キャンセルが出ます。"
                     + "録音を始めてもマイクが一度も音を拾わないときは、棒がオレンジのマイク斜線に替わります。"
                     + "「非表示」でも開始音・完了音は鳴ります"
                     + "（キャンセルは HUD からのみ。挿入できなかった結果は「挿入」の設定に従って表示します）。"
                     + "画面の縁は、マウスのある画面を録音中はすみれ色、文字起こし中は水色で光らせ、挿入できたら白く光って消えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("挿入") {
                Picker("挿入できなかった結果", selection: $settings.resultRetention) {
                    ForEach(SettingsStore.ResultRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                Text("**どれを選んでも履歴には必ず残ります。**"
                     + "クリップボードに残すのは、権限が無い・録音したアプリが前面にない等で"
                     + "はっきり挿入できなかったときだけです。"
                     + "ターミナルのように結果を確認できないアプリでは、挿入は済んでいる可能性が高いので"
                     + "クリップボードは元へ戻します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("ホットキー") {
                HStack {
                    Text("録音トリガー")
                    Spacer()
                    Text(hotKeyCapture.isCapturing
                         ? hotKeyCapture.capturingText
                         : settings.hotKeyDisplayName)
                        .foregroundStyle(hotKeyCapture.isCapturing ? .secondary : .primary)
                    Button(hotKeyCapture.isCapturing ? "キャンセル" : "変更") {
                        hotKeyCapture.isCapturing ? hotKeyCapture.cancel() : hotKeyCapture.start()
                    }
                }
                if let problem = hotKeyCapture.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("修飾キー（右⌥・⇧・⌘ など。複数可）を押したまま別のキーを押すと「左⇧ + 左⌘ + 0」のような組み合わせに、"
                     + "押さずに離すと修飾キーだけになります。通常キー付きのときは、そのキー入力はアプリに届きません。"
                     + "⇧ を含む組み合わせと複数の修飾キーは、通常キーと合わせたときだけ使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("履歴") {
                Picker("保存期間", selection: $settings.historyRetentionDays) {
                    ForEach(SettingsStore.historyRetentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .onChange(of: settings.historyRetentionDays) { _, _ in
                    // 期間を短くしたらその場で古い履歴を消す（起動を待たせない）。
                    HistoryStore.shared.purgeExpired()
                }

                HStack {
                    Text("保存先")
                    Spacer()
                    Button("フォルダを開く") {
                        HistoryFiles.revealRoot()
                    }
                    .buttonStyle(.link)
                }

                HStack {
                    Text("すべての履歴")
                    Spacer()
                    // 一覧は新しい 500 件しか読まないので、これが無いとそれより古いものを
                    // アプリから消す手段が無い（Issue #81）。
                    Button("削除…", role: .destructive) { isConfirmingDeleteAll = true }
                }

                Text("1発話ごとに生テキストと置換後テキストを保存します（録音した音声は残しません）。"
                     + "辞書置換やフィラー除去が何を変えたか、生テキストと突き合わせて確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // システム設定側で変えられている可能性があるので、開くたびに OS から読み直す。
        .onAppear { loginItem.refresh() }
        // .onDisappear はウィンドウを閉じても発火しない（isReleasedWhenClosed = false で
        // ビュー階層が生きたまま残るため）。実際の解除は SettingsWindowController の
        // windowWillClose が行う。ここは念のための保険（Issue #78）。
        .onDisappear { hotKeyCapture.cancel() }
        // Finder で直接置いた音も、設定を開き直せば出るように読み直す（Issue #124）。
        .onAppear { customSounds = SoundPlayer.customSounds() }
        .confirmationDialog("すべての履歴を削除しますか？",
                            isPresented: $isConfirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { HistoryStore.shared.deleteAll() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("これまでの文字起こし結果がすべて消えます。取り消せません。")
        }
    }

    /// 音のピッカーと試聴ボタンの1行（Issue #48）。
    /// 選択肢は「なし」→ sarari の音（同梱）→ 自分の音（~/sarari/sounds/）→ システム音（Issue #71, #2）。
    private func soundRow(_ title: String, selection: Binding<String>) -> some View {
        let custom = customSounds
        return HStack {
            Picker(title, selection: selection) {
                Text(SoundPlayer.none).tag(SoundPlayer.none)
                Section("sarari の音") {
                    ForEach(SoundPlayer.bundledSounds, id: \.self) { Text($0).tag($0) }
                }
                if !custom.isEmpty {
                    Section("自分の音") {
                        ForEach(custom, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("システム音") {
                    ForEach(SoundPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                }
            }
            .onChange(of: selection.wrappedValue) { _, new in preview(new) }
            Button {
                preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection.wrappedValue == SoundPlayer.none)
            .help("試聴")
            .accessibilityLabel("\(title)を試聴")
        }
    }

    private func preview(_ name: String) {
        SoundPlayer.play(name)
    }

    /// 選んだ音声ファイルを `~/sarari/sounds/` に取り込む（Issue #124）。
    /// 複数選べるので、失敗したものだけ理由を並べて残し、成功した分はそのまま選べるようにする。
    private func importSounds() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "追加"
        panel.message = "録音の開始音・停止音に使う音声ファイルを選びます（aiff / wav / mp3 / m4a / caf）"
        guard panel.runModal() == .OK else { return }

        var failures: [String] = []
        var lastImported: String?
        for url in panel.urls {
            do {
                lastImported = try SoundPlayer.importSound(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        customSounds = SoundPlayer.customSounds()
        soundImportError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        // 取り込んだ音がその場で確かめられるように鳴らす。
        if let lastImported { preview(lastImported) }
    }

    /// 取り込んだ音を消す。ゴミ箱に入れるだけなので Finder から戻せる（Issue #124）。
    private func deleteSound(_ name: String) {
        do {
            try SoundPlayer.deleteCustomSound(name)
        } catch {
            soundImportError = "\(name) を削除できませんでした: \(error.localizedDescription)"
            return
        }
        customSounds = SoundPlayer.customSounds()
        soundImportError = nil
        // 消した音を選んだままにすると鳴らない設定になるので「なし」へ戻す。
        if settings.startSound == name { settings.startSound = SoundPlayer.none }
        if settings.stopSound == name { settings.stopSound = SoundPlayer.none }
    }

}

/// 辞書置換ルールの編集。編集内容は即座に `~/sarari/replacements.json` に保存される。
struct ReplacementsSettingsView: View {
    @ObservedObject private var store = ReplacementStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var fillers = FillerStore.shared
    /// 編集中の行。この行のルールについて、過去の発話への影響を出す（Issue #36）。
    @FocusState private var focusedField: RuleField?

    private enum RuleField: Hashable {
        case from(UUID), to(UUID)
        var ruleID: UUID {
            switch self {
            case .from(let id), .to(let id): return id
            }
        }
    }

    /// 直前の取り込みの結果。
    @State private var importMessage: ImportMessage?

    private struct ImportMessage {
        let text: String
        let isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fillerSection
            Divider().padding(.vertical, 4)
            Text("文字起こし直後に機械的に置換します（大文字・小文字は区別しません）。"
                 + "同じ位置に複数該当したら長いルールが優先されます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("読み（発話される語）").frame(maxWidth: .infinity, alignment: .leading)
                Text("置換後").frame(maxWidth: .infinity, alignment: .leading)
                // 削除ボタンぶんの余白。**高さは 0 に固定する**——`Color.clear` は縦にも伸びるので、
                // 放っておくと見出し行がルール一覧と余った高さを分け合い、上下に空白ができる（Issue #9）。
                Color.clear.frame(width: 22, height: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // **`List` を使わない**（Issue #94）。macOS の `List` は `VStack` の中で
            // 余剰高さを取りにいくうえ、`.listStyle(.bordered)` が説明できない上下インセットを
            // 足す。そのぶんルール一覧が圧迫され、既定 5 件の最下段が切れていた。
            // 枠と交互色は自前で描けば、間隔は `spacing` のとおりになる。
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 添字の Binding にしない。外の編集の読み直し（Issue #7）で配列が縮むと、
                    // 編集中の入力欄が古い添字へ書き戻して範囲外で落ちる。id で引き直す。
                    ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 8) {
                            TextField("カーズ桜", text: ruleBinding(rule.id, \.from))
                                .focused($focusedField, equals: .from(rule.id))
                            TextField("河津桜", text: ruleBinding(rule.id, \.to))
                                .focused($focusedField, equals: .to(rule.id))
                            Button {
                                store.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("このルールを削除")
                            .accessibilityLabel("このルールを削除")
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(index.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color.primary.opacity(0.04))
                    }
                }
            }
            // 5 件は必ず収まる高さを確保しつつ、増えたぶんはスクロールで見せる。
            .frame(minHeight: Self.ruleRowHeight * 5, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))

            if let rule = focusedRule, !rule.from.trimmingCharacters(in: .whitespaces).isEmpty {
                RuleImpactView(rule: rule) { $0.id == rule.id }
            }

            HStack {
                Button("ルールを追加") {
                    store.rules.append(ReplacementRule(from: "", to: ""))
                }
                Button("ファイルから読み込む…") { importRules() }
                    .help("JSON のルールファイルをまとめて追加します（同じ読みのルールは飛ばし、既存のルールは変更しません）")
                Spacer()
                Button("記号の初期ルールを追加") { addMissingDefaults() }
                    .help("削除した記号ルールだけを戻します（既存のルールは変更しません）")
            }

            if let importMessage {
                Text(importMessage.text)
                    .font(.caption)
                    .foregroundStyle(importMessage.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EditableFileRow(url: ReplacementStore.fileURL, problem: store.fileProblem)
        }
        .padding()
        // 監視を取りこぼしても、設定を開けば外の編集が反映されるようにする。
        .onAppear {
            store.reloadFromDisk()
            fillers.reloadFromDisk()
            // 影響の見積もりに使う。履歴ウィンドウを一度も開いていなければ未読み込み。
            if HistoryStore.shared.entries.isEmpty { HistoryStore.shared.reload() }
        }
    }

    private var focusedRule: ReplacementRule? {
        guard let id = focusedField?.ruleID else { return nil }
        return store.rules.first { $0.id == id }
    }

    /// ルール 1 行ぶんの高さ（角丸テキストフィールド + 上下パディング）。
    /// 既定の 5 ルールが切れずに収まる下限を決めるために持つ。
    private static let ruleRowHeight: CGFloat = 30

    /// フィラー除去（Issue #59）。語彙は 2 種類に分けて編集する。
    private var fillerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("フィラーを取り除く（えっと・あの・まあ…）", isOn: $settings.fillerRemovalEnabled)
            Text("LLM を使わず機械的に消すので遅延はありません。数値・URL・英単語には触れません。"
                 + "「あの人」「その本」のように意味を持つ位置の語は残します。履歴には元の文が残ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                fillerField("どこでも消す語（読点区切り）", words: $fillers.list.anywhere)
                fillerField("文頭・読点の後・文末でだけ消す語", words: $fillers.list.atBoundary)
            }
            .disabled(!settings.fillerRemovalEnabled)
            HStack {
                Spacer()
                Button("既定の語に戻す") { fillers.list = .default }
                    .controlSize(.small)
                    .disabled(fillers.list == .default)
            }
            EditableFileRow(url: FillerStore.fileURL, problem: fillers.fileProblem)
        }
    }

    private func fillerField(_ title: String, words: Binding<[String]>) -> some View {
        FillerWordsField(title: title, words: words)
    }

    /// ルールの 1 欄を id で引く Binding。行が消えていたら読みは空・書きは捨てる。
    private func ruleBinding(_ id: ReplacementRule.ID,
                             _ keyPath: WritableKeyPath<ReplacementRule, String>) -> Binding<String> {
        Binding(
            get: { store.rules.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
                store.rules[index][keyPath: keyPath] = value
            }
        )
    }

    /// 既定の記号ルールのうち、`from` が未登録のものだけを追加する。
    private func addMissingDefaults() {
        let missing = ReplacementStore.merge(ReplacementStore.defaultRules, into: store.rules).added
        guard !missing.isEmpty else { return }
        store.rules.append(contentsOf: missing)
    }

    /// JSON のルールファイルを選んで一括追加する（Issue #13）。既存ルールは書き換えない。
    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.prompt = "読み込む"
        panel.message = "replacements.json と同じ形式（[{\"from\": \"…\", \"to\": \"…\"}]）のファイルを選びます"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try ReplacementStore.importRules(from: Data(contentsOf: url), into: store.rules)
            if !result.added.isEmpty {
                store.rules.append(contentsOf: result.added)
                // 保存が外の編集とぶつかると読み直しで消え、ファイルが壊れていると保存されない。
                // どちらも fileProblem が立つので、「追加しました」と言わない。
                if store.fileProblem != nil {
                    importMessage = ImportMessage(
                        text: "\(url.lastPathComponent) の取り込みを保存できませんでした。下の表示を確認してから、もう一度読み込んでください",
                        isError: true)
                    return
                }
            }
            importMessage = ImportMessage(
                text: "\(url.lastPathComponent): \(result.added.count) 件を追加"
                    + (result.skipped > 0 ? "、同じ読みがある \(result.skipped) 件は飛ばしました" : "しました"),
                isError: false)
        } catch {
            importMessage = ImportMessage(
                text: "\(url.lastPathComponent) を読み込めないため、何も追加していません（\(error.localizedDescription)）",
                isError: true)
        }
    }
}

/// 設定ファイルの場所と、外で編集するための導線（Issue #7）。
///
/// 辞書置換・フィラー語はエディタや Claude Code でまとめて直す使い方を想定する。
/// 保存すればアプリが読み直すので、再起動は要らない。
/// **ボタンは並べず、パスそのものをリンクにする**（Issue #9。2 つずつ並べると重かった）。
private struct EditableFileRow: View {
    let url: URL
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // ホームは ~ で出す（短く読めるうえ、説明書の画像にユーザー名が写らない。Issue #56）。
            // コピーするのは省略しないパス。
            Button((url.path as NSString).abbreviatingWithTildeInPath) { NSWorkspace.shared.open(url) }
                .buttonStyle(.link)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("クリックで既定のエディタで開きます。保存すると再起動せずに反映されます")
                .contextMenu {
                    Button("ファイルを開く") { NSWorkspace.shared.open(url) }
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("パスをコピー") { TextInjector.copyToPasteboard(url.path) }
                }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// フィラー語の編集欄。
///
/// 配列と文字列を毎打鍵で往復させると `get(set(s)) != s` になり、区切り文字（`、`）を
/// 打った瞬間に `filter { !$0.isEmpty }` で落ちて消える。続けて次の語を打つと**既存の語に
/// 連結されて壊れる**ため、UI から語を追加する正規の手段が存在しなかった（Issue #84）。
/// 編集中は文字列のまま持ち、確定（Enter・フォーカスを外す）したときだけ配列へ落とす。
/// 保存も確定時の1回で済む（以前は 1 打鍵ごとに `fillers.json` を書き出していた）。
private struct FillerWordsField: View {
    let title: String
    @Binding var words: [String]

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($isFocused)
                .accessibilityLabel(title)
                .onAppear { text = Self.join(words) }
                // 外から変わったとき（「既定の語に戻す」）は表示を作り直す。編集中は触らない。
                .onChange(of: words) { _, new in
                    guard !isFocused else { return }
                    text = Self.join(new)
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
        }
        .frame(maxWidth: .infinity)
    }

    private func commit() {
        let parsed = Self.split(text)
        if parsed != words { words = parsed }
        text = Self.join(parsed)
    }

    private static func join(_ words: [String]) -> String {
        words.joined(separator: "、")
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { "、,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
