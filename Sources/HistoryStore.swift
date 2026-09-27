import AppKit
import Foundation
import os

/// 1発話ぶんの履歴（`meta.json` の実体）。
///
/// **生テキストを必ず残す**のがこの構造の芯。辞書置換で壊れた語に後から気づけるようにする。
///
/// 整形 LLM（#131 で削除）の列は書かなくなったが、**古い `meta.json` は読めるままにする**
/// （未知のキーは無視される）。整形結果そのものはファイルに残っている（Issue #19）。
struct HistoryEntry: Codable, Identifiable, Equatable {
    /// 各処理の所要時間（ミリ秒）。
    struct Durations: Codable, Equatable {
        var transcribeMs: Int
        var replaceMs: Int
    }

    /// 保存した録音の情報。**古い履歴を読むためだけに残す。**
    /// 音声の保存は Issue #4 で削除したので、新しい履歴では常に nil。
    struct Audio: Codable, Equatable {
        var fileName: String
        var sampleRate: Int
        var channels: Int
        var durationSeconds: Double
    }

    /// meta.json のスキーマ版。整形 LLM を足したあとも古い履歴を読み分けられるようにする。
    /// 3 = 使用したエンジン（`speechEngine` / `formattingEngine` / `formattingModelId`）を追加（Issue #27）。
    /// 4 = 挿入結果（`insertion`）を追加（Issue #15）。
    ///     `limited`（上限で止めたので挿入していない）は後から足した値で、版は上げていない（Issue #21）。
    var version: Int = HistoryFiles.schemaVersion
    var createdAt: Date
    /// 文字起こしの生出力。**上書きしない**。
    var rawText: String
    /// 辞書置換（決定的な文字列処理）を適用した結果。
    var replacedText: String
    var durations: Durations
    /// 文字起こしに使ったエンジン（`SpeechEngineKind.rawValue`）。v2 以前の履歴は nil。
    ///
    /// **エンジン比較の一次データはここ**（Issue #27）。同じ発話を両エンジンに通したとき、
    /// 生テキストと所要時間をどちらの結果として読めばいいかが、これが無いと分からなくなる。
    var speechEngine: String?
    var audio: Audio?
    /// 挿入を確認できたか（`InsertionOutcome.succeeded` のときだけ true）。
    /// 未確認と失敗を区別できないので、表示には `insertionResult` を使う。
    var inserted: Bool
    /// 挿入結果（v4 から）。挿入する文字が残らなかった発話と v3 以前の履歴は nil。
    var insertion: Insertion? = nil

    /// 保存先ディレクトリ名。ディレクトリ名が正なので meta.json には書かない。
    var id: String = ""

    /// 履歴に残す挿入結果。`InsertionOutcome` から理由と手がかりを落としたもの。
    enum Insertion: String, Codable, Equatable {
        case succeeded, uncertain, failed
        /// 録音の上限で止めたので、そもそも挿入していない（Issue #21）。
        /// **挿入を試みた結果ではない**ので、`init(_:)` からは決して作られない。
        case limited

        init(_ outcome: InsertionOutcome) {
            switch outcome {
            case .succeeded: self = .succeeded
            case .uncertain: self = .uncertain
            case .failed:    self = .failed
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, createdAt, rawText, replacedText, durations
        case speechEngine, audio, inserted, insertion
    }

    /// 表示に使う挿入結果。
    ///
    /// ターミナルは AX が反映を返さないので `.uncertain` が常態。`inserted` だけで見ると
    /// そこへの口述がすべて「未挿入」に見えていた（Issue #15）。v3 以前の `inserted: false` は
    /// 未確認・失敗・空のどれか分からないので、失敗と断定せず nil にする。
    var insertionResult: Insertion? {
        insertion ?? (inserted ? .succeeded : nil)
    }

    /// 履歴に出す音声認識エンジン名。v2 以前の履歴（エンジンが1つしか無かった頃）は nil。
    var speechEngineLabel: String? {
        speechEngine.map { SpeechEngineKind(rawValue: $0)?.shortLabel ?? $0 }
    }

    /// 一覧に出す1行サマリー。
    var summary: String {
        let trimmed = replacedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（無音）" : trimmed
    }
}

/// 履歴のファイル入出力。**メインアクターから切り離す**ための名前空間。
///
/// 保存は挿入をブロックしてはいけない（挿入の体感速度がこのアプリの価値）ので、
/// ここの関数はバックグラウンドの `Task.detached` から呼ばれる。
enum HistoryFiles {
    static let schemaVersion = 4
    static let metaFileName = "meta.json"
    /// 一覧に読み込む上限。古いものは削除されるまでディスクには残る。
    static let listLimit = 500

