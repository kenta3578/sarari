import Testing
import CoreGraphics
@testable import sarari

/// ペンギンの置き場所（Issue #86）。入力中の行と、その先に書かれていく文字を隠さない。
struct ListenerPlacementTests {
    /// 1440×900 の画面 1 枚。下 80pt は Dock、上 25pt はメニューバー。
    private let screenHeight: CGFloat = 900
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 795)
    private let size = CGSize(width: 100, height: 100)

    private func frame(_ anchor: ListenerAnchor?) -> CGRect {
        ListenerPlacement.frame(size: size, anchor: anchor, visibleFrame: visible, primaryScreenHeight: screenHeight)
    }

    @Test("AX の座標（左上原点）を Cocoa の座標（左下原点）に直す")
    func convertsCoordinates() {
        let rect = ListenerPlacement.cocoaRect(fromAX: CGRect(x: 10, y: 100, width: 2, height: 20), primaryScreenHeight: 900)
        #expect(rect == CGRect(x: 10, y: 780, width: 2, height: 20))
    }

    @Test("カーソルの右下に置く")
    func placesBelowRightOfCaret() {
        // AX で y=300 から 20pt の行 → Cocoa では 580…600。
        let f = frame(ListenerAnchor(rect: CGRect(x: 400, y: 300, width: 0, height: 20), kind: .caret))
        #expect(f.minX == 400 + ListenerPlacement.caretGap)
        #expect(f.maxY == 580 - ListenerPlacement.caretGap)
    }

    @Test("右端では、カーソルの左へ回す")
    func flipsLeftAtRightEdge() {
        let f = frame(ListenerAnchor(rect: CGRect(x: 1400, y: 300, width: 0, height: 20), kind: .caret))
        #expect(f.maxX == 1400 - ListenerPlacement.caretGap)
    }

    @Test("下端では、行の上へ回す（行を隠さない）")
    func flipsAboveAtBottomEdge() {
        // AX で y=760 → Cocoa では 120…140。下に 100pt 置くと Dock に食い込む。
        let f = frame(ListenerAnchor(rect: CGRect(x: 400, y: 760, width: 0, height: 20), kind: .caret))
        #expect(f.minY == 140 + ListenerPlacement.caretGap)
    }

    @Test("入力欄やウィンドウの枠しか取れないときは、内側の右下")
    func placesInsideContainer() {
        let f = frame(ListenerAnchor(rect: CGRect(x: 100, y: 100, width: 800, height: 600), kind: .container))
        #expect(f.maxX == 900 - ListenerPlacement.containerInset)
        #expect(f.minY == 200 + ListenerPlacement.containerInset)
    }

    @Test("何も取れないときは画面の右下")
    func fallsBackToScreenCorner() {
        let f = frame(nil)
        #expect(f.maxX == visible.maxX - ListenerPlacement.containerInset)
        #expect(f.minY == visible.minY + ListenerPlacement.containerInset)
    }

    @Test("どの場合も画面の中に収める")
    func staysOnScreen() {
        let f = frame(ListenerAnchor(rect: CGRect(x: 5000, y: -300, width: 0, height: 20), kind: .caret))
        #expect(visible.contains(f))
    }
}
