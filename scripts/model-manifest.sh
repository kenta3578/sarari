#!/usr/bin/env bash
# WhisperKit のモデル重みとトークナイザのマニフェスト（Issue #106）を、いま手元にあるキャッシュから起こす。
#
# 出力を Sources/ModelIntegrity.swift の `largeV3Turbo` と `whisperLargeV3Tokenizer` に丸ごと貼り替える。
# 照合は「ディレクトリの中身＝マニフェスト」で見るので、ファイルの増減もここで拾われる。
#
# 使うのは「WhisperKit を上げた」「モデルを変えた」「取得元の更新を意図して受け入れる」とき。
# 差分が意図しないものなら、それがこの Issue が検知したかった事象そのもの。
set -euo pipefail

MODEL="${1:-large-v3-v20240930_turbo_632MB}"
BASE="$HOME/Library/Application Support/com.kenta3578.koebun/huggingface/models"
MODEL_DIR="$BASE/argmaxinc/whisperkit-coreml/openai_whisper-$MODEL"
TOKENIZER_DIR="$BASE/openai/whisper-large-v3"

for dir in "$MODEL_DIR" "$TOKENIZER_DIR"; do
  if [ ! -d "$dir" ]; then
    echo "キャッシュがありません: $dir" >&2
    echo "設定 › 一般 › 音声認識 で WhisperKit を選んで取得してから実行してください。" >&2
    exit 1
  fi
done

# 照合と同じく、取得時のメタデータ（先頭の .cache）と .DS_Store は除く。
emit() {
  local name="$1" dir="$2"
  echo "    static let $name: [Entry] = ["
  (cd "$dir" && find . -path ./.cache -prune -o -type f ! -name .DS_Store -print | sort) | while read -r f; do
    rel="${f#./}"
    printf '        .init(path: "%s", sha256: "%s", size: %s),\n' \
      "$rel" \
      "$(shasum -a 256 "$dir/$rel" | cut -d' ' -f1)" \
      "$(stat -f%z "$dir/$rel")"
  done
  echo "    ]"
}

emit largeV3Turbo "$MODEL_DIR"
echo
emit whisperLargeV3Tokenizer "$TOKENIZER_DIR"
