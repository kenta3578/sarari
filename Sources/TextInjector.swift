import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 挿入の結果。**成功だと確信できたときだけ `.succeeded`** を返す。
///
/// `.failed` と `.uncertain` は**結果の扱いが同じ**（どちらも捨てない）だが、
/// **見せ方は分ける**（Issue #34）。`.uncertain` は「送出は済んだ・確認手段が無いだけ」で、
/// ターミナルのように AX でテキストを読めないアプリでは毎回起きる。
/// これを警告として描くと、毎回出る警告になって本当の失敗に気づけなくなる。
enum InsertionOutcome: Equatable {
    /// 挿入先のテキストが実際に増えた（または caret が進んだ）ことを確認できた。
    case succeeded
    /// 挿入先が変化しなかった＝受け付けなかったと判断できた。
    /// `hint` は設定で直せる原因（権限）のときだけ付く。
    case failed(reason: String, hint: FailureHint? = nil)
    /// 挿入は送出したが、成否を判定できなかった（Accessibility でテキストを読めないアプリなど）。
    /// `detail` は「なぜ確認できないか」だけを言う（何が起きたかは `headline` 側）。
    case uncertain(detail: String)

    var isSucceeded: Bool { self == .succeeded }

    /// 本当に失敗したか。**警告色・警告アイコンを使ってよいのはこれが true のときだけ**。
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// HUD の見出し。**何が起きたか**を先に言う（「確認できません」で終わらせない）。
    var headline: String {
        switch self {
        case .succeeded, .uncertain: return "挿入しました"
        case .failed(let reason, _): return reason
        }
    }

    /// 設定で直せる原因への手がかり。`.failed` のうち権限起因のときだけ付く。
    var hint: FailureHint? {
        if case .failed(_, let hint) = self { return hint }
        return nil
    }

    /// 見出しに添える補足。`.uncertain` のときだけ付く。
    var detail: String? {
        switch self {
        case .succeeded, .failed:    return nil
        case .uncertain(let detail): return detail
        }
    }

    /// 1行に畳んだ文言。
    var summary: String {
        guard let detail else { return headline }
        return "\(headline)（\(detail)）"
    }

    /// メニューバー側に出す文言。**結果を残したときはその在り処を案内する**。
    ///
    /// 案内が要らないのは成功したときだけ（クリップボードは元に戻してある）。
    /// `.uncertain` はターミナルのように AX でテキストを読めないアプリでは毎回起きるので、
    /// ここで案内しないと「クリップボードを踏んで、戻していない」ことが
    /// ユーザーに一切伝わらない（Issue #79）。
    /// `location` は「HUD・クリップボード・履歴」など、設定に応じた実際の残し先。
    func statusMessage(resultKeptIn location: String) -> String {
        isSucceeded ? summary : "\(summary)。結果は\(location)に残しています"
    }
}

/// 文字起こし結果を最前面アプリのカーソル位置に挿入する。
///
/// クリップボードに一時セット → ⌘V を合成送出 → 判定のあとに元の内容へ復元する。
/// 1文字ずつキーを送る方式もあったが、一度も使われなかったので削除した（Issue #5）。
///
/// Accessibility 権限が要る。挿入後は Accessibility API で挿入先の文字数・caret を
/// 見比べて成否を判定し、確信が持てなければ `.uncertain` を返して結果を保全する
/// （`docs/design-rationale.md` §4）。
///
/// OS に触れる部分（クリップボード・前面アプリ・権限・⌘V と判定）は `Environment` に寄せてあり、
/// テストは名前付きペーストボードとフェイクの送出で同じ手順を通せる。
@MainActor
final class TextInjector {
    /// アプリが使う本物。呼び出し側は static の入口からこれを使う。
    static let shared = TextInjector(environment: .live)

