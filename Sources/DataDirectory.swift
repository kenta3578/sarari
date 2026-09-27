import Foundation

/// ユーザーが編集・閲覧するデータの置き場（`~/sarari`）。
///
/// 辞書・フィラー・履歴・自分の音をまとめて置く。sandbox OFF 前提で実ホーム直下に置き、
/// エディタや Claude Code から直接開けるようにしている。
enum DataDirectory {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    static let name = "sarari"
    /// 旧名のときの置き場。新しい名前から順に探す（koebun → koemakase: Issue #43、koemakase → sarari: Issue #54）。
    static let legacyNames = ["koemakase", "koebun"]

    /// 旧名の置き場が残っていて新しい置き場がまだ無ければ、丸ごと移す。
    ///
    /// **ストアを作る前に呼ぶ。** 先に作ると初期ルールを新しい置き場に書き出し、
    /// 旧データを移せなくなる。新しい置き場が既にあれば何もしない。旧名の置き場が複数あれば、
    /// いちばん新しい名前のものだけを移す（古い方はもう使われていないので触らない）。
    static func migrateIfNeeded(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let manager = FileManager.default
        let current = home.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: current.path),
              let legacyName = legacyNames.first(where: {
                  manager.fileExists(atPath: home.appendingPathComponent($0, isDirectory: true).path)
              })
        else { return }
        let legacy = home.appendingPathComponent(legacyName, isDirectory: true)
        do {
            try manager.moveItem(at: legacy, to: current)
            Log.store.notice("データの置き場を ~/\(legacyName, privacy: .public) から ~/\(name, privacy: .public) に移しました")
        } catch {
            Log.store.error("データの置き場を移せませんでした: \(error.localizedDescription)")
        }
    }
}
