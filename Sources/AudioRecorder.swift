@preconcurrency import AVFAudio
import AVFoundation
import os

/// 録音を始められない理由。**原因がユーザーに読める形で伝わる**ようにする
/// （以前は AVAudioEngine の生エラーがそのまま HUD に出るか、例外で落ちていた）。
enum AudioRecorderError: LocalizedError {
    /// 入力デバイスが 1 台も無い（未接続・システム設定で無効）。
    case noInputDevice
    /// 入力フォーマットを 16kHz / mono / Float32 に変換できない。
    case unsupportedInputFormat(sampleRate: Double, channels: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "マイクが見つかりません。入力デバイスを接続して、システム設定で選んでください。"
        case let .unsupportedInputFormat(sampleRate, channels):
            return "このマイクの形式（\(Int(sampleRate))Hz / \(channels)ch）は変換できません。"
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

    /// **録音を始めるたびに作り直す。** 1 つを使い回すと、既定入力を切り替えたあとも
    /// 前のデバイスに張り付いたまま無音を返すことがある（Issue #139）。
    private var engine = AVAudioEngine()

    /// 今の録音で、構成の変化からエンジンを作り直した回数。上限を超えたら締める。
    private var restartCount = 0
    /// 1 回の録音で作り直してよい回数。Bluetooth は開始時の 1 回で足りる。
    /// 何度も続くのは抜き差しを繰り返しているなど、録り続けても意味がない状況。
    private static let maxRestarts = 3

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

    /// 録音中にオーディオデバイスの構成が変わり、**録り続けられなかった**ときの通知先。
    /// **メインスレッドで呼ばれる**。
    ///
    /// AVAudioEngine は既定入力デバイスが変わるとエンジンを止め、tap へのバッファ供給が
    /// 途絶える。検知しないと「AirPods が繋がった以降の発話が丸ごと欠けた文字起こし」が
    /// 警告なしに挿入される（Issue #77）。
    ///
    /// ただし変化のたびに締めはしない。Bluetooth ヘッドセットはマイクを開いた瞬間に
    /// 通話用プロファイルへ切り替わるので、締めると録り始めと同時に止まる（Issue #139）。
    /// まずエンジンを作り直して録り続け、作り直せないときと回数の上限を超えたときだけ呼ぶ。
    var onConfigurationChange: (@Sendable () -> Void)?

    /// 構成の変化を受けてエンジンを作り直し、録り続けられたときの通知先。**メインスレッドで呼ばれる**。
    /// Bluetooth ヘッドセットの切り替えは出力側も作り直すので、その間に鳴らした開始音は
    /// 聞こえない。鳴らし直すために使う（Issue #139）。
    var onRestart: (@Sendable () -> Void)?

    /// ここまでに溜めた音声の長さ（秒）。
    var recordedSeconds: TimeInterval {
        Double(buffer.withLock { $0.samples.count }) / Double(Self.sampleRate)
    }

    /// レベル通知の最小間隔（20fps）。オーディオスレッドから読むので隔離しない（定数）。
    private nonisolated static let levelInterval: CFAbsoluteTime = 1.0 / 20.0

    private var configurationObserver: NSObjectProtocol?

    /// 録音のサンプルレート（WhisperKit の入力の決まり）。無音の判定もこの値で窓を切る。
    nonisolated static let sampleRate = 16_000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioRecorder.sampleRate),
        channels: 1,
        interleaved: false
    )!

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        // 前回の停止が済んでいなくても、ここで必ず素の状態へ戻してから始める。
        teardown()

        buffer.withLock { $0 = TapBuffer() }
        restartCount = 0
        try startEngine()
    }

    /// 新しいエンジンを作り、その時点の既定入力に tap を張って動かす。
    /// 蓄積済みのサンプルには触らない（作り直しの前後で音声をつなぐため）。
    private func startEngine() throws {
        engine = AVAudioEngine()
        observeConfigurationChange(of: engine)

        let input = engine.inputNode
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
        Log.audio.info("入力 \(Int(inputFormat.sampleRate), privacy: .public)Hz / \(inputFormat.channelCount, privacy: .public)ch で録音を始めました")
    }

    /// 通知は今のエンジンからだけ受ける（捨てたエンジンの通知で今の録音を触らない）。
    private func observeConfigurationChange(of engine: AVAudioEngine) {
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
                // 録音していないときの切り替えは扱わない（起動時やデバイス整理で普通に飛ぶ）。
                guard let self, self.isTapInstalled else { return }
                self.handleConfigurationChange()
            }
        }
    }

    /// 録音中に構成が変わった。エンジンは止まっているので、作り直して録り続ける。
    private func handleConfigurationChange() {
        teardown()
        restartCount += 1
        guard restartCount <= Self.maxRestarts else {
            Log.audio.notice("録音中にオーディオデバイスが繰り返し変わったため録り直しをやめます")
            onConfigurationChange?()
            return
        }
        do {
            try startEngine()
            Log.audio.notice("録音中にオーディオデバイスが変わったので、新しい入力で録り続けます")
            onRestart?()
        } catch {
            Log.audio.error("デバイスの切り替え後に録音を再開できませんでした: \(error.localizedDescription, privacy: .public)")
            onConfigurationChange?()
        }
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

        let level = AudioLevel.normalized(rms: AudioLevel.rms(chunk[...]))

        DispatchQueue.main.async { onLevel(level) }
    }
}
