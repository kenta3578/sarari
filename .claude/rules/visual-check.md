---
paths:
  - "Sources/AppState.swift"
  - "Sources/RecordingHUD*.swift"
  - "Sources/SettingsView.swift"
  - "Sources/MenuContent.swift"
  - "Sources/EdgeGlow.swift"
---

# 見た目に関わる変更は描き出して目視する

描画コードを書いただけで「できた」と言わない。実機に入れる前に一度、入れた後にもう一度見る。

- **メニューバーのグリフ**（`MenuBarGlyph`）: 描画コードを scratchpad の Swift スクリプトへ写し、8 倍スケールでライト／ダーク／録音中の PNG に描き出して Read する。線画と塗りの両方を見る（別パスの重なりは線画では底辺が横切り、塗りでは抜ける）
- **実機のメニューバー**: `install-local.sh` 後に `screencapture -x -R <x,y,w,h>` で右上を撮って Read する
- **HUD**: 失敗パネル・結果パネル・警告など、変えた状態を実機で再現してスクリーンショットをもらう（HUD は `.nonactivatingPanel` なので、自分で確実に再現できない状態はユーザーに1枚頼む）
- **録音 HUD に «波» や動きを足す前に、#146〜#176 と #178 を読む。** 16 回作り直した末に「分かり辛くなってきた」で、全部 #146 より前に戻した（Issue #178）。**重ねるほど «いま何を見ているのか» が読めなくなる**ので、足す前に読み取らせたいことを 1 つに決める。踏んだ落とし穴: ①時間で動かすと速さのつまみが増え、1 つ直すと別のが目立つ（位相・脈・凪ぎ・送り出し・平滑化で 5 つになった） ②比較コマを無音の状態だけで描くと «直った» と読めてしまう——喋っている間は入力レベルが振幅を決める ③速さは静止画 1 枚でも 1 つの時間窓でも決まらない ④線は細いと «ミミズ»、棒は細いと «つぶつぶ» に見える ⑤色で «声を拾った» を示すなら位置ごとに決め、状態色（黄・すみれ・水色・緑・橙。`StatusPalette`）と被らせない ⑥プレビューは Retina と同じ 2x に実寸で描き、最近傍で拡大する（幾何や画像を拡大すると粗さが実物とずれる）
- **画面の縁の光**（`EdgeGlow`、Issue #48）: `sharingType = .none` なので `screencapture` に映らない。`glowMask` を scratchpad のスクリプトへ写し、壁紙色（中間・白っぽい・暗い）の上に合成した PNG で見る。実機の見え方はユーザーに確かめてもらう
- **HUD は 5 ファイルに分かれている**（Issue #65）: `HUDLayout`（位置・サイズの定数）/ `RecordingHUDModel`（何を見せるか）/ `RecordingHUDView`（描画）/ `RecordingHUDController`（状態遷移）/ `RecordingHUDPanel`（NSPanel の生成・配置・監視）。**パネルの大きさを変えるときは `HUDMetrics` の 1 か所**で、View の frame とパネルの実サイズが必ず揃う
- **Model は `SettingsStore.shared` / `AppState.shared` を読まない。** 表示サイズと状態は Controller の `syncEnvironment()` が注入する。ここを通さずに設定を変えると**中身が変わらない**ので、表示に関わる設定を足したらこの関数も見る
- HUD は SwiftUI の `.onHover` が効かない（非アクティブのパネル）。ホバーはマウス位置とパネル枠の当たり判定で自前に取っている。ボタンを足すときは `panelSize` と frame が一致しているかも見る（ズレると見えない領域がクリックを食う）
