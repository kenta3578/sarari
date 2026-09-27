import Foundation
import os

/// `~/sarari/*.json` を読み書きし、**アプリの外での編集**を拾う（Issue #7）。
///
/// 辞書置換とフィラー語はエディタや Claude Code で直接いじる前提にする。以前は起動時に
/// 1 回読むだけだったので、外で編集しても再起動まで効かず、その間に設定画面で 1 行でも
/// 触ると外の編集を上書きしていた。
///
/// 変化の見分けは**バイト列**で行う。自分が書いた・読んだ内容と同じなら何もしない
/// （自分の書き込みで監視が発火しても読み直さない）。
@MainActor
final class JSONFileSync<Value: Codable> {
    enum ReadResult {
        /// 最後に読み書きした内容から変わっていない。
        case unchanged
        /// 外で書き換えられ、読めた。
        case changed(Value)
        /// 外で書き換えられたが、JSON として読めない。いまの値を保つ。
        case broken(String)
        /// ファイルが無い（エディタが保存の途中で消している瞬間を含む）。
        case missing
    }

    enum WriteResult {
        case written
        /// 最後に読んでから外で書き換えられている。上書きしない。
        case conflict
        case failed(String)
    }

    let url: URL
    /// 最後に読んだ・書いたディスク上のバイト列。
    private var lastData: Data?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - 読み書き

    /// 起動時の読み込み。**壊れていたら退避して既定値に戻す**（起動時だけ。実行中の読み直しは値を保つ）。
    func loadAtStartup(default fallback: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            lastData = data
            return value
        } catch {
            // 壊れた JSON を黙って上書きしないよう退避してから既定値に戻す。
            let backup = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.store.error("\(self.url.lastPathComponent) を読めないため退避しました: \(backup.lastPathComponent) / \(error.localizedDescription)")
            return fallback
        }
    }

    /// 外で変わっていれば読み直す。
    func readIfChanged() -> ReadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard data != lastData else { return .unchanged }
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            lastData = data
            return .changed(value)
        } catch {
            return .broken(error.localizedDescription)
        }
    }

    /// 書き出す。**最後に読んでから外で変わっていたら書かない**（外の編集を踏まない）。
    func write(_ value: Value) -> WriteResult {
        let current = try? Data(contentsOf: url)
        if current != nil, current != lastData { return .conflict }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            lastData = data
            // `.atomic` はファイルを差し替えるので、監視しているファイルの記述子が古くなる。
            rearmFileSource()
            return .written
        } catch {
            Log.store.error("\(self.url.lastPathComponent) を保存できませんでした: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 監視

    /// 変化を監視する。**ファイルとディレクトリの両方**を見る。
    ///
    /// その場で書き換えるエディタはファイルにだけ、差し替えて保存するエディタ
    /// （一時ファイル → rename）はディレクトリにだけイベントが出る。
    func startWatching(_ handler: @escaping () -> Void) {
        onChange = handler
        dirSource = makeSource(path: url.deletingLastPathComponent().path, mask: .write)
        rearmFileSource()
    }

    private func rearmFileSource() {
        guard onChange != nil else { return }
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, mask: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            // queue: .main なので main actor 上で呼ばれる。
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func handleEvent() {
        // 差し替え保存のあとは古い記述子を見続けることになるので、毎回張り直す。
        rearmFileSource()
        onChange?()
    }
}
