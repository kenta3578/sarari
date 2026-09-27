import Testing
import SwiftUI
import AppKit
@testable import sarari

/// 説明書サイト（docs/）に載せる画面の画像を描き出す（Issue #56）。
///
/// **普段の `xcodebuild test` では走らない。** `scripts/docs-shots.sh` が書き出し先
/// （`SARARI_DOC_SHOTS_DIR`）と見本用の仮のホーム（`CFFIXED_USER_HOME`）を渡したときだけ走る。
/// 仮のホームでないと本物の `~/sarari` の辞書・履歴が画像に映るので、そのときは描かずに落とす。
/// 設定値（UserDefaults）は仮のホームでは切り替わらないので、スクリプト用のスキーム
/// `sarari-docshots` が既定値を起動引数で渡している（引数の層は保存値より優先され、書き込まれない）。
@MainActor
@Suite(.enabled(if: DocShots.outputDirectory != nil), .serialized)
struct DocScreenshotsTests {
    @Test("設定の各タブを描き出す")
    func settingsTabs() async throws {
        try DocShots.requireSampleHome()
        try await DocShots.writeSampleData()
        try await DocShots.renderWindow(GeneralSettingsView(), size: CGSize(width: 520, height: 1330),
                                        name: "settings-general")
        try await DocShots.renderWindow(ReplacementsSettingsView(), size: CGSize(width: 520, height: 640),
                                        name: "settings-replacements")
        try await DocShots.renderWindow(SuggestionsSettingsView(), size: CGSize(width: 520, height: 420),
                                        name: "settings-suggestions")
    }

    @Test("録音 HUD の状態を描き出す")
    func hudStates() async throws {
        try DocShots.requireSampleHome()
        // 喋っている途中の音量。棒が声で伸びているところを見せる。
        let speaking: [Float] = [0.05, 0.18, 0.26, 0.22]

        try await DocShots.renderHUD(name: "hud-recording") { model in
            model.status = .recording
            model.setElapsed(7)
            speaking.forEach { model.push(level: $0) }
        }
        try await DocShots.renderHUD(name: "hud-recording-hover") { model in
            model.status = .recording
            model.setElapsed(7)
            model.isHovering = true
            speaking.forEach { model.push(level: $0) }
        }
        try await DocShots.renderHUD(name: "hud-processing") { model in
            model.status = .processing
            model.setElapsed(9)
        }
        try await DocShots.renderHUD(name: "hud-done") { model in
            model.status = .done(message: "挿入しました ✓")
            model.setElapsed(9)
        }
        try await DocShots.renderHUD(name: "hud-silent") { model in
            model.status = .recording
            model.setElapsed(3)
            (0..<45).forEach { _ in model.push(level: 0) }
        }
        try await DocShots.renderHUD(name: "hud-result") { model in
            let outcome = InsertionOutcome.failed(reason: "録音したアプリが前面にないため挿入しませんでした")
            model.status = .failed(reason: outcome.headline)
            model.pendingResult = .init(text: DocShots.sampleUtterance, title: outcome.headline,
                                        detail: outcome.detail, isFailure: true, note: nil, hint: outcome.hint)
        }
    }
}

@MainActor
enum DocShots {
    nonisolated static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SARARI_DOC_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let sampleUtterance = "明日の定例は 10 時からに変更します。GitHub の PR にコメントを残しておいたので、見ておいてください。"

    struct NotSampleHome: Error, CustomStringConvertible {
        let path: String
        var description: String { "データの置き場が本物のホームを指している（\(path)）。scripts/docs-shots.sh から走らせる" }
    }

    /// データの置き場が仮のホームを指しているか。本物の `~/sarari` なら描かない。
    static func requireSampleHome() throws {
        let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        let real = URL(fileURLWithPath: realHome).appendingPathComponent(DataDirectory.name).resolvingSymlinksInPath()
        let current = DataDirectory.url.resolvingSymlinksInPath()
        guard current != real else { throw NotSampleHome(path: current.path) }
    }

    /// 辞書と履歴の見本。候補タブは履歴から出すので、聞き違いを含む発話を混ぜておく。
    static func writeSampleData() async throws {
        ReplacementStore.shared.rules = ReplacementStore.defaultRules + [
            ReplacementRule(from: "プルリク", to: "PR"),
            ReplacementRule(from: "ギットハブ", to: "GitHub"),
        ]

        let texts = Array(repeating: "GitHub のブランチを切ってから作業します。", count: 6)
            + Array(repeating: "ブランチ名は GitHub の Issue 番号にそろえます。", count: 6)
            + ["HitHub に上げておきました。", "プランチを消しておいてください。", sampleUtterance]
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (index, text) in texts.enumerated() {
            let createdAt = start.addingTimeInterval(Double(index) * 60)
            var entry = HistoryEntry(createdAt: createdAt, rawText: text, replacedText: text,
                                     durations: .init(transcribeMs: 290, replaceMs: 0),
                                     speechEngine: "apple", audio: nil, inserted: true, insertion: .succeeded)
            entry.id = HistoryFiles.directoryName(for: createdAt)
            _ = try HistoryFiles.write(entry)
        }
        HistoryStore.shared.reload()
        // 読み直しは裏で走るので、見本が全部入るまで待つ。
        for _ in 0..<50 where HistoryStore.shared.entries.count < texts.count {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 設定ウィンドウに入れて、タイトルバーごとライト・ダークの 2 枚を描く。
    static func renderWindow<V: View>(_ view: V, size: CGSize, name: String) async throws {
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "sarari の設定"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            // 候補タブは履歴からの計算を待ってから出る。
            try await Task.sleep(for: .milliseconds(800))
            try write(window.contentView!.superview!, name: name, dark: dark)
            window.close()
        }
    }

    /// HUD を壁紙代わりのグラデーションの上に置いて描く（パネルは半透明なので下地が要る）。
    static func renderHUD(name: String, configure: (RecordingHUDModel) -> Void) async throws {
        let model = RecordingHUDModel()
        configure(model)
        let hud = RecordingHUDView(model: model, onStop: {}, onRequestCancel: {}, onKeepRecording: {},
                                   onConfirmCancel: {}, onDismiss: {}, onCopyResult: {},
                                   onRetryInsert: {}, onDismissResult: {})
        let size = model.panelSize
        let canvas = CGSize(width: max(size.width + 64, 280), height: size.height + 48)
        for dark in [false, true] {
            let backdrop = LinearGradient(colors: dark ? [Color(white: 0.16), Color(red: 0.2, green: 0.18, blue: 0.3)]
                                                       : [Color(white: 0.93), Color(red: 0.86, green: 0.87, blue: 0.95)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
            // 画面外で描くと半透明の下地の端が 1pt の縦線として角丸の外に出るので、パネルと同じ角丸で切る
            // （実機のパネルは透明な窓なので出ない）。
            let radius = model.usesMinimalBar ? HUDMetrics.minimalPanelSize.height / 2 : 14
            let clipped = hud.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            let view = ZStack { backdrop; clipped }.frame(width: canvas.width, height: canvas.height)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: canvas)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            try await Task.sleep(for: .milliseconds(400))
            try write(host, name: name, dark: dark)
            window.close()
        }
    }

    private static func write(_ view: NSView, name: String, dark: Bool) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory!.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
    }
}
