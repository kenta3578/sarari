# ARCHITECTURE — sarari の作り

**この文書が答えること**: 右⌥を押してから文字が入るまでに何がどの順で起き、どのファイルがどこを担い、どこを触ると壊れるか。

Swift 33 ファイル・6,866 行（テスト 17 ファイル・130 ケース）。設計の**理由**は [design-rationale.md](design-rationale.md)、Swift の**記法**は [SWIFT-NOTES.md](SWIFT-NOTES.md)、使い方は [MANUAL.md](MANUAL.md) にある。ここは**構造**だけを扱う。

---

## 1. 処理の流れ

右⌥トグルの 1 往復。左が時間軸、右が担当ファイル。

```
起動
  sarariApp / AppDelegate         MenuBarExtra を出し、AppController.start() を呼ぶ
  AppController.bootstrap()       権限確認 → ホットキー登録 → エンジン読み込み → 履歴の掃除開始
                                  ※ ホットキーはモデルを待たずに張る（待つと数分間 右⌥ が無反応）

右⌥ 押下（1 回目）
  HotKeyManager                   CGEventTap で修飾キーだけを見て onToggle を呼ぶ
  AppController.startRecording()  世代番号を進める / 前面アプリの bundle ID を控える
  AudioRecorder.start()           AVAudioEngine の installTap。16kHz・mono・Float32 に変換して溜める
  RecordingHUDController.show()   HUD を出す（NSPanel）
  SoundPlayer.play(start)         開始音。鳴っている間ぶんは HUD のレベルを無視する
  ↓ 録音中は 20fps で音量が HUD にだけ流れる（AppState は更新しない）

右⌥ 押下（2 回目）
  AppController.stopRecording()   ここは同期のまま短く保つ（挿入の順番待ちに並ぶのが先）
  AudioRecorder.stop()            溜めたサンプルを返してタップを外す
  ↓ 以降は Task の中（AppController.runPipeline）

  DictationPipeline.run()         ← ここだけ AppKit も設定も触らない純関数
    ├ AppleTranscriber / Transcriber   文字起こし（Apple SpeechAnalyzer 既定 / WhisperKit 切替可）
    ├ ReplacementStore.apply()         辞書置換（**先**。フィラー除去が読みを削る前に当てる）
    └ FillerRemover.apply()            フィラー除去（設定 OFF なら丸ごと飛ばす）

  await previousPipeline          前の発話の挿入が終わるまで待つ（貼る順を発話順に揃える）
  TextInjector.insert()           前面アプリ照合 → 権限確認 → セキュア入力確認
                                  → ⌘V 合成（既定）か 1 文字ずつ送出 → **成否判定** → 復元判断
  InsertionPresentation.make()    結果を「メニューバーの状態」と「HUD の動き」に 1 回だけ翻訳
  PipelineGuard.finish()          自分が追い越されていないかを判定（後述）
  AppState.update()               メニューバーと HUD が同じ enum から描き直る
  HistoryStore.record()           挿入の**後**に非同期で書き出す（保存が挿入を遅らせない）
```

### この流れの 3 つの約束

| 約束 | どこで守るか | 破ると何が起きるか |
|---|---|---|
| **処理中でも次の録音を始めてよい** | `PipelineGuard` の世代番号 | 止めた直後の言い残しが録れない |
| **貼る順は発話順** | `stopRecording` の同期部で `previousPipeline` に並ぶ | 2 発話が入れ替わって挿入される |
| **成功と確信できたときだけ成功と言う** | `TextInjector.verify` | 貼れていないのに成功表示・クリップボード復元 |

---

## 2. ファイルの責務（33 ファイル）

### 起動と全体の制御

| ファイル | 行 | 役割 |
|---|---:|---|
| `sarariApp.swift` | 56 | `@main`。`MenuBarExtra` シーンと `AppDelegate`。テスト起動時は何も始めない |
| `AppController.swift` | 420 | **全体のオーケストレーション**。録音の開始/停止、パイプライン起動、状態と HUD と履歴への配線 |
| `AppState.swift` | 293 | `AppStatus`（7 状態）と、そこから導く色・記号・文言・メニューバー画像 |
| `PipelineGuard.swift` | 97 | 世代番号と、追い越されたパイプラインの結果を控えるキュー |
| `DictationPipeline.swift` | 64 | 音声サンプル → 挿入するテキスト。**AppKit・設定・状態に触れない**（テスト可能な芯） |
| `Log.swift` | 37 | 領域別の `os.Logger`（audio / asr / hotkey / history / store / inject）と signposter |

