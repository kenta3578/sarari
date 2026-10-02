import SwiftUI
import AppKit
import Combine

let escapeKeyCode: UInt16 = 53


/// HUD の NSPanel を管理する。パネルは作り直さず使い回すので、
/// ユーザーがドラッグで動かした位置はセッション中保たれる。
@MainActor
final class RecordingHUDController {
    /// 「挿入は済んだが確認できなかった」結果を出しておく時間（Issue #34）。
    /// 本文を読んでコピーに手を伸ばせる長さにする。失敗はこれで閉じない。
    static let uncertainResultDuration: Duration = .seconds(6)

    /// 停止ボタン（ホットキーと等価）。
    var onStop: (() -> Void)?
    /// キャンセル確定（確認が要る場合は確認後に呼ばれる）。
    var onCancel: (() -> Void)?
    /// 残していた結果（挿入できなかった／確認できなかった）をユーザーが閉じた、または
    /// 再挿入で片付いたときに呼ぶ。控えている次の結果があれば呼び出し側がここで出す（Issue #100）。
    var onResultDismissed: (() -> Void)?

    let model = RecordingHUDModel()
    var panel: NSPanel?
    /// 表示位置の設定が変わってから、まだ置き直していない（Issue #46）。
    /// 非表示中に設定を変えると `applyLayout` は置き直せないので、次に出すときに置く。
    var needsReposition = false
    private var ticker: Timer?
    var startedAt: Date?
    var localMonitor: Any?
    var globalMonitor: Any?
    /// マウス位置監視（ホバー判定）。パネルを出している間だけ張る。
    var hoverMonitors: [Any] = []
    var autoHideTask: Task<Void, Never>?
    /// 表示中の結果を自動的に閉じてよいか（`.uncertain` だけ true）。
    var resultAutoHides = false
    private var statusObserver: AnyCancellable?

    var isVisible: Bool { panel?.isVisible == true }

    init() {
        // 状態が変わるとレイアウトも変わりうる（失敗だけは細いバーでなく大きいパネルで出す）。
        // 失敗は AppController が状態だけ更新して HUD を呼ばない経路があるので、ここで拾う。
        // `@Published` は値が入る**前**に流れてくるので、次のターンで読み直す。
        statusObserver = AppState.shared.$status.sink { [weak self] status in
            // `@Published` は値が入る**前**に流れてくるので、次のターンで Model へ移す。
            _ = status
            Task { @MainActor in self?.applyPanelSize() }
        }
    }

    func show() {
        cancelAutoHide()
        model.reset()
        syncEnvironment()
        startedAt = Date()
        // 経過時間は**非表示でも数える**。録音の途中で「最小」へ切り替えたときに
        // 0 から数え直したように見えないようにする。
        startTicking()

        guard SettingsStore.shared.hudSize != .hidden else {
            // 非表示。見えない Esc で録音を失わせないため、監視も張らない。
            panel?.orderOut(nil)
            removeEscapeMonitors()
            removeHoverMonitors()
            return
        }

        presentPanel()
        installEscapeMonitors()
    }

    /// パネルを（無ければ作って）前面に出す。
    /// makeKeyAndOrderFront は使わない。最前面アプリのフォーカスを奪うと挿入先が変わる。
    private func presentPanel() {
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyPanelSize()
        // 位置を決めるのは初回・設定で位置を変えた直後・**表示先の画面から外れたとき**。
        // それ以外はユーザーがドラッグした位置を保つ。
        if isNew || needsReposition || isOffCurrentScreen() { applyPanelPosition() }
        panel.orderFrontRegardless()
        installHoverMonitors()
    }

    /// 設定（表示位置・表示サイズ）の変更を、表示中の HUD へ即座に反映する（Issue #35）。
    ///
    /// 置き直すのは**位置**の設定が変わったときだけ。サイズだけの変更でドラッグ位置を
    /// 中央へ戻さない（Issue #57）。非表示中に位置が変わったら、次に出すときに置く。
    /// 状態を Model へ移す。**Model が共有シングルトンを直読みしない**代わりに、
    /// 環境が変わりうるところで必ずここを通す（Issue #65）。
    func syncEnvironment() {
        model.status = AppState.shared.status
    }

    func applyLayout(positionChanged: Bool) {
        if positionChanged { needsReposition = true }
        syncEnvironment()
        guard SettingsStore.shared.hudSize != .hidden else {
            // 結果を残しているときは閉じない。結果を失わせないことが設定より優先。
            guard model.pendingResult == nil else { return }
            model.isHovering = false
            panel?.orderOut(nil)
            removeEscapeMonitors()
            removeHoverMonitors()
            return
        }

        // 録音中・結果表示中・（失敗表示などで）出しっぱなしのときだけ出し直す。
        // それ以外は次に出すときの大きさだけ揃えておく。
        guard startedAt != nil || model.pendingResult != nil || isVisible else {
            applyPanelSize()
            return
        }
        presentPanel()  // needsReposition が立っているので、ここで置き直しも済む
        // 非表示から戻したときは Esc 監視も張り直す（結果表示中は張らない）。
        if startedAt != nil, model.pendingResult == nil { installEscapeMonitors() }
    }

