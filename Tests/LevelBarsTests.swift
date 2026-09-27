import Testing
import SwiftUI
@testable import sarari

/// 最小表示の «棒»（Issue #180、30 案の 14。#189 で 7 本、#191 で 10 本、#193 で 7 本へ）。
///
/// 読み取らせたいことは «声の大きさ» の 1 つだけ。動くのは届いた音量だけで、
/// 時間で勝手に動く要素は持たない（#146〜#176 で重ねて読めなくなり、#178 で戻した）。
@MainActor
struct LevelBarsTests {
    /// 0 にすると «消えた» に見える。棒の幅と同じ高さ＝点で残す。
    @Test("黙っているときは点になる")
    func silenceIsDots() {
        let heights = LevelBarsView.heights(level: 0, isProcessing: false)
        #expect(heights.count == LevelBarsView.voiceProfile.count)
        #expect(heights.allSatisfy { $0 == LevelBarsView.barWidth })
    }

    /// 実測で声の窓は p95 0.28（Issue #187）。大きめの声で形いっぱいになる。
    @Test("大きめの声で形いっぱいになる")
    func speechFillsTheProfile() {
        #expect(LevelBarsView.heights(level: LevelBarsView.fullLevel, isProcessing: false) == LevelBarsView.voiceProfile)
        #expect(LevelBarsView.heights(level: 1, isProcessing: false) == LevelBarsView.voiceProfile)
    }

    @Test("声が大きいほど高くなる")
    func louderIsTaller() {
        let quiet = LevelBarsView.heights(level: 0.15, isProcessing: false)
        let loud = LevelBarsView.heights(level: 0.45, isProcessing: false)
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
    }

    /// 並んだ棒を 1 つの «波形» として読ませるため、中央ほど高く左右対称。
    @Test("中央ほど高く、左右対称")
    func centerIsTallest() {
        for level: Float in [0.1, 0.2, 0.4] {
            let heights = LevelBarsView.heights(level: level, isProcessing: false)
            // 偶数本なら中央の 2 本、奇数本なら中央の 1 本がいちばん高い。
            #expect(heights[(heights.count - 1) / 2] == heights.max())
            #expect(heights[heights.count / 2] == heights.max())
            #expect(heights == Array(heights.reversed()))
        }
        let processing = LevelBarsView.processingProfile
        #expect(processing == Array(processing.reversed()))
    }

    /// 10 本は «やりすぎ» で 7 本へ戻した（Issue #193）。文字起こし中も同じ本数で、形だけ変わる。
    @Test("棒は 7 本で、文字起こし中も同じ本数")
    func barCountIsSeven() {
        #expect(LevelBarsView.voiceProfile.count == 7)
        #expect(LevelBarsView.processingProfile.count == LevelBarsView.voiceProfile.count)
    }

    /// 広げすぎると «余計な padding»（#191）、詰めすぎると «やりすぎ»（#193）、
    /// 大きすぎると «フォントが大きすぎる»（#195）。見た目の好みは値で決め、
    /// **テストで縛るのは «はみ出さない» ことだけ**にする。
    @Test("棒と経過時間が最小表示に収まる")
    func contentFitsTheMinimalBar() {
        // 経過時間（12pt・5 文字でおよそ 38pt）＋ 棒との間隔 6pt ＋ 左右の余白 12pt。
        let content = LevelBarsView.width + 6 + 38 + 24
        #expect(content <= HUDMetrics.minimalPanelSize.width)
        // ホバー時は停止・キャンセル（22pt ＋ 間隔 6pt が 2 つ）ぶん増える。
        #expect(content + (6 + 22) * 2 <= HUDMetrics.minimalHoverPanelSize.width)
    }

    /// 横 1.5 倍・縦 1.2 倍にしても、ホバー時の停止・キャンセルの余白は変えない（Issue #189）。
    @Test("ホバー時はボタンぶんだけ広く、高さは同じ")
    func hoverAddsOnlyButtonRoom() {
        #expect(HUDMetrics.minimalHoverPanelSize.width - HUDMetrics.minimalPanelSize.width == 60)
        #expect(HUDMetrics.minimalHoverPanelSize.height == HUDMetrics.minimalPanelSize.height)
    }

    /// 完了は棒を点に畳んで緑にするだけ。チェックは出さない（Issue #202）。
    @Test("完了では棒が点に畳まれる")
    func finishedCollapsesToDots() {
        let heights = LevelBarsView.heights(level: 0.3, isProcessing: false, isFinished: true)
        #expect(heights.allSatisfy { $0 == LevelBarsView.barWidth })
        #expect(heights.count == LevelBarsView.voiceProfile.count)
        // 緑になるので、くすませない。
        #expect(LevelBarsView.muting(level: 0.3, isProcessing: false, isFinished: true) == 0)
    }