### 入力（ホットキーとマイク）

| ファイル | 行 | 役割 |
|---|---:|---|
| `HotKeyManager.swift` | 430 | `CGEventTap` で修飾キーを監視。左右の区別・合成イベントの除外・設定画面でのキー取得 |
| `RecordingLimit.swift` | 23 | 録音の上限（10 分）と、上限で止めた発話の見せ方。**止め忘れの保険**で、通常の発話は切らない |
| `AudioRecorder.swift` | 222 | `AVAudioEngine` の tap。16kHz 変換、RMS → 0〜1 のレベル、デバイス変更の検知 |
| `PermissionsManager.swift` | 82 | マイク / アクセシビリティ権限の要求と確認 |

### 認識と後処理

| ファイル | 行 | 役割 |
|---|---:|---|
| `Engines.swift` | 81 | `SpeechEngine` プロトコルと `SpeechEngineKind`（apple / whisperKit）。差し替えの境界 |
| `AppleTranscriber.swift` | 184 | Apple SpeechAnalyzer（macOS 26 以降・既定・DL 無し） |
| `Transcriber.swift` | 91 | WhisperKit large-v3-turbo（初回に約 630MB を取得） |
| `ModelIntegrity.swift` | 132 | WhisperKit の重みが開発時に確かめたものと同じかを SHA-256 で照合 |
| `Replacements.swift` | 140 | 辞書置換のルールと `~/sarari/replacements.json` の読み書き |
| `FillerRemover.swift` | 153 | フィラー語の決定的な除去（`~/sarari/fillers.json`）。語を足さず、数値・URL・英単語には触れない |
| `JSONFileSync.swift` | 140 | `replacements.json` / `fillers.json` の読み書きと、外での編集の監視・読み直し（外の編集を上書きしない） |

### 出力（挿入）

| ファイル | 行 | 役割 |
|---|---:|---|
| `TextInjector.swift` | 545 | **挿入の本体**。前面照合・セキュア入力回避・⌘V 合成・成否判定・クリップボード復元 |
| `Pasteboard.swift` | 69 | クリップボードの「機密・一時」目印（nspasteboard.org の慣習）と全 type のスナップショット |
| `InsertionPresentation.swift` | 63 | 挿入結果 → メニューバー状態 ＋ HUD の動き。**1 か所で導出**して二重分岐を防ぐ |

### 画面

| ファイル | 行 | 役割 |
|---|---:|---|
| `MenuContent.swift` | 39 | メニューバーのドロップダウン |
| `RecordingHUDController.swift` | 385 | HUD の状態遷移。「いま何を見せるか」（パネルは作り直さず使い回す） |
| `RecordingHUDPanel.swift` | 152 | HUD の `NSPanel` 生成・配置と、ホバー / Esc の監視。AppKit 側の面倒 |
| `RecordingHUDModel.swift` | 165 | HUD の表示モデル。20fps で更新されるので `AppState` とは分けてある |
| `RecordingHUDView.swift` | 380 | HUD の中身（SwiftUI）。最小表示の棒・時間・失敗・結果パネル |
| `HUDLayout.swift` | 65 | HUD の表示位置・表示サイズ（最小 / 非表示）の定義 |
| `SettingsView.swift` | 552 | 設定画面（タブ構成） |
| `SettingsWindow.swift` | 57 | 設定ウィンドウを自前の `NSWindow` で開く（SwiftUI の `Settings` は使えない） |
| `HistoryView.swift` | 430 | 履歴ウィンドウ。再挿入・コピー・辞書に登録・削除 |

### 保存

| ファイル | 行 | 役割 |
|---|---:|---|
| `SettingsStore.swift` | 455 | 設定の永続化（UserDefaults）と共有状態 |
| `HistoryStore.swift` | 440 | `~/sarari/history/<時刻>/meta.json`（音声は残さない）。保存期間の掃除 |
| `SoundPlayer.swift` | 200 | 開始音 / 停止音。同梱の sarari の音・`~/sarari/sounds/` の自分の音・システム音 |
| `LoginItem.swift` | 92 | ログイン時の自動起動（`SMAppService`。真偽値を自前で持たない） |

