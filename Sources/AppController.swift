import AppKit
import os

/// 全体のオーケストレーション:
///   権限確認 → モデルロード → ホットキー登録 →
///   右⌥トグルで録音開始 / 停止→文字起こし→挿入。
@MainActor
final class AppController {
    static let shared = AppController()

    private let recorder = AudioRecorder()
    private let hotkeys = HotKeyManager()
    private let hud = RecordingHUDController()
    /// 録音中に画面の縁を光らせる（Issue #48）。状態は自分で AppState から拾う。
    private let edgeGlow = EdgeGlowController()
    private let state = AppState.shared

    /// 録音を始めた時点の最前面アプリ。挿入直前の照合に使う（Issue #80）。
    ///
    /// **挿入先は録音開始時に確定させる**。停止時に取り直すと、喋っている間に
    /// アプリを切り替えただけで別のアプリへ貼ってしまう。
    private var pendingBundleId: String?

    /// アクセシビリティ権限が付くのを見張るタイマー（Issue #78）。許可を検知したら止める。
    private var accessibilityTimer: Timer?

    /// 録音中にオーディオデバイスの構成が変わったか（Issue #77）。
    /// 変わった時点でエンジンは止まり、以降の発話はサンプルに入らないので、
    /// 「途中までで処理した」ことを結果表示に必ず出す。停止処理で読んで false に戻す。
    private var audioDeviceChangedDuringRecording = false
    /// 録音が上限（`RecordingLimit.maxDuration`）に達して止めたか（Issue #17）。
    /// 止め忘れた録音は挿入しない。停止処理で読んで false に戻す。
    private var recordingLimitReached = false
    /// 上限で録音を止めるタスク。停止・破棄のたびに外す（前の録音のタイマーが次の録音を止めないため）。
    private var recordingLimitTask: Task<Void, Never>?
    /// 追い越しの判定と、見せ損ねた結果の退避（Issue #97 / #100）。
    /// 判定そのものは `PipelineGuard` に閉じていて、AppKit 無しで単体テストできる（Issue #102）。
    private var guardState = PipelineGuard()

    /// 直前に停止した発話のパイプライン。挿入の前にこれを待って、発話順に貼る（Issue #99）。
    ///
    /// 文字起こし・整形は並行してよいが、貼る順番は発話順でないと文が入れ替わる。
    /// 停止時（同期部）にここから取るので順序は停止順に決まる。挿入そのものの
    /// 取り合い（クリップボード）は `TextInjector.insert` 側で全呼び出し元をまとめて直列化する。
    private var lastPipeline: Task<Void, Never>?

    // MARK: - エンジン（Issue #27）

    /// 実装は差し替え可能で、**いったん作ったものは使い回す**。
    /// 切り替えのたびに作り直すと WhisperKit のモデルを毎回ダウンロード判定からやり直すことになる。
    ///
    /// Apple 実装は `@available(macOS 26.0, *)` なので型を直接書けない。
    /// プロトコル型で持ち、生成だけを `#available` の中で行う。
    private let whisperTranscriber = Transcriber()
    private var appleTranscriber: (any SpeechEngine)?

    private init() {}

    /// 設定で選ばれている音声認識エンジン。この環境で使えないときは nil。
    private func resolveSpeechEngine() -> (kind: SpeechEngineKind, engine: any SpeechEngine)? {
        let kind = SettingsStore.shared.speechEngine
        switch kind {
        case .whisperKit:
            return (kind, whisperTranscriber)
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            let engine = appleTranscriber ?? AppleTranscriber()
            appleTranscriber = engine
            return (kind, engine)
        }
    }

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        state.update(.loadingModel(step: "権限を確認中…"))
        await PermissionsManager.ensureMicrophone()
        PermissionsManager.promptAccessibilityIfNeeded()

        // ホットキーはモデルの読み込みを待たずに張る。macOS 26 未満では既定が
        // WhisperKit に落ちるので、待つと約630MB のダウンロードのあいだずっと
        // 右⌥ が無反応になる（Issue #78）。
        hotkeys.onToggle = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotkeys.start()

