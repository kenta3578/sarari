# 完全ローカルであることの根拠

sarari は音声もテキストも端末の外に出しません。その根拠を、自分で確かめられる形で書いておきます。

## 通信

- アプリのコードに送信処理はありません。`Sources/` に `URLSession`・`URLRequest`・ソケットは出てきません。
  ```bash
  grep -rniE "URLSession|URLRequest|https?://|socket|dataTask" Sources/*.swift   # 0 件
  ```
- 既定（Apple の音声認識）では、アプリはモデルを取得しません。OS のアセットを借りるだけです。日本語のアセットが Mac に無ければ、OS 自身が取りに行くことはあります。
- 通信が起きるのは、設定で WhisperKit を選んだときだけです。Hugging Face（`argmaxinc/whisperkit-coreml`）から CoreML モデル（約 630MB）を一度だけ取得し、以後はキャッシュを読みます。取得するのは重みだけで、音声とテキストは送りません。

## アプリの外で送るもの

説明書の「履歴から辞書を育てる」は、Claude Code に履歴のテキストを読ませる手順です。このときだけ、履歴のテキストが Anthropic に送られます。アプリの機能ではなく、利用者が自分で実行する操作で、実行しなければ何も送られません。

## 取得したモデルの検証

WhisperKit には revision を固定する口がなく、Hugging Face の `main` を追います。そこで全 22 ファイルの SHA-256 とサイズをリポジトリに固定し（`Sources/ModelIntegrity.swift`）、一致しなければモデルを使いません。期待値は Hugging Face から取りに行きません。検証したい相手から期待値を取っても意味がなく、上の「送信処理が無い」も崩れるためです。

## ディスクに書くもの

| 内容 | 場所 |
|---|---|
| 文字起こしの履歴（テキストのみ。保存期間は設定で 7 日〜無期限） | `~/sarari/history/` |
| 辞書置換ルール | `~/sarari/replacements.json` |
| フィラー語 | `~/sarari/fillers.json` |
| 取り込んだ開始音・停止音 | `~/sarari/sounds/` |
| 設定値 | `UserDefaults`（`com.kenta3578.koebun`） |
| WhisperKit のモデル（選んだときだけ） | `~/Library/Application Support/com.kenta3578.koebun/huggingface/` |

録音した音声はディスクに残しません。

## サンドボックス

App Sandbox は OFF です。グローバルなキー監視（ホットキー）と ⌘V の合成送出に必要なためで、理由は `project.yml` にコメントで残しています。
