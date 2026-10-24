import ApplicationServices

/// 挿入先。録音を**止めた**ときに控え、挿入の直前にもう一度取って比べる（Issue #80 / #107）。
///
/// 始めた場所と別の所へ移ってから止め、そこへ入れる使い方があるので、基準は停止時。
/// 守るのは、止めてから貼るまで（文字起こしの数秒）に別の場所へ移ったときの誤爆。
///
/// AppKit も AX の呼び出しも持たない値なので、判定（`mismatchReason`）は単体テストで確かめられる。
/// AX の要素は `AXUIElementCreateApplication(pid)` で権限なしに作れる。
struct InsertionTarget {
    /// 最前面アプリの識別子（バンドル ID。無いアプリは `pid:<番号>`）。前面のアプリが取れないときは nil。
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

    /// 録音を止めたときの挿入先 `expected` と、いまの挿入先 `current` が違うなら、その理由。
    /// 同じとみなせるなら nil（挿入してよい）。
    ///
    /// - 止めたときに前面のアプリが分からなかったら照合しない（どこへ貼るつもりか比べようがない）
    /// - アプリが違えば止める。sarari 自身も 1 つのアプリとして扱う（sarari の窓で止めたら、
    ///   sarari の入力欄が挿入先。設定画面への口述）
    /// - 同じアプリなら、窓と入力欄を `CFEqual` で比べる。止めたときに読めなかったものは比べない
    ///   （AX が読めないアプリを、読めないだけで止めない）。止めたときに読めたのに貼る直前に
    ///   読めなければ止める（入力欄以外へ移った・応答しない。移っていないと確かめられない）。
    ///   止めても文章は HUD と履歴に残り、「もう一度挿入」で入れ直せる
    static func mismatchReason(expected: InsertionTarget, current: InsertionTarget) -> String? {
        guard let expectedApp = expected.bundleId else { return nil }
        guard current.bundleId == expectedApp else { return appChangedReason }
        if moved(from: expected.window, to: current.window) || moved(from: expected.element, to: current.element) {
            return focusChangedReason
        }
        return nil
    }

    /// 止めたときに読めた要素から移ったか。止めたときに読めていなければ比べない。
    private static func moved(from stop: AXUIElement?, to now: AXUIElement?) -> Bool {
        guard let stop else { return false }
        guard let now else { return true }
        return !CFEqual(stop, now)
    }

    static let appChangedReason = "録音を止めたアプリから移ったため挿入しませんでした"
    static let focusChangedReason = "録音を止めた窓・入力欄から移ったため挿入しませんでした"
}
