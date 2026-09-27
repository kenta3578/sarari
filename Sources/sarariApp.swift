import SwiftUI

/// sarari: 完全ローカルの音声入力アプリ（メニューバー常駐）。
///
/// 流れ:
///   右⌥(Right Option) でトグル録音 → Apple 音声認識（設定で WhisperKit にも切替可）で文字起こし
///   → 辞書置換 →（任意で LLM 整形）→ 最前面アプリのカーソル位置に挿入。
@main
struct SarariApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    init() {
        // ストア（辞書・フィラー・履歴）が旧名の置き場を読む前に移す（Issue #43）。
        if !AppDelegate.isRunningTests { DataDirectory.migrateIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            // 状態はアイコンの形状（mic / mic.fill / waveform / ...）と色の両方で表す。
            // 色が読めない環境でも形状だけで区別できる。
            Image(nsImage: state.status.menuBarImage)
                .accessibilityLabel(state.status.accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
        // 設定は SwiftUI の Settings シーンではなく SettingsWindowController で開く
        // （非公開セレクタに依存すると LSUIElement アプリで無反応になるため）。
    }
}

/// 起動時にコントローラを立ち上げるためのデリゲート。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock に出さず、メニューバーのみの常駐アプリにする（LSUIElement と二重保険）
        NSApp.setActivationPolicy(.accessory)
        // テストのホストとして起動したときは何も始めない（Issue #102）。始めると権限ダイアログ・
        // モデルのダウンロード・グローバル監視が走り、テストがそれを待つことになる。
        guard !Self.isRunningTests else { return }
        AppController.shared.start()
    }

    /// `xcodebuild test` がこのアプリを `TEST_HOST` として起動しているか。
    ///
    /// 環境変数は Apple の非公開仕様で名前が変わってきた（Xcode 26 では `XCTestConfigurationFilePath`
    /// は空文字で渡る）。テストバンドルは `DYLD_INSERT_LIBRARIES` で XCTest ごと `main` 前に
    /// ロードされるので、XCTestCase クラスの存在も併せて見る。本番の起動では決してロードされない。
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestSessionIdentifier"] != nil
            || env["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// 復元は挿入の 0.25 秒後に走る。その待ちの最中に終了すると、口述テキストが
    /// クリップボードに残ったままになる。ここで同期的に戻す（Issue #79）。
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TextInjector.restorePendingClipboard() }
    }
}
