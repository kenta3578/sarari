import SwiftUI
import AppKit

/// アプリの状態。**メニューバーアイコン・メニュー内テキストの両方をこの enum から導出する**
/// （文言とアイコンを別々に持たせて二重管理にしない）。
enum AppStatus: Equatable {
    /// 起動〜権限確認〜モデル読み込み。`step` は現在の工程の文言。
    case loadingModel(step: String)
    /// 待機中（ホットキー待ち）。
    case idle
    /// 録音中。
    case recording
    /// 文字起こし中。
    case processing
    /// 完了。`message` は「挿入しました ✓」など。一定時間後に `.idle` へ自動復帰する。
    case done(message: String)
    /// 挿入は済んだが、整形が数値・URL 等を書き換えた疑いがある（Issue #14）。
    /// **挿入をブロックしない**方針なので失敗ではない。`.done` とは形も色も変えて、
    /// 気づかないまま流れないようにする。
    case warned(message: String)
    /// 失敗。原因が読めるよう、自動復帰させずに残す。
    /// `hint` は「設定で直せる失敗」のときだけ付き、HUD がそこへ飛ぶボタンを出す。
    case failed(reason: String, hint: FailureHint? = nil)

    /// 右⌥で録音を始めてよい状態か。モデル読込中・録音中は始めない。
    /// 失敗表示中は始めてよい（挿入に失敗しただけで、次の発話は受け付ける）。
    /// **処理中も始めてよい**。停止直後の言い残しを押した瞬間から録り始めるため（Issue #97）。
    /// 先行パイプラインが後から状態・HUD を潰さないことは `AppController` が世代番号で守る。
    var canStartRecording: Bool {
        switch self {
        case .idle, .done, .warned, .failed, .processing: return true
        case .loadingModel, .recording: return false
        }
    }

    /// 表示文の前に「どの発話の話か」を付ける（例: 以前の発話）。追い越された発話の結果を
    /// 後から出すとき、いま喋った内容の失敗と誤読させない（Issue #100）。
    func prefixed(_ label: String) -> AppStatus {
        switch self {
        case .done(let message):           return .done(message: "\(label): \(message)")
        case .warned(let message):         return .warned(message: "\(label): \(message)")
        case .failed(let reason, let hint): return .failed(reason: "\(label): \(reason)", hint: hint)
        case .idle, .loadingModel, .recording, .processing: return self
        }
    }

    /// 失敗表示か。原因を残したいので、他の表示で上書きしてよいかの判断に使う。
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// **表示状態から見て**音声認識エンジンを載せ替えてよいか。
    ///
    /// 録音中に載せ替えると `.loadingModel` に上書きされ、マイクが開いたまま
    /// `isRecording` が false になって**右⌥で録音を止める手段が無くなる**（Issue #77）。
    /// 処理中は、その発話の文字起こしが載せ替え中のエンジンに当たるので見送る。
    /// 起動時は `.loadingModel` から読み込むので、そこは通す。
    ///
    /// ただし Issue #97 以降、追い越されたパイプラインは状態を通らずに裏で動くので、
    /// これだけでは「裏で文字起こしが動いていない」ことは保証できない。
    /// 実際の判定は `AppState.canSwitchEngine`（進行中パイプライン数も見る）を使う。
    var canSwitchEngine: Bool {
        switch self {
        case .recording, .processing: return false
        case .loadingModel, .idle, .done, .warned, .failed: return true
        }
    }

    /// 完了表示を待機へ戻すまでの時間。
    static let doneDisplayDuration: Duration = .seconds(1.5)
    /// 警告表示を待機へ戻すまでの時間。読んで判断する必要があるので完了より長く出す。
    static let warnedDisplayDuration: Duration = .seconds(5)

