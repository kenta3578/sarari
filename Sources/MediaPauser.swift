import AppKit
import CoreAudio

/// 録音中だけ、他のアプリが流している音楽を止める（Issue #88）。
///
/// macOS には他アプリの再生を止める公開 API が無いので、2 つを組み合わせる:
///   1. **鳴っているかの判定**は CoreAudio のプロセスオブジェクト（macOS 14.4+）。
///      自分以外のプロセスが出力中なら「鳴っている」とみなす
///   2. **止める・再開する**のはキーボードの再生/一時停止キーと同じイベント。
///      macOS が「再生中」として扱っているアプリ（Music・Spotify・ブラウザ等）に届く
///
/// 再生/一時停止キーは**トグル**なので、鳴っていないときに送ると逆に再生が始まる。
/// だから止めるのは鳴っているときだけ、再開するのは自分が止めたときだけ。
///
/// 既知の穴: ブラウザは一時停止後も 6〜8 秒は出力中のまま（Arc で実測）。手で止めた直後に
/// 録音を始めると「鳴っている」と見て、止まっていた音楽を鳴らしてしまう。
@MainActor
final class MediaPauser {
    /// 録音開始時に自分が一時停止したか。再開したら false に戻す。
    private var didPause = false

    /// 録音開始時に呼ぶ。開始音を鳴らす**前**に呼ぶこと（自分の音は除外しているが、順序で迷わせない）。
    func pauseIfPlaying() {
        didPause = false
        guard SettingsStore.shared.pauseMediaWhileRecording,
              Self.isOtherAudioPlaying() else { return }
        Self.postPlayPauseKey()
        didPause = true
        Log.audio.info("録音中は再生中の音を一時停止します")
    }

    /// 録音の停止・破棄・開始失敗のときに呼ぶ。自分が止めたときだけ再開する。
    func resumeIfPaused() {
        guard didPause else { return }
        didPause = false
        // 「まだ鳴っているなら押さない」とは判定できない。ブラウザは一時停止しても
        // 出力を 6〜8 秒止めない（Arc で実測）ので、短い口述だと再開されなくなる。
        // 録音中に手で再開していた場合はここで止まってしまうが、それは受け入れる。
        Self.postPlayPauseKey()
        Log.audio.info("一時停止した音を再開します")
    }

    // MARK: - 判定

    /// 自分以外のプロセスが音を出力中か。判定できない環境（macOS 14.4 未満・取得失敗）は false。
    ///
    /// false に倒すのは、判定できないのにキーを送ると止まっていた音楽を鳴らしてしまうから。
    private static func isOtherAudioPlaying() -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processObjects().contains { object in
            guard let pid: pid_t = property(object, kAudioProcessPropertyPID), pid != ownPID,
                  let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput)
            else { return false }
            return running != 0
        }
    }

    @available(macOS 14.4, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    // MARK: - 送出

    /// 再生/一時停止キー（`NX_KEYTYPE_PLAY`）の押下と解放を送る。Accessibility 権限で届く。
    private static func postPlayPauseKey() {
        let keyType = 16 // NX_KEYTYPE_PLAY
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (keyType << 16) | ((down ? 0xA : 0xB) << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
