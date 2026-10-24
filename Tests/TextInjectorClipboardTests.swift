import AppKit
import Testing
@testable import sarari

/// 挿入のたびに借りたクリップボードが、元の内容へ戻ること（Issue #105）。
///
/// 名前付きペーストボードとフェイクの送出で `TextInjector` の手順をそのまま通す。
/// フェイクの送出は「挿入先がそのとき ⌘V で読んだ内容」を記録し、AX で確かめられない
/// アプリ（ターミナル）と同じく `.uncertain` を返す。`.uncertain` は復元する経路。
@MainActor
struct TextInjectorClipboardTests {

    /// 復元までの待ち。本物（250ms）より短くしてテストを速くする。
    private static let restoreDelay: Duration = .milliseconds(20)

    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sarari.tests.\(UUID().uuidString)"))
        /// 挿入先が ⌘V で受け取った内容（送出の順）。
        var pasted: [String?] = []
        /// 送出のたびに呼ぶ。挿入先の処理中にユーザーが何かする場面を作る。
        var duringDeliver: (@MainActor () -> Void)?

        @MainActor
        func makeInjector() -> TextInjector {
            TextInjector(environment: TextInjector.Environment(
                pasteboard: pasteboard,
                frontmostBundleId: { "com.example.editor" },
                isAccessibilityTrusted: { true },
                secureInputReason: { nil },
                deliver: { [self] _ in
                    pasted.append(pasteboard.string(forType: .string))
                    duringDeliver?()
                    // 本物は 350ms 以上待って判定する。ここでも中断点を挟む。
                    await Task.yield()
                    return .uncertain(detail: "このアプリでは結果を確認できません")
                },
                keepResultOnFailure: { true },
                restoreDelay: TextInjectorClipboardTests.restoreDelay
            ))
        }

        func copy(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        var current: String? { pasteboard.string(forType: .string) }

        deinit { pasteboard.releaseGlobally() }
    }

    /// 遅らせて走る復元が全部終わるまで待つ。
    private func waitForRestores() async {
        try? await Task.sleep(for: Self.restoreDelay * 8)
    }

    @Test("2回続けて挿入しても、1回目の前にコピーしていた内容に戻る")
    func twoInsertionsRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        _ = await injector.insert("1回目", expectedBundleId: "com.example.editor")
        _ = await injector.insert("2回目", expectedBundleId: "com.example.editor")
        await waitForRestores()

        #expect(h.current == "元のコピー")
        // 貼った内容が入れ替わっていないこと。
        #expect(h.pasted == ["1回目", "2回目"])
    }

    @Test("3回続けても、HUD・履歴からの再挿入（照合なし）を混ぜても元に戻る")
    func manyInsertionsIncludingReinsertRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        _ = await injector.insert("口述", expectedBundleId: "com.example.editor")
        _ = await injector.insert("もう一度挿入")
        _ = await injector.insert("次の口述", expectedBundleId: "com.example.editor")
        await waitForRestores()

        #expect(h.current == "元のコピー")
        #expect(h.pasted == ["口述", "もう一度挿入", "次の口述"])
    }

    @Test("呼び出し側が待たずに続けて投げても、元に戻る")
    func concurrentInsertionsRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        async let first = injector.insert("1回目", expectedBundleId: "com.example.editor")
        async let second = injector.insert("2回目", expectedBundleId: "com.example.editor")
        _ = await (first, second)
        await waitForRestores()

        #expect(h.current == "元のコピー")
        #expect(Set(h.pasted.compactMap { $0 }) == ["1回目", "2回目"])
    }

    @Test("挿入の途中でユーザーがコピーした内容は、戻すときに踏み潰さない")
    func userCopyDuringInsertionIsKept() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")
        h.duringDeliver = { [h] in
            // 1回目の挿入先が処理している間に、ユーザーが別のものをコピーした。
            h.duringDeliver = nil
            h.copy("あとからのコピー")
        }

        _ = await injector.insert("1回目", expectedBundleId: "com.example.editor")
        _ = await injector.insert("2回目", expectedBundleId: "com.example.editor")
        await waitForRestores()

        #expect(h.current == "あとからのコピー")
    }
}
