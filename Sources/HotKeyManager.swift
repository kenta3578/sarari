@preconcurrency import CoreFoundation
import AppKit
import Combine
import os

/// トグル録音ホットキー。
/// SettingsStore.hotKeyModifiers（＋hotKeyExtraKeyCode）が揃うたびに onToggle を呼ぶ。
/// キーリリースは無視する。
///
/// 2 つの方式を設定で切り替える（Issue #112）:
/// - **修飾キーだけ**（`hotKeyExtraKeyCode == nil`）: `flagsChanged` の NSEvent 監視だけを張る。
///   複数なら全部が揃った瞬間にトグル（Issue #115）
/// - **修飾キー + 通常キー**（例: 右⌥ + S、左⇧ + 左⌘ + 0）: `CGEventTap` で keyDown/keyUp を見て、
///   一致した押下は**飲み込む**（前面アプリに ß 等を打ち込ませない）。keyDown を監視するのは
///   キーロガー相当なので、この方式が選ばれているときだけ張る
///
/// 設定画面でホットキーを録っている間は止める（その押下は設定用で、録音しない）。
@MainActor
final class HotKeyManager {
    var onToggle: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    private let tapState = HotKeyTapState()
    private var tapThread: Thread?

    private var observers: Set<AnyCancellable> = []

    /// 監視を張れているか。権限が付いたあとに張り直したかの判断に使う（Issue #78）。
    private(set) var isRunning = false
    /// 一度でも start() されたか。設定変更・録り終わり・スリープ復帰で張り直す判断に使う。
    /// `isRunning` で判断すると、権限が無くてタップを作れなかった後に二度と張り直せない。
    private var hasStarted = false

    init() {
        // 方式・キーが変わったら張り直す（再起動なしで反映。Issue #112）。
        SettingsStore.shared.$hotKeyExtraKeyCode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartIfStarted() }
            .store(in: &observers)
        SettingsStore.shared.$hotKeyModifiers
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartIfStarted() }
            .store(in: &observers)
        // 録っている間は止める。録り終わったら張り直す。
        HotKeyCapture.shared.$isCapturing
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] capturing in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if capturing { self.stop() } else if self.hasStarted { self.start() }
                }
            }
            .store(in: &observers)
        // スリープ復帰後はタップが黙って死んでいることがあるので作り直す。
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.hasStarted, SettingsStore.shared.hotKeyExtraKeyCode != nil else { return }
                    self.start()
                }
            }
            .store(in: &observers)
    }

    /// 監視を張る。**何度呼んでも二重に張らない**。
    ///
    /// グローバル監視はアクセシビリティで trusted でないと一度も発火しないので、
    /// 権限が後から付いたときに呼び直せる必要がある（Issue #78）。
    func start() {
        stop()
        hasStarted = true
        if SettingsStore.shared.hotKeyExtraKeyCode == nil {
            startModifierMonitors()
            isRunning = true
        } else {
            // タップは権限が無いと作れない。false のままにして許可後の再登録に任せる。
            isRunning = startTap()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
        stopTap()
        isRunning = false
    }

    /// 設定変更は didSet の途中（willSet で発火する）なので、値が確定してから張り直す。
    private func restartIfStarted() {
        Task { @MainActor [weak self] in
            guard let self, self.hasStarted, !HotKeyCapture.shared.isCapturing else { return }
            self.start()
        }
    }

    // MARK: - 修飾キーだけ

    private func startModifierMonitors() {
        // 自アプリがアクティブなとき（設定・履歴ウィンドウを開いているとき）は
        // global monitor にイベントが配送されない。local も張らないと
        // 「ウィンドウを開いていると右⌥ が効かない」ことになる（Issue #78）。
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            self?.handle(flags: event.modifierFlags, sideAgnostic: Self.isSynthetic(event))
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            let flags = event.modifierFlags
            let sideAgnostic = Self.isSynthetic(event)
            Task { @MainActor [weak self] in
                self?.handle(flags: flags, sideAgnostic: sideAgnostic)
            }
        }) {
            monitors.append(global)
        }
    }

    /// 他プロセスが合成したイベント（キーマッパー）なら左右を問わない（Issue #120）。
    private nonisolated static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent.map(SettingsStore.isSynthetic) ?? false
    }

    /// どの修飾キーの変化でも「集合が全部押されているか」で見る。
    private func handle(flags: NSEvent.ModifierFlags, sideAgnostic: Bool) {
        let modifiers = SettingsStore.shared.hotKeyModifiers
        let pressed = SettingsStore.allKeysDown(modifiers, flags: flags, sideAgnostic: sideAgnostic)

        if pressed && !isDown {
            // どれかを離すまで再発火させないので、トグルしない場合でも押下は記録する。
            isDown = true
            // 他の修飾キーと一緒なら、ショートカット操作なので録音しない（Issue #78）。
            guard SettingsStore.isExactlyPressed(modifiers, flags: flags, sideAgnostic: sideAgnostic) else { return }
            onToggle?()
        } else if !pressed {
            isDown = false
        }
    }

    // MARK: - 修飾キー + 通常キー（CGEventTap）

    /// タップは**専用スレッド**の run loop に載せる。main に載せると、録音開始時の AX 同期 IPC
    /// （最大 0.4〜0.8 秒。Issue #57）のあいだ WindowServer がこのタップの返事を待ち、
    /// **全アプリのキー入力が止まる**。コールバックは判定だけして main へ投げる。
    private func startTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tapState.configure(
            modifiers: SettingsStore.shared.hotKeyModifiers,
            extraKeyCode: SettingsStore.shared.hotKeyExtraKeyCode,
            onMatch: { [weak self] in
                Task { @MainActor [weak self] in self?.onToggle?() }
            }
        )
        // tapState は self が保持し、stopTap() でタップを invalidate してから捨てるので unretained でよい。
        let userInfo = Unmanaged.passUnretained(tapState).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotKeyTapCallback,
            userInfo: userInfo
        ) else {
            Log.hotkey.error("イベントタップを作れませんでした（アクセシビリティ権限が無い可能性）")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapState.attach(tap: tap)

        let state = tapState
        let thread = Thread {
            let runLoop: CFRunLoop = CFRunLoopGetCurrent()
            // スレッドが動く前に stop されていたら何もしない。
            guard state.registerRunLoop(runLoop) else { return }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "sarari.hotkey-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        return true
    }

    private func stopTap() {
        let (tap, runLoop) = tapState.detach()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // invalidate で run loop source も外れる。
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tapThread = nil
    }
}

