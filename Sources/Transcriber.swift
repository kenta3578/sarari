import Foundation
import Hub
import os
@preconcurrency import WhisperKit

enum TranscriberError: Error {
    case notReady
    case unexpectedVariant
}

/// WhisperKit ラッパー。large-v3-turbo を日本語で文字起こしする。
/// モデル（約630MB）は初回ロード時にダウンロードされる。
///
/// `SpeechEngine` の実装の1つ（Issue #27）。**挙動は差し替え前と同じ**で、
/// 切り替えのために `unload()` だけを足してある。
actor Transcriber: SpeechEngine {
    private var pipe: WhisperKit?

    /// 使うモデルの variant 名。
    ///
    /// large-v3（2.9GB）は認識の中央値が 1,114ms で、挿入までの待ちが明らかに重かった。
    /// turbo（デコーダ 4 層・量子化）は同じ文で精度を保ったまま約 470ms（Issue #25）。
    /// Distil 系は英語専用なので使えない。
    static let model = "large-v3-v20240930_turbo_632MB"

    /// トークナイザの取得元。WhisperKit が turbo（logits 51866・encoder 1280 → `.largev3`）に
    /// 選ぶ名前（`ModelUtilities.tokenizerNameForVariant`。internal なので写してある）。
    /// **WhisperKit を上げたら、この対応が変わっていないかを確かめる。**
    static let tokenizerRepo = "openai/whisper-large-v3"

    /// モデルを読み込む。手元に揃っていなければ取得する（Issue #106）。
    ///
    /// 取得と読み込みを分けている。以前は `download: true` で毎回 WhisperKit に任せていたので、
    /// 起動とエンジン切り替えのたびに配布元へ更新の問い合わせが出て、上流が変われば取り直し、
    /// 照合も読み込みの後だった。今は:
    ///
    /// - 取得は、モデルかトークナイザのファイルが欠けているときだけ（初回・壊れて消したとき）
    /// - 照合は毎回、読み込みの前と後（順番は `ModelLoadSequence`）
    /// - 読み込みは照合したディレクトリだけを指し、`download: false`（`localLoadConfig`）
    ///
    /// 取得に WhisperKit の既定（`modelFolder` 無し + `download: true`）を使わないのは、
    /// 照合より先に CoreML へ読ませてしまうため。逆に `modelFolder` を渡すと WhisperKit は
    /// 取得しない（Issue #83 で踏んだ）ので、取得は `fetch` で明示的にやる。
    func load() async throws {
        guard let base = Self.prepareDownloadBase() else { throw TranscriberError.notReady }
        let targets = Self.verificationTargets(base: base)
        let pipeline = try await ModelLoadSequence.run(
            isCached: Self.isCached(base: base),
            fetch: { try await Self.fetch(base: base) },
            verify: { try Self.verify(targets) },
            load: {
                let pipeline = try await WhisperKit(Self.localLoadConfig(base: base))
                // WhisperKit はトークナイザの名前を variant から決める。照合した
                // `tokenizerRepo` と違う variant と判定したら、照合していないトークナイザを
                // 読んでいるので使わない（WhisperKit を上げて対応が変わったときの網）。
                guard pipeline.modelVariant == .largev3 else { throw TranscriberError.unexpectedVariant }
                return pipeline
            })
        pipe = pipeline
    }

    /// 照合する 1 組（ディレクトリとマニフェスト）。
    struct VerificationTarget: Sendable {
        let directory: URL
        let entries: [ModelIntegrity.Entry]
    }

    /// WhisperKit が読むディレクトリと、それぞれのマニフェスト。
    static func verificationTargets(base: URL) -> [VerificationTarget] {
        [
            .init(directory: modelDirectory(base: base), entries: ModelIntegrity.largeV3Turbo),
            .init(directory: tokenizerDirectory(base: base), entries: ModelIntegrity.whisperLargeV3Tokenizer),
        ]
    }

    /// モデルとトークナイザのファイルが全部あるか（中身は読まない）。
    static func isCached(base: URL) -> Bool {
        verificationTargets(base: base).allSatisfy {
            ModelIntegrity.hasAllFiles(directory: $0.directory, entries: $0.entries)
        }
    }

    /// 手元のファイルだけで読み込む設定。取得はしない。
    ///
    /// トークナイザは `<tokenizerFolder>/models/<repo id>/` を最初に探すので、
    /// `tokenizerFolder` を `base` にすると照合した `tokenizerDirectory` が読まれる。
    static func localLoadConfig(base: URL) -> WhisperKitConfig {
        WhisperKitConfig(downloadBase: base,
                         modelFolder: modelDirectory(base: base).path,
                         tokenizerFolder: base,
                         load: true,
                         download: false)
    }

    /// 配布元から取得する（通信はここだけ）。**欠けている側だけ**を取りに行く。
    ///
    /// 揃っている側まで取得に回すと、取得ライブラリが配布元と突き合わせて、照合済みの
    /// ファイルを上流の新しい版で上書きしうる（トークナイザが欠けただけでモデルが変わる）。
    ///
    /// どちらも**ファイルを置くだけで中身は解析しない**。解析は照合のあと（`localLoadConfig`）。
    /// トークナイザに WhisperKit の `ModelUtilities.loadTokenizer` を使わないのはそのため
    /// （取得したその場で解析する）。置き場は WhisperKit が読み込み時に探す場所と同じ。
    private static func fetch(base: URL) async throws {
        if !ModelIntegrity.hasAllFiles(directory: modelDirectory(base: base),
                                       entries: ModelIntegrity.largeV3Turbo) {
            _ = try await WhisperKit.download(variant: model, downloadBase: base)
        }
        if !ModelIntegrity.hasAllFiles(directory: tokenizerDirectory(base: base),
                                       entries: ModelIntegrity.whisperLargeV3Tokenizer) {
            _ = try await HubApi(downloadBase: base).snapshot(
                from: HubApi.Repo(id: tokenizerRepo),
                matching: ModelIntegrity.whisperLargeV3Tokenizer.map(\.path))
        }
    }

    private static func verify(_ targets: [VerificationTarget]) throws {
        do {
            for target in targets {
                try ModelIntegrity.verify(directory: target.directory, entries: target.entries)
            }
        } catch {
            Log.asr.error("モデルの照合に失敗しました: \(error.localizedDescription)")
            throw error
        }
    }

    /// モデルの保存先の根。**WhisperKit の既定（`~/Documents/huggingface`）を使わない**（Issue #23）。
    ///
    /// 書類フォルダは TCC で守られているので、ダウンロードが途中で壊れてもアプリはそれを消せず、
    /// 「Model not found …アクセス権がないため削除できませんでした」から自力で復帰できない。
    /// iCloud の同期対象にもなりうるので、数 GB を置く場所でもない。
    /// `.cachesDirectory` は OS がパージしうる＝モデルを取り直させるので、Application Support に置く。
    static var downloadBase: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.kenta3578.koebun", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    /// 保存先を用意して返す。場所が決まらなければ nil（読み込みは止まる）。
    private static func prepareDownloadBase() -> URL? {
        guard var base = downloadBase else { return nil }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // 取り直せる数百 MB なので Time Machine には載せない。
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try base.setResourceValues(values)
        } catch {
            // 作れなくても続ける。取得のときに取得ライブラリが同じ場所を作り直す。
            Log.asr.error("モデルの保存先を用意できませんでした: \(error.localizedDescription)")
        }
        return base
    }

    /// モデルのディレクトリ。HubApi は `<downloadBase>/models/<repo id>/` に展開する。
    static var modelDirectory: URL? { downloadBase.map(modelDirectory(base:)) }

    static func modelDirectory(base: URL) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(model)", isDirectory: true)
    }

    /// トークナイザのディレクトリ。モデルと同じく HubApi の並び。
    static var tokenizerDirectory: URL? { downloadBase.map(tokenizerDirectory(base:)) }

    static func tokenizerDirectory(base: URL) -> URL {
        base.appendingPathComponent("models/\(tokenizerRepo)", isDirectory: true)
    }

    /// モデルが取得済みか。UI に「ダウンロード中」を出すかの判断に使う。
    static var hasCachedModel: Bool { downloadBase.map(isCached(base:)) ?? false }

    /// 常駐を解除してメモリを返す。Apple 音声認識へ切り替えたときに呼ぶ。
    func unload() {
        pipe = nil
    }

    /// 16kHz mono Float サンプルを日本語テキストに変換する。
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriberError.notReady }
        guard !samples.isEmpty else { return "" }

        let options = DecodingOptions(task: .transcribe, language: "ja")
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
