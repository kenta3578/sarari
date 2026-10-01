#!/usr/bin/env bash
# 配布用の sarari.app をビルドして zip にする（Issue #73）。
# タグを push すると .github/workflows/release.yml がこれを呼び、zip を GitHub Releases に添付する。
# 手元でも同じものが作れる: ./scripts/build-release.sh v0.2.0 → build/release/sarari-v0.2.0.zip
#
# 署名はアドホック（Developer ID と公証は Apple Developer Program が要るので未対応。RELEASING.md）。
# そのため初回は Gatekeeper に止められ、使う人は「このまま開く」を押す必要がある（README のインストール節）。
set -euo pipefail

VERSION="${1:?使い方: $0 <版（例: v0.2.0）>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${SARARI_DERIVED_DATA:-$REPO_ROOT/.build/release-dd}"
OUT_DIR="$REPO_ROOT/build/release"
ZIP="$OUT_DIR/sarari-$VERSION.zip"

cd "$REPO_ROOT"

echo "==> プロジェクトを生成"
xcodegen generate >/dev/null

echo "==> ビルド (Release / arm64)"
# Personal Team を持たない環境（CI）でも通るよう、Xcode の署名は止めて後でアドホック署名する。
xcodebuild -project sarari.xcodeproj -scheme sarari -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/sarari.app"
[ -d "$APP" ] || { echo "ビルド成果物が見つからない: $APP" >&2; exit 1; }

echo "==> アドホック署名"
# Apple Silicon は未署名のバイナリを起動しない。--deep は署名に使わない（Apple 非推奨）。
# 埋め込みのフレームワークを持つようになったら、内側から先に個別に署名する。
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> zip を作る"
mkdir -p "$OUT_DIR"
rm -f "$ZIP"
# ditto はバンドルの拡張属性・シンボリックリンクを保ったまま固める（zip コマンドだと署名が壊れることがある）。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "完了: $ZIP"
