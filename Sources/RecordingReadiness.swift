import AVFoundation

/// マイクの権限。`AVCaptureDevice.authorizationStatus` を判定に要る 3 つに畳んだもの。
enum MicrophoneAccess: Equatable {
    case authorized
    /// まだ尋ねていない。録音を始めた時点で OS が尋ねる。
    case notDetermined
    /// 拒否・制限。録音しても無音しか入らない。
    case denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:    self = .authorized
        case .notDetermined: self = .notDetermined
        default:             self = .denied
        }
    }
}

/// 音声認識モデルの状態。**読み込み中かどうかはここだけで決める**（Issue #123）。
/// 表示状態（`AppStatus`）は結果パネルを閉じる等で待機に上書きされるので、判定に使わない。
enum ModelReadiness: Equatable {
    /// 読み込み中。中身はそのとき見せる `.loadingModel`。
    case loading(AppStatus)
    case ready
    /// 読み込みに失敗した。中身はそのとき見せる `.failed`。読み込み直して成功するまで残す。
    case failed(AppStatus)
}

/// 読み込みの世代。エンジンを続けて切り替えると前の読み込みが後より先に終わるので、
/// 追い越された読み込みの結果は捨てる。
struct ModelLoads {
    private(set) var generation = 0
    mutating func begin() -> Int {
        generation += 1
        return generation
    }
    func isCurrent(_ load: Int) -> Bool { load == generation }
}

/// 録音を始めてよいか・待機に戻すときに何を見せるか（Issue #123）。
///
/// 起動直後はホットキーがモデルの読み込みを待たずに効く（Issue #78）。そのあいだに押された
/// 録音キーや、権限まわりの失敗を黙って捨てると、最初の口述が丸ごと失われる。
/// **始めないときは必ず理由を見せる。** AppKit に触れないので単体テストできる。
enum RecordingReadiness {
    enum Decision: Equatable {
        case start
        /// 始めない。この状態を HUD に出して理由を見せる。
        case notReady(AppStatus)
        /// 始めないが、表示は変えない。前の発話の文字起こし中で、その表示と HUD を潰さない
        /// （ここに来るのは録音中にマイクの権限を外したときだけ）。
        case notReadyKeepingDisplay
    }

    /// 録音キーを押したとき（録音中でないとき）に始めるか。
    ///
    /// 読み込み中は受け付けない（読み込みは数秒〜数分。その間に話した分を待たせて
    /// 後から文字起こしすると、いつ入るか分からない）。読み込み中と見せる。
    /// 理由が重なったら直す順に見せる: 読み込み中 → モデルの失敗 → マイクの権限。
    static func decide(model: ModelReadiness, status: AppStatus, microphone: MicrophoneAccess) -> Decision {
        switch model {
        case .loading(let loading): return .notReady(loading)
        case .failed(let failure):  return .notReady(failure)
        case .ready:                break
        }
        if microphone == .denied {
            return status == .processing ? .notReadyKeepingDisplay : .notReady(microphoneDenied)
        }
        // 録音中はトグルで止める側なので、ここに来ない。来ても二重に始めない。
        return status.canStartRecording ? .start : .notReady(status)
    }

    static let microphoneDenied = AppStatus.failed(
        reason: "マイクの権限がありません（録音しても音が入りません）",
        hint: .microphonePermission)

    static let accessibilityMissing = AppStatus.failed(
        reason: "アクセシビリティ権限がありません（右⌥ が効きません）",
        hint: .accessibilityPermission)

    /// 読み込みを終えたとき・権限が付いたときに戻す状態。nil なら表示を変えない。
    /// **アクセシビリティが先**（無いと録音キー自体が効かない）、次にモデル、揃えば待機。
    /// 読み込み中に権限が付いたときは、読み込み中の表示を残す（終われば読み込み側が戻す）。
    static func restingStatus(model: ModelReadiness, accessibilityTrusted: Bool) -> AppStatus? {
        if !accessibilityTrusted { return accessibilityMissing }
        switch model {
        case .loading:             return nil
        case .failed(let failure): return failure
        case .ready:               return .idle
        }
    }

    /// 結果パネル・失敗表示を閉じて表示が待機に戻ったときに見せる状態。
    /// 閉じる操作は表示を待機にするので、準備できていなければその理由に戻す。
    static func statusAfterDismiss(model: ModelReadiness, accessibilityTrusted: Bool) -> AppStatus {
        if case .loading(let loading) = model, accessibilityTrusted { return loading }
        return restingStatus(model: model, accessibilityTrusted: accessibilityTrusted) ?? .idle
    }

    /// 読み込みを終えたときの HUD の扱い。
    enum HUDAction: Equatable {
        /// 触れない（始めない理由の HUD を出していない。出ている結果パネルを閉じない）。
        case keep
        case hide
        /// 状態を前面に出す。理由の HUD を出していて失敗したとき——消すと «準備ができた» と読める。
        case present
    }

    /// 読み込みを終えたときに見せる状態と HUD の扱い。`model` は読み込み後（`.ready` か `.failed`）。
    /// `noticeShown` は、録音キーが押されて HUD に始めない理由を出しているか。
    static func afterLoad(model: ModelReadiness, accessibilityTrusted: Bool,
                          noticeShown: Bool) -> (status: AppStatus, hud: HUDAction) {
        let status = restingStatus(model: model, accessibilityTrusted: accessibilityTrusted) ?? .idle
        guard noticeShown else { return (status, .keep) }
        return (status, status.isFailed ? .present : .hide)
    }
}