### ディスク上の置き場

```
~/sarari/
├── history/<yyyyMMdd'T'HHmmss.SSS'Z'>/   meta.json（生テキスト・置換後・所要時間・エンジン）  ※ 0700 で作る
├── replacements.json                    辞書置換ルール
├── fillers.json                         フィラー語
└── sounds/                              自分で入れた開始音・停止音（aiff / wav / mp3 / m4a / caf）
```

設定は UserDefaults（`com.kenta3578.koebun`）。**音声・テキストは端末外に出ない**（`Sources/` に通信 API のヒットが 0 件であることを README が根拠にしている）。

---

## 3. 状態機械

`AppStatus`（`AppState.swift`）は 7 つ。**メニューバーの記号・色・文言も、HUD の見た目も、すべてこの 1 つの enum から導出する**（文言とアイコンを別々に持つと二重管理になるため）。

| 状態 | 記号 | 色 | 意味 | 抜け方 |
|---|---|---|---|---|
| `loadingModel(step:)` | hourglass | 黄 | 起動〜権限確認〜モデル読み込み | 読み込み完了 → `idle` |
| `idle` | mic | なし（システム追従） | ホットキー待ち | 右⌥ → `recording` |
| `recording` | mic.fill | すみれ | 録音中 | 右⌥ / HUD の停止 → `processing`、Esc → `idle` |
| `processing` | waveform | 水色 | 文字起こし〜挿入 | 完了 → `done` / `warned` / `failed` |
| `done(message:)` | checkmark.circle.fill | 緑 | 挿入まで完了 | **1.5 秒**で `idle` |
| `warned(message:)` | exclamationmark.circle.fill | 黄 | 挿入は済んだが伝えることがある（録音デバイスが変わった等） | **5 秒**で `idle`（読む時間が要るので長い） |
| `failed(reason:hint:)` | exclamationmark.triangle.fill | 橙 | 失敗。`hint` が付くと HUD が設定画面へ飛ぶボタンを出す | **自動で戻らない**（原因を残す） |

遷移の判定は enum 自身が持つ。

- `canStartRecording` — `loadingModel` と `recording` 以外はすべて true。**`processing` でも true**（止めた直後の言い残しを録るため）
- `canSwitchEngine` — `recording` / `processing` では false。さらに `AppState.canSwitchEngine` が進行中パイプライン数も見る（裏で走っているパイプラインは状態に現れないため）
- `prefixed(_:)` — 追い越された結果を後から出すとき「以前の発話: 」を付ける。いま喋った内容の失敗と誤読させない

### UI 3 面への反映

| 面 | 読む値 | 更新の頻度 |
|---|---|---|
| メニューバー | `AppStatus`（`menuBarImage` / `menuText`） | 状態が変わったときだけ |
| HUD | `AppStatus` ＋ `RecordingHUDModel`（音量・経過時間） | 状態は都度、波形は 20fps |
| 設定 / 履歴ウィンドウ | `SettingsStore` / `HistoryStore`（`@Published`） | 変更時 |

**波形を `AppState` に流さない**のが要点。流すとメニューバーアイコンまで毎フレーム描き直される。

### 挿入結果の 3 値

`InsertionOutcome` は `succeeded` / `failed` / `uncertain`。`uncertain` は「送出は済んだが Accessibility が確認手段を返さない」で、ターミナルや Electron 製アプリでは**毎回**起きる。これを失敗色で描くと本物の失敗に気づけなくなるので、扱い（結果を捨てない）は同じまま**見せ方だけ分けている**。翻訳は `InsertionPresentation` の 1 か所。

---

## 4. 読む順番

初めて読むなら、この 5 つをこの順で。**挿入の判断（`TextInjector`）を最後に置くのは、そこが一番分量と例外が多く、前の 4 つを知っていないと「なぜここまで慎重か」が読めないから。**

