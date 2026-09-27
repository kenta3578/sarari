---
layout: home

hero:
  name: sarari
  text: さらり
  tagline: 完全ローカルで動く、Mac 用の日本語音声入力アプリ。録音キー（最初は右 ⌥・変更可）を押して話し、もう一度押すと、カーソル位置に文字が入ります。
  actions:
    - theme: brand
      text: 説明書を読む
      link: /manual
    - theme: alt
      text: 更新履歴
      link: /changelog
    - theme: alt
      text: GitHub
      link: https://github.com/kenta3578/sarari

features:
  - title: 端末の外に出さない
    details: 認識は macOS 内蔵の音声認識。音声もテキストも送信せず、録音した音声はディスクにも残しません。
    link: /privacy
    linkText: 根拠を見る
  - title: ダウンロード 0
    details: macOS 26 以降ならモデルのダウンロードは要りません。英数字や URL が多いときだけ WhisperKit に切り替えられます。
  - title: 同じ入力から同じ結果
    details: 辞書置換・フィラー除去・？補完は、LLM を使わない決まった文字列処理です。
    link: /manual#辞書置換
    linkText: 辞書置換を見る
---

## 使い方は 3 つだけ

<div class="flow">
  <div class="flow-step">
    <img class="light-only" src="./screens/hud-recording.png" alt="録音中の HUD。すみれ色の棒が声で伸び縮みする"><img class="dark-only" src="./screens/hud-recording-dark.png" alt="録音中の HUD。すみれ色の棒が声で伸び縮みする">
    <span class="num">1</span>
    <p>文字を入れたい場所にカーソルを置いて、<b>録音キー</b>（最初は右 ⌥）を押して話す。画面下の棒が声に合わせて動きます</p>
  </div>
  <div class="flow-step">
    <img class="light-only" src="./screens/hud-processing.png" alt="文字起こし中の HUD。水色の波形で止まる"><img class="dark-only" src="./screens/hud-processing-dark.png" alt="文字起こし中の HUD。水色の波形で止まる">
    <span class="num">2</span>
    <p>話し終えたら、もう一度 <b>録音キー</b>。棒が水色で止まり、文字起こしが始まります</p>
  </div>
  <div class="flow-step">
    <img class="light-only" src="./screens/hud-done.png" alt="挿入できた HUD。緑の点"><img class="dark-only" src="./screens/hud-done-dark.png" alt="挿入できた HUD。緑の点">
    <span class="num">3</span>
    <p>緑になったら、カーソルの位置に文字が入っています。辞書置換とフィラー除去は済んだ状態です</p>
  </div>
</div>

設定の画面や困ったときの見方は[説明書](/manual)にあります。

