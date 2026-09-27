# Web の言葉で読む sarari（Swift / SwiftUI / macOS）

**想定読者**: Vue / Nuxt・React / Next.js・TypeScript・Node.js は書けるが、Swift と macOS アプリは初めて、という人。

このリポジトリのコードを **Web の概念に翻訳しながら** 読むための地図です。Swift の入門書ではなく、「あの書き方は Web でいうと何か」を引くための対応表と、読む順番を置いています。

---

## 1. 大枠 — このアプリは何なのか

**画面を持たない常駐プロセス＋小さな UI** です。Web に例えると、ブラウザのタブではなく「常駐している Node のプロセス」に近い。

| sarari | Web でいうと |
|---|---|
| メニューバー常駐（Dock に出ない） | 画面を持たない常駐プロセス。UI は右上の小さなメニューだけ |
| グローバルホットキー（右 ⌥） | OS 全体のキーイベントを購読する。ブラウザの `keydown` と違い、**他アプリの上でも拾う** |
| HUD（録音中に浮く小窓） | 画面最前面のオーバーレイ。ただし**フォーカスを奪わない**のが必須条件 |
| 他アプリへの挿入 | 他サイトの DOM に書き込むようなもの。Web には相当物がない（OS の Accessibility API を使う） |
| 履歴 | ファイルに JSON と WAV を書く。DB は使わない |

### 起動してから待機に入るまで

```
sarariApp.swift   @main（アプリの入口。Web でいう main.ts / _app.tsx）
  └ MenuBarExtra           メニューバーの常駐 UI を宣言
  └ AppDelegate            起動完了を受け取り、
      └ AppController.start()   監視・権限・エンジンを立ち上げる（以後ここが司令塔）
```

`AppDelegate` は「アプリのライフサイクルのフック」です。`applicationDidFinishLaunching` は `onMounted`、`applicationWillTerminate` は `beforeunload` に相当します（終了時にクリップボードを戻す処理が入っています）。

### 1 回の口述で何が起きるか

```
ホットキー押下          HotKeyManager      イベント購読
  → 録音開始            AudioRecorder      マイクから PCM を貯める
  → （もう一度押す）
  → 文字起こし          AppleTranscriber / Transcriber（WhisperKit）
  → 辞書置換・フィラー除去 Replacements / FillerRemover    純粋な文字列処理
  → 挿入                TextInjector       Accessibility → 失敗ならクリップボード＋⌘V
  → 履歴に保存          HistoryStore       JSON + WAV をファイルへ
  → 表示                AppState / RecordingHUD*        状態を UI に反映
```

この一連を束ねているのが `AppController`（司令塔）と `DictationPipeline`（音声 → テキストの純粋な部分）です。

---

## 2. ファイル早見表（33 ファイル）

### 入口・司令塔

| ファイル | 中身 | Web でいうと |
|---|---|---|
| `sarariApp.swift` | `@main`。メニューバー UI の宣言と起動フック | `main.ts` ＋ ルートコンポーネント |
| `AppController.swift` | 全体の司令塔。録音開始/停止、パイプライン起動、各所の接続 | アプリのサービス層・オーケストレータ |
| `DictationPipeline.swift` | 「音声サンプル → 挿入するテキスト」の純粋な処理 | 副作用のない純関数モジュール |
| `PipelineGuard.swift` | 録音の世代番号。古い結果が新しい発話を壊さないようにする | リクエストの competing 対策（最新以外を捨てる） |
| `Engines.swift` | 音声認識の差し替え口（プロトコル） | interface で実装を差し替える DI 境界 |

### 音を録る・文字にする

