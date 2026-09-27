import Foundation
import os

/// 辞書置換の1ルール。
///
/// JSON 表現は `{"from": "...", "to": "..."}` のみ（`id` は永続化せず、読み込み時に採番する）。
struct ReplacementRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 辞書置換ルールの永続化（`~/sarari/replacements.json`）と適用。
///
/// 文字起こし直後・（将来入る）整形 LLM の **前段** で機械的に置換する。
/// LLM を通さないので同じ入力からは必ず同じ出力になる。
@MainActor
final class ReplacementStore: ObservableObject {
    static let shared = ReplacementStore()

    /// 記号は音声で入力しづらいので初期ルールとして同梱する。
    ///
    /// **語の一部で誤爆しないものだけを置く**（Issue #82）。`apply` は単語境界を見ない
    /// 部分一致なので、同梱ルールが実在の語を壊すと出荷時のバグになる:
    ///   - `シャープ` は「シャープペンシル」を「#ペンシル」にするので**入れない**
    ///     （`#` が要る人は設定から自分で足す）
    ///   - `スラッシュ` は「バックスラッシュ」を「バック/」にするので、
    ///     より長い `バックスラッシュ` を一緒に置いて最長一致で守る
    static let defaultRules: [ReplacementRule] = [
        ReplacementRule(from: "アットマーク", to: "@"),
        ReplacementRule(from: "ドットコム", to: ".com"),
        ReplacementRule(from: "バックスラッシュ", to: "\\"),
        ReplacementRule(from: "スラッシュ", to: "/"),
        ReplacementRule(from: "アンダースコア", to: "_")
    ]

    @Published var rules: [ReplacementRule] {
        didSet {
            // 外の編集を読み直して入れたときは書き戻さない（書式を勝手に揃えない）。
            guard !isApplyingExternalChange else { return }
            save()
        }
    }

    /// ファイルを読めなかった・外の編集とぶつかったときの説明。設定画面に出す（Issue #7）。
    @Published private(set) var fileProblem: String?

    /// `~/sarari/replacements.json`。sandbox OFF 前提で実ホーム直下に置く。
    static var fileURL: URL {
        DataDirectory.url
            .appendingPathComponent("replacements.json")
    }

    private let file = JSONFileSync<[ReplacementRule]>(url: ReplacementStore.fileURL)
    private var isApplyingExternalChange = false

    private init() {
        // didSet を経由しないよう、まず読み込んでから代入する。
        rules = file.loadAtStartup(default: Self.defaultRules)
        // 初回起動（ファイルが無い）なら初期ルールを書き出して永続化する。
        if !file.fileExists {
            save()
        }
        // 外（エディタ・Claude Code）で編集したら、再起動せずに次の口述から効かせる。
        file.startWatching { [weak self] in self?.reloadFromDisk() }
    }

    /// 外で変わっていれば読み直す。壊れていたら**いまのルールのまま**動かし、理由を出す。
    func reloadFromDisk() {
        switch file.readIfChanged() {
        case .unchanged, .missing:
            return
        case .changed(let loaded):
            // `id` は永続化しないので読み直すたびに採番し直される。同じ位置で中身が同じ行は
            // id を引き継ぎ、編集中の行が作り直されて入力欄のフォーカスが飛ばないようにする。
            let merged = loaded.enumerated().map { index, rule -> ReplacementRule in
                guard rules.indices.contains(index),
                      rules[index].from == rule.from, rules[index].to == rule.to else { return rule }
                var kept = rule
                kept.id = rules[index].id
                return kept
            }
            isApplyingExternalChange = true
            rules = merged
            isApplyingExternalChange = false
            fileProblem = nil
        case .broken(let reason):
            fileProblem = "replacements.json を読めないため、直前のルールで動いています（\(reason)）"
        }
    }

    // MARK: - 適用

    /// ルールを適用したテキストを返す。
    func apply(_ text: String) -> String {
        Self.apply(text, rules: rules)
    }

    /// 先頭から1パスで走査し、各位置で **最長にマッチするルール** を1つだけ適用する。
    ///
    /// ルールごとに全文置換を繰り返すと置換後の文字列が後続ルールに再マッチしてしまう
    /// （`アットマーク`→`@` の結果を別ルールがさらに書き換える）。1パス走査ならその連鎖が起きず、
    /// 適用順にも依存しない。日本語が対象なので単語境界は見ず素直な部分一致とする。
    /// **純関数なので `nonisolated`。** `DictationPipeline` が MainActor の外から呼ぶ（Issue #66）。
    nonisolated static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        let active = rules
            .filter { !$0.from.isEmpty }
            .sorted {
                // 長いルールを優先。同長は from の辞書順で固定して結果を決定的にする。
                $0.from.count != $1.from.count ? $0.from.count > $1.from.count : $0.from < $1.from
            }
        guard !active.isEmpty else { return text }

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            var matched = false
            for rule in active {
                guard let end = text.index(index, offsetBy: rule.from.count, limitedBy: text.endIndex),
                      text[index..<end].compare(rule.from, options: .caseInsensitive) == .orderedSame
                else { continue }
                result += rule.to
                index = end
                matched = true
                break
            }
            if !matched {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    // MARK: - 取り込み

    /// 取り込みの結果。`added` は既存に無かったルール、`skipped` は読みが重なって足さなかった件数。
    struct ImportResult: Equatable {
        var added: [ReplacementRule]
        var skipped: Int
    }

    /// `candidates` のうち、`existing` に同じ読み（大文字小文字は区別しない）が無いものだけを返す。
    ///
    /// 既存ルールは書き換えない。候補どうしで読みが重なれば先のものを採る。読みが空の行は数えずに捨てる。
    nonisolated static func merge(_ candidates: [ReplacementRule],
                                  into existing: [ReplacementRule]) -> ImportResult {
        var seen = Set(existing.map { $0.from.lowercased() })
        var added: [ReplacementRule] = []
        var skipped = 0
        for rule in candidates where !rule.from.isEmpty {
            if seen.insert(rule.from.lowercased()).inserted {
                added.append(rule)
            } else {
                skipped += 1
            }
        }
        return ImportResult(added: added, skipped: skipped)
    }

    /// `replacements.json` と同じ形式の JSON を読み、足すルールを決める（Issue #13）。
    ///
    /// 語彙セット（エンジニア用語など）はアプリに同梱せず、ファイルで配って取り込んでもらう。
    /// **壊れた JSON は 1 件も足さずに投げる**（途中まで足すと、どこまで入ったか分からない）。
    nonisolated static func importRules(from data: Data,
                                        into existing: [ReplacementRule]) throws -> ImportResult {
        let candidates = try JSONDecoder().decode([ReplacementRule].self, from: data)
        return merge(candidates, into: existing)
    }

    // MARK: - 永続化

    private func save() {
        switch file.write(rules) {
        case .written:
            fileProblem = nil
        case .conflict:
            // 外の編集を踏まない。そちらを正として読み直し、画面の変更はやり直してもらう。
            reloadFromDisk()
            if fileProblem == nil {
                fileProblem = "replacements.json が外で編集されていたので読み直しました。直前の変更はもう一度行ってください"
            }
        case .failed(let reason):
            fileProblem = "replacements.json を保存できませんでした（\(reason)）"
        }
    }
}
