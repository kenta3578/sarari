import AppKit
import SwiftUI

/// 設定ウィンドウを自前の `NSWindow` で開く。
///
/// SwiftUI の `Settings` シーンは非公開セレクタ（`showSettingsWindow:`）経由でしか
/// 開けず、セレクタ名が OS バージョンで変わるうえ `LSUIElement`（Dock に出さない
/// メニューバー常駐）アプリでは無反応になることがある。設定に到達できないと
/// エンジン切替も辞書登録もできないので、ここは OS の実装に依存しない形にする。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// 設定ウィンドウを前面に出す。既に開いていれば作り直さず使い回す。
    func show() {
        // 常駐アプリは非アクティブなことが多く、activate しないと背面に出る。
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "sarari 設定"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 閉じても解放しない（次に開くときに同じウィンドウを使う）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 520, height: 640))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// ウィンドウを閉じるときの後始末。
    ///
    /// `isReleasedWhenClosed = false` でウィンドウを使い回すため、閉じても SwiftUI の
    /// ビュー階層は生きたままで `.onDisappear` が発火しない。ホットキー録りの監視を
    /// ここで止めないと、次に ⌘C を押しただけで録音キーがそれに書き換わり、
    /// 画面は閉じているので何も表示されない（Issue #78）。
    func windowWillClose(_ notification: Notification) {
        HotKeyCapture.shared.cancel()
    }

    /// 別アプリに切り替えたら録りをやめる。続けると、別アプリで押した修飾キーで
    /// 設定が書き換わる（Issue #112）。
    func windowDidResignKey(_ notification: Notification) {
        HotKeyCapture.shared.cancel()
    }
}