| ファイル | 中身 | Web でいうと |
|---|---|---|
| `AudioRecorder.swift` | マイクの録音、レベル（音量）の通知 | `MediaRecorder` ＋ AudioWorklet |
| `RecordingLimit.swift` | 録音の上限（10 分）と、上限で止めた発話の見せ方 | 暴走を止めるタイムアウト定数 |
| `JSONFileSync.swift` | 設定ファイルの読み書きと、外で編集されたときの読み直し | ファイル監視つきの JSON ストア |
| `AppleTranscriber.swift` | OS 内蔵の音声認識（既定） | 外部 API を呼ばない音声認識 |
| `Transcriber.swift` | WhisperKit（大きいモデル）での文字起こし | ローカルの推論ライブラリ呼び出し |
| `ModelIntegrity.swift` | ダウンロードしたモデルが改竄されていないかの照合 | `package-lock.json` の integrity ハッシュ検証 |

### テキストを整える・入れる

| ファイル | 中身 | Web でいうと |
|---|---|---|
| `Replacements.swift` | 辞書置換（確定誤変換の機械置換） | 純粋な文字列変換 |
| `FillerRemover.swift` | 「えっと」「あの」を決定的に除去 | 同上 |
| `TextInjector.swift` | **挿入の本体**。成功したと確信できたときだけ成功を返す | 他アプリへの書き込み＋成否判定（Web に相当なし） |
| `Pasteboard.swift` | クリップボードの「機密」「一時的」の目印 | クリップボード API ＋ メタ情報 |
| `InsertionPresentation.swift` | 挿入結果を「状態」と「HUD の動き」にどう見せるか | 結果 → ビューモデルへの変換 |

### 状態と画面

| ファイル | 中身 | Web でいうと |
|---|---|---|
| `AppState.swift` | アプリ全体の状態（`AppStatus` の 7 状態）とアイコン | グローバルストア（Pinia / Zustand） |
| `MenuContent.swift` | メニューバーのドロップダウン | ナビゲーションのコンポーネント |
| `RecordingHUDModel.swift` | HUD の表示モデル（音量・経過時間・状態） | 画面専用のストア |
| `RecordingHUDView.swift` | HUD の見た目（棒・経過時間・ボタン） | プレゼンテーショナルコンポーネント |
| `RecordingHUDController.swift` | HUD の出し入れ・自動で閉じる制御 | コンテナコンポーネント |
| `RecordingHUDPanel.swift` | ウィンドウの生成・配置・監視 | オーバーレイの DOM 生成と位置決め |
| `HUDLayout.swift` | 位置・サイズの定数 | レイアウトトークン |
| `HistoryView.swift` | 履歴ウィンドウ | 一覧ページ |
| `SettingsView.swift` / `SettingsWindow.swift` | 設定画面とそのウィンドウ | 設定ページ |

### 周辺

| ファイル | 中身 | Web でいうと |
|---|---|---|
| `HotKeyManager.swift` | ホットキーの監視と判定 | グローバルなキーイベント購読 |
| `SettingsStore.swift` | 設定の永続化（`UserDefaults`） | `localStorage` ＋ ストア |
| `HistoryStore.swift` | 履歴の保存・削除・上限 | ファイルベースの永続化層 |
| `PermissionsManager.swift` | マイク・アクセシビリティ権限 | ブラウザの権限 API（ただし OS 設定への誘導が要る） |
| `SoundPlayer.swift` | 開始音・停止音 | `Audio` 要素 |
| `LoginItem.swift` | ログイン時の自動起動 | 相当なし（OS 機能） |
| `Log.swift` | 領域別のログ | `pino` などの logger |

---

## 3. 言語の対比（TypeScript ↔ Swift）

