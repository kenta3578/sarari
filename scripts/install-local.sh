#!/usr/bin/env bash
# sarari をローカルにビルドして /Applications へインストールする。
#
# アドホック署名（xcodebuild の既定）だと**ビルドのたびに署名が変わる**ため、
# macOS はそれを別のアプリと見なし、アクセシビリティ権限が毎回リセットされる。
# 開発中はこれが致命的に煩わしいので、固定の自己署名証明書 (koebun-dev) があれば
# それで署名し直してからインストールする。証明書が無ければアドホックのまま続行する。
#
# 証明書の作り方は BUILD.md の「開発用の署名を固定する」を参照。
set -euo pipefail

IDENTITY="${SARARI_SIGN_IDENTITY:-koebun-dev}"
CONFIG="${SARARI_CONFIG:-Release}"
APP_DEST="/Applications/sarari.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${SARARI_DERIVED_DATA:-$REPO_ROOT/.build/dd}"

cd "$REPO_ROOT"

echo "==> プロジェクトを生成"
xcodegen generate >/dev/null

echo "==> ビルド ($CONFIG)"
xcodebuild -project sarari.xcodeproj -scheme sarari -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' build >/dev/null

APP_SRC="$DERIVED/Build/Products/$CONFIG/sarari.app"
[ -d "$APP_SRC" ] || { echo "ビルド成果物が見つからない: $APP_SRC" >&2; exit 1; }

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> $IDENTITY で署名（権限を保持するため）"
  echo "    （キーチェーンの許可ダイアログが出たら「常に許可」。出続けるときは BUILD.md「署名ステップで止まる」）"
  if ! codesign --force --deep --sign "$IDENTITY" "$APP_SRC"; then
    echo "==> 署名に失敗しました。インストールせず終了します（/Applications の旧ビルドはそのまま）" >&2
    echo "    対処: BUILD.md「install-local.sh の署名ステップで止まる」を参照" >&2
    exit 1
  fi
else
  echo "==> $IDENTITY が無いのでアドホック署名のまま（起動のたびに権限を取り直す必要あり）"
fi

echo "==> 起動中の sarari を終了"
osascript -e 'tell application "sarari" to quit' 2>/dev/null || true
# 旧名 koebun（Issue #43）・koemakase（Issue #54）のときの本体。Bundle ID が同じなので、残すと 2 つ常駐して取り合う。
for LEGACY_APP in /Applications/koemakase.app /Applications/koebun.app; do
  if [ -d "$LEGACY_APP" ]; then
    echo "==> 旧名の $LEGACY_APP を終了して削除"
    osascript -e "tell application \"$LEGACY_APP\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "$LEGACY_APP"
  fi
done
sleep 1

echo "==> $APP_DEST へインストール"
# ditto は既存バンドルへ上書きコピーする（消えたファイルは残るので、
# 構成が変わったときは APP_DEST を手で消してから実行する）。
ditto "$APP_SRC" "$APP_DEST"

echo "==> 署名の確認"
codesign -dvv "$APP_DEST" 2>&1 | grep -E "Authority|Signature" || true

echo "==> 起動"
open -a "$APP_DEST"
echo "完了"
