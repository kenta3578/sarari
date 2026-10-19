@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import os

/// 録音を始められない理由。**原因がユーザーに読める形で伝わる**ようにする
/// （以前は AVAudioEngine の生エラーがそのまま HUD に出るか、例外で落ちていた）。
enum AudioRecorderError: LocalizedError {
    /// 入力デバイスが 1 台も無い（未接続・システム設定で無効）。
    case noInputDevice
    /// 入力フォーマットを 16kHz / mono / Float32 に変換できない。
    case unsupportedInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    /// エンジンを作り直しても、マイクの実際の形式とエンジンの形式が揃わない（切り替えの途中）。
    case deviceSwitching

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "マイクが見つかりません。入力デバイスを接続して、システム設定で選んでください。"
        case let .unsupportedInputFormat(sampleRate, channels):
            return "このマイクの形式（\(Int(sampleRate))Hz / \(channels)ch）は変換できません。"
        case .deviceSwitching:
            return "マイクの切り替え中です。少し待ってからもう一度押してください。"
        }
    }
}

/// マイク入力を 16kHz / mono / Float32 にリサンプリングして蓄積する。
/// WhisperKit はこの形式の [Float] を入力に取る。
///
/// **API は MainActor に隔離し、オーディオスレッドが触る状態は `TapBuffer` だけに閉じる**
/// （Issue #103）。tap のブロックは `self` を捕まえず、この箱と値だけを受け取る。
/// 以前は `samples` を `NSLock` で守る一方 `lastLevelSentAt` は素通しで、
/// メインスレッドとオーディオスレッドの両方から書いていた。
@MainActor
final class AudioRecorder {
    /// オーディオスレッドとメインスレッドが共有する唯一の状態。
    /// `OSAllocatedUnfairLock` は State が Sendable なら自身も Sendable なので、
    /// `@unchecked` を書かずに tap ブロックへ渡せる。
    private struct TapBuffer {
        var samples: [Float] = []
        var lastLevelSentAt: CFAbsoluteTime = 0
    }
    private let buffer = OSAllocatedUnfairLock(initialState: TapBuffer())

    /// **機器が変わったら作り直す**（Issue #91）。使い回すと `inputNode` が切り替え前の
    /// 機器の形式を返し続け、`installTap` が `Failed to create tap due to format mismatch` の
    /// Objective-C 例外を投げる。catch できないうえ、作り直すまで毎回同じ例外になるので
    /// 「一度こうなると再起動するまで録音できない」状態になっていた。
    private var engine = AVAudioEngine()

    /// 構成変更の通知を受けた。次の `start()` でエンジンを作り直す。
    private var engineIsStale = false

    /// このエンジンで録っている機器。通知を取りこぼしても、
    /// 機器が変わったことをここで気づける。
    private var engineDevice: InputDevice?

    /// 入力機器を指定すると、エンジンは動いたまま構成変更の通知が 1 回届く（約 90ms 後、実測）。
    /// これを機器の切り替えと取り違えないよう、指定した直後のしばらくは無視する（Issue #94）。
    private var ignoreConfigurationChangesUntil: Date = .distantPast
    private static let pinSettleTime: TimeInterval = 0.5

    /// tap を張っているか。`removeTap` の呼び忘れ・二重呼び出しの両方を防ぐ唯一の真実。
    ///
    /// **`installTap` は `engine.start()` が失敗しても張られたまま残る。** 外し忘れると
    /// 次の `start()` が同じバスへ二重に張り、AVAudioNode が
    /// `required condition is false: nullptr == Tap()` の Objective-C 例外を投げる。
    /// Swift では catch できないのでプロセスが落ちる（Issue #77）。
    private var isTapInstalled = false

    /// 録音レベル（0…1）の通知先。**メインスレッドで呼ばれる**。
    /// 波形表示のためだけに使うので、UI 側の負荷を抑えるよう間引いてから渡す。
    var onLevel: (@Sendable (Float) -> Void)?