/// タップのコールバックが読む状態。タップ専用スレッドと main の両方から触るのでロックで守る。
///
/// `@unchecked Sendable` の理由: 可変状態はすべて `lock` 経由でしか触らない。
private final class HotKeyTapState: @unchecked Sendable {
    private struct Inner {
        var modifiers: [UInt16] = []
        var extraKeyCode: UInt16?
        var onMatch: (@Sendable () -> Void)?
        var tap: CFMachPort?
        var runLoop: CFRunLoop?
        var stopped = true
        /// 飲み込んだ keyDown に対応する keyUp も飲み込むために覚えておく。
        var swallowedKeyCode: UInt16?
    }

    private let lock = OSAllocatedUnfairLock(initialState: Inner())

    func configure(modifiers: [UInt16], extraKeyCode: UInt16?, onMatch: @escaping @Sendable () -> Void) {
        lock.withLock {
            $0.modifiers = modifiers
            $0.extraKeyCode = extraKeyCode
            $0.onMatch = onMatch
            $0.swallowedKeyCode = nil
        }
    }

    func attach(tap: CFMachPort) {
        lock.withLock {
            $0.tap = tap
            $0.stopped = false
        }
    }

    /// タップ用スレッドの run loop を登録する。すでに stop されていれば false。
    func registerRunLoop(_ runLoop: CFRunLoop) -> Bool {
        lock.withLock {
            guard !$0.stopped else { return false }
            $0.runLoop = runLoop
            return true
        }
    }

    /// タップと run loop を外して返す。以後コールバックは何もしない。
    func detach() -> (CFMachPort?, CFRunLoop?) {
        lock.withLock { inner in
            let detached = (inner.tap, inner.runLoop)
            inner.stopped = true
            inner.tap = nil
            inner.runLoop = nil
            inner.swallowedKeyCode = nil
            return detached
        }
    }

    /// コールバック本体。**判定して main へ投げるだけ**（遅いと OS にタップを切られる）。
    /// 戻り値は「このイベントを飲み込むか」。
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // OS が切ったら張り直す。放置すると黙って効かなくなる。
            let tap = lock.withLock { $0.stopped ? nil : $0.tap }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // NSEvent.ModifierFlags は CGEventFlags と同じビット配置（左右のデバイスマスク込み）。
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let sideAgnostic = SettingsStore.isSynthetic(event)
            let onMatch: (@Sendable () -> Void)? = lock.withLock { inner in
                guard !inner.stopped, keyCode == inner.extraKeyCode,
                      SettingsStore.isExactlyPressed(inner.modifiers, flags: flags, ignoringFunction: true, sideAgnostic: sideAgnostic)
                else { return nil }
                inner.swallowedKeyCode = keyCode
                // 押しっぱなしのオートリピートでは 1 回だけ（飲み込みは続ける）。
                // 空クロージャのリテラルは @Sendable と推論されないので明示する。
                let noop: @Sendable () -> Void = {}
                return isRepeat ? noop : inner.onMatch
            }
            guard let onMatch else { return false }
            onMatch()
            return true

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return lock.withLock { inner in
                guard inner.swallowedKeyCode == keyCode else { return false }
                inner.swallowedKeyCode = nil
                return true
            }

        default:
            return false
        }
    }
}

/// `CGEventTap` の C コールバック。クロージャは捕捉できないので userInfo で状態を受け取る。
private func hotKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<HotKeyTapState>.fromOpaque(userInfo).takeUnretainedValue()
    return state.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// 設定画面の「ホットキーを録る」状態。
