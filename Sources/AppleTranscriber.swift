import AVFoundation
import Foundation
import Speech

enum AppleTranscriberError: LocalizedError {
    /// `load()` を通っていない（または `unload()` 済み）。
    case notReady
    /// SpeechTranscriber が日本語ロケールを持っていない。
    case localeUnsupported
    /// アナライザが受け付ける音声フォーマットを取得できなかった。
    case noCompatibleAudioFormat
    /// 録音サンプルをアナライザの要求フォーマットへ変換できなかった。
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Apple 音声認識が準備できていません"
        case .localeUnsupported:
            return "Apple 音声認識が日本語（ja-JP）に対応していません"
        case .noCompatibleAudioFormat:
            return "Apple 音声認識が受け付ける音声フォーマットを取得できませんでした"
        case .audioConversionFailed:
            return "録音データを Apple 音声認識の形式へ変換できませんでした"
        }
    }
}

/// Apple の SpeechAnalyzer / SpeechTranscriber（macOS 26 以降）による音声認識（Issue #27）。
///
/// WhisperKit 実装との決定的な違いは**アプリ側のダウンロードが 0** であること。
/// 認識モデルは OS のアセットで、`AssetInventory` は未インストールのときだけ OS に取りに行かせる
/// （HuggingFace から約630MB を引く WhisperKit とは別物）。常駐メモリもアプリは持たない。
///
/// かつて「精度は妥協」として不採用にしていたが、その判断の根拠は
/// 他者の英語ベンチに基づくもので日本語・実利用では検証していない。それを測るための実装。
@available(macOS 26.0, *)
actor AppleTranscriber: SpeechEngine {
    /// 日本語固定。sarari は多言語を明示的に捨てている（`docs/design-rationale.md` §3）。
    private static let requestedLocale = Locale(identifier: "ja-JP")

    /// `AudioRecorder` が出力するサンプルレート。比較のため入力側は WhisperKit と揃える。
    private static let recorderSampleRate: Double = 16_000

    /// 解決済みのロケール。`nil` なら未ロード。
    private var locale: Locale?

    /// アナライザが受け付ける音声フォーマット。実測（macOS 26.5）では 16kHz / mono / **Int16 interleaved** で、
    /// `AudioRecorder` の Float32 バッファをそのまま渡すと Speech 内部でクラッシュする。必ず変換する。
    private var analyzerFormat: AVAudioFormat?

    // MARK: - ロード

    func load() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.requestedLocale) else {
            throw AppleTranscriberError.localeUnsupported
        }

        // フォーマットの問い合わせとアセット確認のためだけのインスタンス。
        // 実際の認識では発話ごとに作り直す（後述）。
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)

        // 未インストールのときだけ非 nil が返る。**これは OS 内蔵アセットの取得**であって、
        // アプリが数GB のモデルを持つこととは別（Issue #27 の「ゼロダウンロード」はこの意味）。
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            throw AppleTranscriberError.noCompatibleAudioFormat
        }

        self.locale = locale
        self.analyzerFormat = format
    }

    /// OS 側のモデルを借りているだけなので、返すメモリは無い。状態だけ落とす。
    func unload() {
        locale = nil
        analyzerFormat = nil
    }

    // MARK: - 文字起こし

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let locale, let analyzerFormat else { throw AppleTranscriberError.notReady }
        guard !samples.isEmpty else { return "" }

        let buffer = try Self.convert(samples, to: analyzerFormat)

        // モジュールとアナライザは**1発話ごとに作る**。`results` は finish で終端するので、
        // 使い回すと2回目以降の結果が取れない。
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 購読は `start(inputSequence:)` より**先**に始める。順序を逆にすると
        // results が終端せず、下の `collector.value` が返ってこない。
        let collector = Task {
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                text += result.text
            }
            return String(text.characters)
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            // ストリームを閉じるだけでは解析は終わらない。finalize を明示的に呼ぶ。
            inputBuilder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            inputBuilder.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 音声フォーマット変換

    /// `AudioRecorder` の 16kHz / mono / Float32 サンプルを、アナライザが要求する形式へ変換する。
    ///
    /// 実測ではサンプルレートは同じで、違うのは Float32 → Int16（interleaved）だけ。
    /// ただし将来 OS 側が別のレートを返す可能性があるので、レート違いの経路も残してある。
    private static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: recorderSampleRate,
                channels: 1,
                interleaved: false
              ),
              let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = source.floatChannelData
        else { throw AppleTranscriberError.audioConversionFailed }

        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }

        if sourceFormat == format { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw AppleTranscriberError.audioConversionFailed
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppleTranscriberError.audioConversionFailed
        }

        if sourceFormat.sampleRate == format.sampleRate {
            // レートが同じならフレーム数も変わらない。1回で変換しきれる。
            try converter.convert(to: output, from: source)
            return output
        }

        var error: NSError?
        // 入力ブロックは `convert` の中から**同期的に**呼ばれるので、バッファもフラグも実際には
        // 並行領域を跨がない。`AVAudioConverter` 側の @Sendable 注釈に合わせるためだけの退避。
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = source
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}
