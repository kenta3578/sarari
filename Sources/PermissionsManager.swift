import AVFoundation
import AppKit
@preconcurrency import ApplicationServices

/// マイク / アクセシビリティ権限の要求・確認。
enum PermissionsManager {

    /// マイク権限を確認し、未決定ならシステムダイアログを出す。
    static func ensureMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// マイクの権限。録音を始める前に確かめる（Issue #123）。
    static var microphoneAccess: MicrophoneAccess {
        MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// アクセシビリティ（入力監視 / イベント送出）権限があるか。
    ///
    /// **グローバルなキー監視はこれが true でないと一度も発火しない。** 起動時に監視を
    /// 張っただけでは、後から許可しても右⌥ が効かないので、許可されたかを見張るのに使う
    /// （Issue #78）。
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// アクセシビリティ権限が無ければ、System Settings へ誘導するシステムのプロンプトを出す。
    /// 戻り値は「いま許可されているか」。
    @discardableResult
    static func promptAccessibilityIfNeeded() -> Bool {
        // `kAXTrustedCheckOptionPrompt` は ApplicationServices の**未注釈のグローバル var**
        // なので、読むだけで並行性検査に引っかかる。値は公開された固定文字列なので直接書く。
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定の「プライバシーとセキュリティ」内の該当ペインを開く。
    /// メニューと HUD の両方から使う（開き方を2か所に書かない）。
    static func openPrivacyPane(_ pane: PrivacyPane) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    enum PrivacyPane {
        case accessibility
        case microphone

        var anchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .microphone:    return "Privacy_Microphone"
            }
        }
    }
}

/// 失敗の原因が**ユーザー側の設定で直せる**ものだと分かっているときに、失敗表示へ添える手がかり。
/// 文言の文字列を見て判定しない（文言は変わるので）。`AppStatus.failed` / `InsertionOutcome.failed` が運ぶ。
enum FailureHint: Equatable {
    /// アクセシビリティ権限が無い（挿入・キー送出ができない）。
    case accessibilityPermission
    /// Secure Keyboard Entry 中・パスワード欄。**アプリ側から解除する手段は無い**（Issue #104）。
    case secureInput
    /// マイクの権限が無い（録音しても無音しか入らない。Issue #123）。
    case microphonePermission

    /// HUD のボタンに出す文言。**nil ならボタンを出さない。**
    /// 押しても何も起きないボタンは、原因を読ませる邪魔にしかならない。
    var actionTitle: String? {
        switch self {
        case .accessibilityPermission: return "設定を開く"
        case .secureInput:             return nil
        case .microphonePermission:    return "設定を開く"
        }
    }

    /// ボタンで開くシステム設定の画面。nil なら開く先が無い。
    var privacyPane: PermissionsManager.PrivacyPane? {
        switch self {
        case .accessibilityPermission: return .accessibility
        case .microphonePermission:    return .microphone
        case .secureInput:             return nil
        }
    }

    /// ボタンを押したときの動作。
    func perform() {
        if let privacyPane { PermissionsManager.openPrivacyPane(privacyPane) }
    }
}
