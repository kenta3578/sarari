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
    private static let restoreDelay: Duration = .milliseconds(50)
    /// 挿入先が送出から遅れて読むまでの時間。復元より十分早く読む（負荷で順番が入れ替わらない幅を取る）。
    private static let lateReadDelay: Duration = .milliseconds(10)

    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sarari.tests.\(UUID().uuidString)"))
        /// 挿入先が ⌘V で受け取った内容（送出の順）。
        var pasted: [String?] = []
        /// 挿入先が送出から遅れて読んだ内容。本物のアプリは ⌘V を処理してから読むので、
        /// 復元を早めすぎるとここに古い内容が入る。
        var lateReads: [String?] = []
        /// 送出のたびに呼ぶ。挿入先の処理中にユーザーが何かする場面を作る。
        var duringDeliver: (@MainActor () -> Void)?

        @MainActor
        func makeInjector() -> TextInjector {
            TextInjector(environment: TextInjector.Environment(
                pasteboard: pasteboard,
                isAccessibilityTrusted: { true },
                secureInputReason: { nil },
                deliver: { [self] _ in
                    pasted.append(pasteboard.string(forType: .string))
                    Task { @MainActor [self] in
                        try? await Task.sleep(for: TextInjectorClipboardTests.lateReadDelay)
                        self.lateReads.append(self.pasteboard.string(forType: .string))
                    }
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

    @Test("2回続けて挿入しても、1回目の前にコピーしていた内容に戻る")
    func twoInsertionsRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        _ = await injector.insert("1回目")
        _ = await injector.insert("2回目")
        await injector.waitUntilIdle()

        #expect(h.current == "元のコピー")
        // 貼った内容が入れ替わっていないこと。
        #expect(h.pasted == ["1回目", "2回目"])
        // 挿入先が遅れて読んでも、まだ自分の口述文が置いてあること（復元を早めすぎない）。
        #expect(h.lateReads == ["1回目", "2回目"])
    }

    @Test("3回続けても、HUD・履歴からの再挿入を混ぜても元に戻る")
    func manyInsertionsIncludingReinsertRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        _ = await injector.insert("口述")
        _ = await injector.insert("もう一度挿入")
        _ = await injector.insert("次の口述")
        await injector.waitUntilIdle()

        #expect(h.current == "元のコピー")
        #expect(h.pasted == ["口述", "もう一度挿入", "次の口述"])
        #expect(h.lateReads == ["口述", "もう一度挿入", "次の口述"])
    }

    @Test("呼び出し側が待たずに続けて投げても、元に戻る")
    func concurrentInsertionsRestoreOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")

        async let first = injector.insert("1回目")
        async let second = injector.insert("2回目")
        _ = await (first, second)
        await injector.waitUntilIdle()

        #expect(h.current == "元のコピー")
        // どちらが先に並ぶかは決めない。重複せず1回ずつ貼られていること。
        #expect(h.pasted.compactMap { $0 }.sorted() == ["1回目", "2回目"])
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

        _ = await injector.insert("1回目")
        _ = await injector.insert("2回目")
        await injector.waitUntilIdle()

        #expect(h.current == "あとからのコピー")
    }

    @Test("口述の前にクリップボードが空なら、続けて挿入したあとも口述文を残さない")
    func emptyOriginalLeavesNoDictation() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.pasteboard.clearContents()

        _ = await injector.insert("1回目")
        _ = await injector.insert("2回目")
        await injector.waitUntilIdle()

        #expect(h.current == nil)
        #expect(h.pasted == ["1回目", "2回目"])
    }

    @Test("判定を待っている間にアプリが終わっても、元のコピーに戻す")
    func terminateDuringDeliverRestoresOriginal() async {
        let h = Harness()
        let injector = h.makeInjector()
        h.copy("元のコピー")
        h.duringDeliver = { [h, injector] in
            // ⌘V を送ったあと、判定が出る前に終了した（applicationWillTerminate）。
            h.duringDeliver = nil
            injector.restorePendingClipboard()
            #expect(h.current == "元のコピー")
        }

        _ = await injector.insert("口述")
        await injector.waitUntilIdle()

        #expect(h.current == "元のコピー")
    }
}
