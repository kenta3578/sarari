import AVFoundation
import Testing
@testable import sarari

/// 起動直後・権限まわりで、最初の口述が黙って失われないこと（Issue #123）。
/// 録音キーを押したときに始めるか・何を見せるかと、読み込みの終わり・権限の許可で戻す状態を確かめる。
///
/// **読み込み中かどうかは `ModelReadiness` の 1 か所だけで決まる。** 表示状態（`AppStatus`）は
/// 結果パネルを閉じる等で待機に上書きされるので、判定に使わない。
@MainActor
struct RecordingReadinessTests {

    private let loading = AppStatus.loadingModel(step: "音声認識モデルを読み込み中…")
    private let failure = AppStatus.failed(reason: "モデル読込失敗: 見つかりません")

    // MARK: 録音キーを押したとき

    @Test("モデルの読み込み中に押したら始めず、読み込み中と見せる")
    func waitsWhileLoading() {
        let decision = RecordingReadiness.decide(
            model: .loading(loading), status: loading, microphone: .authorized)
        #expect(decision == .notReady(loading))
    }

    /// 結果パネルを閉じると表示は待機に戻るが、エンジンはまだ読み込み中。
    @Test("表示が待機に上書きされていても、読み込み中なら始めない")
    func waitsWhileLoadingEvenWhenIdle() {
        let decision = RecordingReadiness.decide(
            model: .loading(loading), status: .idle, microphone: .authorized)
        #expect(decision == .notReady(loading))
    }

    @Test("モデルの読み込みに失敗しているあいだは始めず、その失敗を見せる")
    func blocksAfterModelFailure() {
        let decision = RecordingReadiness.decide(
            model: .failed(failure), status: failure, microphone: .authorized)
        #expect(decision == .notReady(failure))
    }

    /// 権限の許可などで表示が待機に戻っていても、モデルが無ければ録れても文字起こしできない。
    @Test("表示が待機でも、モデルの失敗が残っていれば始めない")
    func blocksAfterModelFailureEvenWhenIdle() {
        let decision = RecordingReadiness.decide(
            model: .failed(failure), status: .idle, microphone: .authorized)
        #expect(decision == .notReady(failure))
    }

    @Test("マイクの権限が拒否されていたら始めず、マイクの設定へ案内する")
    func blocksWithoutMicrophone() {
        let decision = RecordingReadiness.decide(model: .ready, status: .idle, microphone: .denied)
        guard case .notReady(.failed(_, let hint)) = decision else {
            Issue.record("失敗として見せていない: \(decision)")
            return
        }
        #expect(hint == .microphonePermission)
    }

    /// マイクを許可してもモデルが無ければ文字起こしできない。直す順に見せる。
    @Test("モデルの失敗とマイクの拒否が重なったら、モデルの失敗を先に見せる")
    func modelFailureWinsOverMicrophone() {
        let decision = RecordingReadiness.decide(model: .failed(failure), status: .idle, microphone: .denied)
        #expect(decision == .notReady(failure))
    }