    /// SF Symbols 名。色だけに頼らず**形状でも**状態が区別できるようにする。
    var symbolName: String {
        switch self {
        case .loadingModel: return "hourglass"
        case .idle:         return "mic"
        case .recording:    return "mic.fill"
        case .processing:   return "waveform"
        case .done:         return "checkmark.circle.fill"
        case .warned:       return "exclamationmark.circle.fill"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }

    /// アイコンの色。`nil` = テンプレート描画（メニューバーの明暗にシステムが追従させる）。
    var tintColor: NSColor? {
        switch self {
        case .loadingModel: return .systemYellow
        case .idle:         return nil
        case .recording:    return StatusPalette.recording
        case .processing:   return StatusPalette.processing
        case .done:         return .systemGreen
        case .warned:       return .systemYellow
        case .failed:       return .systemOrange
        }
    }

    /// VoiceOver 用の説明（色・形状が読めない環境向けの3つ目の手がかり）。
    var accessibilityLabel: String {
        switch self {
        case .loadingModel: return "sarari: モデル読み込み中"
        case .idle:         return "sarari: 待機中"
        case .recording:    return "sarari: 録音中"
        case .processing:   return "sarari: 文字起こし中"
        case .done:         return "sarari: 完了"
        case .warned:       return "sarari: 完了（注意あり）"
        case .failed:       return "sarari: エラー"
        }
    }

    /// メニュー内に出す文言。
    @MainActor
    var menuText: String {
        switch self {
        case .loadingModel(let step):  return step
        case .idle:                    return "待機中（\(Self.hotKeyName)で録音開始）"
        case .recording:               return "録音中…（\(Self.hotKeyName)で停止）"
        case .processing:              return "文字起こし中…"
        case .done(let message):       return "\(message) 待機中（\(Self.hotKeyName)で録音開始）"
        case .warned(let message):     return message
        case .failed(let reason, _):   return reason
        }
    }

    /// メニューバーに表示するアイコン。
    ///
    /// 待機中・録音中は自前のグリフ（吹き出し＋波形。Issue #47）。SF Symbols の `mic` は
    /// macOS 音声入力や他のマイク系アプリと見分けがつかない。
    /// それ以外は一過性の状態なので、形と色で区別できる SF Symbols を使う。
    var menuBarImage: NSImage {
        switch self {
        case .idle:      return MenuBarGlyph.idle(label: accessibilityLabel)
        case .recording: return MenuBarGlyph.recording(label: accessibilityLabel)
        default:         break
        }
        // symbolName はリテラル固定の SF Symbols 名なので、ここで nil にはならない。
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)!
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let tintColor {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        }
        let image = base.withSymbolConfiguration(config)!
        image.isTemplate = tintColor == nil
        return image
    }

    @MainActor
    private static var hotKeyName: String {
        SettingsStore.shared.hotKeyDisplayName
    }
}

/// 録音中・文字起こし中の色（Issue #48）。
///
/// 以前はシステムの赤・青だった。画面の縁を一周光らせると赤は警報に見えるので、
/// 録音中をすみれ、文字起こし中を水色に替えた。メニューバー・HUD・縁の光はここから引く。
/// 完了の緑・警告の黄・失敗の橙はシステム色のまま（意味が定着している）。
enum StatusPalette {
    static let recording = dynamic(light: 0x7C5CF0, dark: 0x9D85FF)
    static let processing = dynamic(light: 0x1E9BE0, dark: 0x45B8F5)

    /// 画面の縁の光。壁紙の上に重ねるので明暗に追従させず、淡い側に固定する。
    static let glowRecording = rgb(0x9D85FF)
    static let glowProcessing = rgb(0x45B8F5)
    /// 完了は白く一瞬光って消える（緑を画面一周に出すと «成功» が強すぎる）。
    static let glowDone = rgb(0xF2F4FF)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// メニューバー用の独自グリフ。吹き出しの中に3本の波形バー（＝声が文になる）。
///
/// Core Graphics で描く（画像アセットを持たない。Retina でも滲まない）。
/// `filled == false` はテンプレート描画で、メニューバーの明暗にシステムが追従させる。
enum MenuBarGlyph {
    /// メニューバーの標準的なアイコン高さに合わせる（SF Symbols 15pt 相当）。
    private static let size = CGSize(width: 20, height: 16)

