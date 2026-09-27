import AppKit
import Combine
import QuartzCore

/// 画面の縁の光で何を見せるか（Issue #48）。`AppStatus` から決める。
enum EdgeGlowPhase: Equatable {
    case off
    /// ゆっくり明滅し、声の大きさで濃くなる。
    case recording
    /// 速めに明滅する。声には反応しない。
    case processing
    /// 白く一瞬光って消える。
    case done

    /// 光らせるのは録音〜挿入の流れだけ。警告・失敗は HUD とメニューで伝える
    /// （画面一周で出すと、原因を読む前に «何か起きた» だけが強く伝わる）。
    static func phase(for status: AppStatus) -> EdgeGlowPhase {
        switch status {
        case .recording:  return .recording
        case .processing: return .processing
        case .done:       return .done
        case .loadingModel, .idle, .warned, .failed: return .off
        }
    }

    /// 明滅の半周期（秒）。明るい → 暗い で 1 回。
    var breathHalfPeriod: CFTimeInterval? {
        switch self {
        case .recording:  return 1.3
        case .processing: return 0.55
        case .off, .done: return nil
        }
    }

    var color: NSColor? {
        switch self {
        case .recording:  return StatusPalette.glowRecording
        case .processing: return StatusPalette.glowProcessing
        case .done:       return StatusPalette.glowDone
        case .off:        return nil
        }
    }
}

/// 録音中、マウスのある画面の四辺を内側からぼかした光で縁取る（Issue #48）。
///
/// HUD は画面の一点にしか出ないので、作業しながら口述していると視線が届かず、
/// 録音中かどうか分からなくなることがあった。周辺視野は色より動きに反応するので、ゆっくり明滅させる。
///
/// - クリックは素通し（`ignoresMouseEvents`）。borderless の NSWindow はキーにもメインにもならないので、
///   挿入先のフォーカスは奪わない。
/// - 光の形（縁から内へ薄れていく帯）は画面の大きさごとに一度だけビットマップへ焼き、色付きの層のマスクにする。
///   色の切り替えは層の背景色を変えるだけ、明滅は不透明度のアニメーションなので WindowServer 側で回り、CPU を使わない。
@MainActor
final class EdgeGlowController {
    /// 常に出ている細い光の半径（pt）。16 / 44 では実機で «もう少し幅が広くてもいい» と言われ、約 1.5 倍にした（Issue #50）。
    private static let baseRadius: CGFloat = 24
    /// 声に合わせて濃くなる太い光の半径（pt）。
    private static let voiceRadius: CGFloat = 64
    /// 消えるとき・完了の光の時間。
    private static let fadeDuration: CFTimeInterval = 0.35
    private static let doneFlashDuration: CFTimeInterval = 1.2

    private var window: NSWindow?
    /// 明滅はこの層の不透明度で回す。下の 2 層を束ねる。
    private let breathLayer = CALayer()
    private let baseLayer = CALayer()
    private let voiceLayer = CALayer()
    private var phase: EdgeGlowPhase = .off
    /// マスクを焼いた画面の大きさ。変わったときだけ焼き直す。
    private var maskedSize: CGSize?
    private var cancellables: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?

