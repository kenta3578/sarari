import CryptoKit
import Foundation

/// 取得した WhisperKit のモデル重みとトークナイザが、**開発時に確かめたものと同じか**を照合する
/// （Issue #106）。
///
/// ## なぜ revision 固定ではないのか
///
/// WhisperKit 0.18.0 には revision を渡す口が無い（`WhisperKitConfig` にも
/// `WhisperKit.download(variant:)` にも無く、ソース全体を検索しても `revision` は 0 件）。
/// `argmaxinc/whisperkit-coreml` の `main` を必ず追うので、**ブランチが書き換えられたら
/// 黙って別の重みを読む**。
///
/// ## なぜ HuggingFace の API から期待値を取らないのか
///
/// 2 つの理由で取らない:
///
/// 1. **循環する。** 検証したい相手（HF）から期待値を取っても、重みを差し替えられる攻撃者は
///    同じ場所のメタデータも差し替えられる。意味のある検証にならない
/// 2. **「ネットワーク送信処理が存在しない」という検証可能な主張を壊す。** README は
///    通信 API の名前を `Sources/` へ grep してヒットが 0 件であることを根拠に、完全ローカルを
///    説明している（パターンは README 側にある。**ここに書くとこのファイルが引っかかる**）。
///    通信を足せばその根拠そのものが消える
///
/// ## 何を、いつ照合するか
///
/// - **読み込むたびに全ファイルを照合する。** 646MB で 0.3 秒ほど（実測）で、モデルの読み込み本体より
///   ずっと軽い。以前は一度通ると印を残して以後ファイルを見なかったので、あとの変化に気づけなかった
/// - **ディレクトリの中身とマニフェストが一致すること**を見る。読み込む側はディレクトリの中を
///   ファイル名で探す（トークナイザは `chat_template.jinja` があれば読む等）ので、記録に無いファイルが
///   あれば照合していないものが読まれうる。対象外は最上位の `.cache`（取得時のメタデータで、
///   読み込みでは使わない）と `.DS_Store` だけ
///
/// ## この検証が保証すること・しないこと
///
/// - **する**: 開発時に確かめた重み・トークナイザから**あとで変わった**ことの検知
/// - **しない**: 最初に取得したものが本物かどうか。マニフェストは実機のキャッシュから
///   起こしているので、そこは trust on first use のまま
///
/// マニフェストの作り直しは `scripts/model-manifest.sh`。
enum ModelIntegrity {

    /// 照合する 1 ファイル。パスは照合するディレクトリからの相対。
    struct Entry: Sendable {
        let path: String
        let sha256: String
        let size: Int
    }

