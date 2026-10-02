import SwiftUI
import AppKit
import Combine

// MARK: - 話しかける相手のペンギン（Issue #86）

/// 録音中・文字起こし中に、入力カーソルの近くへペンギンを出す。
///
/// 音声入力だと意識すると、言い直しや文の途中の «。» が増える。目線の先に相手がいると、
/// 人に説明するつもりで文を組み立ててから話しやすくなる。**役目はそれだけ。**
/// #80 では HUD に小さな顔を置いたが、小さすぎて相手として意識できなかった（#84 で取り消し）。
/// なので大きく・色付きで・目線の先（カーソルの近く）に出す。
///
/// - 状態は HUD とメニューバーが持つ。ペンギンはポーズを変えるだけで、**常に動き続ける
///   アニメーションは付けない**（#146〜#178 で、動きを重ねるほど読めなくなった）
/// - クリックは素通りさせ、フォーカスも奪わない（挿入先が変わると挿入に失敗する）
@MainActor
final class ListenerPenguinController {
    private var panel: NSPanel?
    private let model = ListenerPenguinModel()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // `@Published` は値が入る**前**に流れるので、流れてきた値そのものを使う。
        AppState.shared.$status
            .sink { [weak self] status in
                self?.apply(status, enabled: SettingsStore.shared.listenerPenguinEnabled)
            }
            .store(in: &cancellables)
        SettingsStore.shared.$listenerPenguinEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.apply(AppState.shared.status, enabled: enabled)
            }
            .store(in: &cancellables)
    }

    private func apply(_ status: AppStatus, enabled: Bool) {
        guard enabled else { hide(); return }
        switch status {
        case .recording:
            // 位置は**録音を始めたときに一度だけ**決める。録音中はカーソルが動かないので、
            // 追いかけると AX を毎回叩くだけになる。
            if !model.isVisible { show() }
            model.isListening = true
        case .processing:
            // 文字起こし中は羽を下ろす。録音を経ずに来ることは無いので、出ていなければ出さない。
            model.isListening = false
        default:
            hide()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: ListenerPenguinView.size, height: ListenerPenguinView.size)
        let anchor = CaretLocator.locate()
        let screen = ListenerPlacement.screen(containing: anchor?.rect)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let frame = ListenerPlacement.frame(size: size, anchor: anchor, visibleFrame: screen.visibleFrame,
                                            primaryScreenHeight: primaryHeight)
        panel.setFrame(frame, display: true)
        // `makeKeyAndOrderFront` は使わない。最前面アプリのフォーカス（＝挿入先）を奪う。
        panel.orderFrontRegardless()
        model.isVisible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        model.isVisible = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: ListenerPenguinView.size, height: ListenerPenguinView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: ListenerPenguinView(model: model))
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // クリックは下のアプリへ素通りさせる。送信ボタンなどに重なっても押せる。
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 画面共有に映さない（HUD と同じ。Issue #84 の HUD 側の判断に揃える）。
        panel.sharingType = .none
        return panel
    }
}

@MainActor
final class ListenerPenguinModel: ObservableObject {
    /// 録音中は羽を上げる（«聞いてるよ»）。文字起こし中は下ろす。
    @Published var isListening = true
    var isVisible = false
}

// MARK: - 配置

/// ペンギンを置く目印。AX の座標（左上原点・下向き）のまま持つ。
struct ListenerAnchor: Equatable {
    enum Kind: Equatable {
        /// 入力カーソルそのもの。右下に置く。
        case caret
        /// カーソル位置が取れず、入力欄やウィンドウの枠だけ取れた。内側の右下に置く。
        case container
    }
    var rect: CGRect
    var kind: Kind
}

enum ListenerPlacement {
    /// カーソルからの離れ具合。文字に被らないよう少し空ける。
    static let caretGap: CGFloat = 8
    /// 枠の内側に置くときの余白。
    static let containerInset: CGFloat = 16