    /// 挿入が触る外の世界。
    struct Environment {
        var pasteboard: NSPasteboard
        /// いまの挿入先（前面アプリ・前面の窓・フォーカスのある要素）。
        var currentTarget: @MainActor () -> InsertionTarget
        var isAccessibilityTrusted: @MainActor () -> Bool
        /// 挿入してはいけない状態ならその理由（パスワード欄・Secure Keyboard Entry）。
        var secureInputReason: @MainActor () -> String?
        /// ⌘V を送り、挿入先の変化から成否を判定する。クリップボードは書き込み済みで呼ばれる。
        var deliver: @MainActor (_ text: String) async -> InsertionOutcome
        /// `.failed` のときクリップボードに結果を残すか（設定）。
        var keepResultOnFailure: @MainActor () -> Bool
        /// 判定後、クリップボードを復元するまでの追加待ち。
        var restoreDelay: Duration
    }

    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - 入口（static）

    /// - Parameter expectedTarget: 録音を止めたときの挿入先。渡すと、挿入直前に
    ///   変わっていないかを照合する。nil なら照合しない（HUD・履歴からの再挿入）。
    static func insert(_ text: String, expectedTarget: InsertionTarget? = nil) async -> InsertionOutcome {
        await shared.insert(text, expectedTarget: expectedTarget)
    }

    /// いまの挿入先。録音を止めたときにこれを控え、挿入直前に同じかを見る（Issue #80 / #107）。
    /// **取る側と比べる側を同じ場所に置く**ことで、片方だけ条件が変わる事故を防ぐ。
    static func currentTarget() -> InsertionTarget {
        shared.environment.currentTarget()
    }

    /// 口述テキストをクリップボードへ置く。**HUD と履歴の「コピー」はここを通す。**
    ///
    /// 経路を 1 つに寄せることで、機密の目印の付け方が漏れないようにする。
    /// 以前は HUD と履歴が `NSPasteboard` を直接叩いていた（Issue #79）。
    ///
    /// **`Concealed` だけを立てる。** ユーザーが自分の意思でコピーしたものなので、
    /// クリップボードマネージャの履歴には**残ってよい**（残らないと「さっきコピーしたのに
    /// 履歴に無い」になる）。伏字扱いにするかは各マネージャの判断に任せる。
    static func copyToPasteboard(_ text: String) {
        shared.write(text, purpose: .userCopy)
    }

    /// アプリ終了時の取りこぼしを防ぐ。復元待ちが残っていれば同期的に戻す（Issue #79）。
    static func restorePendingClipboard() {
        shared.restorePendingClipboard()
    }

    // MARK: - 挿入

    /// 直前の挿入。`insert` はこれを待ってから始める。**クリップボードの復元が終わるまで**を含む。
    ///
    /// 挿入は settle/recheck の待ち（0.35〜0.8 秒）を挟むので、その間に別の挿入が入ると
    /// クリップボードと `pendingRestore` を取り合って貼る内容が入れ替わる。
    /// 呼び出し元は録音パイプラインだけでなく HUD・履歴の再挿入もあるので、入口で直列化する（Issue #99）。
    ///
    /// 判定が出た時点で次へ進めていた頃は、遅らせた復元より先に次の挿入が始まり、
    /// 前の口述文を「元の内容」として退避していた。続けて口述すると、ユーザーのコピーが消えて
    /// 口述文が残った（Issue #105）。呼び出し側へは判定が出た時点で返し、次の挿入だけを待たせる。
    private var lastInsertion: Task<Void, Never>?

    /// 挿入 1 回ぶんの結果と、それが予約した復元。
    private struct Attempt {
        let outcome: InsertionOutcome
        let restore: Task<Void, Never>?
    }

    func insert(_ text: String, expectedTarget: InsertionTarget? = nil) async -> InsertionOutcome {
        let previous = lastInsertion
        let current = Task { @MainActor in
            await previous?.value
            return await performInsert(text, expectedTarget: expectedTarget)
        }
        lastInsertion = Task { await current.value.restore?.value }
        return await current.value.outcome
    }

    /// 予約済みの復元まで含めて、いまある挿入が全部終わるのを待つ（テストが固定の待ちを使わないため）。
    func waitUntilIdle() async {
        await lastInsertion?.value
    }

