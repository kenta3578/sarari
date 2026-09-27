# リリース手順

`sarari.app` を「ダウンロードして開くだけで動く」形で配布するための手順。

> **重要: この手順はまだ一度も実行していません。**
> 署名と notarization には有料の Apple Developer Program（年 $99）と Developer ID Application 証明書が必要で、
> 現時点では取得していません。ここに書いてあるのは**証明書を用意したあとに実行する手順の文書化**であり、
> 実行して検証した結果ではありません。GitHub Releases にはまだ何も置いていません。

---

## なぜ署名と notarization が要るのか

macOS の Gatekeeper は、未署名／未 notarize のアプリを「開発元を検証できないため開けません」と拒否する。
ユーザーに「右クリック > 開く」や `xattr -d com.apple.quarantine` を強要するのは導入摩擦としては致命的なので、
配布物は必ず署名 + notarization を通す。

sarari はサンドボックス OFF（グローバルキー監視と ⌘V 合成のため）なので、
**Hardened Runtime だけは必ず有効にする**。無効のままだと notarization が弾かれる。

---

## 事前準備（初回のみ）

1. **Apple Developer Program に登録**（年 $99）
2. **Developer ID Application 証明書を作成**
   - Xcode > Settings > Accounts > Manage Certificates > `+` > Developer ID Application
   - キーチェーンに入ったことを確認:
     ```bash
     security find-identity -v -p codesigning
     # "Developer ID Application: <Your Name> (TEAMID)" が出れば OK
     ```
3. **notarytool 用の認証情報をキーチェーンに保存**
   - App-Specific Password を https://account.apple.com で作成する
     （Apple ID のログインパスワードそのものは使えない）
   ```bash
   xcrun notarytool store-credentials "sarari-notary" \
     --apple-id "<your-apple-id@example.com>" \
     --team-id "<TEAMID>" \
     --password "<app-specific-password>"
   ```
   以降は `--keychain-profile "sarari-notary"` で参照できる。

---

## 1. リリースビルドの設定を戻す

`project.yml` の `ENABLE_HARDENED_RUNTIME` は、ローカル開発の都合で `NO` になっている。
**配布ビルドでは必ず `YES` に変更する。**

```yaml
# project.yml
        ENABLE_APP_SANDBOX: NO           # ← Accessibility / CGEvent のため OFF のまま
        ENABLE_HARDENED_RUNTIME: YES     # ← 配布時は YES（notarization の必須条件）
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        DEVELOPMENT_TEAM: "<TEAMID>"
```

Hardened Runtime を有効にすると、マイクとイベント送出に entitlement が要る。
`Sources/sarari.entitlements` を作って target の `ENTITLEMENTS` に指定する:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
```

`MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` も上げること。

---

## 2. アーカイブして書き出す

```bash
xcodegen generate

xcodebuild -project sarari.xcodeproj \
  -scheme sarari \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath build/sarari.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath build/sarari.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
```

`ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string><!-- TEAMID --></string>
	<key>signingStyle</key>
	<string>manual</string>
</dict>
</plist>
```

署名を確認:

```bash
codesign --verify --deep --strict --verbose=2 build/export/sarari.app
codesign -dvvv --entitlements - build/export/sarari.app 2>&1 | grep -i runtime
# flags に "runtime" が含まれていること（= Hardened Runtime 有効）
```

---

## 3. .dmg を作る

```bash
mkdir -p build/dmg
cp -R build/export/sarari.app build/dmg/
ln -s /Applications build/dmg/Applications   # ドラッグ&ドロップ用

hdiutil create -volname "sarari" \
  -srcfolder build/dmg \
  -ov -format UDZO \
  build/sarari-<VERSION>.dmg
```

**.dmg 自体にも署名する**（署名しないと notarization を通してもマウント時に警告が出る）:

```bash
codesign --force --sign "Developer ID Application: <Your Name> (TEAMID)" \
  --timestamp build/sarari-<VERSION>.dmg
```

---

## 4. Notarization

```bash
# 提出（完了までブロックする）
xcrun notarytool submit build/sarari-<VERSION>.dmg \
  --keychain-profile "sarari-notary" \
  --wait

# 失敗したらログを見る
xcrun notarytool log <SUBMISSION_ID> --keychain-profile "sarari-notary"
```

成功したら **staple**（.dmg にチケットを埋め込み、オフラインでも検証が通るようにする）:

```bash
xcrun stapler staple build/sarari-<VERSION>.dmg
xcrun stapler validate build/sarari-<VERSION>.dmg
```

最終確認 — ここが Gatekeeper の実挙動そのもの:

```bash
spctl -a -vvv -t install build/sarari-<VERSION>.dmg
# → "accepted / source=Notarized Developer ID" と出れば配布可能
```

### よくある失敗

| 症状 | 原因 |
|---|---|
| `The signature does not include a secure timestamp` | `--timestamp` を付け忘れている |
| `The executable does not have the hardened runtime enabled` | `ENABLE_HARDENED_RUNTIME: NO` のまま |
| `The binary is not signed with a valid Developer ID certificate` | Apple Development 証明書で署名している（Developer ID が必要） |
| SwiftPM 依存のバイナリが弾かれる | `--deep` ではなく、内包フレームワークを個別に署名する |

---

## 5. GitHub Releases に公開

```bash
git tag v<VERSION>
git push origin v<VERSION>

gh release create v<VERSION> \
  build/sarari-<VERSION>.dmg \
  --title "sarari v<VERSION>" \
  --notes-file <リリースノート>
```

リリースノートに必ず書くこと:

- **既定（Apple 音声認識）ではモデルを取得しない**こと。WhisperKit に切り替えたときだけ
  約 630MB を Hugging Face からダウンロードし、それが唯一の通信であること
- **アクセシビリティ権限**が必要で、ON にしないとホットキーが無反応であること
- Apple Silicon 専用であること
- 何が実装済みで何が未実装か（README の表と揃える）

---

## 6. Homebrew cask（任意・Releases が安定してから）

`homebrew-sarari` のような tap リポジトリを作り、`Casks/sarari.rb` を置く:

```ruby
cask "sarari" do
  version "<VERSION>"
  sha256 "<shasum -a 256 build/sarari-<VERSION>.dmg の結果>"

  url "https://github.com/kenta3578/sarari/releases/download/v#{version}/sarari-#{version}.dmg"
  name "sarari"
  desc "Fully local Japanese dictation app for macOS"
  homepage "https://github.com/kenta3578/sarari"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "sarari.app"

  zap trash: [
    "~/Library/Preferences/com.kenta3578.koebun.plist",
    "~/Library/Application Support/com.kenta3578.koebun",
    "~/sarari",
  ]
end
```

インストールは `brew install --cask kenta3578/sarari/sarari`。

> 本家 homebrew-cask への登録には「安定してメンテされている」等の要件があるので、
> まずは自前 tap から始める。

---

## リリース前チェックリスト

- [ ] `ENABLE_HARDENED_RUNTIME: YES` になっている
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` を上げた
- [ ] `Package.resolved` がコミット済みで、その revision でビルドしている
- [ ] `codesign --verify --deep --strict` が通る
- [ ] `spctl -a -t install` が `Notarized Developer ID` を返す
- [ ] `stapler validate` が通る
- [ ] クリーンな Mac（または別ユーザーアカウント）でダウンロード → 起動 → 権限付与 → 実際に文字起こしできることを確認した
- [ ] README の「いまできること / まだできないこと」がこのバージョンの実態と一致している