    /// AX の座標（主画面の左上が原点・下向き）を Cocoa の座標（左下が原点・上向き）に直す。
    static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 目印を含む画面。取れなければマウスのある画面。
    @MainActor
    static func screen(containing axRect: CGRect?) -> NSScreen {
        let screens = NSScreen.screens
        if let axRect, let primary = screens.first {
            let point = cocoaRect(fromAX: axRect, primaryScreenHeight: primary.frame.height).origin
            if let hit = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { return hit }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? screens[0]
    }

    /// ペンギンの枠（Cocoa の座標）。
    ///
    /// - カーソル: 右下に置く。右にはみ出すなら左へ、下にはみ出すなら行の上へ回す
    ///   （入力中の行と、その先に書かれていく文字を隠さない）
    /// - 枠: 内側の右下
    /// - 何も取れない: 画面の右下
    ///
    /// 最後に画面の中へ収める。
    static func frame(size: CGSize, anchor: ListenerAnchor?, visibleFrame: CGRect,
                      primaryScreenHeight: CGFloat) -> CGRect {
        var origin: CGPoint
        if let anchor {
            let rect = cocoaRect(fromAX: anchor.rect, primaryScreenHeight: primaryScreenHeight)
            switch anchor.kind {
            case .caret:
                origin = CGPoint(x: rect.maxX + caretGap, y: rect.minY - caretGap - size.height)
                if origin.x + size.width > visibleFrame.maxX { origin.x = rect.minX - caretGap - size.width }
                if origin.y < visibleFrame.minY { origin.y = rect.maxY + caretGap }
            case .container:
                origin = CGPoint(x: rect.maxX - containerInset - size.width, y: rect.minY + containerInset)
            }
        } else {
            origin = CGPoint(x: visibleFrame.maxX - containerInset - size.width, y: visibleFrame.minY + containerInset)
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - カーソル位置

/// 入力カーソルの位置を AX で取る。読むのは focused element だけ（ツリーは走査しない）。
///
/// アプリによって取れる深さが違う（ターミナルや一部の Electron はカーソルの矩形を返さない）
/// ので、取れたところまでで返す: カーソル → 入力欄の枠 → フォーカスのあるウィンドウの枠。
@MainActor
enum CaretLocator {
    /// 応答しないアプリで録音開始が固まらないよう短く切る。
    private static let timeout: Float = 0.2

    static func locate() -> ListenerAnchor? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        if let element = element(system, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, timeout)
            if let caret = caretRect(element) { return ListenerAnchor(rect: caret, kind: .caret) }
            if let frame = frame(element) { return ListenerAnchor(rect: frame, kind: .container) }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, timeout)
            if let window = element(appElement, kAXFocusedWindowAttribute), let frame = frame(window) {
                return ListenerAnchor(rect: frame, kind: .container)
            }
        }
        return nil
    }

    /// 選択範囲（＝カーソル）の矩形。幅 0 の範囲で空の矩形を返すアプリがあるので、
    /// そのときは直前の 1 文字の矩形で代える。
    private static func caretRect(_ element: AXUIElement) -> CGRect? {
        guard let rangeValue = axValue(element, kAXSelectedTextRangeAttribute),
              AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        if let rect = bounds(element, range), rect.height > 0 { return rect }
        guard range.location > 0 else { return nil }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let previousValue = AXValueCreate(.cfRange, &previous),
              let rect = bounds(element, previousValue), rect.height > 0 else { return nil }
        // 直前の文字の右端＝カーソル。
        return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        return bounds(element, value)
    }

    private static func bounds(_ element: AXUIElement, _ rangeValue: AXValue) -> CGRect? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), !rect.isNull else { return nil }
        return rect
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// CF の型は `as?` が常に成功してしまうので、TypeID で確かめてから渡す。
    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}

// MARK: - 絵

/// ペンギン（オリジナル）。紺の体・白いお腹・黄色いくちばしと足・ほっぺ。
///
/// **ポーズは 2 つだけ**: 録音中は片方の羽を上げる（«聞いてるよ»）、文字起こし中は下ろす。
/// 状態が変わるときだけ 0.2 秒で繋ぐ。時間で勝手に動く要素は持たない。
struct ListenerPenguinView: View {
    @ObservedObject var model: ListenerPenguinModel

    /// パネルの一辺（pt）。#80 の顔（22pt）が «目に入らない» だったので大きくする。
    static let size: CGFloat = 104

    private static let bodyColor = Color(red: 0.16, green: 0.28, blue: 0.55)
    private static let wing = Color(red: 0.13, green: 0.22, blue: 0.42)
    private static let beak = Color(red: 1.0, green: 0.68, blue: 0.15)
    private static let cheek = Color(red: 1, green: 0.55, blue: 0.6).opacity(0.7)

    var body: some View {
        // 130pt で描いた形を縮めて使う（比率を保つ）。
        ZStack {
            Ellipse().fill(Self.wing)
                .frame(width: 26, height: 50)
                .rotationEffect(.degrees(model.isListening ? -35 : 20))
                .offset(x: -46, y: model.isListening ? 4 : 14)
            Ellipse().fill(Self.wing)
                .frame(width: 26, height: 50)
                .rotationEffect(.degrees(-20))
                .offset(x: 46, y: 14)
            Ellipse().fill(Self.bodyColor).frame(width: 100, height: 116)
            Ellipse().fill(.white).frame(width: 72, height: 84).offset(y: 12)
            HStack(spacing: 22) { eye; eye }.offset(y: -14)
            Capsule().fill(Self.beak).frame(width: 18, height: 9)
            HStack(spacing: 40) {
                Circle().fill(Self.cheek).frame(width: 12)
                Circle().fill(Self.cheek).frame(width: 12)
            }
            .offset(y: 6)
            HStack(spacing: 22) {
                Capsule().fill(Self.beak).frame(width: 20, height: 8)
                Capsule().fill(Self.beak).frame(width: 20, height: 8)
            }
            .offset(y: 58)
        }
        .frame(width: 130, height: 130)
        .scaleEffect(Self.size / 130)
        .frame(width: Self.size, height: Self.size)
        // 1 枚の絵にしてから影を付ける。付けないと部品ごとに影が落ち、お腹がにじむ。
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.2), value: model.isListening)
        .accessibilityHidden(true)
    }

    private var eye: some View {
        ZStack {
            Circle().fill(.black).frame(width: 11)
            Circle().fill(.white).frame(width: 4).offset(x: 2, y: -2)
        }
    }
}
