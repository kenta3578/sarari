import AppKit
import os

/// アプリを終了して立ち上げ直す。調子が悪いときの逃げ道（Issue #91）。
///
/// 設定・辞書・履歴はファイルに保存済みなので消えない。消えるのはメモリ上の状態だけ。
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // 自分が終わるのを待ってから開き直す。先に開くと既に起動中の自分が前に出るだけになる。
        // シェルは親が終了しても残るので、終了後の起動を任せられる。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            bundlePath,
            String(pid),
        ]
        do {
            try task.run()
        } catch {
            // 開き直せないなら終了もしない（終わったまま戻らなくなるより、調子の悪いまま残る方がまし）。
            Log.audio.error("再起動に失敗しました: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