    /// 待機中: 線画のテンプレート画像（メニューバーの明暗にシステムが追従させる）。
    static func idle(label: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, filled: false, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// 録音中: すみれ色の塗りでバーを抜いた画像。
    static func recording(label: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, filled: true, color: StatusPalette.recording)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }

    private static func draw(in rect: CGRect, filled: Bool, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 吹き出し本体: 丸角の長方形に、左下へ短いしっぽを付けた**ひと続きの**パス
        // （別パスで重ねると、線画では底辺がしっぽを横切り、塗りでは重なりが抜ける）。
        let bodyHeight: CGFloat = 11
        let tailHeight: CGFloat = 3.5
        let inset: CGFloat = 0.75
        let r: CGFloat = 3.5
        let body = CGRect(x: inset, y: tailHeight, width: rect.width - inset * 2, height: bodyHeight)
        let bubble = CGMutablePath()
        bubble.move(to: CGPoint(x: body.minX + r, y: body.minY))
        bubble.addLine(to: CGPoint(x: body.minX + 4.5, y: body.minY))
        bubble.addLine(to: CGPoint(x: body.minX + 3.5, y: body.minY - tailHeight))
        bubble.addLine(to: CGPoint(x: body.minX + 8.5, y: body.minY))
        bubble.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        bubble.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                      tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        bubble.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        bubble.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                      tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        bubble.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        bubble.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                      tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        bubble.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        bubble.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                      tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        bubble.closeSubpath()

        // 波形バー: 中央に短・長・中の3本。
        let barWidth: CGFloat = 1.8
        let barGap: CGFloat = 2.2
        let heights: [CGFloat] = [3.5, 6.5, 5]
        let totalWidth = barWidth * 3 + barGap * 2
        let startX = body.midX - totalWidth / 2
        let bars = CGMutablePath()
        for (i, h) in heights.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let bar = CGRect(x: x, y: body.midY - h / 2, width: barWidth, height: h)
            bars.addRoundedRect(in: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        }

        ctx.setLineJoin(.round)
        if filled {
            // 塗りの吹き出しからバーを抜く（背景色が透けて見える）。
            ctx.saveGState()
            ctx.addPath(bubble)
            ctx.addPath(bars)
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        } else {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(bubble)
            ctx.strokePath()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(bars)
            ctx.fillPath()
        }
    }
}

/// UI 表示用の状態。実処理は AppController が担う。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var status: AppStatus = .loadingModel(step: "起動中…")

    /// `.recording` の別名。状態は status に一本化しているので保存しない。
    var isRecording: Bool { status == .recording }

    /// 停止後のパイプライン（文字起こし→整形→挿入）が何本動いているか。
    /// 追い越されたパイプラインは `status` に現れないので、別に数える（Issue #97 / #101）。
    @Published private(set) var inFlightPipelines = 0

    func pipelineStarted() { inFlightPipelines += 1 }
    func pipelineFinished() { inFlightPipelines = max(0, inFlightPipelines - 1) }

    /// 音声認識エンジンを載せ替えてよいか。表示状態に加えて、裏で動くパイプラインが
    /// 無いことも見る。載せ替え中に `unload()` されたエンジンへ文字起こしが当たらないように。
    var canSwitchEngine: Bool { status.canSwitchEngine && inFlightPipelines == 0 }

    private var doneResetTask: Task<Void, Never>?

    private init() {}

    /// 状態を更新する。`.done` / `.warned` は一定時間後に `.idle` へ自動復帰する。
    func update(_ newStatus: AppStatus) {
        doneResetTask?.cancel()
        doneResetTask = nil
        status = newStatus

        let duration: Duration
        switch newStatus {
        case .done:   duration = AppStatus.doneDisplayDuration
        case .warned: duration = AppStatus.warnedDisplayDuration
        default:      return
        }
        doneResetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }
}