    /// 録音中にオーディオデバイスの構成が変わったときの通知先。**メインスレッドで呼ばれる**。
    ///
    /// AVAudioEngine は既定入力デバイスが変わるとエンジンを止め、tap へのバッファ供給が
    /// 途絶える。検知しないと「AirPods が繋がった以降の発話が丸ごと欠けた文字起こし」が
    /// 警告なしに挿入される（Issue #77）。
    var onConfigurationChange: (@Sendable () -> Void)?

    /// レベル通知の最小間隔（20fps）。オーディオスレッドから読むので隔離しない（定数）。
    private nonisolated static let levelInterval: CFAbsoluteTime = 1.0 / 20.0

    private var configurationObserver: NSObjectProtocol?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        observeConfigurationChanges()
    }

    /// 今の `engine` の構成変更を購読する。エンジンを作り直すたびに張り替える。
    private func observeConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` を指定しているのでこのブロックはメインスレッドで届く。
            // ブロック自体は @Sendable なので、隔離済みであることを明示してから触る。
            MainActor.assumeIsolated {
                guard let self else { return }
                // 自分で機器を指定したときの通知。エンジンが止まっていなければ何も壊れていない。
                if Date() < self.ignoreConfigurationChangesUntil, self.engine.isRunning { return }
                // 録音していなくても、形式は古くなっている。次の録音で作り直す。
                self.engineIsStale = true
                // 録音していないときの切り替えは通知しない（起動時やデバイス整理で普通に飛ぶ）。
                guard self.isTapInstalled else { return }
                self.onConfigurationChange?()
            }
        }
    }

    /// エンジンを新しく作り直す。tap は外してある前提（`teardown()` の後に呼ぶ）。
    private func rebuildEngine(reason: String) {
        Log.audio.notice("オーディオエンジンを作り直します（\(reason, privacy: .public)）")
        engine = AVAudioEngine()
        engineIsStale = false
        engineDevice = nil
        observeConfigurationChanges()
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        // 前回の停止が済んでいなくても、ここで必ず素の状態へ戻してから始める。
        teardown()

        buffer.withLock { $0 = TapBuffer() }

        let device = InputDeviceSelector.current()
        if engineIsStale {
            rebuildEngine(reason: "構成変更の通知")
        } else if let engineDevice, engineDevice != device {
            rebuildEngine(reason: "入力機器が変わった")
        }
        if engineDevice == nil { bind(to: device) }

        var input = engine.inputNode
        // 機器側（inputFormat）とエンジン側（outputFormat）のレートがずれていたら、
        // そのまま installTap すると例外で落ちる。一度だけ作り直して確かめ直す。
        if Self.ratesDiffer(input) {
            rebuildEngine(reason: "機器とエンジンのサンプルレートが違う")
            bind(to: device)
            input = engine.inputNode
            guard !Self.ratesDiffer(input) else { throw AudioRecorderError.deviceSwitching }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        // 入力デバイスが無いと sampleRate 0 / channelCount 0 が返る。検証せずに
        // installTap へ渡すと AVAudioEngine が不正フォーマットで例外を投げる（Issue #77）。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.unsupportedInputFormat(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }

        // コンバータはプロパティに置かずクロージャへ渡す。プロパティにすると
        // メインスレッドの `start()`／`teardown()` とオーディオスレッドの `append` が
        // 同じ変数を触ることになる。
        // **ブロックは `self` を捕まえない。** 実時間スレッドなので、渡すのは値と
        // ロック付きの箱だけにして、UI もインスタンス状態も触らない。
        let sink = buffer
        let target = targetFormat
        let level = onLevel
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { pcm, _ in
            Self.append(pcm, using: converter, target: target, into: sink, onLevel: level)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // ここで外さないと tap が残り、次の start() で落ちる。
            teardown()
            throw error
        }
    }

    /// 作ったばかりのエンジンを `device` で録るようにする。指定が要るのは内蔵マイクへ
    /// 差し替えるときだけで、それ以外は既定のマイクに任せる（Issue #94）。
    private func bind(to device: InputDevice?) {
        engineDevice = device
        guard let device, device.isPinned, let unit = engine.inputNode.audioUnit else { return }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            // 指定できなくても既定のマイクで録れる（ヘッドホンは通話モードに入るが、録音は続く）。
            Log.audio.error("内蔵マイクを指定できませんでした: \(status)")
            return
        }
        ignoreConfigurationChangesUntil = Date().addingTimeInterval(Self.pinSettleTime)
        Log.audio.info("既定のマイクが Bluetooth のため、内蔵マイクで録音します")
    }

    /// 入力ノードの機器側とエンジン側でサンプルレートが違うか。どちらかが 0（機器なし）なら
    /// 違うとは見なさない（その場合は `noInputDevice` で扱う）。
    private static func ratesDiffer(_ input: AVAudioInputNode) -> Bool {
        let hardware = input.inputFormat(forBus: 0).sampleRate
        let client = input.outputFormat(forBus: 0).sampleRate
        guard hardware > 0, client > 0 else { return false }
        return hardware != client
    }

    /// 録音を止めて蓄積済みサンプルを返す。
    func stop() -> [Float] {
        teardown()
        return buffer.withLock { $0.samples }
    }

    /// tap とエンジンを素の状態へ戻す。**何度呼んでも安全**であることが要件。
    private func teardown() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private static func append(_ buffer: AVAudioPCMBuffer,
                               using converter: AVAudioConverter,
                               target targetFormat: AVAudioFormat,
                               into sink: OSAllocatedUnfairLock<TapBuffer>,
                               onLevel: (@Sendable (Float) -> Void)?) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        // 入力ブロックは `convert` の中から**同期的に**1 回だけ呼ばれるので、実際には
        // 並行領域を跨がない。`@Sendable` 注釈に合わせるためだけの退避（Issue #103）。
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, let channel = out.floatChannelData else {
            // 無言で捨てると「録音したのに（無音）」の原因が追えなくなる。
            if let error { Log.audio.error("音声の変換に失敗しました: \(error.localizedDescription)") }
            return
        }
        let frames = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: frames))

        // 蓄積とレベル通知の間引き判定を 1 回のロックで済ませる。
        let shouldEmit = sink.withLock { state -> Bool in
            state.samples.append(contentsOf: chunk)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - state.lastLevelSentAt >= levelInterval else { return false }
            state.lastLevelSentAt = now
            return true
        }
        guard shouldEmit, let onLevel else { return }
        emitLevel(chunk, to: onLevel)
    }

    /// 直近チャンクの RMS を 0…1 に正規化して通知する。間引きの判定は呼ぶ側で済ませてある。
    private static func emitLevel(_ chunk: [Float], to onLevel: @escaping @Sendable (Float) -> Void) {
        guard !chunk.isEmpty else { return }

        var sumOfSquares: Float = 0
        for sample in chunk { sumOfSquares += sample * sample }
        let level = normalizedLevel(rms: (sumOfSquares / Float(chunk.count)).squareRoot())

        DispatchQueue.main.async { onLevel(level) }
    }

    /// RMS を -50dB…0dB で 0…1 に写す。
    /// 線形のままだと通常の発話がほぼ潰れて波形が動いて見えない。
    ///
    /// **通常の発話は、写した値で 0.1〜0.3（RMS でおよそ 0.006〜0.016）**。履歴の録音 619 件を
    /// 実測した値（声の窓の p25 0.11 / p50 0.16 / p95 0.28、Issue #187）。以前ここに書いていた
    /// «RMS 0.02〜0.1» は想定で、表示の基準をそこから決めると声が小さく出る。
    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let floorDB: Float = -50
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }
}
