#!/usr/bin/env bash
# 使われ方のシナリオ S1〜S5（docs/scenarios.md の「自動」）を E2E で通す（Issue #126）。
#
# - 音声は `say`（日本語の声 Kyoko）で読み上げて作る。録音した本人の声はリポに置かない
# - 置き場は仮のホーム（build/e2e/home）。本物の ~/sarari の辞書・履歴は読まない・書かない
# - 音声認識は本物（Apple）、挿入は本物の ⌘V。挿入先はテスト用の小さなアプリ（sarariE2EHost）
# - 走っている間は挿入先の窓が前面に出て、クリップボードを使う。触らずに待つ
# - 最後に Release ビルドを作り、テスト用の入口が入っていないことを確かめる
#
# アクセシビリティ権限: テスト用のビルドも koebun-dev で署名するので、/Applications の sarari に
# 付けた許可がそのまま効く。効かないときは表示される案内に従う。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SARARI_SIGN_IDENTITY:-koebun-dev}"
root="build/e2e"
mkdir -p "$root/fixtures" "$root/home"
fixtures="$(cd "$root/fixtures" && pwd -P)"
home="$(cd "$root/home" && pwd -P)"
rm -rf "$home/sarari"

echo "==> 読み上げ音声を作る"
speak() { say -v Kyoko --file-format=WAVE --data-format=LEF32@16000 -o "$fixtures/$1.wav" "$2"; }
speak s1  "えーと、今日はいい天気ですね。"
speak s2a "最初の文です。少し長めに、ゆっくり話しています。"
speak s2b "最後の文です。"
speak s4  "来週、東京に行きます。"
speak s5  "これはパスワードの欄です。"

security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
  || { echo "署名用の証明書 $IDENTITY がありません（BUILD.md「開発用の署名を固定する」）" >&2; exit 1; }

echo "==> S1〜S5 を走らせる（挿入先の窓が前面に出ます。触らずに待ってください）"
xcodegen generate >/dev/null
log="$root/xcodebuild.log"
status=0
# Hardened Runtime を外すのはテストのときだけ。自己署名の証明書には Team ID が無く、
# 有効だとテストバンドルを読み込めない（ライブラリの検証で弾かれる）。権限の判定は署名で決まるので影響しない。
TEST_RUNNER_CFFIXED_USER_HOME="$home" TEST_RUNNER_SARARI_E2E_FIXTURES="$fixtures" \
  xcodebuild test -project sarari.xcodeproj -scheme sarari-e2e \
  -destination 'platform=macOS' -derivedDataPath "$root/dd" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO \
  -only-testing:sarariTests/ScenarioE2ETests >"$log" 2>&1 || status=$?
grep -E "\.swift:[0-9]+:[0-9]+: error:|✘|✔ Test \"S|Test run with|TEST (SUCCEEDED|FAILED)" "$log" || true
if [ "$status" -ne 0 ]; then
  if grep -q "アクセシビリティ権限が無い" "$log"; then
    echo "" >&2
    echo "テスト用のビルドにアクセシビリティ権限がありません。システム設定 › プライバシーとセキュリティ ›" >&2
    echo "アクセシビリティで「+」を押し、次のアプリを足して ON にしてから、もう一度走らせてください:" >&2
    echo "  $(pwd -P)/$root/dd/Build/Products/Debug/sarari.app" >&2
  fi
  echo "失敗しました。全文は $log" >&2
  exit "$status"
fi

echo "==> Release にテスト用の入口が入っていないことを確かめる"
xcodebuild -project sarari.xcodeproj -scheme sarari -configuration Release \
  -derivedDataPath "$root/release-dd" CODE_SIGNING_ALLOWED=NO build >"$root/release.log" 2>&1 \
  || { echo "Release のビルドに失敗しました。全文は $root/release.log" >&2; exit 1; }
# Debug では本体が sarari.debug.dylib に分かれ、目印はそちらに入る。Release は MacOS/ の全ファイルを見る。
macos="$root/release-dd/Build/Products/Release/sarari.app/Contents/MacOS"
[ -f "$macos/sarari" ] || { echo "Release の実行ファイルが見つかりません: $macos" >&2; exit 1; }
# grep -q は使わない。見つけた時点で抜けると strings が SIGPIPE で落ち、pipefail で「無い」と判定される。
if cat "$macos"/* | strings | grep -E "SARARI_E2E_ENTRY|e2eDictate|SARARI_E2E_FIXTURES" >/dev/null; then
  echo "Release の実行ファイルにテスト用の入口が入っています" >&2
  exit 1
fi
echo "Release には入っていません"
echo "完了"
