import ApplicationServices

/// 挿入先。録音を始めたときに控え、挿入の直前にもう一度取って比べる（Issue #80 / #107）。
///
/// AppKit も AX の呼び出しも持たない値なので、判定（`mismatchReason`）は単体テストで確かめられる。
/// AX の要素は `AXUIElementCreateApplication(pid)` で権限なしに作れる。
struct InsertionTarget {
    /// 最前面アプリのバンドル ID。sarari 自身が前面のとき・取れないときは nil。
    let bundleId: String?
    /// 前面の窓。読めなければ nil。
    let window: AXUIElement?
    /// フォーカスのある要素（入力欄）。読めなければ nil。
    let element: AXUIElement?

    init(bundleId: String?, window: AXUIElement? = nil, element: AXUIElement? = nil) {
        self.bundleId = bundleId
        self.window = window
        self.element = element
    }

    /// 録音を始めたときの挿入先 `expected` と、いまの挿入先 `current` が違うなら、その理由。
    /// 同じとみなせるなら nil（挿入してよい）。
    ///
    /// - アプリが違う、またはどちらかで sarari 自身が前面（bundleId が nil）なら止める。
    ///   開始時に sarari の窓が前面だった録音は、どこへ貼るつもりか分からないので照合を飛ばさない
    /// - 同じアプリなら、窓と入力欄を `CFEqual` で比べる。**両方で読めたものだけを比べる**。
    ///   AX が読めないアプリ（ターミナルの一部・Electron）を、読めないだけで止めないため
    ///   （`.claude/rules/insertion-feedback.md`「失敗と断定するのは失敗だと分かるときだけ」）
    static func mismatchReason(expected: InsertionTarget, current: InsertionTarget) -> String? {
        guard let expectedApp = expected.bundleId else { return startedOnSarariReason }
        guard let currentApp = current.bundleId, currentApp == expectedApp else { return appChangedReason }
        if differs(expected.window, current.window) || differs(expected.element, current.element) {
            return focusChangedReason
        }
        return nil
    }

    /// 両方で読めていて、別の要素なら true。
    private static func differs(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return false }
        return !CFEqual(a, b)
    }

    static let appChangedReason = "録音したアプリが前面にないため挿入しませんでした"
    static let focusChangedReason = "録音した窓・入力欄から移ったため挿入しませんでした"
    static let startedOnSarariReason = "録音を始めたとき sarari の窓が前面だったため挿入しませんでした"
}
