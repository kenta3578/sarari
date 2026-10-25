#if DEBUG
import AVFoundation
import AppKit
import ApplicationServices
import Testing
@testable import sarari

/// 使われ方のシナリオ S1〜S5（`docs/scenarios.md` の「自動」）を、話して入るまで通して確かめる（Issue #126）。
///
/// **普段の `xcodebuild test` では走らない。** `scripts/e2e.sh` が読み上げ音声の置き場
/// （`SARARI_E2E_FIXTURES`）と仮のホーム（`CFFIXED_USER_HOME`）を渡したときだけ走る。
/// 音声認識は本物（Apple）、挿入は本物の ⌘V で、挿入先は別プロセスの `sarariE2EHost`。
/// アクセシビリティ権限と画面が要るので CI には載せない。走っている間は挿入先の窓が前面に出る。
@MainActor
@Suite(.enabled(if: E2E.fixtures != nil), .serialized)
struct ScenarioE2ETests {

    // MARK: S1 — 話した内容がカーソル位置に入り、フィラーは消えている

    @Test("S1: 話した内容がカーソル位置に入り、フィラーは消えている")
    func s1DictationReachesCursor() async throws {
        let clipboard = try await E2E.prepare()
        defer { clipboard.restore() }
        let host = try await E2EHost.launch(field: .text)
        defer { host.quit() }

        await AppController.shared.e2eDictate(samples: try E2E.speech("s1"))

        let inserted = try await host.waitForText()
        #expect(inserted.contains("天気"), "入った文字: \(inserted)")
        #expect(!inserted.contains("えーと"), "フィラーが残っている: \(inserted)")
    }

    // MARK: S2 — 続けて口述しても、どの回も入り、クリップボードが元に戻る

    @Test("S2: 続けて口述しても話した順に両方入り、終わったあとクリップボードが口述前の内容に戻る")
    func s2ConsecutiveDictationsRestoreClipboard() async throws {
        let clipboard = try await E2E.prepare()
        defer { clipboard.restore() }
        let original = "E2E: 口述の前にコピーしていた内容"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)

        let host = try await E2EHost.launch(field: .text)
        defer { host.quit() }

        // 1 回目の文字起こしが終わる前に 2 回目を止める。1 回目を長くして、2 回目の文字起こしが
        // 先に終わる状況を作る。それでも挿入は話した順でないといけない（Issue #99）。
        await AppController.shared.e2eDictate(samples: try E2E.speech("s2a"), waitForInsertion: false)
        await AppController.shared.e2eDictate(samples: try E2E.speech("s2b"))
        await TextInjector.shared.waitUntilIdle()

        let inserted = try await host.waitForText(containing: "最後")
        let first = try #require(inserted.range(of: "最初"), "1 回目が入っていない: \(inserted)")
        let second = try #require(inserted.range(of: "最後"), "2 回目が入っていない: \(inserted)")
        #expect(first.lowerBound < second.lowerBound, "話した順に入っていない: \(inserted)")
        #expect(NSPasteboard.general.string(forType: .string) == original)
    }

    // MARK: S3 — 何も話さずに止めたら何も入らない

    @Test("S3: 何も話さずに止めたら、何も入らず履歴にも残らない")
    func s3SilenceInsertsNothing() async throws {
        let clipboard = try await E2E.prepare()
        defer { clipboard.restore() }
        let host = try await E2EHost.launch(field: .text)
        defer { host.quit() }
        let historyBefore = HistoryStore.shared.entries.count

        await AppController.shared.e2eDictate(samples: [Float](repeating: 0, count: 16_000 * 2))

        try await Task.sleep(for: .seconds(1))
        #expect(host.text() == "")
        #expect(HistoryStore.shared.entries.count == historyBefore)
    }

    // MARK: S4 — 辞書置換に登録した語は置き換えたあとの語で入る

    @Test("S4: 辞書置換に登録した語は、置き換えたあとの語で入る")
    func s4ReplacementApplies() async throws {
        let clipboard = try await E2E.prepare()
        defer { clipboard.restore() }
        let saved = ReplacementStore.shared.rules
        ReplacementStore.shared.rules = saved + [ReplacementRule(from: "東京", to: "TOKYO")]
        defer { ReplacementStore.shared.rules = saved }

        let host = try await E2EHost.launch(field: .text)
        defer { host.quit() }

        await AppController.shared.e2eDictate(samples: try E2E.speech("s4"))

        let inserted = try await host.waitForText()
        #expect(inserted.contains("TOKYO"), "入った文字: \(inserted)")
        #expect(!inserted.contains("東京"))
    }

    // MARK: S5 — パスワード欄には入れず、クリップボードにも残さない。結果は履歴に残る

    @Test("S5: パスワード欄には入れず、クリップボードにも残さない。結果は履歴に残る")
    func s5PasswordFieldIsSkipped() async throws {
        let clipboard = try await E2E.prepare()
        defer { clipboard.restore() }
        let original = "E2E: パスワード欄の前のコピー"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)

        let host = try await E2EHost.launch(field: .password)
        defer { host.quit() }
        let historyBefore = HistoryStore.shared.entries.count

        await AppController.shared.e2eDictate(samples: try E2E.speech("s5"))
        await TextInjector.shared.waitUntilIdle()

        try await Task.sleep(for: .seconds(1))
        #expect(host.text() == "", "パスワード欄に入った")
        #expect(NSPasteboard.general.string(forType: .string) == original)
        let entry = try #require(HistoryStore.shared.entries.first)
        #expect(HistoryStore.shared.entries.count == historyBefore + 1)
        #expect(entry.insertion == .failed)
    }
}