    private func performInsert(_ text: String, expectedTarget: InsertionTarget?) async -> Attempt {
        guard !text.isEmpty else { return Attempt(outcome: .succeeded, restore: nil) }

        let keepResult = environment.keepResultOnFailure()

        // 録音を止めた場所と違うところへ貼らない（Issue #80 / #107）。
        //
        // 文字起こしと整形に数秒かかる間にアプリを切り替えると、⌘V はその時点の前面へ飛ぶ。
        // しかも before / after は両方その新しい要素なので `CFEqual` が一致し、文字数も
        // 増えるので **「成功」と判定されて誤爆が検知されなかった**。
        if let expectedTarget,
           let reason = InsertionTarget.mismatchReason(expected: expectedTarget,
                                                       current: environment.currentTarget()) {
            // 移った先がパスワード欄なら、クリップボードにも残さない（Issue #104 と同じ理由）。
            if keepResult, environment.secureInputReason() == nil {
                write(text, purpose: .injection)
            }
            return Attempt(outcome: .failed(reason: reason), restore: nil)
        }

        guard environment.isAccessibilityTrusted() else {
            // CGEvent の送出自体ができない。結果だけでも拾えるようにしてから返す。
            if keepResult {
                write(text, purpose: .injection)
            }
            return Attempt(outcome: .failed(reason: "アクセシビリティ権限が無いため入力できません",
                                            hint: .accessibilityPermission),
                           restore: nil)
        }

        // パスワード欄・Secure Keyboard Entry 中は送出そのものが届かない（Issue #104）。
        // **`FocusSnapshot.capture()` より前に見る。** 安全なテキスト欄は文字数も caret も
        // 返さないので capture は nil になり、そこからでは「読めないだけ」と区別できない。
        //
        // **この経路だけはクリップボードに残さない。** 残すと、パスワードを入れようとしている
        // 場所の隣に口述文が置かれ、次の ⌘V で意図しない場所へ貼られる。
        // 結果は履歴に残り、HUD からコピーもできるので失われはしない。
        if let reason = environment.secureInputReason() {
            return Attempt(outcome: .failed(reason: reason, hint: .secureInput), restore: nil)
        }

        // **全 type** を退避する。プレーンテキストだけを覚えていると、スクショ・ファイル・
        // 書式付きテキストを戻せず、復元のつもりでクリップボードを空にする（Issue #79）。
        let previous = PasteboardSnapshot.capture(environment.pasteboard)
        // 自分が書いた変化を changeCount で覚える。復元の直前に比べて、その間に
        // **ユーザーが**コピーした分は踏み潰さない（Issue #63 の抑止を Issue #79 で作り直したもの）。
        let writtenChangeCount = write(text, purpose: .injection)
        // 判定を待つ間（0.35〜0.8 秒）に終了しても戻せるよう、書いた直後から控える。
        pendingRestore = (previous, writtenChangeCount)

        let outcome = await environment.deliver(text)

        // **クリップボードに残すのは「本当に失敗した」ときだけ**（Issue #143）。
        //
        // 以前は「成功と確認できたとき以外」は残していたが、主戦場のターミナルは
        // Accessibility が文字数も caret も返さないので判定は必ず `.uncertain` になる。
        // 実測 411 件のうち `.succeeded` は 2 件で、**99.5% が復元されない経路を通っていた**
        // ——つまり口述のたびに直前のコピーが失われ、発話内容がクリップボードに残り続けていた。
        //
        // `.uncertain` は「送出は済んだ・確認手段が無いだけ」なので、貼れている可能性の方が
        // 高い。結果は履歴に必ず残るので、クリップボードは戻す方が損が小さい。
        guard !outcome.isFailure || !keepResult else {
            pendingRestore = nil
            return Attempt(outcome: outcome, restore: nil)
        }
        let restore = scheduleClipboardRestore(previous: previous, writtenChangeCount: writtenChangeCount)
        return Attempt(outcome: outcome, restore: restore)
    }

    // MARK: - クリップボード

    /// クリップボードに置く目的。**立てる目印が変わる**（Issue #105）。
    private enum WritePurpose {
        /// ⌘V で貼るための一時的な置き場。ユーザーはコピーしたつもりが無い。
        case injection
        /// ユーザーが「コピー」を押した。
        case userCopy
    }