///
/// **View の `@State` に置かない**。`SettingsWindowController` はウィンドウを使い回す
/// （`isReleasedWhenClosed = false`）ので、閉じても SwiftUI の `.onDisappear` は発火せず、
/// 監視が張られたまま残る。次に ⌘C を押しただけで録音キーがそれに書き換わり、
/// 画面は閉じているので何も表示されない（Issue #78）。
/// ここに出しておけば `windowWillClose` / `windowDidResignKey` からも確実に止められる。
@MainActor
final class HotKeyCapture: ObservableObject {
    static let shared = HotKeyCapture()

    @Published private(set) var isCapturing = false
    /// 成立しない組み合わせを押したときの理由。次に録り始めるか確定したら消える。
    @Published private(set) var problem: String?
    private var monitors: [Any] = []
    /// 押されたまま離されていない修飾キー（押した順）。これらを押したまま通常キーを押せば
    /// 組み合わせ、押さずにどれかを離せば修飾キーだけで確定する（Issue #112 / #115）。
    /// 設定画面に「いま何が押されていると認識しているか」を出すために公開する（Issue #118）。
    @Published private(set) var pendingModifiers: [UInt16] = []

    /// 録っている最中の表示。押すたびに増え、確定すると `SettingsStore.hotKeyDisplayName` に変わる。
    var capturingText: String {
        guard !pendingModifiers.isEmpty else { return "修飾キーを押してください…" }
        let names = pendingModifiers.map(SettingsStore.keyName(for:)).joined(separator: " + ")
        return "\(names) + …（通常キーを押すか、離して確定）"
    }

    private init() {}

    /// 修飾キーの押下（と、押したままの通常キー）を拾ってホットキーにする。
    ///
    /// 設定ウィンドウは `NSApp.activate` で前面＝アクティブなので、自アプリに配送される押下は
    /// local monitor でないと拾えない（Issue #68）。**local だけ張る**。global も張ると、
    /// 別アプリに切り替えた先で押した修飾キーで設定が書き換わる（Issue #112）。
    /// ウィンドウが key でなくなったら `SettingsWindowController` が cancel() する。
    func start() {
        cancel()
        isCapturing = true
        problem = nil
        pendingModifiers = []

        // 修飾キーの押下・解放。戻り値は「飲み込むか」。
        let acceptFlags: @MainActor (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            let code = event.keyCode
            let pressed = SettingsStore.isKeyDown(keyCode: code, flags: event.modifierFlags)
            if pressed, !self.pendingModifiers.contains(code) {
                self.pendingModifiers.append(code)
                return true
            }
            // 溜めたキーを**全部**離したら修飾キーだけで確定する。1 つ離しただけで確定すると、
            // 3 キーの組み合わせを押す途中で指がずれたときに通常キーが落ちる。
            if !pressed, self.pendingModifiers.contains(code),
               !SettingsStore.anyKeyDown(self.pendingModifiers, flags: event.modifierFlags) {
                self.commit(modifiers: self.pendingModifiers, extraKeyCode: nil)
                return true
            }
            return false
        }
        // 修飾キーを押したままの通常キー。Esc は録りをやめる。
        // 実際の判定（HotKeyTapState.handle）と同じ「溜めた修飾キーだけが押されている」条件で受ける。
        // 溜めていない修飾キーが混ざったものを黙って落とすと、表示と違うホットキーが出来上がる。
        let acceptKey: @MainActor (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 {
                Task { @MainActor in self.cancel() }
                return true
            }
            let modifiers = self.pendingModifiers
            guard SettingsStore.isExactlyPressed(modifiers, flags: event.modifierFlags, ignoringFunction: true)
            else { return false }
            self.commit(modifiers: modifiers, extraKeyCode: event.keyCode)
            return true
        }

        // local monitor は main thread で同期に呼ばれる。
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            // 採用した押下は飲み込む（設定画面のフォーカスを動かさない）。
            MainActor.assumeIsolated { acceptFlags(event) } ? nil : event
        }) {
            monitors.append(local)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated { acceptKey(event) } ? nil : event
        }) {
            monitors.append(local)
        }
    }

    /// 監視のコールバック中に監視を外さないよう、確定は次のターンで行う。
    /// 待ちだけは即座に消す（組み合わせ確定の直後に来る修飾キーの解放で単独に上書きしない）。
    /// 成立しない組み合わせは保存せず、理由を出して録り続ける（押し直せる）。
    private func commit(modifiers: [UInt16], extraKeyCode: UInt16?) {
        pendingModifiers = []
        let modifiers = SettingsStore.canonicalModifiers(modifiers)
        if let problem = SettingsStore.hotKeyProblem(modifiers: modifiers, extraKeyCode: extraKeyCode) {
            self.problem = problem
            return
        }
        problem = nil
        Task { @MainActor in
            SettingsStore.shared.hotKeyModifiers = modifiers
            SettingsStore.shared.hotKeyExtraKeyCode = extraKeyCode
            self.cancel()
        }
    }

    func cancel() {
        isCapturing = false
        pendingModifiers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
