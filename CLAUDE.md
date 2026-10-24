# sarari

自分専用・完全ローカルの音声入力（ディクテーション）アプリ。

## Overview

Mac（Apple Silicon）で、音声 → 文字起こし → カーソルへ直挿し までをすべてオンデバイスで完結させる個人用ツール。クラウド不要・サブスク不要・音声を外部に出さない。

**差は認識エンジンではなく「入り口と出口」にある**。認識は macOS 内蔵の SpeechAnalyzer そのものなので、価値は右⌥トグル・開始音／停止音・フィラー除去・辞書置換・確実な挿入・履歴の側にある。**薄さが価値なので、機能を足すたびに価値が減る。**

## Tech Stack

- **言語**: Swift / SwiftUI（メニューバー常駐アプリ）
- **ASR**: Apple SpeechAnalyzer（日本語・既定。OS 内蔵・DL 0・実測 292ms）／ WhisperKit large-v3-turbo（切替可。URL・メール・英数字が要るとき用。実測 約470ms）
- **後処理**: 辞書置換（確定誤変換の機械置換）＋ フィラー除去（どちらも決定的な文字列処理）
- **OS API**: AVFoundation（マイク）/ Accessibility API（テキスト直挿し）/ グローバルホットキー

## アーキテクチャ

```
メニューバー常駐(Swift) → push-to-talk
  → AVFoundation(マイク)
  → Apple SpeechAnalyzer(日本語・既定) / WhisperKit large-v3-turbo(切替可)
  → 辞書置換 → フィラー除去
  → Accessibility APIでカーソルに直挿し
```

## Directory Structure

```
├── local_docs/      # ローカル専用（git管理外）
├── .claude/rules/   # パス限定の規約（該当ファイルを触るときだけロード）
└── ...
```

## Development Guidelines

- **完全ローカル前提**: クラウド送信・外部API依存を増やさない。音声・テキストは端末外に出さない
- **低遅延優先**: 認識は Apple 内蔵で 292ms（実測）。重い処理をホットパスに足さない
- **機能を足さない**: LLM 整形・5 モード・コンテキスト注入・アプリ別自動切替・整形差分ガードは #62 の判定で削除済み（#128〜#131）。**同じものを戻す前に、冒頭の「薄さが価値」を読む**
- **並行性の警告を 0 に保つ**: `SWIFT_STRICT_CONCURRENCY: complete`（Issue #103）。`@unchecked Sendable` を増やさず、`@MainActor` か `OSAllocatedUnfairLock` で隔離する。未注釈ライブラリ由来だけ `@preconcurrency import` で抑える
- **ネイティブAPIで素直に書く**: ホットキー/マイク/注入は macOS ネイティブAPIをそのまま使う（ブリッジ越しに無理しない）

領域ごとの規約は `.claude/rules/` にある（該当ファイルを開いたときに自動でロードされる）:

| ファイル | 対象 | 中身 |
|---|---|---|
| `insertion-feedback.md` | TextInjector / RecordingHUD / AppState / AppController | 失敗と断定する条件、失敗表示が2ビューある件、`FailureHint` |
| `permissions-tcc.md` | PermissionsManager / scripts / BUILD.md | アクセシビリティ権限と署名・TCC のはまりどころ |
| `visual-check.md` | AppState / RecordingHUD / SettingsView / MenuContent | 見た目の変更は描き出して目視する手順 |

## Branch Strategy

- `main`: 他人に渡す版（保護）。入れるたびにタグ `vX.Y.Z` を打つ。説明書サイトはここから出る
- `develop`: 開発（デフォルト）。自分の実機に入るのはこちら

## Development Flow（このリポジトリの完了条件）

**「マージした」では終わらない。実機に入れて動かすまでが1サイクル。** 自分専用アプリなので、実機で使って初めて次のフィードバックが出る。