    /// 結果をクリップボードへ書く。
    ///
    /// **機密の目印を立てる**ので、Maccy / Raycast / Paste のような常駐クリップボード
    /// マネージャの DB に口述テキストが溜まらない。「音声を外部に出さない」と掲げながら
    /// テキストが別アプリの永続ストアへ流れているのは筋が通らない（Issue #79）。
    ///
    /// nspasteboard.org の取り決めでは 3 つの意味が別々（Issue #105）:
    ///   - `Concealed` — 中身が機密。**記録はするが伏字**にするマネージャがある
    ///   - `Transient` — 一時的。**履歴に記録しない**
    ///   - `AutoGenerated` — ユーザーの Copy ではない
    ///
    /// 挿入用は 3 つとも立てて `source` に自分の bundle ID を入れる。`Concealed` だけだと
    /// 「記録はする」マネージャに残ってしまい、目的（残さない）を果たせない。
    @discardableResult
    private func write(_ text: String, purpose: WritePurpose) -> Int {
        let pasteboard = environment.pasteboard
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: PasteboardPrivacy.concealed)
        if purpose == .injection {
            item.setString("", forType: PasteboardPrivacy.transient)
            item.setString("", forType: PasteboardPrivacy.autoGenerated)
            item.setString(PasteboardPrivacy.sourceValue, forType: PasteboardPrivacy.source)
        }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// 復元待ちのスナップショット。終了・クラッシュで口述テキストをクリップボードに
    /// 置き去りにしないため、`restorePendingClipboard()` から同期的に戻せるよう控えておく。
    private var pendingRestore: (snapshot: PasteboardSnapshot, changeCount: Int)?

    /// 復元までの間に他アプリ/ユーザーがクリップボードを書き換えていたら
    /// （changeCount が変化）、その内容を踏み潰さないよう復元しない。
    /// `pendingRestore` は書き込んだ直後に `performInsert` が控えてある。
    private func scheduleClipboardRestore(previous: PasteboardSnapshot, writtenChangeCount: Int) -> Task<Void, Never> {
        let delay = environment.restoreDelay
        return Task { @MainActor in
            try? await Task.sleep(for: delay)
            restoreClipboard(previous, writtenChangeCount: writtenChangeCount)
        }
    }

    /// 復元待ちがあれば、いまここで戻す（終了時）。
    func restorePendingClipboard() {
        guard let pending = pendingRestore else { return }
        restoreClipboard(pending.snapshot, writtenChangeCount: pending.changeCount)
    }

    private func restoreClipboard(_ snapshot: PasteboardSnapshot, writtenChangeCount: Int) {
        pendingRestore = nil
        let pasteboard = environment.pasteboard
        guard pasteboard.changeCount == writtenChangeCount else { return }
        // ここに置かれているのは自分の口述文なので、元が空なら消すのが「戻す」こと。
        // 残すと、次の挿入がそれを「元の内容」として退避して書き戻してしまう（Issue #105）。
        if snapshot.isEmpty {
            pasteboard.clearContents()
        } else {
            snapshot.restore(to: pasteboard)
        }
    }
}

// MARK: - 本物の環境

extension TextInjector.Environment {
    /// アプリが使う本物。`NSPasteboard.general`・AX・CGEvent に触れる。
    static var live: TextInjector.Environment {
        TextInjector.Environment(
            pasteboard: .general,
            currentTarget: {
                // sarari 自身も除かない。止めた時点が基準なので、設定画面で止めたら設定画面が挿入先
                // （HUD は `.nonactivatingPanel` なので、HUD の停止ボタンでは前面にならない）。
                guard let app = NSWorkspace.shared.frontmostApplication
                else { return InsertionTarget(bundleId: nil) }
                let focus = FocusSnapshot.focus(of: app.processIdentifier)
                // バンドル ID の無いアプリ（素の実行ファイル等）は pid で見分ける。
                return InsertionTarget(bundleId: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                       window: focus.window,
                                       element: focus.element)
            },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            secureInputReason: { FocusSnapshot.secureInputReason() },
            deliver: { text in await LivePaste.deliver(text) },
            keepResultOnFailure: { SettingsStore.shared.keepResultOnClipboardWhenUnsure },
            // ⌘V から復元まで、判定の待ち（`LivePaste` の 350ms＋見直しの 450ms）に足して 250ms。
            // 合計 0.6 秒以上あけるのは、挿入先が ⌘V を処理して読む前に戻すと、元の内容が貼られるため。
            restoreDelay: .milliseconds(250)
        )
    }
}

