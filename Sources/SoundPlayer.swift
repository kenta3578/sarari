import AppKit

/// 録音開始音・停止音の一覧と再生（Issue #71）、自分で作った音の取り込み（Issue #124）。
///
/// 選択肢は出どころで分ける（Issue #2）: 「なし」→ sarari の音（アプリに同梱）
/// → 自分の音（`~/sarari/sounds/` に置いた音声ファイル）→ macOS のシステム音。
/// 設定に保存するのは名前の文字列だけ（システム音は `NSSound(named:)` の名前、
/// それ以外は拡張子を除いたファイル名）。鳴らすときは自分の音 → sarari の音 → システム音の順に探す。
@MainActor
enum SoundPlayer {
    static let none = "なし"

    /// アプリに同梱した音（`Resources/Sounds/*.wav`、`scripts/make-sounds.py` の BUNDLED と同じ）。
    /// 開始と停止のペアが隣に並ぶ順にしてある。
    static let bundledSounds: [String] = [
        "koebun-up", "koebun-down",
        "chime-open", "chime-close",
        "marimba-high", "marimba-low",
        "classic-start", "classic-stop"
    ]

    static func bundledFileURL(for name: String) -> URL? {
        guard bundledSounds.contains(name) else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
    }

    static let systemSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
        "Sosumi", "Submarine", "Tink"
    ]

    /// 自分の音の置き場。ここに aiff / wav / mp3 / m4a / caf を置くと選択肢に出る。
    static var customDirectory: URL {
        DataDirectory.url
            .appendingPathComponent("sounds", isDirectory: true)
    }

    nonisolated static let supportedExtensions: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]

    /// `~/sarari/sounds/` にある音の名前（拡張子なし、名前順）。
    /// sarari の音と同じ名前は除く（以前は同梱せず、ここへ生成していたため。一覧が二重にならないように）。
    static func customSounds() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return items
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !bundledSounds.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 設定の選択肢。「なし」→ sarari の音 → 自分の音 → システム音。
    static func choices() -> [String] {
        [none] + bundledSounds + customSounds() + systemSounds
    }

    /// 名前が今も選べるか（ファイルを消したあとの設定を「なし」に戻すために使う）。
    static func isAvailable(_ name: String) -> Bool {
        name == none || systemSounds.contains(name)
            || customFileURL(for: name) != nil || bundledFileURL(for: name) != nil
    }

    /// 音を鳴らし、その長さ（秒）を返す。「なし」や読めなかったときは 0。
    ///
    /// 長さを返すのは、起動音をマイクが拾う分を HUD が棒に見せないため（Issue #186）。
    @discardableResult
    static func play(_ name: String) -> TimeInterval {
        guard name != none else { return 0 }
        // 同名なら手元で作り直した音を優先する（make-sounds.py で調整して試せるように）。
        if let url = customFileURL(for: name) ?? bundledFileURL(for: name) {
            // 前の再生が終わる前に次を鳴らしても切れないよう、毎回インスタンスを作る。
            let sound = NSSound(contentsOf: url, byReference: true)
            sound?.play()
            retain(sound)
            return sound?.duration ?? 0
        } else {
            let sound = NSSound(named: .init(name))
            sound?.play()
            return sound?.duration ?? 0
        }
    }

    private static func customFileURL(for name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for ext in supportedExtensions.sorted() {
            let url = customDirectory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - 取り込み・削除（Issue #124）

    enum ImportError: LocalizedError {
        case unsupportedExtension(String)
        case unreadable
        case copyFailed(String)

        var errorDescription: String? {
            let list = SoundPlayer.supportedExtensions.sorted().joined(separator: " / ")
            switch self {
            case .unsupportedExtension(let ext):
                return ext.isEmpty
                    ? "拡張子がないので扱えません（\(list) のいずれか）"
                    : ".\(ext) は扱えません（\(list) のいずれか）"
            case .unreadable:
                return "音声として開けませんでした"
            case .copyFailed(let reason):
                return "コピーできませんでした: \(reason)"
            }
        }
    }

    /// 選んだファイルを `~/sarari/sounds/` に取り込み、選択肢に出る名前を返す。
    /// 元ファイルは動かさずコピーする（取り込んだあとに元を消しても鳴る）。
    @discardableResult
    static func importSound(from source: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedExtension(ext) }
        // 拡張子だけでは中身を保証できないので、実際に開けるかで弾く。
        guard NSSound(contentsOf: source, byReference: false) != nil else { throw ImportError.unreadable }

        do {
            try FileManager.default.createDirectory(
                at: customDirectory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        let base = sanitizedName(source.deletingPathExtension().lastPathComponent)
        let name = availableName(basedOn: base)
        let destination = customDirectory.appendingPathComponent(name).appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        return name
    }

    /// 取り込んだ音をゴミ箱へ入れる（間違えて消しても Finder から戻せる）。
    static func deleteCustomSound(_ name: String) throws {
        guard let url = customFileURL(for: name) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// 置き場を Finder で開く（無ければ作ってから）。
    static func revealCustomDirectory() {
        try? FileManager.default.createDirectory(
            at: customDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(customDirectory)
    }

    /// ファイル名として安全で、設定にそのまま保存できる名前にする。
    private static func sanitizedName(_ raw: String) -> String {
        var name = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }   // 隠しファイルにしない
        return name.isEmpty ? "音" : name
    }

    /// 既存のどの音とも重ならない名前を返す（ピッカーの選択肢が重複しないように）。
    private static func availableName(basedOn base: String) -> String {
        var candidate = base
        var suffix = 2
        while isTaken(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func isTaken(_ name: String) -> Bool {
        isAvailable(name) || bundledSounds.contains(name)
    }

    /// `NSSound(contentsOf:)` は参照を保持しないと再生途中で解放されることがある。
    private static var playing: [NSSound] = []
    private static func retain(_ sound: NSSound?) {
        guard let sound else { return }
        playing.append(sound)
        // 数秒後に掃除する（効果音は短いので、それまでに再生は終わっている）。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            playing.removeAll { $0 === sound || !$0.isPlaying }
        }
    }
}
