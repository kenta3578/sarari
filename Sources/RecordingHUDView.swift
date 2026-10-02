import SwiftUI
import AppKit

// MARK: - ビュー

/// 録音中に浮くフローティング HUD の中身。状態は AppState の `AppStatus` から導出する
/// （メニューバーアイコンと同じ色・同じシンボルを使い、語彙を二重管理しない）。
struct RecordingHUDView: View {
    /// **観測するのは Model だけ**（Issue #65）。状態も表示サイズも Model が持つので、
    /// 無関係な設定変更で描き直されない。
    @ObservedObject var model: RecordingHUDModel

    let onStop: () -> Void
    let onRequestCancel: () -> Void
    /// キャンセル確認の「続ける」。パネルの大きさも戻す必要があるので、状態は直接いじらず委ねる。
    let onKeepRecording: () -> Void
    let onConfirmCancel: () -> Void
    let onDismiss: () -> Void
    let onCopyResult: () -> Void
    let onRetryInsert: () -> Void
    let onDismissResult: () -> Void

    var body: some View {
        let size = model.panelSize
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            content
                // 最小表示の余白。10 → 8（Issue #191）→ 12（#193）。棒を 7 本に戻したぶん、
                // 余白を広げて詰まりすぎないようにする。
                .padding(.horizontal, model.usesMinimalBar ? 12 : 14)
        }
        .frame(width: size.width, height: size.height)
    }

    /// 最小表示は高さぶんの角丸にして、細いバーが「ピル」に見えるようにする。
    private var cornerRadius: CGFloat {
        model.usesMinimalBar ? HUDMetrics.minimalPanelSize.height / 2 : 14
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.pendingResult {
            resultContent(result)
        } else if model.isConfirmingCancel {
            cancelConfirmation
        } else if case .failed(let reason, let hint) = model.status {
            failedContent(reason, hint: hint)
        } else {
            // 「通常」表示は Issue #6 で削除した。結果・確認・失敗以外はすべて細いバー。
            minimalContent
        }
    }

    // 最小表示: 状態と経過時間だけの細いバー（Issue #35）。
    // 状態は**色と形の両方**で示す。録音中＝赤い棒が声で伸び縮み、文字起こし中＝同じ棒が
    // 青い波形の形で止まる（Issue #180）。それ以外はメニューバーと同じシンボル。
    // 停止・キャンセルはホバーで出す＝常時は場所を取らない。
    private var minimalContent: some View {
        HStack(spacing: 6) {
            minimalIndicator
            // 11 → 13pt（Issue #191）→ 12pt（#195 の候補 A。13pt は «大きすぎる»）。
            // «12:34» の 5 文字でも折り返さないよう 1 行に固定し、収まらないときだけ少し縮める。
            Text(model.elapsedText)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
            if model.isHovering {
                iconButton("stop.fill", help: "停止して文字起こし", action: onStop)
                iconButton("xmark", help: "キャンセル（Esc）", action: onRequestCancel)
            }
        }
    }

    /// 最小表示の左端。録音中・文字起こし中・完了は «棒»、それ以外は状態アイコン。
    ///
    /// **状態で `switch` して別のビューを返さない**（Issue #200）。返すと SwiftUI が «別物» と
    /// 見なして補間しないので、状態が変わる瞬間に絵が飛ぶ。同じビューを置いたまま入力値だけ
    /// 変えると、高さ・色が 0.2 秒で繋がる。
    ///
    /// **完了にチェックは出さない**（Issue #202）。完了の瞬間、ユーザーの視線は挿入先にある。
    /// 記号を置いても読み戻させる必要はなく、存在感だけが増える。棒が最小（点）に畳まれて
    /// 緑になるだけにする——**増やすのではなく静かに減らす**。視界の隅で «終わった» は伝わる。
    ///
    /// **左端の幅は録音中の棒と同じに固定する**（Issue #198）。12pt に縮むと中身が中央寄せで
    /// 並び直し、経過時間の位置まで動いてガタつく。幅は棒の定義を参照するので自動で揃う。
    ///
    /// アニメーションは**状態が変わったときだけ**。音量による高さの変化には掛けない
    /// （毎 85ms の値に掛けると遅れて見える）。
    ///
    /// **録音を始めてから一度も音を拾っていないときだけ**、棒をマイク斜線に替える（Issue #6）。
    /// 考えながら黙った程度では出さない（`looksSilent` の判定）。
    private var minimalIndicator: some View {
        ZStack {
            if model.showsSilenceWarning {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: LevelBarsView.width)
            } else if model.showsBars {
                LevelBarsView(level: model.currentLevel,
                              isProcessing: model.isTranscribing,
                              isFinished: model.isFinished,
                              color: statusColor)
            } else {
                statusIcon(size: 15, width: LevelBarsView.width)
            }
        }
        .frame(width: LevelBarsView.width)
        .animation(.easeOut(duration: 0.2), value: model.status)
        // **読み上げの要素をここで 1 つ作る**（Issue #204）。コンテナ自体は要素にならず、
        // 棒の側の子孫（`HStack` と `Capsule`）も要素を作らないので、これが無いと
        // 録音中だけラベルの付く先が無くなる。色が読めない環境向けの 3 つ目の手がかり。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.indicatorAccessibilityLabel)
    }

    // 失敗（結果テキストを伴わないもの＝文字起こし失敗・録音開始失敗など）。
    // 見出し行は結果付きの失敗と**同じ部品**を使う。以前は別実装で、権限失敗の「設定を開く」を
    // 片方にだけ付けて出なかった（Issue #39 → #64）。
    private func failedContent(_ reason: String, hint: FailureHint?) -> some View {
        resultHeader(isFailure: true, title: reason, detail: nil, hint: hint, onDismiss: onDismiss)
            .padding(.vertical, 2)
    }

    /// 失敗・未確認の見出し行。アイコン（失敗は警告色、未確認は情報色）・見出し・補足・
    /// 設定で直せる失敗への「設定を開く」・閉じる。結果テキストの有無に関わらずこれを使う。
    private func resultHeader(isFailure: Bool, title: String, detail: String?,
                              hint: FailureHint?, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if let hint, let actionTitle = hint.actionTitle {
                Button(actionTitle) { hint.perform() }
                    .controlSize(.small)
            }
            Button("閉じる", action: onDismiss)
                .controlSize(.small)
        }
    }

    // 30秒超のキャンセルは誤爆が痛いので、HUD 内で確認を取る
    // （NSAlert だと最前面アプリのフォーカスを奪うため使わない）。
    private var cancelConfirmation: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("録音を破棄しますか？")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(model.elapsedText) ぶんの録音が失われます")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("続ける", action: onKeepRecording)
                .controlSize(.small)
            Button("破棄", action: onConfirmCancel)
                .controlSize(.small)
        }
    }

    // 挿入できなかった／確認できなかった結果。ここからコピー・再挿入できる
    // （`docs/design-rationale.md` §4: 結果を失わせないことが表示の設定より優先）。
    //
    // **失敗と「確認できないだけ」で見せ方を変える**（Issue #34）。
    // 確認できないだけの状態は情報色で描き、数秒で自動的に閉じる。失敗は警告色のまま残す。
    private func resultContent(_ result: RecordingHUDModel.PendingResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            resultHeader(isFailure: result.isFailure, title: result.title, detail: result.detail,
                         hint: result.hint, onDismiss: onDismissResult)

            ScrollView {
                Text(result.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 68)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(spacing: 8) {
                Button("コピー", action: onCopyResult)
                    .controlSize(.small)
                Button("もう一度挿入", action: onRetryInsert)
                    .controlSize(.small)
                Spacer()
                if let note = result.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// 状態アイコン。メニューバーと同じシンボルと色で、**色と形の両方**で状態を示す。
    private func statusIcon(size: CGFloat, width: CGFloat) -> some View {
        Image(systemName: model.status.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(statusColor)
            .frame(width: width)
            .accessibilityLabel(model.status.accessibilityLabel)
    }

    /// メニューバーアイコンと同じ色分けを流用する。
    private var statusColor: Color {
        model.status.tintColor.map(Color.init(nsColor:)) ?? .secondary
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 最小表示の «棒»（Issue #180、30 案の 14。#189 で 7 本、#191 で 10 本、#193 で 7 本へ）。
///
/// **読み取らせたいことは 1 つ——声の大きさ。** 録音中は声の大きさで高さが変わり、
/// 文字起こし中は同じ棒が青い波形記号の形で止まる（棒が波形になって処理へ移る）。
///
/// **時間で勝手に動く要素を足さない。** #146〜#176 で重ねるほど読めなくなり、
/// #178 で全部戻した。動くのは届いた音量だけ。
///
/// テストから高さの決め方を確かめられるよう `private` にしていない。
struct LevelBarsView: View {
    /// いまの音量（0…1）。文字起こし中は使わない。
    let level: Float
    /// 文字起こし中か。true なら声に関係なく波形記号の形で止める。
    let isProcessing: Bool
    /// 挿入まで終わったか（Issue #200）。true なら棒を «点の列» に畳む。
    var isFinished: Bool = false
    let color: Color

    /// 声が大きいときの形（pt）。中央ほど高くして、並んだ棒を 1 つの «波形» として読ませる。
    ///
    /// **7 本**（Issue #193）。奇数なので中央の山は 1 本で、左右対称。
    /// 最大 20pt（Issue #195 の候補 A で 24 → 20）。パネル（144×34）の上下に 7pt を残す。
    static let voiceProfile: [CGFloat] = [8, 12, 17, 20, 17, 12, 8]
    /// 文字起こし中の形。SF Symbols の `waveform` に寄せる（メニューバーと同じ読み）。
    static let processingProfile: [CGFloat] = [7, 10, 13, 17, 13, 10, 7]
    /// 完了の形（Issue #200 / #202）。全部を点に畳む。
    /// **チェックは出さない**——完了の瞬間は視線が挿入先にあり、視界の隅で緑が見えれば足りる。
    static let finishedProfile: [CGFloat] = Array(repeating: barWidth, count: voiceProfile.count)
    /// 棒の幅。黙っているときの高さもこれ＝点。0 にすると «消えた» に見える。
    ///
    /// 幅 4・間隔 3（Issue #195 の候補 A）。#191 の 幅5・間隔4 は «大きすぎる» と言われた。
    /// 7 本で並びは 46pt。
    static let barWidth: CGFloat = 4
    static let spacing: CGFloat = 3
    /// 声とみなす下限（Issue #187）。これ未満は環境音として、棒も色も動かさない。
    ///
    /// 履歴の録音 619 件を実測すると、85ms 窓の 64% がこれ未満に入る（環境音と声の境目）。
    static let voiceFloor: Float = 0.05

    /// この音量で形いっぱいになる（Issue #187）。レベルは −50dB…0dB を 0…1 に写した値。
    ///
    /// **実測から決めた。** 声の窓（0.05 以上）は p25 0.11 / p50 0.16 / p75 0.21 / p95 0.28。
    /// 以前は «通常の発話は 0.3〜0.6» という想定で 0.6 にしていて、普段の声では棒が 27% しか
    /// 伸びなかった。大きめの声（p95）で最大、普段の声は半分ほどで抑揚が見える。
    static let fullLevel: Float = 0.28

    /// 黙っているときに赤へ重ねる灰の濃さ（Issue #182 / #184）。喋るほど薄くなり、赤が冴える。
    ///
    /// **黙っていても赤みをわずかに残す。** 1.0（灰そのもの）にすると «録音中» の赤が消える。
    /// 0.55 では «差が弱い» と言われた。黙っているときは 3pt の点で色の違いが目に入りにくく、
    /// 0.8 以上はほぼ同じに見えたので、赤みが残る 0.8 にしている。
    static let quietMuting: CGFloat = 0.8

    /// この音量で赤になりきる（Issue #184 / #187）。**高さの `fullLevel` とは別の値。**
    ///
    /// 普段の声（実測 p50 0.16）で赤になりきるよう 0.15 にしている。以前の 0.3 は想定値からの
    /// 決め打ちで、普段の声では半分しか赤にならず «差が弱い» と言われた。
    /// 音量から連続的に決めるので、切り替えのチカチカはない。
    static let colorFullLevel: Float = 0.15

    static var width: CGFloat {
        CGFloat(voiceProfile.count) * barWidth + CGFloat(voiceProfile.count - 1) * spacing
    }
    static var height: CGFloat { voiceProfile.max() ?? barWidth }

    /// いまの音量を高さの比（0…1）にする。`voiceFloor` 以下で 0、`fullLevel` で 1。
    static func ratio(level: Float) -> CGFloat {
        span(level, upTo: fullLevel)
    }

    /// いまの音量を色の比（0…1）にする。`voiceFloor` 以下で 0、`colorFullLevel` で 1——
    /// 高さより先に赤になりきる。
    static func colorRatio(level: Float) -> CGFloat {
        span(level, upTo: colorFullLevel)
    }

    /// 環境音の下限から基準までを 0…1 に写す。
    private static func span(_ level: Float, upTo full: Float) -> CGFloat {
        CGFloat(min(1, max(0, level - voiceFloor) / (full - voiceFloor)))
    }

    /// 棒それぞれの高さ（pt）。
    static func heights(level: Float, isProcessing: Bool, isFinished: Bool = false) -> [CGFloat] {
        if isFinished { return finishedProfile }
        if isProcessing { return processingProfile }
        let ratio = ratio(level: level)
        return voiceProfile.map { barWidth + ($0 - barWidth) * ratio }
    }

    /// 棒の上に重ねる灰の濃さ（0…`quietMuting`）。文字起こし中の青には重ねない。
    ///
    /// **音量から連続的に決め、二択で切り替えない。** 切り替えるとそこでチカチカする。
    /// 合図は «声の大きさ» 1 つのまま、高さと一緒に色が付いてくる。
    static func muting(level: Float, isProcessing: Bool, isFinished: Bool = false) -> CGFloat {
        if isProcessing || isFinished { return 0 }
        return quietMuting * (1 - colorRatio(level: level))
    }

    var body: some View {
        // **`Canvas` で一括描画しない**（Issue #200）。Canvas は高さが変わっても途中の値を
        // 補間しないので、状態が変わる瞬間に別の絵へ飛ぶ。1 本ずつのビューにすると、
        // 高さと色の変化を SwiftUI が繋いでくれる。見た目（寸法・角丸）は同じ。
        let heights = Self.heights(level: level, isProcessing: isProcessing, isFinished: isFinished)
        let muting = Self.muting(level: level, isProcessing: isProcessing, isFinished: isFinished)
        return HStack(spacing: Self.spacing) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color)
                    // 録音色の上に灰を重ねる＝2 色を混ぜた色。どちらも明暗に追従する。
                    .overlay(Capsule(style: .continuous).fill(Color(nsColor: .systemGray).opacity(muting)))
                    .frame(width: Self.barWidth, height: heights[index])
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

// MARK: - パネル

/// Esc の keyCode。監視クロージャは非同期文脈から参照されるのでファイルスコープに置く。