1. Issue を立てる（`category:*` / `priority:*` ラベル。本文は 問題 / 解決方針 / 完了条件）
2. `EnterWorktree`（名前は `issue<N>`）で worktree を切って実装する。`.xcodeproj` は gitignore なので最初に `xcodegen generate`。型チェックは署名なしの Debug ビルド、**PR の前に `xcodebuild test` が通ること**（どちらも下の Commands）
3. Issue 単位でコミット → PR（`Closes #N`）→ `gh pr merge --merge --delete-branch`
   - **使う人から見て何かが変わる PR は、同じ PR の中で `docs/MANUAL.md` の該当する節を直し、`docs/changelog.md` の「次の版」に1行足す**（判定はそれだけ。中の作りだけの変更は載せない。見出しが無ければ先頭に作る）。サイト（GitHub Pages）に出るのは main に入ったとき
4. `ExitWorktree`（remove）→ `git pull --ff-only origin develop`
5. **`./scripts/install-local.sh`** で実機へ入れて起動する（Release ビルド → `koebun-dev` 署名 → `/Applications` 置換 → 起動）
6. 実機で確認する。`pgrep -x sarari` で起動を確かめ、UI 変更はスクリーンショットで見る
7. ユーザーの実機フィードバックは、その場で次の Issue にする（メモに溜めない）

複数の小さな Issue は1つの worktree・1つの PR にまとめてよいが、**コミットは Issue 単位**に分ける。ドキュメントだけの変更は 5〜6 を省いてよい。

## Release（develop → main）

**出す時機**: 更新履歴の「次の版」に使う人から見た変化が溜まり、かつ develop の版を実機で数日使って困りごとが出ていないとき。日付では決めない。

1. `project.yml` の `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を上げ、`docs/changelog.md` の「次の版」を `vX.Y.Z（YYYY-MM-DD）` に改名する（develop への PR）。**同じ PR で `docs/MANUAL.md` を「次の版」の各項目と今の `Sources/` の挙動に突き合わせ、ズレを直す**（各 PR で直す決まりの取りこぼしをここで拾う。CI で自動更新しないのは、公開リポでは Actions のログと bot の PR が誰でも見えるため）
2. develop → main の PR を作ってマージする（`gh pr create --base main --head develop`）
3. main の先頭にタグを打つ: `git tag -a vX.Y.Z origin/main -m vX.Y.Z && git push origin vX.Y.Z`
4. タグの push で `release` ワークフローが走り、Releases に `sarari-vX.Y.Z.zip` が付いたことを確かめる（`gh release view vX.Y.Z`）。タグと `MARKETING_VERSION` が違うと止まる
5. main への push で説明書サイトが更新されたことを確かめる

版の上げ方: 使う人から見て新しいことができる → minor（0.2.0）、直しだけ → patch（0.1.1）。

## Commands

```bash
xcodegen generate                                   # project.yml → sarari.xcodeproj（worktree では必須）
git diff --exit-code sarari.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  || echo "依存の revision が動いた。意図した更新か確認する（Issue #106）"
xcodebuild -project sarari.xcodeproj -scheme sarari -configuration Debug \
  -derivedDataPath /tmp/sarari-dd CODE_SIGNING_ALLOWED=NO build \
  2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"  # 型チェック（署名なし）。**警告も 0 を保つ**
xcodebuild test -project sarari.xcodeproj -scheme sarari \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "✘|Test run|TEST (SUCCEEDED|FAILED)"     # 単体テスト（0.1秒未満。守備範囲は Tests/README.md）
./scripts/install-local.sh                          # 実機へインストールして起動（マージ後に必ず）
./scripts/build-release.sh vX.Y.Z                   # 配布用のアドホック署名 zip を build/release/ に作る（CI と同じ物）
pnpm install && pnpm docs:dev                       # 説明書サイトを手元で見る（docs/ を VitePress で出す。pnpm docs:build でリンク切れ検査）
pgrep -x sarari                                     # 起動確認
./scripts/kpi.sh [--target N]                       # 北極星の KPI（平日の挿入回数）を履歴から集計。目標値は引数で渡す
./scripts/model-manifest.sh                         # WhisperKit の重みのマニフェストを作り直す（Issue #106）
tccutil reset Accessibility com.kenta3578.koebun    # 権限トグルが効かないときの一度きりのリセット
log stream --predicate 'subsystem == "com.kenta3578.koebun"' --level info   # ログ（category: audio/asr/hotkey/history/store/inject）
gh issue list --state open                          # 候補プール（Issue が唯一の置き場）
```
