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

        Button("終了") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