    /// `~/sarari/history`。sandbox OFF 前提で実ホーム直下に置く（replacements.json と同じ場所）。
    static var rootURL: URL {
        DataDirectory.url
            .appendingPathComponent("history", isDirectory: true)
    }

    static func directoryURL(for id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    /// 保存先フォルダを Finder で開く（1度も保存していないと存在しないので作ってから開く）。
    @MainActor
    static func revealRoot() {
        try? createPrivateDirectory(at: rootURL)
        NSWorkspace.shared.open(rootURL)
    }

    /// ディレクトリ名。ISO8601 の basic 形式（`:` を含まないので Finder 上でも化けない）。
    static func directoryName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 書き出し

    /// 1発話ぶんを `~/sarari/history/<timestamp>/meta.json` に書き出す。
    /// 録音した音声は残さない（Issue #4。声は履歴の中で最も機微で、使い道も無かった）。
    static func write(_ entry: HistoryEntry) throws -> HistoryEntry {
        let dir = directoryURL(for: entry.id)
        try createPrivateDirectory(at: dir)
        try encoder.encode(entry).write(to: dir.appendingPathComponent(metaFileName), options: .atomic)
        return entry
    }

    /// 履歴のディレクトリに使う権限。
    ///
    /// 既定（0755）のままだと、マルチユーザーの Mac で他アカウントから発話の全文と
    /// 音声を読める。`~/sarari` は Desktop や Documents と違い TCC の保護対象外（Issue #81）。
    /// `[FileAttributeKey: Any]` は Sendable でないので `static let` だと共有された可変状態に見える。
    /// 呼ぶたびに作れば渡す先はローカルの値だけになる（生成コストは無視できる）。
    private static var privateAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }

    static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: privateAttributes
        )
    }

    /// 保存先を用意し、既にあるものも 0700 に締め直す（以前は 0755 で作っていた）。
    static func prepareRoot() {
        let manager = FileManager.default
        try? createPrivateDirectory(at: rootURL)
        for url in [rootURL.deletingLastPathComponent(), rootURL] {
            try? manager.setAttributes(privateAttributes, ofItemAtPath: url.path)
        }
    }

    // MARK: - 読み込み・削除

    /// 新しい順に最大 `limit` 件読み込む。壊れた meta.json は読み飛ばす。
    /// 一覧は `listLimit` 件で足りるが、辞書の候補（Issue #40）は保存期間内の全件を見る。
    static func loadEntries(limit: Int = listLimit) -> [HistoryEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return [] }

        // ディレクトリ名（ISO8601 basic）は辞書順＝時系列順。meta を読む前に絞る。
        let newest = names
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
            .prefix(limit)

        return newest.compactMap { name in
            let url = directoryURL(for: name).appendingPathComponent(metaFileName)
            guard let data = try? Data(contentsOf: url) else {
                // 無言で読み飛ばすと、音声だけが残った孤児に気づけない（Issue #81）。
                Log.history.notice("meta が見つかりません（録音だけが残っている可能性）: \(name)")
                return nil
            }
            guard var entry = try? decoder.decode(HistoryEntry.self, from: data) else {
                Log.history.error("meta を読めませんでした: \(name)")
                return nil
            }
            entry.id = name
            return entry
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(id: String) {
        do {
            try FileManager.default.removeItem(at: directoryURL(for: id))
        } catch CocoaError.fileNoSuchFile {
            // 既に無いのは正常（purge と重なったときなど）。
        } catch {
            // 握り潰すと「消したのに復活した」の原因が追えない（Issue #81）。
            Log.history.error("削除できませんでした: \(id) / \(error.localizedDescription)")
        }
    }

    /// 履歴をすべて消す。`listLimit`（500 件）より古いものは一覧に出ないので、
    /// これが無いと**アプリから消す手段が存在しない**（Issue #81）。
    static func deleteAll() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where !name.hasPrefix(".") {
            delete(id: name)
        }
    }

