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
    }

    /// 録音キーを押したとき（録音中でないとき）に始めるか。
    ///
    /// - Parameters:
    ///   - status: いまの表示状態。
    ///   - modelFailure: 音声認識モデルの読み込みに失敗したときの状態。表示が別の状態で
    ///     上書きされていても、モデルが無ければ録っても文字起こしできないので持ち続ける。
    ///   - microphone: マイクの権限。
    static func decide(status: AppStatus, modelFailure: AppStatus?, microphone: MicrophoneAccess) -> Decision {
        // 読み込み中は受け付けない（読み込みは数秒〜数分。その間に話した分を待たせて
        // 後から文字起こしすると、いつ入るか分からない）。読み込み中と見せる。
        if case .loadingModel = status { return .notReady(status) }
        if let modelFailure { return .notReady(modelFailure) }
        if microphone == .denied { return .notReady(microphoneDenied) }
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
    /// **アクセシビリティが先**（無いと録音キー自体が効かない）、次にモデルの失敗、揃えば待機。
    /// 読み込み中に権限が付いたときは、読み込み中の表示を残す（終われば読み込み側が戻す）。
    static func restingStatus(modelFailure: AppStatus?, accessibilityTrusted: Bool,
                              isLoadingModel: Bool = false) -> AppStatus? {
        if !accessibilityTrusted { return accessibilityMissing }
        if isLoadingModel { return nil }
        return modelFailure ?? .idle
    }
}
