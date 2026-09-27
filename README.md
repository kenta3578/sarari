# sarari（さらり）

完全ローカルで動く、Mac 用の日本語音声入力アプリ。

ホットキーを押して話し、もう一度押すと、最前面のアプリのカーソル位置に文字が入ります。認識は macOS 内蔵の音声認識を使うので、モデルのダウンロードは要りません。音声もテキストも端末の外に出ません。

LLM を介した音声入力で困っていた 2 つを無くすために作りました。停止してから文字が入るまで毎回 1 秒ほど待つことと、何も喋らずに止めると「ご視聴ありがとうございました」のような定型文が入ることです。sarari は LLM を通さないので、止めればすぐ入り、喋らなければ何も入りません。

<img src="docs/menubar.png" alt="sarari のメニューバーのメニュー" width="267">

<!-- TODO: デモ GIF を docs/demo.gif に置いてここに貼る（録音 → 挿入まで）-->

旧名は koemakase（声まかせ）、その前は koebun です（2026 年 9 月に改名）。`~/koemakase` や `~/koebun` のデータは、初回起動時に `~/sarari` へ移ります。

## 機能

- メニューバー常駐。ホットキー（既定は右 ⌥）で録音の開始と停止を切り替える
- 認識は Apple の音声認識（macOS 26 以降）。英数字や URL が多いときは WhisperKit（large-v3-turbo）に切り替えられる
- 開始音と停止音。同梱の音・自分の音・システムサウンドから選べる
- 辞書置換（`アットマーク` → `@` など）。履歴から聞き違いの候補を出し、選んで登録できる
- 「えーと」「あの」などのフィラー除去と、疑問文の文末の？補完。どちらも LLM を使わない文字列処理
- 挿入できなかったときは、結果を HUD・クリップボード・履歴のどこかに残す
- パスワード欄と Secure Keyboard Entry 中は入力しない
- 履歴（生のテキストと置換後）。保存期間は 7 日〜無期限

LLM による整形、話しながら文字が出る表示、多言語対応はありません。

## 必要環境

- Apple Silicon の Mac
- macOS 26 以降。14 以降でも動きますが、その場合は WhisperKit になり、初回に約 630MB をダウンロードします

## インストール

署名済みのバイナリはまだ配っていないので、ソースからビルドします。詳しくは [BUILD.md](BUILD.md)。

```bash
brew install xcodegen
git clone https://github.com/kenta3578/sarari.git
cd sarari
xcodegen generate
open sarari.xcodeproj   # Signing & Capabilities で自分の Personal Team を選んで ⌘R
```

初回はマイクとアクセシビリティの許可が要ります。ホットキーを押しても反応しないときは、システム設定 › プライバシーとセキュリティ › アクセシビリティ で sarari が ON になっているか見てください。

## 使い方

1. 入力したい場所にカーソルを置く
2. 録音キー（最初は右 ⌥。設定で変えられる）を押して話す（開始音が鳴る）
3. もう一度録音キーを押す（停止音が鳴り、カーソル位置に文字が入る）

設定の全体と「やりたいこと → どこを触る」は [説明書](https://kenta3578.github.io/sarari/manual)（[Markdown](docs/MANUAL.md)）に、何が変わったかは [更新履歴](https://kenta3578.github.io/sarari/changelog) にあります。

## プライバシー

アプリに送信処理はありません。通信するのは、WhisperKit を選んだときのモデルの初回ダウンロードだけです。録音した音声はディスクに残しません。根拠と、ディスクに書くものの一覧は [docs/PRIVACY.md](docs/PRIVACY.md) にあります。

## もっと読む

- [作った経緯](https://zenn.dev/ken_ken_ken/articles/dictation-without-llm)（Zenn）
- [設計の根拠](docs/design-rationale.md) と [認識エンジンの計測](docs/engine-benchmark.md)
- [中の作り](docs/ARCHITECTURE.md)

## ライセンス

MIT。音声認識に Apple の Speech フレームワークと [WhisperKit](https://github.com/argmaxinc/WhisperKit)（MIT, Argmax Inc.）を使っています。