| やりたいこと | TypeScript | Swift | 補足 |
|---|---|---|---|
| null かもしれない値 | `string \| null`（strictNullChecks） | `String?` | `?` が付いたら「無いかもしれない」 |
| 安全に取り出す | `if (x != null) { ... }` | `if let x { ... }` / `guard let x else { return }` | `guard` は「条件を満たさなければ即 return」 |
| 既定値 | `x ?? "既定"` | `x ?? "既定"` | 同じ |
| 強制的に取り出す | `x!`（型だけの話） | `x!`（**実行時にクラッシュする**） | このリポでは実行時データに `!` を使わない規約 |
| 判別可能なユニオン | `{ type: "done", message: string } \| ...` | `enum AppStatus { case done(message: String) ... }` | `AppStatus` が実例。`switch` で網羅性がコンパイル時に検査される |
| interface | `interface SpeechEngine { ... }` | `protocol SpeechEngine { ... }` | `Engines.swift` が実例 |
| 値のコピー | オブジェクトは参照 | `struct` は**値**（代入でコピー）、`class` は参照 | SwiftUI の View はすべて `struct` |
| 無名関数 | `(x) => x + 1` | `{ x in x + 1 }` | 引数が最後なら `func(...) { ... }` と外に出せる（trailing closure） |
| 非同期に渡す関数 | そのまま | `@escaping` を付ける | 「関数の実行後も生き残る」印 |
| 循環参照を切る | GC が回収 | `[weak self]` | 参照カウント方式なので、自分で切る必要がある |
| 型を隠す | 戻り値型の推論 | `some View` | 「View の一種だが具体型は書かない」 |

**読むときの勘所**: `?` と `!` と `guard` が読めれば、Swift のコードは 8 割読めます。

---

## 4. UI の対比（Vue / React ↔ SwiftUI）

| 概念 | Vue / React | SwiftUI | このリポの実例 |
|---|---|---|---|
| コンポーネント | 関数コンポーネント / SFC | `struct ...: View` | `RecordingHUDView` |
| 描画本体 | `render()` / `<template>` | `var body: some View` | 同上 |
| props | props | struct のプロパティ（`let`） | `LevelBarsView(level:isProcessing:...)` |
| ローカル状態 | `useState` / `ref` | `@State` | 設定画面など |
| 共有ストア | Zustand / Pinia | `ObservableObject` ＋ `@Published` | `AppState` / `RecordingHUDModel` |
| ストアの購読 | `useStore()` | `@ObservedObject` / `@StateObject` | `RecordingHUDView` が Model を購読 |
| リストの key | `:key` / `key` | `ForEach(..., id: \.self)` | 棒 7 本の描画 |
| **同一性** | key が変わると作り直し | **分岐で別の型を返すと別物扱い** | HUD の表示が繋がらなくなった原因がこれ。`switch` で別ビューを返すとアニメーションが繋がらない |
| スタイル | class / style | modifier チェーン（`.frame().padding()`） | 順番に意味がある（`.overlay` の後に `.frame` など） |
| トランジション | CSS transition | `.animation(_:value:)` | **値が変わったときだけ**動く。音量の変化には掛けていない |
| canvas 描画 | `<canvas>` | `Canvas { ... }` | 差分更新されないので、補間が要るなら普通のビューにする |
| 画像化 | html2canvas | `ImageRenderer` | **アプリ本体では使わない**。見た目を確認する使い捨てスクリプトで、実物のビューを PNG に描き出すのに使う |

**ここが一番の違い**: SwiftUI は「同じ場所に同じ型のビューがあり続けるか」で、アニメーションするかどうかが決まります。React の `key` に近いですが、**分岐の書き方だけで同一性が壊れる**のが落とし穴です。

---

## 5. 非同期の対比（Node.js ↔ Swift）

| 概念 | Node.js | Swift | このリポの実例 |
|---|---|---|---|
| 実行モデル | シングルスレッドのイベントループ | **マルチスレッド**。どのスレッドで動くかを型で縛る | — |
| UI を触れる場所 | （ブラウザの）メインスレッド | `@MainActor` を付けた型・関数 | `AppController`・HUD 群 |
| 非同期の起動 | `Promise` / `async` 関数の呼び出し | `Task { ... }` | パイプラインの起動 |
| await | `await` | `await` | ほぼ同じ |
| 中断 | `AbortController` | `Task.cancel()` ＋ `Task.checkCancellation()` | **協調的**（自分で確認しないと止まらない） |
| 排他制御 | 不要（単一スレッド） | `OSAllocatedUnfairLock` / `actor` | `AudioRecorder` の録音バッファ |
| スレッド間で渡せる値 | 制限なし | `Sendable` な値だけ | マイクのコールバックには値だけ渡す |
| 競合の検出 | 実行時に気づく | **コンパイル時に検出**（strict concurrency） | ビルド警告 0 を維持する方針 |