    /// 3 状態は同じビューのまま繋ぐ（Issue #200）。どれを棒で見せるかはモデルが決める。
    @Test("棒で見せるのは録音中・文字起こし中・完了")
    func barsCoverTheThreeStates() {
        let model = RecordingHUDModel()
        model.status = .recording
        #expect(model.showsBars && !model.isTranscribing && !model.isFinished)
        model.status = .processing
        #expect(model.showsBars && model.isTranscribing && !model.isFinished)
        model.status = .done(message: "挿入しました ✓")
        #expect(model.showsBars && !model.isTranscribing && model.isFinished)
        model.status = .idle
        #expect(!model.showsBars && !model.isFinished)
    }

    /// 文字起こし中は «青く固まる»。声が残っていても形は変えない。
    @Test("文字起こし中は声に関係なく波形の形で止まる")
    func processingIsFixed() {
        #expect(LevelBarsView.heights(level: 0, isProcessing: true) == LevelBarsView.processingProfile)
        #expect(LevelBarsView.heights(level: 0.9, isProcessing: true) == LevelBarsView.processingProfile)
    }

    @Test("棒は最小表示の高さに収まる")
    func barsFitTheMinimalBar() {
        #expect(LevelBarsView.height <= HUDMetrics.minimalPanelSize.height - 8)
    }