/// 本物の ⌘V 送出と、挿入先の変化による成否判定。
@MainActor
private enum LivePaste {
    /// ペーストが挿入先に反映されるのを待つ時間。
    private static let settleDelay: Duration = .milliseconds(350)

    static func deliver(_ text: String) async -> InsertionOutcome {
        let before = FocusSnapshot.capture()
        postPaste()
        return await verifyAfterSettle(text: text, before: before)
    }

    // MARK: - イベント送出

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode = keyCode(for: "v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// いまのキーボード配列でその文字を打つ仮想キーコード。引けなければ nil。
    ///
    /// キーコードは**物理キーの位置**なので、9 が 'v' になるのは QWERTY 系のときだけ。
    /// Dvorak ではその位置が 'K' で、⌘V のつもりで **⌘K** を送ることになる
    /// （Slack ならジャンプダイアログ、エディタなら行削除やリンク挿入）。
    /// 貼られないだけでなく破壊的な操作が走るので、配列から引き直す（Issue #80）。
    /// JIS 配列は英字のキーコードが ANSI と同じなので、これまでも問題は出ていなかった。
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(LMGetKbdType())

            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length == 1,
                      let scalar = UnicodeScalar(chars[0]),
                      Character(scalar) == character
                else { continue }
                return CGKeyCode(code)
            }
            return nil
        }
    }

    // MARK: - 成否判定

    /// 反映が遅いアプリのために、「変化なし」だったときだけ追加で待って見直す時間。
    private static let recheckDelay: Duration = .milliseconds(450)

    /// 送出が落ち着くのを待ってから挿入前後を見比べる。
    ///
    /// 直後に「変化なし」でも、描画や AX の更新が遅いだけのアプリがある（ターミナル等）。
    /// 一度だけ待ち直して再確認し、それでも変化が無ければ **`.failed` ではなく `.uncertain`** を返す
    /// （Issue #43）。「変化を報告しない」と「受け付けなかった」は AX からは区別できないので、
    /// 警告色で断定しない（Issue #34 と同じ方針）。結果はクリップボード・履歴に残る。
    private static func verifyAfterSettle(text: String, before: FocusSnapshot?) async -> InsertionOutcome {
        try? await Task.sleep(for: settleDelay)
        var verdict = verify(text: text, before: before, after: FocusSnapshot.capture())
        if case .unchanged = verdict {
            try? await Task.sleep(for: recheckDelay)
            verdict = verify(text: text, before: before, after: FocusSnapshot.capture())
        }
        switch verdict {
        case .succeeded:              return .succeeded
        case .unchanged:              return .uncertain(detail: "入力先が変化を報告しませんでした")
        case .uncertain(let detail):  return .uncertain(detail: detail)
        }
    }

    /// `verify` の生の判定。`unchanged` は「文字数も caret も動かなかった」という観測で、
    /// それを失敗と呼ぶかは呼び出し側（`verifyAfterSettle`）が決める。
    private enum Verification {
        case succeeded
        case unchanged
        case uncertain(detail: String)
    }

    /// 挿入前後のフォーカス要素を見比べる。
    ///
    /// **限界**: Accessibility でテキスト長も caret も読めないアプリ（多くの Electron 製アプリ、
    /// 一部のターミナル、Canvas 描画のエディタ）では判定できない。その場合は `.uncertain` を返し、
    /// 「挿入できたことにしない」側に倒す。
    private static func verify(text: String, before: FocusSnapshot?, after: FocusSnapshot?) -> Verification {
        guard let before, let after else {
            return .uncertain(detail: "このアプリでは結果を確認できません")
        }
        guard CFEqual(before.element, after.element) else {
            return .uncertain(detail: "入力先が変わったため結果を確認できません")
        }

        let selectionLength = before.selectionLength ?? 0

        if let old = before.characterCount, let new = after.characterCount {
            // 選択範囲は置き換わるので、その分を差し引いた長さが基準。
            let base = old - selectionLength
            if new > base {
                // **増えた量が挿入しようとした量と釣り合うときだけ**成功と断定する（Issue #80）。
                // 「増えた＝成功」にしていたので、ターミナルで出力が流れている最中に口述すると
                // ペーストの有無に関係なく文字数が増えて `.succeeded` になり、クリップボードも
                // 復元され、HUD も成功表示で閉じていた（実際には貼られていない）。
                //   下限: アプリ側の整形（改行の正規化）で多少縮むことがあるので半分まで許す
                //   上限: 自律的にテキストが伸びるアプリを弾く
                let delta = new - base
                let expected = text.utf16.count
                if delta * 2 >= expected, delta <= expected * 4 + 32 { return .succeeded }
                return .uncertain(detail: "入力先の変化が挿入内容と一致しません")
            }
            if new == old, before.caret == after.caret { return .unchanged }
            return .uncertain(detail: "結果を確認できません")
        }

        if let oldCaret = before.caret, let newCaret = after.caret {
            if newCaret > oldCaret { return .succeeded }
            return .unchanged
        }

        return .uncertain(detail: "このアプリでは結果を確認できません")
    }
}

