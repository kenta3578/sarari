import Foundation
import Testing
@testable import sarari

/// 履歴 `meta.json` の互換。**古い記録が読めなくなることが、この機能で一番痛い回帰**
/// （発話の記録は作り直せない）。
///
/// #128〜#131 で整形系の列（`formattedText` / `modeName` / `prompt` / `formattingEngine` /
/// `formattingModelId` / `diff` / `durations.formatMs`）を書かなくなり、Issue #19 で読む側も消した。
/// **未知のキーは無視されるだけ**なので、当時の JSON がそのまま読めることをここで固定する。
struct HistoryEntryTests {

    private func decode(_ json: String) throws -> HistoryEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HistoryEntry.self, from: Data(json.utf8))
    }

    /// 2026-08-23 のエンジン比較で実際に書かれた形（整形あり・整形ガードあり）。
    private let legacy = """
    {
      "version": 3,
      "createdAt": "2026-08-23T14:18:11Z",
      "rawText": "請求額が4217円です",
      "replacedText": "請求額が4217円です",
      "formattedText": "請求額が4,217円です。",
      "modeName": "メール",
      "prompt": "共通規則…",
      "durations": { "transcribeMs": 292, "replaceMs": 1, "formatMs": 2819 },
      "speechEngine": "apple",
      "formattingEngine": "mlx",
      "formattingModelId": "mlx-community/Qwen3-14B-4bit",
      "diff": { "changes": [], "checkedKinds": ["number"] },
      "inserted": true
    }
    """

    @Test("整形系の列を持つ古い meta.json がそのまま読める")
    func legacyEntryDecodes() throws {
        let entry = try decode(legacy)
        #expect(entry.rawText == "請求額が4217円です")
        #expect(entry.replacedText == "請求額が4217円です")
        #expect(entry.durations.transcribeMs == 292)
        #expect(entry.inserted)
        // 一覧の1行は置換後から作る（整形後はもう読まない。Issue #19）。
        #expect(entry.summary == "請求額が4217円です")
    }

    /// `diff` は #128 で `CodingKeys` から外した。**未知のキーは無視されるだけ**という
    /// 前提（`modelId` を外した Issue #87 と同じ扱い）がここで崩れると古い履歴が全部消える。
    @Test("消したキー（diff）が JSON に残っていてもデコードは壊れない")
    func removedKeyIsIgnored() throws {
        let entry = try decode(legacy)
        #expect(entry.speechEngine == "apple")
    }

    @Test("整形を通していない現在の形（整形系がすべて無い）も読める")
    func currentEntryDecodes() throws {
        let entry = try decode("""
        {
          "version": 3,
          "createdAt": "2026-09-10T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "speechEngine": "apple",
          "inserted": true
        }
        """)
        #expect(entry.speechEngine == "apple")
        #expect(entry.summary == "こんにちは")
    }

    /// 音声の保存は Issue #4 で削除した。それ以前の履歴には `audio` が付いている。
    @Test("音声付きの古い meta.json も読める")
    func legacyEntryWithAudioDecodes() throws {
        let entry = try decode("""
        {
          "version": 3,
          "createdAt": "2026-09-13T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "speechEngine": "apple",
          "audio": { "fileName": "audio.wav", "sampleRate": 16000, "channels": 1, "durationSeconds": 1.5 },
          "inserted": true
        }
        """)
        #expect(entry.rawText == "こんにちは")
        #expect(entry.audio?.durationSeconds == 1.5)
    }

    /// v3 以前は `inserted` しか無い。false は未確認・失敗・空を区別できないので失敗にしない（Issue #15）。
    @Test("挿入結果を持たない古い meta.json は、inserted から結果を導く", arguments: [
        (true, HistoryEntry.Insertion.succeeded),
        (false, nil),
    ])
    func legacyInsertionResult(inserted: Bool, expected: HistoryEntry.Insertion?) throws {
        let entry = try decode("""
        {
          "version": 3,
          "createdAt": "2026-09-14T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "inserted": \(inserted)
        }
        """)
        #expect(entry.insertion == nil)
        #expect(entry.insertionResult == expected)
    }

    @Test("挿入結果を持つ meta.json は、inserted より insertion を優先する", arguments: [
        HistoryEntry.Insertion.succeeded, .uncertain, .failed, .limited,
    ])
    func insertionResultDecodes(insertion: HistoryEntry.Insertion) throws {
        let entry = try decode("""
        {
          "version": 4,
          "createdAt": "2026-09-15T09:00:00Z",
          "rawText": "こんにちは",
          "replacedText": "こんにちは",
          "durations": { "transcribeMs": 300, "replaceMs": 1 },
          "inserted": \(insertion == .succeeded),
          "insertion": "\(insertion.rawValue)"
        }
        """)
        #expect(entry.insertionResult == insertion)
    }

    @Test("挿入の成否は、失敗と断定できたときだけ failed になる")
    func insertionFromOutcome() {
        #expect(HistoryEntry.Insertion(.succeeded) == .succeeded)
        #expect(HistoryEntry.Insertion(.uncertain(detail: "読めない")) == .uncertain)
        #expect(HistoryEntry.Insertion(.failed(reason: "権限なし")) == .failed)
    }

    /// 上限で止めた発話は挿入を試みていない。挿入を試みた結果に混ざると、
    /// 本当に貼れなかった発話と区別できなくなる（Issue #21）。
    @Test("挿入を試みた結果が limited になることはない", arguments: [
        InsertionOutcome.succeeded, .uncertain(detail: "x"), .failed(reason: "x"),
    ])
    func outcomeNeverBecomesLimited(outcome: InsertionOutcome) {
        #expect(HistoryEntry.Insertion(outcome) != .limited)
    }

    @Test("書き出し → 読み戻しで内容が変わらない")
    func roundTrips() throws {
        let original = try decode(legacy)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(HistoryEntry.self, from: data)
        // id は保存先ディレクトリ名が正で meta.json には書かない。
        restored.id = original.id
        #expect(restored == original)
    }
}
