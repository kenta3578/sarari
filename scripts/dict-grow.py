#!/usr/bin/env python3
"""履歴から辞書置換を育てるための決定的な下ごしらえ（Issue #58）。

LLM が候補を出す前後の、機械でできる部分だけを持つ。判断（どの語を入れるか）は
.claude/skills/grow-dictionary/SKILL.md の手順で行う。アプリには触らない。

  ./scripts/dict-grow.py dump [--since YYYY-MM-DD] > hist.tsv
      履歴を「ID<TAB>置換後テキスト」で書き出す（10 文字未満は除く）
  ./scripts/dict-grow.py check candidates.tsv
      候補（「読み<TAB>置換後」の行）を履歴全体の生テキストに当て、
      一致件数と前後の文を出す。既存ルールと重なる読みには印を付ける
  ./scripts/dict-grow.py apply candidates.tsv
      replacements.json をバックアップしてから、既存に無い読みだけを末尾に足す

置換はアプリと同じく大文字小文字を区別しない部分一致で見る（単語境界を見ない）。
"""
import datetime
import glob
import json
import os
import shutil
import sys

ROOT = os.path.expanduser("~/sarari")
HISTORY = os.path.join(ROOT, "history")
RULES = os.path.join(ROOT, "replacements.json")
MIN_CHARS = 10  # scripts/kpi.sh と同じ。これ未満はテスト入力として扱う


def history():
    for f in sorted(glob.glob(os.path.join(HISTORY, "*", "meta.json"))):
        try:
            m = json.load(open(f))
        except Exception:
            continue
        yield os.path.basename(os.path.dirname(f)), m


def load_candidates(path):
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0]:
            sys.exit(f"形式が違う行: {line!r}（読み<TAB>置換後）")
        out.append((parts[0], parts[1]))
    return out


def load_rules():
    return json.load(open(RULES, encoding="utf-8")) if os.path.exists(RULES) else []


def cmd_dump(args):
    since = args[args.index("--since") + 1] if "--since" in args else None
    for hid, m in history():
        raw = m.get("rawText") or ""
        if len(raw) < MIN_CHARS:
            continue
        if since and hid[:8] < since.replace("-", ""):
            continue
        text = (m.get("replacedText") or raw).replace("\n", " ").replace("\t", " ")
        print(f"{hid}\t{text}")


def cmd_check(args):
    cands = load_candidates(args[0])
    raws = [m.get("rawText") or "" for _, m in history()]
    existing = {r["from"].lower() for r in load_rules()}
    for src, dst in cands:
        key = src.lower()
        hits = [t for t in raws if key in t.lower()]
        mark = " [既存]" if key in existing else ""
        print(f"{src} → {dst}: {len(hits)} 件{mark}")
        for t in hits[:3]:
            i = t.lower().find(key)
            print(f"    …{t[max(0, i - 10):i + len(src) + 10]}…")


def cmd_apply(args):
    cands = load_candidates(args[0])
    rules = load_rules()
    existing = {r["from"].lower() for r in rules}
    added = [(s, d) for s, d in cands if s.lower() not in existing]
    if not added:
        print("足すルールはありません")
        return
    if os.path.exists(RULES):
        stamp = datetime.date.today().strftime("%Y%m%d")
        shutil.copy2(RULES, f"{RULES}.bak-{stamp}")
    rules += [{"from": s, "to": d} for s, d in added]
    tmp = RULES + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rules, f, ensure_ascii=False, indent=2)
    os.replace(tmp, RULES)
    print(f"{len(added)} ルールを足しました（計 {len(rules)}）")


if __name__ == "__main__":
    cmds = {"dump": cmd_dump, "check": cmd_check, "apply": cmd_apply}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])