    init() {
        // `@Published` は値が入る**前**に流れるので、流れてきた値そのものを使う。
        AppState.shared.$status
            .sink { [weak self] status in
                self?.apply(EdgeGlowPhase.phase(for: status),
                            enabled: SettingsStore.shared.edgeGlowEnabled)
            }
            .store(in: &cancellables)
        SettingsStore.shared.$edgeGlowEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.apply(EdgeGlowPhase.phase(for: AppState.shared.status), enabled: enabled)
            }
            .store(in: &cancellables)
    }

    /// 録音レベル（0…1）で太い光の濃さを決める。HUD の棒と同じ «声とみなす» 範囲で写す。
    func push(level: Float) {
        guard phase == .recording, !Self.reduceMotion else { return }
        let ratio = Float(LevelBarsView.colorRatio(level: level))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        voiceLayer.opacity = ratio
        CATransaction.commit()
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func apply(_ next: EdgeGlowPhase, enabled: Bool) {
        let next = enabled ? next : .off
        guard next != phase else { return }
        let previous = phase
        phase = next
        hideTask?.cancel()
        hideTask = nil

        guard let color = next.color else {
            fadeOut()
            return
        }
        // 画面は録音を始めたときに決め、文字起こし〜完了はそのまま（途中でマウスを動かしても跳ばない）。
        let window = self.window ?? makeWindow()
        self.window = window
        if previous == .off || !window.isVisible { place(window) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.backgroundColor = color.cgColor
        voiceLayer.backgroundColor = color.cgColor
        voiceLayer.opacity = next == .recording && Self.reduceMotion ? 0.5 : 0
        CATransaction.commit()

        breathLayer.removeAllAnimations()
        breathLayer.opacity = 1
        if next == .done {
            flashThenHide()
        } else if let half = next.breathHalfPeriod, !Self.reduceMotion {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 1.0
            breath.toValue = 0.55
            breath.duration = half
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathLayer.add(breath, forKey: "breath")
        }
        window.orderFrontRegardless()
    }

    private func flashThenHide() {
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0.0, 1.0, 0.0]
        flash.keyTimes = [0, 0.15, 1]
        flash.duration = Self.doneFlashDuration
        breathLayer.opacity = 0
        breathLayer.add(flash, forKey: "flash")
        scheduleOrderOut(after: Self.doneFlashDuration)
    }

    private func fadeOut() {
        guard let window, window.isVisible else { return }
        let current = breathLayer.presentation()?.opacity ?? breathLayer.opacity
        breathLayer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        breathLayer.opacity = 0
        breathLayer.add(fade, forKey: "fade")
        scheduleOrderOut(after: Self.fadeDuration)
    }

    private func scheduleOrderOut(after seconds: CFTimeInterval) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.window?.orderOut(nil)
        }
    }

    // MARK: ウインドウ

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // メニューバーより上に置き、上辺もメニューバーの上で光らせる。
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 画面共有・収録に映さない（HUD と同じ。Issue #84）。
        window.sharingType = .none
        window.animationBehavior = .none

        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(breathLayer)
        breathLayer.addSublayer(baseLayer)
        breathLayer.addSublayer(voiceLayer)
        window.contentView = view
        return window
    }

    /// マウスのある画面いっぱいに広げる（HUD と同じ選び方）。
    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        window.setFrame(screen.frame, display: false)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        breathLayer.frame = bounds
        baseLayer.frame = bounds
        voiceLayer.frame = bounds
        if maskedSize != bounds.size {
            maskedSize = bounds.size
            baseLayer.mask = Self.maskLayer(size: bounds.size, radius: Self.baseRadius)
            voiceLayer.mask = Self.maskLayer(size: bounds.size, radius: Self.voiceRadius)
        }
        CATransaction.commit()
    }

    private static func maskLayer(size: CGSize, radius: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contents = glowMask(size: size, radius: radius)
        layer.contentsGravity = .resize
        return layer
    }

    /// 縁から内へ薄れていく帯のアルファ画像。ぼけた光なので、画面の 1/4 の解像度で焼いて引き伸ばす
    /// （フル解像度だと 5K で 1 枚 50MB 近くになる）。
    static func glowMask(size: CGSize, radius: CGFloat, scale: CGFloat = 0.25) -> CGImage? {
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let blur = radius * scale
        // 画面の外側を囲む輪を塗り、その影だけを内側へ落とす。輪そのものは画面の外で見えない。
        // CGContext の影のぼかしは CTM の影響を受けないので、ピクセル単位で渡す。
        context.setShadow(offset: .zero, blur: blur * 2, color: CGColor(gray: 0, alpha: 1))
        context.addPath(ringPath(around: rect, spread: blur * 4))
        context.fillPath(using: .evenOdd)
        return context.makeImage()
    }

    /// 画面の外側を囲む輪（外周と画面の矩形。even-odd で塗ると画面の部分が抜ける）。
    private static func ringPath(around rect: CGRect, spread: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect.insetBy(dx: -spread, dy: -spread))
        path.addRect(rect)
        return path
    }
}
