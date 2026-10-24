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
    static func mismatchReason(expected: InsertionTarget, current: InsertionTarget) -> String? {
        guard let expectedApp = expected.bundleId,
              let currentApp = current.bundleId,
              currentApp != expectedApp
        else { return nil }
        return appChangedReason
    }

    static let appChangedReason = "録音したアプリが前面にないため挿入しませんでした"
}