    /// 黙っているときはくすんだ赤、喋るほど赤が冴える（Issue #182）。
    @Test("黙るとくすみ、喋るほど赤が冴える")
    func speechClearsTheMuting() {
        #expect(LevelBarsView.muting(level: 0, isProcessing: false) == LevelBarsView.quietMuting)
        #expect(LevelBarsView.muting(level: LevelBarsView.fullLevel, isProcessing: false) == 0)
        #expect(LevelBarsView.muting(level: 0.1, isProcessing: false)
                > LevelBarsView.muting(level: 0.25, isProcessing: false))
    }

    /// 差が弱いと読めない（Issue #184）が、灰まで落とすと «録音中» の赤が消える。
    @Test("黙っているときはしっかりくすむが、赤みは残る")
    func silenceIsMutedButStillRed() {
        #expect(LevelBarsView.quietMuting >= 0.7)
        #expect(LevelBarsView.quietMuting < 1)
    }

    /// 普段の声でくすんだままだと «差が弱い»（Issue #184）。色は高さより先に赤になりきる。
    /// 実測の普段の声（p50 0.16、Issue #187）でも赤になりきること。
    @Test("通常の発話で赤になりきる")
    func normalSpeechIsFullyRed() {
        #expect(LevelBarsView.colorFullLevel <= 0.3)
        #expect(LevelBarsView.colorFullLevel < LevelBarsView.fullLevel)
        #expect(LevelBarsView.muting(level: 0.3, isProcessing: false) == 0)
        #expect(LevelBarsView.muting(level: 0.16, isProcessing: false) == 0)
    }

    /// 環境音（窓の 64% が 0.05 未満、Issue #187）で棒が伸びたり赤くなったりしない。
    @Test("環境音では棒も色も動かない")
    func ambientNoiseMovesNothing() {
        let ambient = LevelBarsView.voiceFloor - 0.01
        #expect(LevelBarsView.heights(level: ambient, isProcessing: false).allSatisfy { $0 == LevelBarsView.barWidth })
        #expect(LevelBarsView.muting(level: ambient, isProcessing: false) == LevelBarsView.quietMuting)
    }

    /// 基準は想定ではなく実測から決める（Issue #187）。声の窓は p50 0.16 / p90 0.26 / p99 0.33。
    @Test("基準は実測の声の範囲に収まる")
    func thresholdsMatchMeasuredSpeech() {
        #expect(LevelBarsView.colorFullLevel <= 0.16)
        #expect(LevelBarsView.fullLevel >= 0.26 && LevelBarsView.fullLevel <= 0.33)
        #expect(LevelBarsView.voiceFloor < LevelBarsView.colorFullLevel)
    }

    /// 二択で切り替えるとチカチカする。色は音量から連続的に変わる。
    @Test("色は音量から連続的に変わる")
    func tintChangesContinuously() {
        let values = stride(from: Float(0), through: LevelBarsView.colorFullLevel, by: 0.005)
            .map { LevelBarsView.muting(level: $0, isProcessing: false) }
        let steps = zip(values, values.dropFirst()).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 >= 0 })      // 喋るほど減る
        #expect((steps.max() ?? 1) < 0.05)         // 一度に大きく跳ばない
    }

    @Test("文字起こし中の青はくすませない")
    func processingIsNotMuted() {
        #expect(LevelBarsView.muting(level: 0, isProcessing: true) == 0)
    }

    /// 起動音をマイクが拾う（Issue #186）。鳴っているあいだに届いた音量は棒に見せない。
    @Test("起動音のあいだに届いた音量は棒に出さない")
    func startSoundIsIgnored() {
        let model = RecordingHUDModel()
        let start = Date()
        model.ignoreLevels(until: start.addingTimeInterval(0.46))
        model.push(level: 0.46, now: start.addingTimeInterval(0.2))
        #expect(model.currentLevel == 0)
        model.push(level: 0.16, now: start.addingTimeInterval(0.6))
        #expect(model.currentLevel == 0.16)
    }

    /// 実測で起動音（0.21 秒）は最も遅いもので開始から 354ms 地点に終わっていた。
    @Test("無視する長さは実測の起動音の終わりを覆う")
    func ignoreWindowCoversMeasuredChime() {
        #expect(0.21 + RecordingHUDController.soundLatencyMargin >= 0.354)
    }

    /// 次の録音に持ち越さない。
    @Test("リセットすると無視は解ける")
    func resetClearsIgnore() {
        let model = RecordingHUDModel()
        model.ignoreLevels(until: Date().addingTimeInterval(60))
        model.reset()
        model.push(level: 0.2)
        #expect(model.currentLevel == 0.2)
    }

    /// 音量はアプリ中の «起動音を無視していない» 状態ではそのまま出る。
    @Test("無視していなければ届いた音量はそのまま出る")
    func levelsPassThroughWithoutIgnore() {
        let model = RecordingHUDModel()
        model.push(level: 0.2)
        #expect(model.currentLevel == 0.2)
    }

    /// 「通常」は削除した（Issue #6）。保存済みの値は「最小」として読む。
    @Test("保存済みの「通常」は「最小」に読み替える")
    func legacyNormalSizeBecomesMinimal() {
        #expect(HUDSize.fromStored("normal") == .minimal)
        #expect(HUDSize.fromStored("minimal") == .minimal)
        #expect(HUDSize.fromStored("hidden") == .hidden)
        #expect(HUDSize.fromStored("unknown") == nil)
        #expect(HUDSize.allCases == [.minimal, .hidden])
    }

    /// 細いバーに収まらないものだけ大きいパネルで出す。
    @Test("失敗・結果・キャンセル確認以外は細いバー")
    func onlyUnreadableStatesLeaveTheMinimalBar() {
        let model = RecordingHUDModel()
        for status: AppStatus in [.recording, .processing, .done(message: "挿入しました ✓"), .warned(message: "注意")] {
            model.status = status
            #expect(model.usesMinimalBar)
        }
        model.status = .failed(reason: "失敗")
        #expect(!model.usesMinimalBar)
        model.status = .recording
        model.isConfirmingCancel = true
        #expect(!model.usesMinimalBar)
    }

    /// 考えながら黙るたびに警告が出ると邪魔になる（Issue #6）。一度も拾っていないときだけ。
    @Test("一度も音を拾っていないときだけ «拾えていません» を出す")
    func silenceWarningOnlyWhenNothingWasHeard() {
        let model = RecordingHUDModel()
        model.status = .recording
        for _ in 0..<40 { model.push(level: 0) }
        #expect(model.showsSilenceWarning)

        model.reset()
        model.status = .recording
        model.push(level: 0.2)
        for _ in 0..<80 { model.push(level: 0) }
        #expect(!model.showsSilenceWarning)
    }

    @Test("録音を始めた直後は «拾えていません» を出さない")
    func silenceWarningWaitsForTheWindow() {
        let model = RecordingHUDModel()
        model.status = .recording
        for _ in 0..<10 { model.push(level: 0) }
        #expect(!model.showsSilenceWarning)
    }

    /// 音節の切れ目で点に潰れないよう、直近の数回分の最大を使う。窓を過ぎれば下がる。
    @Test("いまの音量は直近の数回分の最大")
    func currentLevelHoldsThroughSyllableGaps() {
        let model = RecordingHUDModel()
        model.push(level: 0.5)
        model.push(level: 0.05)
        #expect(model.currentLevel == 0.5)
        for _ in 0..<RecordingHUDModel.peakWindow { model.push(level: 0.05) }
        #expect(model.currentLevel == 0.05)
    }
}
