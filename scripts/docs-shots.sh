#!/usr/bin/env bash
# 説明書サイト（docs/）に載せる画面の画像を描き出す（Issue #56）。
#
# Tests/DocScreenshotsTests.swift を、見本データだけを置いた仮のホームで走らせる。
# 本物の ~/sarari（辞書・履歴）と設定値は読まないので、個人のデータは画像に写らない。
# 画面を変えた PR ではこれを走らせて、docs/screens/ の差分も一緒にコミットする。
set -euo pipefail
cd "$(dirname "$0")/.."

out="docs/screens"
mkdir -p "$out" build/docs-shots/home
out="$(cd "$out" && pwd -P)"
# 仮のホーム。DerivedData を <仮のホーム>/Applications の下に置くのは、
# 「/Applications の外から動いています」の警告を設定画面に出さないため（LoginItem.isOutsideApplications）。
home="$(cd build/docs-shots/home && pwd -P)"
rm -rf "$home/sarari"

xcodegen generate >/dev/null
log="build/docs-shots/xcodebuild.log"
status=0
TEST_RUNNER_CFFIXED_USER_HOME="$home" TEST_RUNNER_SARARI_DOC_SHOTS_DIR="$out" \
  xcodebuild test -project sarari.xcodeproj -scheme sarari-docshots \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath "$home/Applications/DerivedData" \
  -only-testing:sarariTests/DocScreenshotsTests >"$log" 2>&1 || status=$?
grep -E "\.swift:[0-9]+:[0-9]+: error:|✘|✔|TEST (SUCCEEDED|FAILED)" "$log" || true
[ "$status" -eq 0 ] || { echo "失敗しました。全文は $log" >&2; exit "$status"; }
ls "$out"
