import Testing
@testable import sarari

/// 起動直後・権限まわりで、最初の口述が黙って失われないこと（Issue #123）。
/// 録音キーを押したときに始めるか・何を見せるかと、待機に戻すときの状態を確かめる。
@MainActor
struct RecordingReadinessTests {

    private let modelFailure = AppStatus.failed(reason: "モデル読込失敗: 見つかりません")

    // MARK: 録音キーを押したとき

    @Test("モデルの読み込み中に押したら始めず、読み込み中と見せる")
    func waitsWhileLoading() {
        let step = "音声認識モデルを読み込み中…"
        let decision = RecordingReadiness.decide(
            status: .loadingModel(step: step), modelFailure: nil, microphone: .authorized)
        #expect(decision == .notReady(.loadingModel(step: step)))
    }

    @Test("モデルの読み込みに失敗しているあいだは始めず、その失敗を見せる")
    func blocksAfterModelFailure() {
        let decision = RecordingReadiness.decide(
            status: modelFailure, modelFailure: modelFailure, microphone: .authorized)
        #expect(decision == .notReady(modelFailure))
    }

    /// 権限の許可などで表示が待機に戻っていても、モデルが無ければ録れても文字起こしできない。
    @Test("表示が待機でも、モデルの失敗が残っていれば始めない")
    func blocksAfterModelFailureEvenWhenIdle() {
        let decision = RecordingReadiness.decide(
            status: .idle, modelFailure: modelFailure, microphone: .authorized)
        #expect(decision == .notReady(modelFailure))
    }

    @Test("マイクの権限が拒否されていたら始めず、マイクの設定へ案内する")
    func blocksWithoutMicrophone() {
        let decision = RecordingReadiness.decide(
            status: .idle, modelFailure: nil, microphone: .denied)
        guard case .notReady(.failed(_, let hint)) = decision else {
            Issue.record("失敗として見せていない: \(decision)")
            return
        }
        #expect(hint == .microphonePermission)
    }

    /// 未決定なら録音を始めた時点で OS が許可を尋ねる。
    @Test("マイクの権限が未決定なら始める")
    func startsWhenMicrophoneUndetermined() {
        #expect(RecordingReadiness.decide(status: .idle, modelFailure: nil, microphone: .notDetermined) == .start)
    }

    /// 挿入に失敗しただけなら次の発話は受け付ける（Issue #97 の既存の決まり）。
    @Test("準備ができていれば、待機・完了・挿入の失敗・処理中のどれからでも始める")
    func startsWhenReady() {
        let statuses: [AppStatus] = [
            .idle, .done(message: "挿入しました"), .warned(message: "注意"),
            .failed(reason: "挿入できませんでした"), .processing
        ]
        for status in statuses {
            #expect(RecordingReadiness.decide(status: status, modelFailure: nil, microphone: .authorized) == .start)
        }
    }

    // MARK: 待機に戻すとき

    @Test("アクセシビリティを許可しても、モデルの失敗は消さない")
    func accessibilityGrantKeepsModelFailure() {
        #expect(RecordingReadiness.restingStatus(modelFailure: modelFailure, accessibilityTrusted: true)
                == modelFailure)
    }

    @Test("アクセシビリティが無ければ、その失敗を先に見せる（録音キーが効かないため）")
    func accessibilityFailureComesFirst() {
        let status = RecordingReadiness.restingStatus(modelFailure: modelFailure, accessibilityTrusted: false)
        guard case .failed(_, let hint) = status else {
            Issue.record("失敗として見せていない: \(status)")
            return
        }
        #expect(hint == .accessibilityPermission)
    }

    @Test("どちらも揃っていれば待機")
    func readyIsIdle() {
        #expect(RecordingReadiness.restingStatus(modelFailure: nil, accessibilityTrusted: true) == .idle)
    }

    // MARK: 見せ方

    @Test("読み込み中を見せる HUD は、文言が読める大きさで出す")
    func loadingIsNotMinimalBar() {
        let model = RecordingHUDModel()
        model.status = .loadingModel(step: "音声認識モデルを読み込み中…")
        #expect(!model.usesMinimalBar)
    }

    @Test("マイクの権限の手がかりには「設定を開く」ボタンが付く")
    func microphoneHintHasAction() {
        #expect(FailureHint.microphonePermission.actionTitle == "設定を開く")
    }
}
