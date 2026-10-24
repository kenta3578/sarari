/// WhisperKit のモデルを読むときの順番（Issue #106）。純粋な順序だけを持ち、テストで確かめる。
///
/// 1. 取得（通信）は、手元にファイルが揃っていないときだけ。揃っていれば配布元に問い合わせない
/// 2. 照合は毎回、**読み込みより先に**。未照合のデータを CoreML に渡さない
/// 3. 読み込みのあとにもう一度照合する。トークナイザの読み込みは、手元から読めないと黙って
///    配布元から取り直して同じ場所に書く（WhisperKit の `ModelUtilities.loadTokenizer`）。
///    そうなったら照合していない中身を使っていることになるので、結果を捨てる
enum ModelLoadSequence {
    static func run<T>(
        isCached: Bool,
        fetch: () async throws -> Void,
        verify: () throws -> Void,
        load: () async throws -> T
    ) async throws -> T {
        if !isCached { try await fetch() }
        try verify()
        let loaded = try await load()
        try verify()
        return loaded
    }
}