| # | ファイル | 行 | なぜこの順か |
|---|---|---:|---|
| 1 | `sarariApp.swift` | 56 | 入口。常駐アプリの起動の形（`MenuBarExtra` ＋ `AppDelegate`）が 1 画面で分かる |
| 2 | `AppState.swift` | 293 | 7 状態を先に知ると、以降のコードが「どの状態を作っているか」で読める |
| 3 | `DictationPipeline.swift` | 64 | アプリの芯が 60 行に収まっている。ここだけ AppKit も設定も無い |
| 4 | `AppController.swift` | 420 | 1〜3 を配線している場所。`startRecording` → `stopRecording` → `runPipeline` を順に追う |
| 5 | `TextInjector.swift` | 545 | 判断量が最大。`performInsert` の早期 return を上から読むと、守っている条件が列挙できる |

余力があれば `PipelineGuard.swift`（97 行）。並行の約束がここに閉じているので、`Tests/PipelineGuardTests.swift` と並べて読むと動きが確かめられる。

---

## 5. 触ると危ない場所

`.claude/rules/` の 3 枚が、**踏んだ地雷をそのまま書いたもの**。該当ファイルを開くと自動で読み込まれる。

| ルール | 対象 | 何を守っているか |
|---|---|---|
| [`insertion-feedback.md`](../.claude/rules/insertion-feedback.md) | `TextInjector` / `RecordingHUD*` / `AppState` / `AppController` | 失敗と断定してよい条件。失敗表示が 2 面ある事情。`FailureHint` |
| [`permissions-tcc.md`](../.claude/rules/permissions-tcc.md) | `PermissionsManager` / `scripts` / `BUILD.md` | 署名と TCC。Bundle ID や署名 ID を変えると権限が全部飛ぶ |
| [`visual-check.md`](../.claude/rules/visual-check.md) | `AppState` / `RecordingHUD*` / `SettingsView` / `MenuContent` | 見た目の変更は実物を描き出して目視してから出す |

加えて、ルールになっていないが壊しやすいところ:

- **`AppStatus` に case を足す** — `symbolName` / `tintColor` / `menuText` / `canStartRecording` / `canSwitchEngine` / `showsBars` が全部 `switch` の網羅で書いてある（`default:` を置かないのは、足したときにコンパイラに漏れを指摘させるため）。`default:` を足すと、この安全網が消える
- **`stopRecording` に `await` を足す** — 挿入の順番待ちに並ぶ前に中断点が入ると、発話の順序が入れ替わる
- **`installTap` のブロックの中で UI や actor に触る** — 実時間スレッドなので、遅れるとその場で音が欠ける
- **`PipelineGuard` を経由せずに `state.update` を呼ぶ** — 追い越された古いパイプラインが、いまの録音の表示を上書きする

---

## 6. 並行性の地図

| 隔離 | 誰が | 備考 |
|---|---|---|
| `@MainActor` | `AppController` / `AppState` / `SettingsStore` / `TextInjector` / HUD 一式 | UI と状態はすべてメインに閉じる |
| 実時間スレッド | `AudioRecorder` の tap ブロック | `[Float]` にコピーして渡すだけ。`await` しない |
| 構造化されない `Task` | `runPipeline` | ハンドルを `lastPipeline` に保持し、次の発話が `await` する |
| 直列化 | `TextInjector.insert` | 入口で前の挿入を `await`（HUD・履歴からの再挿入も同じ口を通る） |

ビルド設定は `SWIFT_STRICT_CONCURRENCY: complete`。**警告 0 を保つ**のがこのリポジトリの決まりで、`@unchecked Sendable` を増やす代わりに `@MainActor` か actor に閉じる。

---

## 7. テスト

`Tests/` は **AppKit・実モデル・TCC に依存しない純 Swift のロジックだけ**を見る（130 ケース・実行 0.1 秒未満）。権限ダイアログもモデルのダウンロードも起きない（`AppDelegate` がテスト起動を検知して何も始めないため）。

```bash
xcodebuild test -project sarari.xcodeproj -scheme sarari \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

守備範囲の一覧は [`Tests/README.md`](../Tests/README.md)。**逆に、ここに無いもの**（TCC ダイアログ・グローバルホットキー・他アプリへの実挿入）は自動テストの対象外で、実機で手で確かめる。
