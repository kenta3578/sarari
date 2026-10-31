#!/bin/bash
# リリースの準備: 版を上げ、更新履歴の「次の版」を「vX.Y.Z（今日の日付）」に改名する（Issue #135）。
# 結果は develop への PR にする。main に入るとリリースのワークフローがタグ・Release・zip を作る。
#
#   ./scripts/prepare-release.sh v0.4.0
#
# 説明書（docs/MANUAL.md）の突き合わせはここでは書き換えない。最後に出す「次の版」の項目を見て、同じ PR で直す。
set -euo pipefail

cd "$(dirname "$0")/.."

tag="${1:-}"
if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "使い方: $0 vX.Y.Z" >&2
  exit 1
fi
version="${tag#v}"

current=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)
if [ -z "$current" ] || [ -z "$build" ]; then
  echo "project.yml から MARKETING_VERSION / CURRENT_PROJECT_VERSION を読めない" >&2
  exit 1
fi
# 同じ版・下がる版は出せない（タグがあるとリリースのワークフローが何もしない）
if [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" != "$version" ] || [ "$current" = "$version" ]; then
  echo "今の版 ${current} より上の版を指定する（指定: ${version}）" >&2
  exit 1
fi

changelog=docs/changelog.md
if ! grep -qx '## 次の版' "$changelog"; then
  echo "${changelog} に「## 次の版」が無い" >&2
  exit 1
fi
items=$(awk '
  $0 == "## 次の版" { on = 1; next }
  on && /^## / { exit }
  on && /^- / { print }
' "$changelog")
if [ -z "$items" ]; then
  echo "「## 次の版」に項目が無い。出すものが無い" >&2
  exit 1
fi

next_build=$((build + 1))
today=$(date +%Y-%m-%d)
sed -i '' \
  -e "s/^\( *MARKETING_VERSION: *\)\"$current\"/\1\"$version\"/" \
  -e "s/^\( *CURRENT_PROJECT_VERSION: *\)\"$build\"/\1\"$next_build\"/" \
  project.yml
sed -i '' "s/^## 次の版\$/## ${tag}（${today}）/" "$changelog"

echo "版: ${current} → ${version}（ビルド番号 ${build} → ${next_build}）"
echo "更新履歴: 「次の版」→「${tag}（${today}）」"
echo
echo "説明書（docs/MANUAL.md）をこの項目と今の Sources/ の挙動に突き合わせて、同じ PR で直す:"
echo "$items"