**Node との最大の違い**: Swift はマルチスレッドが前提なので、「この関数はメインスレッド専用」「この値は別スレッドへ渡してよい」を**型で宣言**します。慣れるまではエラーメッセージが厳しく見えますが、Node で言えば「データ競合を実行時に踏む前にコンパイラが止めてくれる」仕組みです。

---

## 6. ツールの対比

| 目的 | Web | sarari |
|---|---|---|
| 依存管理 | `package.json` / `package-lock.json` | Swift Package Manager / `Package.resolved` |
| プロジェクト設定 | `vite.config.ts` など | `project.yml` → **XcodeGen が `.xcodeproj` を生成**（生成物は git 管理外） |
| ビルド | `vite build` | `xcodebuild` |
| テスト | Vitest（`test` / `expect`） | Swift Testing（`@Test` / `#expect`） |
| 型チェック | `tsc --noEmit` | ビルドがそのまま型チェック |
| lint | ESLint | コンパイラ警告（**0 を維持**が規約） |
| E2E | Playwright | 無し。**実機に入れて手で確かめる**（権限ダイアログやホットキーは自動化できない） |

テストは 17 ファイルあり、**純粋な処理（文字列変換・状態遷移・表示の計算）だけを対象**にしています。実機でしか再現しない部分（権限・他アプリへの挿入）はテストせず、手で確認する方針です。

---

## 7. 読む順番（この順に読むと繋がる）

1. **`sarariApp.swift`**（56 行）— 入口。どこから始まるか
2. **`AppState.swift`**（293 行）— 7 つの状態。この enum が UI 全体を決める
3. **`AppController.swift`**（420 行）— 司令塔。1 回の口述の流れが全部ここに書いてある
4. **`TextInjector.swift`**（545 行）— このアプリで**最も判断が多い場所**。「成功したと言い切れるか」の扱い
5. **`RecordingHUDView.swift`**（436 行）— SwiftUI の書き方の実例。棒の描画・アニメーション

補助として、`.claude/rules/` の 3 ファイル（挿入の失敗判定・権限と署名・見た目の確認）に「触るときの注意」が書いてあります。

---

## 8. つまずきやすい記法

| 記法 | 意味 |
|---|---|
| `guard x else { return }` | 条件を満たさなければ即終了（早期 return） |
| `if case .done = status` | enum が特定のケースかを判定する |
| `switch` に `default` が無い | **全ケースを列挙している**。ケースが増えるとコンパイルエラーになり、判断を迫られる |
| `func f(_ x: Int)` | `_` は「呼ぶときにラベルを書かない」 |
| `{ [weak self] in ... }` | 循環参照を切る。常駐アプリでは必須 |
| `defer { ... }` | スコープを抜けるときに必ず実行（`finally` 相当） |
| `@discardableResult` | 戻り値を使わなくても警告しない |
| `nonisolated(unsafe)` | 「並行性の検査を外す」印。**理由のコメントが必須**という規約 |
| `some View` | 具体的な型を書かずに「View の一種」を返す |
| `.frame(width:)` の位置 | modifier は**書いた順に適用**される。`.overlay` の前後で結果が変わる |

---

## 9. 手を動かす課題

読むだけでは身につかないので、壊して直す練習を置いています。

1. `AppController` から `@MainActor` を外すと、どんなエラーが出るか（並行性の検査の読み方）
2. `PipelineGuard` の世代チェックを外し、録音を重ねたときに何が壊れるかをテストで再現する
3. `minimalIndicator` を `switch` で分岐する形に戻し、アニメーションが消えることを確かめる（同一性の実験）
4. `FillerRemover` にテストを 1 本、自分で書いて通す

いずれも **git で元に戻せる範囲**です。壊した状態でコミットしないようにだけ注意してください。
