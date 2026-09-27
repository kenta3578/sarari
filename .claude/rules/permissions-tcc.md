---
paths:
  - "Sources/PermissionsManager.swift"
  - "Sources/TextInjector.swift"
  - "Sources/HotKeyManager.swift"
  - "scripts/**"
  - "BUILD.md"
---

# 権限（TCC）のはまりどころ

- アクセシビリティ権限は **sarari 自身への全体設定**。挿入先アプリごとには付かない。「新しいアプリで使うと外れる」ように見えたら、それは署名が変わって別アプリ扱いになっている
- `scripts/install-local.sh` は `koebun-dev` 証明書で署名を固定する。これで再ビルドしても権限は保持される。アドホック署名（`xcodebuild` 既定）に戻さない
- アドホック署名時代の登録が TCC に残っていると、システム設定のトグルを ON にしても効かない。一度だけ `tccutil reset Accessibility com.kenta3578.koebun` → 再起動で新署名を登録し直す（手順は `BUILD.md`）
- 権限の付け直し（トグル ON）はユーザーにしかできない。それ以外（リセット・再起動・`AXIsProcessTrusted` の確認）は自分でやる
- 権限が無いときの失敗には `FailureHint.accessibilityPermission` を付け、HUD から `PermissionsManager.openPrivacyPane(.accessibility)` で設定画面へ飛ばす。設定画面を開く URL はここ1か所に寄せる
