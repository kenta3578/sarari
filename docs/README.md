# docs/

公開ドキュメントと、README に貼る画像の置き場。

使う人向けの Markdown（説明書・更新履歴・プライバシー）は [説明書サイト](https://kenta3578.github.io/sarari/)（VitePress・GitHub Pages）になる。コードを読む人向けの文書はサイトに出さず、GitHub 上で読む（`srcExclude`）。設定は `.vitepress/config.mts`、手元で見るのは `pnpm docs:dev`。

| ファイル | 読む人 | 中身 |
|---|---|---|
| [`MANUAL.md`](MANUAL.md) | 使う人 | 説明書。設定項目と「やりたいこと → どこを触る」 |
| [`changelog.md`](changelog.md) | 使う人 | 更新履歴。使う人から見て変わったことだけ |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | 中を読む人 | 処理の流れ・33 ファイルの責務・状態機械・読む順番・触ると危ない場所 |
| [`PRIVACY.md`](PRIVACY.md) | 確かめたい人 | 完全ローカルであることの根拠（通信・モデルの検証・ディスクに書くもの） |
| [`SWIFT-NOTES.md`](SWIFT-NOTES.md) | Web 側の言語から来た人 | Swift / SwiftUI を TypeScript・Vue/React・Node.js の言葉に置き換えた地図 |

設計の**理由**（なぜこの作りにしたか）は [design-rationale.md](design-rationale.md) にある。ここは「何がどうなっているか」まで。

> ソースコードのコメントに出てくる Issue 番号には、**移行前のリポジトリのもの**が混ざっている。
> このリポジトリの Issue とは対応しないので、番号ではなくコメント本文を読んでほしい。

## 画像

設定の画面と録音 HUD の画像（`screens/`）は、見本データで描き出している。画面を変えた PR では撮り直して一緒にコミットする。

```bash
./scripts/docs-shots.sh   # docs/screens/ にライト・ダークの PNG を書き出す
```

本物の `~/sarari`（辞書・履歴）と設定値は読まない。描き方は `Tests/DocScreenshotsTests.swift`。

手で撮るもの:

| ファイル | 中身 | 状態 |
|---|---|---|
| `menubar.png` | メニューバーアイコンをクリックしてメニューを開いた状態 | ✅ 済み |
| `demo.gif` | 右⌥ で録音 → 話す → もう一度右⌥ → カーソル位置に挿入されるまでの一連（10 秒以内） | 未（README 冒頭の TODO コメントを画像タグに差し替える） |

画面の縁の光は `screencapture` に映らない（`sharingType = .none`）ので、画像にしていない。
撮影時の注意: 実在の宛先・個人情報が映り込まないダミーテキストで撮ること。
