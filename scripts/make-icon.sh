#!/usr/bin/env bash
# アプリアイコンの原本 Resources/AppIcon.svg から、各所で使う画像を書き出す（Issue #97）。
#
#   ./scripts/make-icon.sh
#
# 書き出す先:
#   Resources/Assets.xcassets/AppIcon.appiconset/  アプリ本体（Finder・Spotlight・設定の権限一覧）
#   docs/public/logo.svg                            説明書サイトのロゴと favicon
#   docs/social-preview.png                         GitHub のリポジトリのカード（Settings → Social preview に手で上げる）
#
# 要るもの: rsvg-convert と ImageMagick（brew install librsvg imagemagick）。
# 絵を変えるときは原本の SVG だけを直して、このスクリプトを流し直す。
set -euo pipefail
cd "$(dirname "$0")/.."

src=Resources/AppIcon.svg
set_dir=Resources/Assets.xcassets/AppIcon.appiconset

for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" "$src" -o "$set_dir/icon_${px}.png"
done

cp "$src" docs/public/logo.svg

# 1280×640。GitHub が角を丸めて小さく出すので、絵は中央に大きめに置く。
rsvg-convert -w 400 -h 400 "$src" | magick -size 1280x640 gradient:'#221D42-#120F24' \
  png:- -gravity West -geometry +150+0 -composite \
  -fill '#F2F4FF' -font '/System/Library/Fonts/Supplemental/Arial Bold.ttf' -pointsize 120 -gravity West -annotate +600-40 'sarari' \
  -fill '#B9B3D9' -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 40 -gravity West -annotate +606+60 'Local voice input for Mac' \
  docs/social-preview.png

echo "書き出しました: $set_dir / docs/public/logo.svg / docs/social-preview.png"
