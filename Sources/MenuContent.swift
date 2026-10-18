import SwiftUI
import AppKit

/// メニューバーのドロップダウン内容。
struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Text(state.status.menuText)
            .font(.system(size: 12))

        Divider()

        Button("履歴…") {
            HistoryWindowController.shared.show()
        }

        Button("設定…") {
            SettingsWindowController.shared.show()
        }

        Divider()

        Button("アクセシビリティ設定を開く") {
            PermissionsManager.openPrivacyPane(.accessibility)
        }
        Button("マイク設定を開く") {
            PermissionsManager.openPrivacyPane(.microphone)
        }

        Divider()

        // 録音が始まらないなど調子が悪いときの逃げ道。設定・辞書・履歴は消えない（Issue #91）。
        Button("再起動") {
            AppRelauncher.relaunch()
        }
        Button("終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