    func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// 即座に閉じる（キャンセル時・失敗表示を閉じたとき）。
    func hide() {
        cancelAutoHide()
        resultAutoHides = false
        stopTicking()
        removeEscapeMonitors()
        removeHoverMonitors()
        model.reset()
        startedAt = nil
        panel?.orderOut(nil)
    }

    /// 完了表示を一瞬だけ見せてから自動的に閉じる（挿入できたことを HUD 側でも確認できる）。
    ///
    func finish() {
        // 前回の挿入結果を残したままなら、今回の成功で役目を終える。
        if model.pendingResult != nil {
            model.pendingResult = nil
            resultAutoHides = false
            applyPanelSize()
        }
        // 非表示でも動いている経過時間タイマーを必ず止める。
        stopTicking()
        removeEscapeMonitors()
        startedAt = nil
        guard isVisible else { return }

        cancelAutoHide()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: AppStatus.doneDisplayDuration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// 録音レベル（0…1）を波形へ流す。
    /// 起動音をマイクが拾う分を、棒に見せない（Issue #186）。`show()` の直後に呼ぶ。
    func ignoreLevels(forSoundOf duration: TimeInterval) {
        guard duration > 0 else { return }
        model.ignoreLevels(until: Date().addingTimeInterval(duration + Self.soundLatencyMargin))
    }

    /// 音の長さに足す余裕。**実測から決めた。** 直近 6 件の録音で、起動音（0.21 秒）は
    /// 開始から 84〜144ms 遅れて入り、最も遅いもので 354ms 地点に終わっていた。
    /// 0.21 ＋ 0.25 ＝ 0.46 秒でそこを覆う（鳴らすまでの遅れとバッファ 1 つ分を含む）。
    static let soundLatencyMargin: TimeInterval = 0.25

    func push(level: Float) {
        guard isVisible else { return }
        model.push(level: level)
    }

    // MARK: 挿入できなかった結果

    /// 挿入できなかった（または成否を確認できなかった）結果を HUD に残す。
    ///
    /// **表示サイズが「非表示」でもここでは出す**。結果を失わせないことが優先で、
    /// 出さなければユーザーは結果がどこにあるか分からない。
    ///
    /// 失敗は原因を読ませる必要があるので残す。**確認できなかっただけなら数秒で閉じる**
    /// （Issue #34: 毎回出る警告は読まれなくなる）。閉じても結果はクリップボードと履歴に残る。
    ///
    /// `label` は「どの発話の結果か」の前置き（例: 前の発話）。追い越された発話の結果を
    /// 後から出すとき、いま喋った内容の失敗と誤読させないために付ける（Issue #100）。
    func presentResult(_ text: String, outcome: InsertionOutcome, label: String? = nil) {
        cancelAutoHide()
        stopTicking()
        // Esc で消えると結果を失う。結果を残している間は Esc 監視を張らない。
        removeEscapeMonitors()
        startedAt = nil

        model.pendingResult = .init(text: text,
                                    title: label.map { "\($0): \(outcome.headline)" } ?? outcome.headline,
                                    detail: outcome.detail,
                                    isFailure: outcome.isFailure,
                                    note: nil,
                                    hint: outcome.hint)
        resultAutoHides = !outcome.isFailure

        presentPanel()
        scheduleResultAutoHide()
    }

    /// 「確認できなかっただけ」の結果を自動的に閉じる。失敗のときは何もしない。
    func scheduleResultAutoHide() {
        guard resultAutoHides, model.pendingResult != nil else { return }
        cancelAutoHide()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.uncertainResultDuration)
            guard !Task.isCancelled else { return }
            guard let self, self.model.pendingResult != nil else { return }
            self.dismissResult()
        }
    }

    /// ユーザーが結果に触れたら自動クローズをやめる（読んでいる途中で消さない）。
    func keepResultOpen() {
        resultAutoHides = false
        cancelAutoHide()
    }

    func copyResult() {
        guard let result = model.pendingResult else { return }
        keepResultOpen()
        TextInjector.copyToPasteboard(result.text)
        model.setResultNote("コピーしました")
    }

    /// もう一度挿入を試す。HUD は `.nonactivatingPanel` なので、
    /// ボタンを押しても最前面アプリは変わらない＝同じ入力先へ送れる。
    func retryInsert() {
        guard let result = model.pendingResult else { return }
        keepResultOpen()
        model.setResultNote("挿入中…")
        Task { @MainActor in
            let outcome = await TextInjector.insert(result.text)
            guard model.pendingResult?.text == result.text else { return }
            if outcome.isSucceeded {
                AppState.shared.update(.done(message: "挿入しました ✓"))
                finish()  // 残していた結果を片付けて閉じる
                onResultDismissed?()
            } else {
                model.setResultNote(outcome.summary)
            }
        }
    }

    func dismissResult() {
        // ユーザーが結果を見た上で閉じたので、エラー表示のまま残さず待機へ戻す。
        AppState.shared.update(.idle)
        hide()
        onResultDismissed?()
    }

    /// 結果パネル無しの失敗表示（文字起こし失敗など）の「閉じる」。
    /// 控えている次の結果があれば呼び出し側がここで出す（Issue #100）。
    func dismissFailure() {
        hide()
        onResultDismissed?()
    }

    /// 状態から導出される表示（失敗の原因など）を、録音のタイマーや自動クローズ無しで前面に出す。
    /// 追い越された発話の失敗を後から出すときに使う。HUD が閉じていても出す（結果を失わせない）。
    func presentStatus() {
        cancelAutoHide()
        resultAutoHides = false
        stopTicking()
        removeEscapeMonitors()
        startedAt = nil
        model.pendingResult = nil
        presentPanel()
    }

    /// 表示中の内容と設定に合わせてパネルの大きさを切り替える。
    func applyPanelSize() {
        // **大きさを決める前に環境を Model へ移す。** Model は SettingsStore を直読みしなく
        // なったので（Issue #65）、ここで移し忘れると設定を変えても中身が変わらない。
        syncEnvironment()
        guard let panel else { return }
        let size = model.panelSize
        let previous = panel.frame
        guard previous.size != size else { return }
        // borderless パネルは原点が左下。幅は中心を保ったまま広げる
        // （ユーザーがドラッグで動かした位置を尊重するため、再センタリングはしない）。
        // 高さは**画面外へ伸びない側へ**——下寄せなら上へ、上寄せなら下へ伸ばす。
        let y = SettingsStore.shared.hudPosition == .topCenter
            ? previous.maxY - size.height
            : previous.minY
        panel.setContentSize(size)
        let origin = CGPoint(x: previous.minX + (previous.width - size.width) / 2, y: y)
        panel.setFrameOrigin(Self.clamped(origin, size: size))
    }

    /// パネルが、いまマウスのある画面から外れているか。
    ///
    /// 位置を決めるのが初回と設定変更だけだったので、外部ディスプレイで最初に録音すると
    /// 内蔵ディスプレイへ移っても HUD は外部に出続けた。ディスプレイを外した場合は
    /// borderless window が画面内クランプの対象外なので存在しない座標に出て、
    /// **見えないまま Esc 監視だけが張られた**状態になっていた（Issue #84）。
    func isOffCurrentScreen() -> Bool {
        guard let panel else { return false }
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let target else { return false }
        return !target.frame.intersects(panel.frame)
    }

    /// パネルの原点を、いる画面の可視領域に収める。
    ///
    /// 幅の変更を「中心を保つ」だけで行っていたので、画面端へドラッグした HUD が
    /// 結果パネル（380×160）に育つと右側が画面外へ出て、「設定を開く」「閉じる」が
    /// 押せなくなっていた。失敗パネルは自動で閉じないので出しっぱなしになる（Issue #84）。
    private static func clamped(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let rect = CGRect(origin: origin, size: size)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        // 画面より大きいパネルは想定しないが、その場合は左下に寄せる。
        let x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    // MARK: 経過時間

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let startedAt else { stopTicking(); return }
        // 経過時間は HUD が非表示でも数えている（途中で表示へ切り替えたときのため）。
        // セッションが終わっていたら止める——**失敗で終わったときも**タイマーを残さない。
        switch AppState.shared.status {
        case .recording, .processing:
            model.setElapsed(Date().timeIntervalSince(startedAt))
        default:
            stopTicking()
        }
    }

    // MARK: キャンセル

    /// Esc / キャンセルボタン。30秒を超える録音は確認を挟む。
    func requestCancel() {
        guard AppState.shared.status == .recording, !model.isConfirmingCancel else { return }
        if model.needsCancelConfirmation {
            model.isConfirmingCancel = true
            // 最小表示でも確認は読ませる必要があるので、通常の大きさへ戻す。
            applyPanelSize()
        } else {
            onCancel?()
        }
    }

    /// キャンセル確認をやめて録音を続ける。
    func keepRecording() {
        guard model.isConfirmingCancel else { return }
        model.isConfirmingCancel = false
        applyPanelSize()
    }

    func handleEscape() {
        // 確認中の Esc は「続ける」に倒す。破棄はクリックでのみ確定させる（誤爆で音声を失わせない）。
        if model.isConfirmingCancel {
            keepRecording()
        } else {
            requestCancel()
        }
    }
}