// MARK: - 準備

@MainActor
enum E2E {
    nonisolated static var fixtures: URL? {
        ProcessInfo.processInfo.environment["SARARI_E2E_FIXTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    struct Precondition: Error, CustomStringConvertible {
        let description: String
    }

    private static var engineLoaded = false

    /// テストの前のクリップボード。E2E は本物のクリップボードを使うので、終わったら全 type を戻す
    /// （走らせた人がコピーしていた内容を失わせない。テストが途中で落ちても `defer` で戻る）。
    struct SavedClipboard {
        let snapshot: PasteboardSnapshot
        @MainActor func restore() {
            if snapshot.isEmpty {
                NSPasteboard.general.clearContents()
            } else {
                snapshot.restore(to: .general)
            }
        }
    }

    /// 毎回の前提: 前のテストの挿入が終わっている・仮のホーム・アクセシビリティ権限・音声認識エンジン。
    /// 戻り値のクリップボードは、テストの終わりに `restore()` で戻す。
    static func prepare() async throws -> SavedClipboard {
        // 前のテストが予約したクリップボードの復元を済ませる。残っていると、このテストで置いた内容と競る。
        await TextInjector.shared.waitUntilIdle()
        let saved = SavedClipboard(snapshot: PasteboardSnapshot.capture(.general))
        let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        let real = URL(fileURLWithPath: realHome).appendingPathComponent(DataDirectory.name).resolvingSymlinksInPath()
        guard DataDirectory.url.resolvingSymlinksInPath() != real else {
            throw Precondition(description: "データの置き場が本物の ~/sarari を指している。scripts/e2e.sh から走らせる")
        }
        guard AXIsProcessTrusted() else {
            throw Precondition(description: "テスト用にビルドした sarari にアクセシビリティ権限が無い。"
                + "scripts/e2e.sh の案内に従ってシステム設定で許可する")
        }
        if !engineLoaded {
            guard await AppController.shared.e2eLoadSpeechEngine() else {
                throw Precondition(description: "音声認識エンジンを読み込めなかった。ログ（category: asr）を見る")
            }
            engineLoaded = true
        }
        return saved
    }

    /// `scripts/e2e.sh` が `say` で作った 16kHz / mono / Float32 の WAV を読む。
    static func speech(_ name: String) throws -> [Float] {
        let url = try #require(fixtures).appendingPathComponent("\(name).wav")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}

/// 挿入先のアプリ（`sarariE2EHost`）。テストのたびに起動して最前面に出し、終わったら閉じる。
@MainActor
struct E2EHost {
    enum Field: String { case text, password }

    static let bundleID = "com.kenta3578.sarariE2EHost"

    let app: NSRunningApplication
    let outURL: URL

    /// テストのホスト（sarari.app）と同じ出力先に並ぶ。
    static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("sarariE2EHost.app")
    }

    static func launch(field: Field) async throws -> E2EHost {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarari-e2e-\(UUID().uuidString).txt")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--field", field.rawValue, "--out", outURL.path]
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)

        // 最前面に出て欄にフォーカスが入るまで待つ（⌘V は最前面の窓に届く）。
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               FileManager.default.fileExists(atPath: outURL.path) {
                try await Task.sleep(for: .milliseconds(300))
                return E2EHost(app: app, outURL: outURL)
            }
            app.activate()
            try await Task.sleep(for: .milliseconds(100))
        }
        app.terminate()
        throw E2E.Precondition(description: "挿入先の窓が最前面に出なかった")
    }

    func text() -> String {
        (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    }

    /// 欄に文字が入るまで待つ（⌘V の反映は非同期）。
    func waitForText(containing needle: String? = nil) async throws -> String {
        for _ in 0..<30 {
            let current = text()
            if !current.isEmpty, needle.map(current.contains) ?? true { return current }
            try await Task.sleep(for: .milliseconds(100))
        }
        return text()
    }

    func quit() {
        app.terminate()
        try? FileManager.default.removeItem(at: outURL)
    }
}
#endif
