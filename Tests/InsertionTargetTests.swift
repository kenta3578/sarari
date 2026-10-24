import AppKit
import ApplicationServices
import Testing
@testable import sarari

/// 録音を始めたときと挿入の直前で、挿入先が変わっていないかの判定（Issue #107）。
///
/// AX の要素は `AXUIElementCreateApplication(pid)` で作る。権限が無くても作れて、
/// 同じ pid なら `CFEqual` で等しく、違う pid なら等しくない。窓・入力欄の「別物」をこれで表す。
struct InsertionTargetTests {

    private static let editor = "com.example.editor"
    private static let other = "com.example.other"

    /// 識別用の AX 要素。番号が同じなら同じ要素。
    private func element(_ id: Int32) -> AXUIElement {
        AXUIElementCreateApplication(id)
    }

    private func target(_ bundleId: String?, window: Int32? = nil, element id: Int32? = nil) -> InsertionTarget {
        InsertionTarget(bundleId: bundleId,
                        window: window.map(element),
                        element: id.map(element))
    }

    // MARK: - 挿入してよい

    @Test("同じアプリ・同じ窓・同じ入力欄なら挿入する")
    func sameTargetIsAllowed() {
        let start = target(Self.editor, window: 1, element: 10)
        let now = target(Self.editor, window: 1, element: 10)
        #expect(InsertionTarget.mismatchReason(expected: start, current: now) == nil)
    }

    @Test("開始時に窓も入力欄も読めなかったアプリは、アプリが同じなら挿入する")
    func unreadableAtStartFallsBackToApp() {
        let start = target(Self.editor)
        let now = target(Self.editor, window: 1, element: 10)
        #expect(InsertionTarget.mismatchReason(expected: start, current: now) == nil)
    }

    @Test("挿入の直前に読めなかった側は比べない（読めないだけで止めない）")
    func unreadableNowIsNotAMismatch() {
        let start = target(Self.editor, window: 1, element: 10)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(Self.editor)) == nil)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(Self.editor, window: 1)) == nil)
    }

    // MARK: - 挿入しない

    @Test("別のアプリに移ったら挿入しない")
    func otherAppIsRejected() {
        let start = target(Self.editor, window: 1, element: 10)
        let now = target(Self.other, window: 2, element: 20)
        #expect(InsertionTarget.mismatchReason(expected: start, current: now) != nil)
    }

    @Test("同じアプリの別の窓に移ったら挿入しない")
    func otherWindowIsRejected() {
        let start = target(Self.editor, window: 1, element: 10)
        // 入力欄が読めないアプリでも、窓が違えば止める。
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(Self.editor, window: 2, element: 20)) != nil)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(Self.editor, window: 2)) != nil)
    }

    @Test("同じ窓の別のタブ（別の入力欄）に移ったら挿入しない")
    func otherTabIsRejected() {
        let start = target(Self.editor, window: 1, element: 10)
        let now = target(Self.editor, window: 1, element: 11)
        #expect(InsertionTarget.mismatchReason(expected: start, current: now) != nil)
    }

    @Test("録音を始めたとき sarari 自身が前面だったら、照合を飛ばさずに挿入しない")
    func startedOnSarariIsRejected() {
        let start = target(nil)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(Self.editor, window: 1, element: 10)) != nil)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(nil)) != nil)
    }

    @Test("挿入の直前に sarari 自身が前面になっていたら挿入しない")
    func sarariInFrontNowIsRejected() {
        let start = target(Self.editor, window: 1, element: 10)
        #expect(InsertionTarget.mismatchReason(expected: start, current: target(nil)) != nil)
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

    @Test("録音中に同じアプリの別のタブへ移ったら、送らずに失敗を返す")
    func switchedTabIsNotDelivered() async {
        let start = InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10))
        let h = Harness(current: InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(11)))
        let injector = h.makeInjector()

        let outcome = await injector.insert("口述", expectedTarget: start)

        #expect(outcome.isFailure)
        #expect(h.delivered == 0)
    }

    @Test("挿入先が変わっていなければ送る")
    func sameTargetIsDelivered() async {
        let start = InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10))
        let h = Harness(current: InsertionTarget(bundleId: "com.example.editor", window: element(1), element: element(10)))
        let injector = h.makeInjector()

        let outcome = await injector.insert("口述", expectedTarget: start)

        #expect(outcome == .succeeded)
        #expect(h.delivered == 1)
    }
}