// MARK: - フォーカス要素のスナップショット

/// 挿入前後で比較するための、フォーカス中テキスト要素の状態。
///
/// 文字数は `AXNumberOfCharacters` を優先して読む（長文の `AXValue` を丸ごとコピーすると
/// 大きな書類で無駄に重い）。読めないときだけ `AXValue` の文字列長にフォールバックする。
private struct FocusSnapshot {
    let element: AXUIElement
    let characterCount: Int?
    let caret: Int?
    let selectionLength: Int?

    @MainActor
    static func capture() -> FocusSnapshot? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let element = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)

        var count: Int?
        if let number = copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber {
            count = number.intValue
        } else if let value = copyAttribute(element, kAXValueAttribute) as? String {
            count = value.utf16.count
        }

        var caret: Int?
        var selectionLength: Int?
        if let rangeValue = axValue(element, kAXSelectedTextRangeAttribute),
           AXValueGetType(rangeValue) == .cfRange {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                caret = range.location
                selectionLength = range.length
            }
        }

        guard count != nil || caret != nil else { return nil }
        return FocusSnapshot(element: element,
                             characterCount: count,
                             caret: caret,
                             selectionLength: selectionLength)
    }

    /// そのアプリの前面の窓と、フォーカスのある要素。読めなければ nil（Issue #107）。
    ///
    /// 権限が無い・応答しないアプリでは nil になる。比べる側（`InsertionTarget.mismatchReason`）は
    /// 読めたものだけを比べるので、nil でも挿入は止まらない。
    @MainActor
    static func focus(of pid: pid_t) -> (window: AXUIElement?, element: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return (element(app, kAXFocusedWindowAttribute), element(app, kAXFocusedUIElementAttribute))
    }

    /// 挿入してはいけない状態なら、その理由。挿入してよいなら nil。
    ///
    /// 2 つを見る（TN2150 / `swift-macos.md` §4）:
    ///   1. `IsSecureEventInputEnabled()` — Terminal の Secure Keyboard Entry など。
    ///      **システム全体で合成入力が届かなくなる**ので、前面アプリを問わず止める
    ///   2. focused element の subrole が `AXSecureTextField` — パスワード欄
    ///
    /// どちらも「送っても届かない」だけでなく、**届いてしまったらパスワード欄に口述文が入る**。
    /// 送る前に止めるのが唯一の正解。
    @MainActor
    static func secureInputReason() -> String? {
        if IsSecureEventInputEnabled() {
            return "Secure Keyboard Entry が有効なため入力できません"
        }
        if isFocusedElementSecure() {
            return "パスワード欄には入力しません"
        }
        return nil
    }

    /// フォーカス中の要素がパスワード欄か。読めなければ false（普通の欄として扱う）。
    @MainActor
    private static func isFocusedElementSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return false }
        AXUIElementSetMessagingTimeout(focused, timeout)
        guard let subrole = copyAttribute(focused, kAXSubroleAttribute) as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// AX の同期 IPC で固まらないよう、応答待ちを打ち切る秒数。
    private static let timeout: Float = 0.25

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    /// CF の型は `as?` が常に成功してしまうので、TypeID で確かめてから渡す。
    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}
