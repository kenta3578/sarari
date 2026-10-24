import AppKit
import ApplicationServices
import Testing
@testable import sarari

/// 録音を止めたときと挿入の直前で、挿入先が変わっていないかの判定（Issue #107）。
///
/// 基準は「止めた時点」。始めた場所と別の所へ移ってから止める使い方があるため、
/// 守るのは止めてから貼るまで（文字起こしの数秒）の移動だけ。
///
/// AX の要素は `AXUIElementCreateApplication(pid)` で作る。権限が無くても作れて、
/// 同じ pid なら `CFEqual` で等しく、違う pid なら等しくない。窓・入力欄の「別物」をこれで表す。
struct InsertionTargetTests {

    private static let editor = "com.example.editor"
    private static let other = "com.example.other"
    /// sarari 自身。止めた時点が基準なので、sarari の窓で止めたら sarari の入力欄が挿入先になる。
    private static let sarari = "com.kenta3578.koebun"

    /// 識別用の AX 要素。番号が同じなら同じ要素。
    private func element(_ id: Int32) -> AXUIElement {
        AXUIElementCreateApplication(id)
    }

    private func target(_ bundleId: String?, window: Int32? = nil, element id: Int32? = nil) -> InsertionTarget {
        InsertionTarget(bundleId: bundleId,
                        window: window.map(element),
                        element: id.map(element))
    }

    private func reason(_ stop: InsertionTarget, _ now: InsertionTarget) -> String? {
        InsertionTarget.mismatchReason(expected: stop, current: now)
    }

    // MARK: - 挿入してよい

    @Test("同じアプリ・同じ窓・同じ入力欄なら挿入する")
    func sameTargetIsAllowed() {
        #expect(reason(target(Self.editor, window: 1, element: 10), target(Self.editor, window: 1, element: 10)) == nil)
    }

    @Test("止めたときに読めなかった窓・入力欄は比べない（アプリが同じなら挿入する）")
    func unreadableAtStopFallsBackToApp() {
        #expect(reason(target(Self.editor), target(Self.editor, window: 1, element: 10)) == nil)
        // 止めたときに入力欄だけ読めなかった。
        #expect(reason(target(Self.editor, window: 1), target(Self.editor, window: 1, element: 10)) == nil)
    }

    @Test("止めたときに前面のアプリが分からなければ照合しない（以前と同じ）")
    func unknownAppAtStopIsNotChecked() {
        #expect(reason(target(nil), target(Self.editor, window: 1, element: 10)) == nil)
    }

    @Test("sarari の窓で止めたら、sarari の同じ入力欄には挿入する（設定画面への口述）")
    func stoppedOnSarariInsertsIntoSarari() {
        #expect(reason(target(Self.sarari, window: 1, element: 10), target(Self.sarari, window: 1, element: 10)) == nil)
    }

    // MARK: - 挿入しない

    @Test("別のアプリに移ったら挿入しない")
    func otherAppIsRejected() {
        #expect(reason(target(Self.editor, window: 1, element: 10), target(Self.other, window: 2, element: 20))
                == InsertionTarget.appChangedReason)
        // 窓も入力欄も読めないアプリどうしでも、アプリが違えば止める。
        #expect(reason(target(Self.editor), target(Self.other)) == InsertionTarget.appChangedReason)
        // 貼る直前に前面のアプリが分からなくなっていても止める。
        #expect(reason(target(Self.editor), target(nil)) == InsertionTarget.appChangedReason)
    }

    @Test("sarari と他のアプリの間で移ったら挿入しない")
    func movingBetweenSarariAndOthersIsRejected() {
        #expect(reason(target(Self.editor, window: 1, element: 10), target(Self.sarari, window: 2, element: 20))
                == InsertionTarget.appChangedReason)
        #expect(reason(target(Self.sarari, window: 2, element: 20), target(Self.editor, window: 1, element: 10))
                == InsertionTarget.appChangedReason)
    }

    @Test("同じアプリの別の窓に移ったら挿入しない")
    func otherWindowIsRejected() {
        let stop = target(Self.editor, window: 1, element: 10)
        #expect(reason(stop, target(Self.editor, window: 2, element: 20)) == InsertionTarget.focusChangedReason)
        #expect(reason(target(Self.editor, window: 1), target(Self.editor, window: 2)) == InsertionTarget.focusChangedReason)
    }

    @Test("同じ窓の別のタブ（別の入力欄）に移ったら挿入しない")
    func otherTabIsRejected() {
        #expect(reason(target(Self.editor, window: 1, element: 10), target(Self.editor, window: 1, element: 11))
                == InsertionTarget.focusChangedReason)
        // 止めたときに窓だけ読めなくても、入力欄が違えば止める。
        #expect(reason(target(Self.editor, element: 10), target(Self.editor, window: 1, element: 11))
                == InsertionTarget.focusChangedReason)
    }

    @Test("止めたときに読めた窓・入力欄が、貼る直前に読めなくなっていたら挿入しない")
    func unreadableNowIsRejected() {
        let stop = target(Self.editor, window: 1, element: 10)
        // 入力欄以外（サイドバーなど）へ移った・応答しなくなった。移っていないと確かめられないので送らない。
        #expect(reason(stop, target(Self.editor, window: 1)) == InsertionTarget.focusChangedReason)
        #expect(reason(stop, target(Self.editor)) == InsertionTarget.focusChangedReason)
    }
}

/// `TextInjector` を通したとき、挿入先が変わっていたら ⌘V を送らないこと（Issue #107）。
@MainActor
struct TextInjectorTargetTests {

    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sarari.tests.\(UUID().uuidString)"))
        var current: InsertionTarget
        /// ⌘V を送った回数。
        var delivered = 0

        init(current: InsertionTarget) { self.current = current }

        @MainActor
        func makeInjector() -> TextInjector {
            TextInjector(environment: TextInjector.Environment(
                pasteboard: pasteboard,
                currentTarget: { [self] in current },
                isAccessibilityTrusted: { true },
                secureInputReason: { nil },
                deliver: { [self] _ in
                    delivered += 1
                    return .succeeded
                },
                keepResultOnFailure: { false },
                restoreDelay: .zero
            ))
        }

        deinit { pasteboard.releaseGlobally() }
    }

    private func element(_ id: Int32) -> AXUIElement { AXUIElementCreateApplication(id) }

    @Test("止めたあと文字起こし中に同じアプリの別のタブへ移ったら、送らずに失敗を返す")
    func switchedTabIsNotDelivered() async {
        let stop = InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10))
        let h = Harness(current: InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(11)))
        let injector = h.makeInjector()

        let outcome = await injector.insert("口述", expectedTarget: stop)

        #expect(outcome.isFailure)
        #expect(h.delivered == 0)
    }

    @Test("挿入先が変わっていなければ送る")
    func sameTargetIsDelivered() async {
        let stop = InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10))
        let h = Harness(current: InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10)))
        let injector = h.makeInjector()

        let outcome = await injector.insert("口述", expectedTarget: stop)

        #expect(outcome == .succeeded)
        #expect(h.delivered == 1)
    }
}
