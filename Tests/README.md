# Tests

`sarariTests`（Swift Testing）。`xcodebuild test` はアプリを `TEST_HOST` として起動するが、
`AppDelegate` が XCTest 環境を検知して起動処理（権限・モデル・ホットキー）を走らせないので、
権限ダイアログもモデルのダウンロードも出ない。実行は 0.1 秒未満。

```bash
xcodebuild test -project sarari.xcodeproj -scheme sarari \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 守備範囲

AppKit の実画面・モデル・TCC に依存しない **純 Swift のロジック** だけを置く。

| ファイル | 対象 |
|---|---|
| `PipelineGuardTests` | 世代番号ガード（追い越し・退避キュー・replay。Issue #97 / #100） |
| `DictationPipelineTests` | 文字起こし → 辞書置換 → フィラー除去 の順序と計時（Issue #66。フェイクのエンジンと固定した時計で） |
| `InsertionPresentationTests` | 挿入結果 → メニューバー状態と HUD の動き（`.claude/rules/insertion-feedback.md`） |
| `RecordingLimitTests` | 録音の上限で止めた発話の見せ方（挿入しない・クリップボードを案内しない。Issue #17） |
| `TranscriberPathTests` | WhisperKit のモデルの保存先（書類フォルダに置かない・HubApi の並びに合わせる。Issue #23） |
| `HistoryEntryTests` | `meta.json` の互換。**整形系の列を持つ古い記録が読めること**（#128〜#131 で書く側だけ消した） |
| `FailureHintTests` | 失敗の手がかりの契約（ボタンを出す／出さない・状態まで運ばれるか） |
| `ResultRetentionTests` | 挿入できなかった結果の残し先。履歴が必ず含まれること・保存値の綴り |
| `ReplacementsTests` | 辞書置換の 1 パス最長一致。ルールファイルの取り込み（重複を飛ばす・壊れた JSON は足さない）と、配布する語彙セット（`presets/`）が一般の語を壊さないこと |
| `FillerRemoverTests` | フィラー除去。「残す」側（指示語・連語）を重点的に |
| `QuestionMarkerTests` | 疑問文の文末の？補完。付けすぎない側（かな・ません）も見る |
| `RuleImpactTests` | 辞書ルールを足したときの過去の発話への影響。誤爆が例に出るか |
| `RuleSuggesterTests` | 履歴からの辞書候補。別の語を候補にしない側を重点的に |
| `DataDirectoryTests` | 旧名の置き場 `~/koemakase`・`~/koebun` からの移行。新しい置き場があれば触らない。旧名が2つあれば新しい名前の方を移す |
| `PasteboardTests` | 全 type の退避と復元（名前付きペーストボードで隔離） |
| `PasteboardMarkerTests` | クリップボードに立てる目印。挿入用（4 つ）とユーザーのコピー（Concealed のみ）の違い |
| `HotKeyJudgeTests` | 修飾キーの左右区別・合成イベント・複数修飾キーの正規化 |
| `LevelBarsTests` | 最小表示の棒（7 本）。黙ると点、声で高くなり、文字起こし中は波形の形で止まる。音節の切れ目で潰れない |

## 普段は走らないもの

| ファイル | 対象 |
|---|---|
| `DocScreenshotsTests` | 説明書サイトの画面画像を描き出す（Issue #56）。`scripts/docs-shots.sh` が書き出し先と仮のホームを渡したときだけ走り、ふだんの `xcodebuild test` では飛ばされる |

## 置かないもの

- WhisperKit を読み込むもの（約 630MB の DL と数十秒のロード）。要るなら `.disabled` で常時実行から外す
- TCC ダイアログ・グローバルホットキー・他アプリへの挿入（XCUITest でも権限は自動化できない。実機で手動確認）
- 見た目（`.claude/rules/visual-check.md` の手順でスクリーンショット）

## 書き方

- `~/sarari/` のファイルを読み書きする `*.shared` シングルトンは使わず、`nonisolated static` な純関数を呼ぶ
- `@MainActor` に隔離された型を呼ぶスイートには `@MainActor` を付ける
- テスト名は日本語で「何を保証するか」を書く。失敗したときにそのまま Issue の見出しになる
- **消えた機能のテストは消す。** #128〜#131 で `FormatDiffTests` / `ModeTests` を削除した
