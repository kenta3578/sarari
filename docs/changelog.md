# 更新履歴

使う人から見て変わったことだけを、新しい順に書いています。中の作りだけの変更は載せません（全部は [GitHub の PR 一覧](https://github.com/kenta3578/sarari/pulls?q=is%3Apr+is%3Amerged)にあります）。

版ごとにまとめています。

## 次の版

- 録音中の HUD に **«話しかける相手» の顔**を出しました。人に説明するつもりで話せるようにするためのものです。設定で消せます（[#80](https://github.com/kenta3578/sarari/issues/80)）

## v0.2.0（2026-10-01）

- **Xcode なしで入れられる**ようにしました。[Releases](https://github.com/kenta3578/sarari/releases/latest) の zip を展開して「アプリケーション」に移し、開くだけです（[#73](https://github.com/kenta3578/sarari/issues/73)）

## v0.1.0（2026-09-27）

最初の版です。これまでの変更を、入った日付ごとに並べています。

### 2026-09-27

- **履歴から辞書を育てる手順**を足しました。Claude Code に履歴を読ませて、文脈で分かる誤変換（`スライプ` → `Stripe` など）を辞書の候補にし、履歴全体で他の文を壊さないと確かめてから足します。口述のたびに LLM は使いません（[#58](https://github.com/kenta3578/sarari/issues/58)）

### 2026-09-26

- 説明書に**設定の各タブと録音 HUD の画像**を載せ、トップページに使い方の流れを足しました。設定画面のファイルのパスは `~/sarari/...` と短く出るようにしました（[#56](https://github.com/kenta3578/sarari/issues/56)）
- 名前を koemakase から **sarari（さらり）** に変えました。LLM を待たずに、言ったとおりの文字がさらりと入る、という意味です。`~/koemakase` のデータは初回起動時に `~/sarari` へ移ります。説明書サイトの URL も変わりました（[#54](https://github.com/kenta3578/sarari/issues/54)）

### 2026-09-25

- **録音中は、マウスのある画面の縁がすみれ色に光る**ようにしました。HUD を見ていなくても録音中だと分かります。一般 › 録音HUD でオフにできます（[#49](https://github.com/kenta3578/sarari/pull/49)、[#51](https://github.com/kenta3578/sarari/pull/51)）
- 名前を koebun から **koemakase（声まかせ）** に変えました。`~/koebun` のデータは初回起動時に `~/koemakase` へ移ります（[#44](https://github.com/kenta3578/sarari/pull/44)）

### 2026-09-23

- 設定に **「候補」タブ**を足しました。履歴から聞き違いらしい語（`HitHub` → `GitHub` など）を出し、選んで辞書に追加できます（[#41](https://github.com/kenta3578/sarari/pull/41)）
- 辞書置換のルールを登録・編集するとき、**過去の発話のうち何件が変わるか**と変わる箇所の例が出るようにしました（[#37](https://github.com/kenta3578/sarari/pull/37)、[#39](https://github.com/kenta3578/sarari/pull/39)）
- 「〜ですか」「〜ますか」で終わる文の末尾に **？を補う**ようにしました（[#35](https://github.com/kenta3578/sarari/pull/35)）

### 2026-09-17

- WhisperKit のモデルを large-v3-turbo に替え、WhisperKit を選んだときの挿入までの待ちを縮めました。ダウンロードは約 630MB です（[#26](https://github.com/kenta3578/sarari/pull/26)）

### 2026-09-16

- WhisperKit に切り替えると「Model not found」で読み込めないことがあったのを直しました。モデルの置き場所を書類フォルダから `~/Library/Application Support/` の下に移しています（[#24](https://github.com/kenta3578/sarari/pull/24)）
- 録音の上限で止めた発話を、履歴で「挿入失敗」と区別して表示するようにしました（[#22](https://github.com/kenta3578/sarari/pull/22)）

### 2026-09-15

- **録音は 10 分で自動的に止まり**、止め忘れた録音は挿入しないようにしました（[#18](https://github.com/kenta3578/sarari/pull/18)）
- 挿入が反映されたかを確かめられなかっただけのときに「未挿入」と表示しないようにしました（[#16](https://github.com/kenta3578/sarari/pull/16)）
- 辞書置換に **「ファイルから読み込む…」** を足しました。同じ形式の JSON のルールをまとめて追加できます（[#14](https://github.com/kenta3578/sarari/pull/14)）

### 2026-09-14

- 辞書置換タブのファイルのパスをクリックすると、エディタで開けるようにしました（[#10](https://github.com/kenta3578/sarari/pull/10)）
- 辞書置換とフィラー語のファイルを外のエディタで直すと、再起動せずに次の口述から効くようにしました。あわせて、キー送出での入力・録音音声の保存と再生・HUD の「通常」表示を削除しました。HUD は「最小／非表示」の2つです（[#8](https://github.com/kenta3578/sarari/pull/8)）
- 開始音・停止音に sarari の音を同梱し、自分で足した音と分けて表示するようにしました（[#3](https://github.com/kenta3578/sarari/pull/3)）