    /// 録音中にマイクの権限を外して止めた直後。前の発話の文字起こしの表示と HUD を潰さない。
    @Test("文字起こし中にマイクの権限が無ければ、始めず表示も変えない")
    func keepsProcessingDisplayWithoutMicrophone() {
        #expect(RecordingReadiness.decide(model: .ready, status: .processing, microphone: .denied)
                == .notReadyKeepingDisplay)
    }

    /// 未決定なら録音を始めた時点で OS が許可を尋ねる。
    @Test("マイクの権限が未決定なら始める")
    func startsWhenMicrophoneUndetermined() {
        #expect(RecordingReadiness.decide(model: .ready, status: .idle, microphone: .notDetermined) == .start)
    }

    /// 挿入に失敗しただけなら次の発話は受け付ける（Issue #97 の既存の決まり）。
    @Test("準備ができていれば、待機・完了・挿入の失敗・処理中のどれからでも始める")
    func startsWhenReady() {
        let statuses: [AppStatus] = [
            .idle, .done(message: "挿入しました"), .warned(message: "注意"),
            .failed(reason: "挿入できませんでした"), .processing
        ]
        for status in statuses {
            #expect(RecordingReadiness.decide(model: .ready, status: status, microphone: .authorized) == .start)
        }
    }

    /// 手がかり付きの失敗をまとめて止めると、パスワード欄に当たったあとの次の口述が入らない。
    @Test("パスワード欄で挿入しなかったあとでも、次の録音は始める")
    func startsAfterSecureInputFailure() {
        let status = AppStatus.failed(reason: "パスワード欄には入力しません", hint: .secureInput)
        #expect(RecordingReadiness.decide(model: .ready, status: status, microphone: .authorized) == .start)
    }

    @Test("録音中に呼ばれても始めない（二重に始めない）")
    func doesNotStartWhileRecording() {
        #expect(RecordingReadiness.decide(model: .ready, status: .recording, microphone: .authorized) != .start)
    }

    @Test("マイクの権限は、許可・未決定以外（拒否・制限）を拒否として扱う")
    func microphoneAuthorizationMapping() {
        #expect(MicrophoneAccess(.authorized) == .authorized)
        #expect(MicrophoneAccess(.notDetermined) == .notDetermined)
        #expect(MicrophoneAccess(.denied) == .denied)
        #expect(MicrophoneAccess(.restricted) == .denied)
    }

    // MARK: 権限が付いたとき・待機に戻すとき

    @Test("アクセシビリティを許可しても、モデルの失敗は消さない")
    func accessibilityGrantKeepsModelFailure() {
        #expect(RecordingReadiness.restingStatus(model: .failed(failure), accessibilityTrusted: true) == failure)
    }

    @Test("読み込み中にアクセシビリティが許可されても、読み込み中のまま（表示を変えない）")
    func accessibilityGrantDuringLoadingKeepsLoading() {
        #expect(RecordingReadiness.restingStatus(model: .loading(loading), accessibilityTrusted: true) == nil)
    }

    @Test("アクセシビリティが無ければ、その失敗を先に見せる（録音キーが効かないため）")
    func accessibilityFailureComesFirst() {
        let status = RecordingReadiness.restingStatus(model: .failed(failure), accessibilityTrusted: false)
        guard case .failed(_, let hint) = status else {
            Issue.record("失敗として見せていない: \(String(describing: status))")
            return
        }
        #expect(hint == .accessibilityPermission)
    }

    @Test("どちらも揃っていれば待機")
    func readyIsIdle() {
        #expect(RecordingReadiness.restingStatus(model: .ready, accessibilityTrusted: true) == .idle)
    }

    // MARK: 読み込みが終わったとき

    @Test("読み込みが成功したら待機に戻し、読み込み中の HUD は閉じる")
    func loadSucceededClosesNotice() {
        let end = RecordingReadiness.afterLoad(model: .ready, accessibilityTrusted: true, noticeShown: true)
        #expect(end.status == .idle)
        #expect(end.hud == .hide)
    }

    /// 消えると «準備ができた» と読める。押し直して初めて失敗に気づくことになる。
    @Test("読み込み中の HUD を出していて失敗したら、閉じずに失敗を見せる")
    func loadFailedShowsFailureInNotice() {
        let end = RecordingReadiness.afterLoad(model: .failed(failure), accessibilityTrusted: true, noticeShown: true)
        #expect(end.status == failure)
        #expect(end.hud == .present)
    }

    @Test("HUD を出していなければ、終わっても HUD には触れない（結果パネルを閉じない）")
    func loadEndWithoutNoticeLeavesHUD() {
        let end = RecordingReadiness.afterLoad(model: .ready, accessibilityTrusted: true, noticeShown: false)
        #expect(end.status == .idle)
        #expect(end.hud == .keep)
    }

    @Test("読み込みが終わっても、アクセシビリティが無ければその失敗を見せる")
    func loadEndWithoutAccessibility() {
        let end = RecordingReadiness.afterLoad(model: .ready, accessibilityTrusted: false, noticeShown: false)
        #expect(end.status == RecordingReadiness.accessibilityMissing)
    }

    /// エンジンを続けて切り替えると、前の読み込みが後の読み込みより先に終わることがある。
    @Test("後から始めた読み込みに追い越された読み込みの結果は捨てる")
    func supersededLoadIsIgnored() {
        var loads = ModelLoads()
        let first = loads.begin()
        let second = loads.begin()
        #expect(!loads.isCurrent(first))
        #expect(loads.isCurrent(second))
    }

    // MARK: 見せ方

    @Test("読み込み中を見せる HUD は、文言が読める大きさで出す")
    func loadingIsNotMinimalBar() {
        let model = RecordingHUDModel()
        model.status = loading
        #expect(!model.usesMinimalBar)
    }

    @Test("マイクの権限の手がかりには「設定を開く」ボタンが付き、マイクの設定を開く")
    func microphoneHintHasAction() {
        #expect(FailureHint.microphonePermission.actionTitle == "設定を開く")
        #expect(FailureHint.microphonePermission.privacyPane == .microphone)
        #expect(FailureHint.accessibilityPermission.privacyPane == .accessibility)
        #expect(FailureHint.secureInput.privacyPane == nil)
    }
}