    enum VerificationError: LocalizedError {
        case missing(String)
        case sizeMismatch(String)
        case digestMismatch(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "モデルのファイルが足りません（\(path)）。取得し直してください。"
            case .sizeMismatch(let path), .digestMismatch(let path):
                return "モデルの内容が記録と一致しません（\(path)）。"
                     + "取得元が更新されたか、ファイルが壊れています。"
            case .unexpected(let path):
                return "モデルのフォルダに記録に無いファイルがあります（\(path)）。"
            }
        }
    }

    /// `openai_whisper-large-v3-v20240930_turbo_632MB` の全 22 ファイル。
    /// 2026-09-16 に実機のモデルから起こした。
    /// 更新するときは `scripts/model-manifest.sh` の出力で丸ごと差し替える。
    static let largeV3Turbo: [Entry] = [
        .init(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "0dd9f529c744ed3c6be67f699588f7aadc4f366b5b7301dc31bd3f199944fbcc", size: 243),
        .init(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3", size: 348),
        .init(path: "AudioEncoder.mlmodelc/metadata.json", sha256: "2cd0538f90a012de3f07d38669026d527490eff1dcfd2479a81c48206a90f0a2", size: 1974),
        .init(path: "AudioEncoder.mlmodelc/model.mil", sha256: "ef5a252831e61bb91d6547fe1add3d0658895b518d47d70004322b40a2192668", size: 7589739),
        .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1", size: 421968768),
        .init(path: "config.json", sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1", size: 1149),
        .init(path: "generation_config.json", sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6", size: 2767),
        .init(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce", size: 243),
        .init(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a", size: 329),
        .init(path: "MelSpectrogram.mlmodelc/metadata.json", sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f", size: 1850),
        .init(path: "MelSpectrogram.mlmodelc/model.mil", sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463", size: 10143),
        .init(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49", size: 373376),
        .init(path: "TextDecoder.mlmodelc/analytics/coremldata.bin", sha256: "4b5119bdc621c3c494f63846dc3ed43852e88826fc3b6345d42272d4b7e67724", size: 243),
        .init(path: "TextDecoder.mlmodelc/coremldata.bin", sha256: "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd", size: 633),
        .init(path: "TextDecoder.mlmodelc/metadata.json", sha256: "e3ce6d83884552ffcc2c34799e8e1211dcda59f1aaea5a79bf988c6cd16abbf0", size: 4924),
        .init(path: "TextDecoder.mlmodelc/model.mil", sha256: "ebaf8566f367b6465276c3ed57bb99063888fa955b67828585bf19db24c85f56", size: 217177),
        .init(path: "TextDecoder.mlmodelc/weights/weight.bin", sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db", size: 203199860),
        .init(path: "TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", sha256: "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1", size: 243),
        .init(path: "TextDecoderContextPrefill.mlmodelc/coremldata.bin", sha256: "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e", size: 380),
        .init(path: "TextDecoderContextPrefill.mlmodelc/metadata.json", sha256: "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068", size: 2240),
        .init(path: "TextDecoderContextPrefill.mlmodelc/model.mil", sha256: "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34", size: 4092),
        .init(path: "TextDecoderContextPrefill.mlmodelc/weights/weight.bin", sha256: "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd", size: 12288192),
    ]

    /// トークナイザ（`openai/whisper-large-v3`）。WhisperKit が `loadTokenizer` で読む 3 ファイル。
    /// 認識結果の文字列はここで決まるので、重みと同じく照合する。
    /// 2026-10-24 に実機のキャッシュ（2026-09-16 取得）から起こした。
    static let whisperLargeV3Tokenizer: [Entry] = [
        .init(path: "config.json", sha256: "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b", size: 1272),
        .init(path: "tokenizer_config.json", sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389", size: 282843),
        .init(path: "tokenizer.json", sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca", size: 2480617),
    ]

    /// ディレクトリを照合する。**一致しなければ throw**（呼び出し側が読み込みを止める）。
    ///
    /// 毎回すべてのファイルを読む。記録に無いファイルがあっても落とす。
    static func verify(directory: URL, entries: [Entry]) throws {
        let present = try filesInside(directory)
        let expected = Set(entries.map(\.path))
        if let extra = present.subtracting(expected).sorted().first {
            throw VerificationError.unexpected(extra)
        }
        for entry in entries {
            let url = directory.appendingPathComponent(entry.path)
            guard present.contains(entry.path), let size = fileSize(url) else {
                throw VerificationError.missing(entry.path)
            }
            // 先にサイズを見る。違えば数百 MB を読まずに落とせる。
            guard size == entry.size else { throw VerificationError.sizeMismatch(entry.path) }
            guard try sha256(of: url) == entry.sha256 else {
                throw VerificationError.digestMismatch(entry.path)
            }
        }
    }

    /// 全ファイルがあるか（中身は読まない）。取得が要るかの判断に使う。
    static func hasAllFiles(directory: URL, entries: [Entry]) -> Bool {
        entries.allSatisfy { fileSize(directory.appendingPathComponent($0.path)) != nil }
    }

    /// ディレクトリの中のファイル（ディレクトリ以外すべて。リンクも含む）の相対パス。
    /// 最上位の `.cache` と `.DS_Store` は除く。
    private static func filesInside(_ directory: URL) throws -> Set<String> {
        let base = directory.standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys)
        else { return [] }
        var files = Set<String>()
        for case let url as URL in walker {
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(base.pathComponents.count).joined(separator: "/")
            let values = try url.resourceValues(forKeys: Set(keys))
            if relative == ".cache" {
                walker.skipDescendants()
                continue
            }
            if url.lastPathComponent == ".DS_Store" { continue }
            // リンクは辿らずに 1 ファイルとして数える（記録に無ければ落ちる）。
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
            files.insert(relative)
        }
        return files
    }

    /// 通常のファイルならサイズ。無い・ディレクトリ・リンクなら nil。
    private static func fileSize(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return attributes[.size] as? Int
    }

    /// ファイル全体を読み込まずに SHA-256 を取る（weight.bin は 400MB ある）。
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