    /// 保存期間を過ぎたディレクトリを削除する。`retentionDays <= 0` なら無期限（何もしない）。
    /// 判定はディレクトリ名のタイムスタンプで行う（名前が読めないものは meta.json の作成日時で見る）。
    @discardableResult
    static func purge(retentionDays: Int) -> Int {
        guard retentionDays > 0 else { return 0 }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: rootURL.path) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let cutoffName = directoryName(for: cutoff)
        var removed = 0

        for name in names where !name.hasPrefix(".") {
            let isExpired: Bool
            if name.count == cutoffName.count, name.hasSuffix("Z") {
                isExpired = name < cutoffName
            } else {
                let url = directoryURL(for: name).appendingPathComponent(metaFileName)
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(HistoryEntry.self, from: data) else { continue }
                isExpired = entry.createdAt < cutoff
            }
            guard isExpired else { continue }
            do {
                try manager.removeItem(at: directoryURL(for: name))
                removed += 1
            } catch {
                Log.history.error("古い履歴を削除できませんでした: \(name) / \(error.localizedDescription)")
            }
        }
        return removed
    }
}

/// 履歴の共有状態。ファイル入出力は `HistoryFiles`、ここは UI に見せる一覧の管理だけ。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// 新しい順。
    @Published private(set) var entries: [HistoryEntry] = []
    /// ディスクへ書き出し中の履歴。`reload` はディスクの一覧にこれを合成する
    /// （書き込み完了前に再読み込みすると直前の発話が一覧から消えていた。Issue #63）。
    private var writing: [HistoryEntry.ID: HistoryEntry] = [:]
    /// 削除された ID。書き出しが後から完了しても復活させないため（Issue #81）。
    private var deleted: Set<HistoryEntry.ID> = []
    /// 保存期間の掃除を定期的に回すタイマー。
    private var purgeTimer: Timer?
    /// 掃除の間隔。常駐したまま日付をまたいでも、その日のうちに効くようにする。
    private static let purgeInterval: TimeInterval = 60 * 60

    private init() {}

    /// 保存先を用意し、保存期間の掃除を始める（起動時に一度だけ呼ぶ）。
    ///
    /// 以前は起動時と設定変更時にしか掃除していなかったので、メニューバー常駐で
    /// 何週間も動かしていると「7日」と表示しながら消えなかった。保存期間はこのアプリで
    /// 唯一の明示的なプライバシー制御なので、表示と実挙動の食い違いが一番効く（Issue #81）。
    func start() {
        HistoryFiles.prepareRoot()
        purgeExpired()
        guard purgeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.purgeInterval, repeats: true) { _ in
            Task { @MainActor in HistoryStore.shared.purgeExpired() }
        }
        timer.tolerance = Self.purgeInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
    }

    // MARK: - 記録

    /// 1発話ぶんを記録する。
    ///
    /// **挿入をブロックしない**: 一覧には即座に反映し、ディスクへの書き出しは
    /// バックグラウンドで行う。書き出しに失敗しても挿入は成功しているので、
    /// ログに残すだけでユーザーの操作は止めない。
    /// - Parameters:
    ///   - prompt: 整形 LLM に送ったシステムプロンプト全文（整形が通ったときのみ）。
    ///   - speechEngine: 文字起こしに使ったエンジン（`SpeechEngineKind.rawValue`）。
    ///   - insertion: 挿入結果。挿入する文字が残らなかった発話は nil。
    func record(
        rawText: String,
        replacedText: String,
        speechEngine: String? = nil,
        durations: HistoryEntry.Durations,
        insertion: HistoryEntry.Insertion?
    ) {
        // 無音（文字起こしが何も返さなかった）は残さない。後から見ても何も分からない（Issue #81）。
        guard !rawText.isEmpty || !replacedText.isEmpty else { return }

        let createdAt = Date()
        var entry = HistoryEntry(
            createdAt: createdAt,
            rawText: rawText,
            replacedText: replacedText,
            durations: durations,
            speechEngine: speechEngine,
            audio: nil,
            inserted: insertion == .succeeded,
            insertion: insertion
        )
        entry.id = HistoryFiles.directoryName(for: createdAt)
        entries.insert(entry, at: 0)
        writing[entry.id] = entry

        Task.detached(priority: .utility) {
            do {
                let written = try HistoryFiles.write(entry)
                await MainActor.run { HistoryStore.shared.finishWriting(written) }
            } catch {
                Log.history.error("保存できませんでした: \(error.localizedDescription)")
                await MainActor.run { HistoryStore.shared.abandonWriting(entry.id) }
            }
        }
    }

    /// 書き出し後の内容を一覧側に反映し、書き込み中の印を外す。
    private func finishWriting(_ entry: HistoryEntry) {
        writing[entry.id] = nil
        // 書き出しの最中に削除されていたら、書き上がったものを消し直す。
        // これが無いと、削除タスクが先に走ったときに書き出しがディレクトリを作り直し、
        // 消したはずの音声と全文がディスクに残る（Issue #81）。
        if deleted.remove(entry.id) != nil {
            let id = entry.id
            Task.detached(priority: .utility) { HistoryFiles.delete(id: id) }
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
    }

    /// 書き出しに失敗した分の後始末。中途半端に残ったディレクトリも消す。
    private func abandonWriting(_ id: HistoryEntry.ID) {
        writing[id] = nil
        deleted.remove(id)
        entries.removeAll { $0.id == id }
        Task.detached(priority: .utility) { HistoryFiles.delete(id: id) }
    }

    /// ディスクから読んだ一覧に、まだ書き込み中の履歴を合成して置き換える。
    private func replaceEntries(with loaded: [HistoryEntry]) {
        let onDisk = Set(loaded.map(\.id))
        let pending = writing.values.filter { !onDisk.contains($0.id) }
        entries = pending.isEmpty ? loaded : (loaded + pending).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 一覧

    func reload() {
        Task.detached(priority: .userInitiated) {
            let loaded = HistoryFiles.loadEntries()
            await MainActor.run { HistoryStore.shared.replaceEntries(with: loaded) }
        }
    }

    func delete(_ entry: HistoryEntry) {
        let id = entry.id
        entries.removeAll { $0.id == id }
        // 書き込み中の印も外す。残っていると `reload` が `writing` から復元して
        // 一覧に戻ってくる（Issue #81）。
        writing[id] = nil
        // 書き出しが後から完了したときに消し直せるよう覚えておく。
        deleted.insert(id)
        if deleted.count > 64 { deleted = Set(deleted.sorted().suffix(32)) }
        Task.detached(priority: .utility) { HistoryFiles.delete(id: id) }
    }

    /// 履歴をすべて消す。
    ///
    /// 一覧は新しい 500 件しか読まないので、これが無いと**それより古いものを
    /// アプリから消す手段が存在しない**（保存期間「無期限」だと恒久的に残る）。Issue #81。
    func deleteAll() {
        entries.removeAll()
        writing.removeAll()
        deleted.removeAll()
        Task.detached(priority: .utility) {
            HistoryFiles.deleteAll()
            await MainActor.run { HistoryStore.shared.reload() }
        }
    }

    /// 保存期間を過ぎた履歴を削除する（起動時と設定変更時に呼ぶ）。
    func purgeExpired() {
        let days = SettingsStore.shared.historyRetentionDays
        Task.detached(priority: .utility) {
            let removed = HistoryFiles.purge(retentionDays: days)
            guard removed > 0 else { return }
            Log.history.info("保存期間（\(days, privacy: .public)日）を過ぎた履歴を \(removed, privacy: .public) 件削除しました")
            await MainActor.run { HistoryStore.shared.reload() }
        }
    }

}