        await reloadSpeechEngine()

        // 権限が無いとグローバル監視は一度も発火しない。「待機中」と出したまま
        // 永久に効かない状態を作らず、許可されるまで見張る（Issue #78）。
        updateAccessibilityState()

        // 保存先を 0700 で用意し、保存期間の掃除を定期的に回す。起動時にしか掃除して
        // いなかったので、常駐したままだと「7日」と表示しながら消えなかった（Issue #81）。
        HistoryStore.shared.start()

        // 録音レベルは HUD の波形と縁の光にだけ流す（AppState を毎フレーム更新しない）。
        recorder.onLevel = { [hud, edgeGlow] level in
            Task { @MainActor in
                hud.push(level: level)
                edgeGlow.push(level: level)
            }
        }
        // 録音中に AirPods が繋がる／USB マイクを抜くと AVAudioEngine が止まり、
        // 以降の音が入らない。黙って欠けたまま挿入しないよう、その場で締める（Issue #77）。
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleAudioConfigurationChange() }
        }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
        hud.onResultDismissed = { [weak self] in self?.presentNextDeferredIfIdle() }

        // 整形モデルは WhisperKit の**後**に、録音を待たせずに積む。
        // 数GB のダウンロードが走りうるので、ここを await すると起動が止まる。
    }

    // MARK: - 録音 HUD

    /// 設定で HUD の表示位置・表示サイズを変えたときに、表示中の HUD へ即座に反映する（Issue #35）。
    /// `positionChanged` が true のときだけ置き直す（サイズ変更ではドラッグ位置を保つ。Issue #57）。
    func refreshHUDLayout(positionChanged: Bool) {
        hud.applyLayout(positionChanged: positionChanged)
    }

    // MARK: - 音声認識エンジン

    /// 設定で選ばれている音声認識エンジンを読み込み直す（起動時とエンジン切り替え時）。
    ///
    /// 切り替え時は**使わない方を必ず降ろす**。両方載せたままだと、この Issue で測りたい
    /// 常駐メモリが比較できなくなる。
    func loadSpeechEngine() {
        Task { await reloadSpeechEngine() }
    }

    private func reloadSpeechEngine() async {
        // 録音中・文字起こし中に載せ替えると、マイクが開いたまま状態だけが上書きされて
        // 録音を止める手段が無くなり、次の録音でクラッシュする（Issue #77）。
        // 裏で動く追い越されたパイプラインも数に入れる（Issue #101）。
        // UI 側でも切り替えを無効にしてあるが、経路を 1 つに絞れないのでここでも守る。
        guard state.canSwitchEngine else {
            Log.asr.notice("録音・処理中のため音声認識エンジンの切り替えを見送りました")
            return
        }

        guard let (kind, engine) = resolveSpeechEngine() else {
            state.update(.failed(reason: "Apple 音声認識には \(EngineSupport.requiresMacOS26)"))
            return
        }

        // WhisperKit は初回に約630MB を取りに行く。「読み込み中」とだけ出すと
        // 回線次第で数十分固まったように見える（Issue #83）。
        let isDownloading = kind == .whisperKit && !Transcriber.hasCachedModel
        state.update(.loadingModel(
            step: isDownloading
                ? "音声認識モデルをダウンロード中…（約630MB）"
                : "音声認識モデルを読み込み中…"
        ))

        // 選ばれなかった方を降ろす（WhisperKit ならモデルぶんのメモリが返る）。
        if kind != .whisperKit { await whisperTranscriber.unload() }
        if kind != .apple, let appleTranscriber { await appleTranscriber.unload() }

        do {
            try await engine.load()
            state.update(.idle)
        } catch {
            // WhisperKit の modelsUnavailable は生のまま出すと「Model file not found at
            // .../MelSpectrogram.mlmodelc」で、何をすればいいか分からない（Issue #83）。
            let reason = isDownloading
                ? "音声認識モデルを取得できませんでした（ネットワークと空き容量を確認してください）"
                : "モデル読込失敗: \(error.localizedDescription)"
            Log.asr.error("音声認識モデルを読み込めませんでした: \(error.localizedDescription)")
            state.update(.failed(reason: reason))
        }
    }

    private func toggleRecording() {
        if state.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // 読込中は始めない。処理中は始めてよい（Issue #97）。先行パイプラインの完了処理が
        // この録音の状態・HUD を潰さないことは、世代番号で守る（Issue #57 H3 の再来を防ぐ）。
        guard state.status.canStartRecording else { return }
        let generation = guardState.begin()
        do {
            // 挿入先は録音開始の**前**に控える。NSWorkspace だけなので AX 権限も要らず軽い。
            pendingBundleId = TextInjector.frontmostBundleId()

            try recorder.start()
            state.update(.recording)
            scheduleRecordingLimit(generation: generation)
            // 表示サイズ（非表示/最小/通常）の判断は HUD 側に一本化してある。
            hud.show()
            let start = SettingsStore.shared.startSound
            // 起動音はマイクが録っている最中に鳴る。その分を棒に見せない（Issue #186）。
            // 録音・文字起こしには触らない。
            hud.ignoreLevels(forSoundOf: SoundPlayer.play(start))
        } catch {
            state.update(.failed(reason: "録音開始失敗: \(error.localizedDescription)"))
        }
    }

    /// 録音を止めて、この発話ぶんのパイプラインを起動する。
    ///
    /// **ここは同期のまま短く保つ。** 挿入の順番待ち（`previousPipeline`）は同期部で並ばないと、
    /// 文字起こしの `await` を挟んだ後に並ぶことになり発話順が入れ替わる（Issue #99）。
    private func stopRecording() {
        guard state.isRecording else { return }
        state.update(.processing)

        let generation = guardState.generation
        let expectedBundleId = takePendingBundleId()
        SoundPlayer.play(SettingsStore.shared.stopSound)
        let samples = recorder.stop()
        // ここで読んで戻す（この録音ぶんの事情なので、次の録音へ持ち越さない）。
        let deviceChanged = audioDeviceChangedDuringRecording
        audioDeviceChangedDuringRecording = false
        let limitReached = recordingLimitReached
        recordingLimitReached = false
        cancelRecordingLimit()

        // **ユーザーが待つ実時間**をここから測る（Issue #107）。履歴の `durations` は
        // 処理ごとの内訳だが、こちらは挿入の順番待ちも含む「押してから入るまで」。
        let signpost = Log.signposter.beginInterval("dictation", id: Log.signposter.makeSignpostID())

        let previousPipeline = lastPipeline
        state.pipelineStarted()
        lastPipeline = Task { @MainActor in
            // どの経路で抜けても進行中の数を戻す（次の発話の挿入待ちは Task の完了で解ける）。
            defer {
                state.pipelineFinished()
                Log.signposter.endInterval("dictation", signpost)
            }
            await runPipeline(samples: samples,
                              expectedBundleId: expectedBundleId,
                              deviceChanged: deviceChanged,
                              limitReached: limitReached,
                              generation: generation,
                              after: previousPipeline)
        }
    }

    /// 文字起こし → 挿入 → 表示 → 履歴。**例外を外に出さない**（発話を失わないため）。
    ///
    /// 文字起こしと後処理そのものは `DictationPipeline` に閉じている。ここに残すのは
    /// 「挿入する・見せる・残す」という副作用の側だけ。
    private func runPipeline(samples: [Float],
                             expectedBundleId: String?,
                             deviceChanged: Bool,
                             limitReached: Bool,
                             generation: Int,
                             after previousPipeline: Task<Void, Never>?) async {
        guard let (speechKind, speechEngine) = resolveSpeechEngine() else {
            state.update(.failed(reason: "Apple 音声認識には \(EngineSupport.requiresMacOS26)"))
            return
        }

        let output: DictationPipeline.Output
        do {
            // MainActor の設定を読むのはここまで。以降パイプラインは純関数として動く。
            output = try await DictationPipeline.run(
                samples: samples,
                engine: speechEngine,
                rules: ReplacementStore.shared.rules,
                fillers: SettingsStore.shared.fillerRemovalEnabled ? FillerStore.shared.list : nil
            )
        } catch {
            let status = AppStatus.failed(reason: "文字起こし失敗: \(error.localizedDescription)")
            switch guardState.fail(generation: generation, status: status) {
            case .superseded:
                // 次の録音に追い越された。その HUD を潰さず控えてある（Issue #97）。
                presentNextDeferredIfIdle()
            case .present:
                // 失敗は自動で閉じない。HUD に原因を残す。
                state.update(status)
            }
            return
        }

        let text = output.replacedText
        // 前の発話のパイプラインが終わるまで待つ。貼る順番を発話順に揃える（Issue #99）。
        await previousPipeline?.value
        // 挿入は成否を判定して返る。成功と確認できなければ結果を捨てない（Issue #13）。
        // 録音を始めたアプリと違うところへ貼らないよう、照合用に渡す（Issue #80）。
        // 上限で止めた録音は止め忘れの可能性が高いので、カーソルへは入れない（Issue #17）。
        let outcome: InsertionOutcome
        if text.isEmpty {
            outcome = .succeeded
        } else if limitReached {
            outcome = RecordingLimit.outcome
        } else {
            outcome = await TextInjector.insert(text, expectedBundleId: expectedBundleId)
        }
        let resultLocation = SettingsStore.shared.resultLocationDescription(isFailure:)
        // 見せ方（メニューバーの状態と HUD の動き）は 1 か所で導出する（Issue #64）。
        let presentation = InsertionPresentation.make(
            outcome: outcome,
            text: text,
            showResultPanel: SettingsStore.shared.showResultPanel,
            resultLocation: limitReached ? RecordingLimit.resultLocation(resultLocation) : resultLocation)

        let completion = guardState.finish(generation: generation,
                                           status: presentation.status,
                                           hud: presentation.hud,
                                           text: text,
                                           outcome: outcome)
        if case .present = completion {
            state.update(presentation.status)
            // 途中でデバイスが変わって音が欠けたことは、成功表示に紛れさせない（Issue #77）。
            // 失敗表示のときは原因の方が大事なので上書きしない。
            if deviceChanged, !presentation.status.isFailed {
                state.update(.warned(message: "録音デバイスが変わったため、切り替え前までの音声で処理しました"))
            }
        }

        // 履歴は挿入のあとにバックグラウンドで書き出す（保存が挿入を遅らせない）。
        // 無音だった発話は `record` 側で弾く（Issue #81）。
        HistoryStore.shared.record(
            rawText: output.rawText,
            replacedText: output.replacedText,
            // どのエンジンで処理したかを残す。これがエンジン比較（Issue #27）の一次データ。
            speechEngine: speechKind.rawValue,
            durations: output.durations,
            insertion: text.isEmpty
                ? nil
                : (limitReached ? HistoryEntry.Insertion.limited : HistoryEntry.Insertion(outcome))
        )

        guard case .present(let replay) = completion else {
            // 控えた結果は、待機中ならその場で出す（拾う機会が無くなるため）。
            presentNextDeferredIfIdle()
            return
        }
        // 追い越された前のパイプラインが結果を見せ損ねていれば、自分の完了表示の代わりに出す。
        // 自分も結果を残す表示なら自分を先に出し、控えた分は結果パネルを閉じたときに続けて出す。
        if let replay {
            showDeferred(replay)
            return
        }
        // 履歴を書き出してから HUD を動かす（完了表示を一瞬見せる／結果を残す／閉じる）。
        switch presentation.hud {
        case .finish:     hud.finish()
        case .keepResult: hud.presentResult(text, outcome: outcome)
        case .hide:       hud.hide()
        }
    }

    /// 録音開始時に控えた挿入先を取り出す。nil なら照合しない（開始時に取れなかった場合）。
    private func takePendingBundleId() -> String? {
        defer { pendingBundleId = nil }
        return pendingBundleId
    }

    /// 追い越されたパイプラインが見せ損ねた結果を出す（Issue #100）。
    /// 結果があれば結果パネルで残す。無ければ状態表示（失敗の原因）を HUD に前面で出す。
    /// HUD が閉じていても出す。閉じたまま状態だけ変えるとメニューバーの色しか変わらず原因が読めない。
    private func showDeferred(_ deferred: PipelineGuard.Deferred) {
        state.update(deferred.status)
        if let result = deferred.result {
            hud.presentResult(result.text, outcome: result.outcome, label: PipelineGuard.deferredLabel)
        } else {
            hud.presentStatus()
        }
    }

    /// 結果パネルが閉じられた。控えた結果が残っていれば次を出す（Issue #100）。
    /// 録音中・処理中なら出さない（その HUD を潰さない。完了時に拾われる）。
    private func presentNextDeferredIfIdle() {
        switch state.status {
        case .recording, .processing, .loadingModel: return
        case .idle, .done, .warned, .failed: break
        }
        guard let next = guardState.take() else { return }
        showDeferred(next)
    }

    /// 録音を破棄する。文字起こしも挿入も行わない（履歴にも残さない）。
    private func cancelRecording() {
        guard state.isRecording else { return }
        _ = recorder.stop()
        pendingBundleId = nil
        audioDeviceChangedDuringRecording = false
        recordingLimitReached = false
        cancelRecordingLimit()
        // 追い越された前の発話が結果を見せ損ねていれば、閉じる代わりにそれを出す（Issue #97）。
        if let deferred = guardState.take() {
            showDeferred(deferred)
            return
        }
        hud.hide()
        state.update(.idle)
    }

    /// アクセシビリティ権限の状態を UI に反映し、未許可なら許可されるまで見張る。
    ///
    /// グローバル監視は trusted でないと一度も発火しないので、起動時に張っただけでは
    /// 後から許可しても右⌥ が効かない。許可を検知したら張り直す（Issue #78）。
    private func updateAccessibilityState() {
        guard !PermissionsManager.isAccessibilityTrusted else {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            return
        }

        state.update(.failed(
            reason: "アクセシビリティ権限がありません（右⌥ が効きません）",
            hint: .accessibilityPermission
        ))

        guard accessibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppController.shared.pollAccessibility() }
        }
        timer.tolerance = 1
        // システム設定を触っている間もメニュー操作中も止めない。
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    /// 権限が付いたらホットキーを張り直す。張り直さないと監視は動き出さない。
    private func pollAccessibility() {
        guard PermissionsManager.isAccessibilityTrusted else { return }
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hotkeys.start()
        state.update(.idle)
        Log.hotkey.notice("アクセシビリティ権限を検知したのでホットキーを登録し直しました")
    }

    /// 録音の上限で止めるタスクを張る（Issue #17）。
    /// 世代番号を控え、発火した時点で別の録音に変わっていたら何もしない。
    private func scheduleRecordingLimit(generation: Int) {
        cancelRecordingLimit()
        recordingLimitTask = Task { [weak self] in
            try? await Task.sleep(for: RecordingLimit.maxDuration)
            guard !Task.isCancelled else { return }
            self?.handleRecordingLimit(generation: generation)
        }
    }

    private func cancelRecordingLimit() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
    }

    /// 録音が上限に達した。止め忘れの可能性が高いので、止めて文字起こしまで行い、挿入はしない。
    private func handleRecordingLimit(generation: Int) {
        guard state.isRecording, !guardState.isSuperseded(generation) else { return }
        Log.audio.notice("録音が上限に達したため止めます（挿入はしません）")
        recordingLimitReached = true
        stopRecording()
    }

    /// 録音中にオーディオデバイスの構成が変わった。AVAudioEngine は既に止まっていて
    /// 以降の音は入らないので、ここで締めて途中までの音声を処理する（Issue #77）。
    private func handleAudioConfigurationChange() {
        guard state.isRecording else { return }
        Log.audio.notice("録音中にオーディオデバイスが変わったため録音を終了します")
        audioDeviceChangedDuringRecording = true
        stopRecording()
    }
}
