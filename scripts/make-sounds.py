#!/usr/bin/env python3
"""録音開始音・停止音を波形合成して、アプリに同梱する Resources/Sounds/ に書き出す（Issue #71, #2）。

外部サービス・追加ライブラリ不要（標準ライブラリだけ）。短くて主張しすぎない音を狙う。

    python3 scripts/make-sounds.py            # 同梱する音（BUNDLED）を作り直す
    python3 scripts/make-sounds.py --list     # 候補名を表示
    python3 scripts/make-sounds.py --gain 0.5 # 音量（既定 0.35。1.0 でフルスケール）
    python3 scripts/make-sounds.py --out ~/sarari/sounds tick   # 同梱しない候補を自分の音として試す

同梱した音は設定 →「録音開始音」「録音停止音」の「sarari の音」に出る。
BUNDLED を変えたら Sources/SoundPlayer.swift の bundledSounds も揃える（テストが突き合わせる）。
気に入らなければ下の PRESETS の周波数・長さを変えて作り直す。

## 開始音と停止音を聞き分けられるようにする（Issue #121）

同じ素材を少しだけ変えたペアは、小音量だと同じ音に聞こえる。ペアを作るときは
次の3つを**同時に**変える（1つだけだと区別がつかない）。

1. **向き** — 開始は上昇、停止は下降
2. **音域** — 開始は明るい高域、停止は低域。上下の音域は重ねない
3. **語尾** — 最後に鳴る音を別物にする（人は語尾で判断する）。停止は少し長く残す

ペアは classic-start/stop・chime-open/close・marimba-high/low・koebun-up/down。
pop-like / purr-like は macOS 純正音の再現なので、この規則の対象外。
"""
import argparse, math, os, struct, wave

RATE = 44100

def tone(freq, seconds, *, wave_fn="sine", attack=0.004, decay=None, level=1.0):
    """1 音。decay は指数減衰の時定数（秒）。None なら台形エンベロープ。"""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        if wave_fn == "sine":
            v = math.sin(2 * math.pi * freq * t)
        elif wave_fn == "triangle":
            v = 2 * abs(2 * ((t * freq) % 1) - 1) - 1
        elif wave_fn == "marimba":
            # 基音＋ 4 倍音（木琴は 4 倍音が強い）。倍音は速く減衰する。
            v = math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 4 * t) * math.exp(-t * 30)
        else:
            raise ValueError(wave_fn)
        env = min(1.0, t / attack) if attack > 0 else 1.0
        if decay is not None:
            env *= math.exp(-t / decay)
        else:
            release = 0.02
            env *= min(1.0, (seconds - t) / release)
        out.append(v * env * level)
    return out

def glide(f0, f1, seconds, *, decay, level=1.0, attack=0.001):
    """周波数が f0 → f1 へ指数的に滑る減衰音（泡がはじける「ポッ」の芯）。"""
    n = int(RATE * seconds)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (f1 / f0) ** (t / seconds)
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t / attack) * math.exp(-t / decay)
        out.append(math.sin(phase) * env * level)
    return out

def purr_burst(freqs, seconds, *, mod_hz, decay, level=1.0):
    """(周波数, 重み) の正弦波を重ね、mod_hz で振幅変調した短い「ブルッ」。"""
    n = int(RATE * seconds)
    total = sum(w for _, w in freqs)
    out = []
    for i in range(n):
        t = i / RATE
        v = sum(w * math.sin(2 * math.pi * f * t) for f, w in freqs) / total
        am = 0.55 + 0.45 * math.sin(2 * math.pi * mod_hz * t)
        env = min(1.0, t / 0.003) * math.exp(-t / decay)
        out.append(v * am * env * level)
    return out

def knock(seconds=0.09, *, body=190.0, sub=45.0, level=1.0, seed=1, ring=1.0):
    """木を軽く叩いた「コツッ」。短い雑音のアタック＋ body Hz の胴鳴り＋ sub Hz の低い響き。

    body を上げると硬く明るい板、下げると太く鈍い板になる。ring は響きの長さの倍率。
    """
    import random
    rnd = random.Random(seed)
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        click = (rnd.random() * 2 - 1) * math.exp(-t / 0.002) * 0.35
        tone_ = math.sin(2 * math.pi * body * t) * math.exp(-t / (0.02 * ring))
        low = math.sin(2 * math.pi * sub * t) * math.exp(-t / (0.026 * ring)) * 1.2
        env = min(1.0, t / 0.0015)
        out.append((click + tone_ + low) * env * level)
    return out

def beep(freq, seconds, *, attack=0.005, release=0.015, level=1.0):
    """一定音量のビープ（台形エンベロープ）。"""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack, (seconds - t) / release)
        out.append(math.sin(2 * math.pi * freq * t) * max(0.0, env) * level)
    return out

def mix(*segments, gap=0.0):
    """音を順に並べる（gap 秒の無音を挟む）。"""
    silence = [0.0] * int(RATE * gap)
    out = []
    for i, seg in enumerate(segments):
        if i: out += silence
        out += seg
    return out

def overlay(a, b, offset=0.0):
    """b を a の offset 秒後に重ねる。"""
    start = int(RATE * offset)
    n = max(len(a), start + len(b))
    out = [0.0] * n
    for i, v in enumerate(a): out[i] += v
    for i, v in enumerate(b): out[start + i] += v
    return out

def compose(*items):
    """(開始秒, 波形) を並べて 1 つに重ねる（overlay の入れ子より読みやすい）。"""
    n = max(int(RATE * off) + len(seg) for off, seg in items)
    out = [0.0] * n
    for off, seg in items:
        start = int(RATE * off)
        for i, v in enumerate(seg): out[start + i] += v
    return out

# 名前 → 波形。開始音は上向き・明るめ、停止音は下向き・落ち着いた音。
PRESETS = {
    # 2 音の上昇ブリップ（開始）。E5 → C6 で高く終わる
    "koebun-up":     lambda: mix(tone(659, 0.06), tone(1046, 0.10), gap=0.012),
    # 2 音の下降ブリップ（停止）。G5 → E4 と落ち、語尾だけ余韻を付けて長く残す
    "koebun-down":   lambda: mix(tone(784, 0.06), tone(330, 0.26, decay=0.09, level=0.95), gap=0.012),
    # 木琴風の 1 打（開始）。B5 の高い 1 打だけ、短く切る
    "marimba-high":  lambda: tone(988, 0.30, wave_fn="marimba", decay=0.075),
    # 木琴風の 2 打（停止）。G4 → C4 と落ちる。打数・音域・長さの 3 つで開始と違う
    "marimba-low":   lambda: compose(
                         (0.0,  tone(392, 0.35, wave_fn="marimba", decay=0.10)),
                         (0.10, tone(262, 0.50, wave_fn="marimba", decay=0.17))),
    # ごく短いティック（主張しない。どちらにも）
    "tick":          lambda: tone(1400, 0.03, wave_fn="triangle", decay=0.008),
    # 柔らかい上昇の 2 音（開始）。D5 → A5、後の音を長く残して高く終わる
    "chime-open":    lambda: compose(
                         (0.0,   tone(587, 0.20, decay=0.075)),
                         (0.085, tone(880, 0.34, decay=0.115))),
    # 柔らかい下降の 2 音（停止）。E5 → E4 と 1 オクターブ落ち、開始より長く残る
    "chime-close":   lambda: compose(
                         (0.0,   tone(659, 0.18, decay=0.07, level=0.9)),
                         (0.085, tone(330, 0.46, decay=0.17))),
    # macOS の Pop 風: 700→480Hz を 15ms で急降下する「ポッ」＋ 70ms 後の小さな反響
    # （実物を解析: 本体 5〜15ms・約 600〜700Hz、反響 70ms・135ms）
    "pop-like":      lambda: overlay(
                         overlay(glide(720, 480, 0.06, decay=0.007),
                                 glide(680, 470, 0.06, decay=0.007, level=0.6), 0.068),
                         glide(660, 460, 0.05, decay=0.006, level=0.25), 0.135),
    # macOS の Purr 風: 520Hz の脈 → 790Hz の脈（各 20〜30ms、約 28Hz の振幅変調で「ブルッ」）
    # ＋ 135ms 後の薄い反響（実物を解析: 15〜35ms が 500Hz 台、40〜60ms が 790Hz 台）
    "purr-like":     lambda: overlay(
                         overlay(purr_burst([(520, 1.0), (1040, 0.3)], 0.045, mod_hz=28, decay=0.014),
                                 purr_burst([(790, 1.0), (1580, 0.3)], 0.045, mod_hz=28, decay=0.012, level=1.1), 0.026),
                         purr_burst([(780, 1.0), (1560, 0.3)], 0.04, mod_hz=28, decay=0.012, level=0.28), 0.135),
    # 「クラシック」風の開始音: 硬く明るい木のノック（280Hz の板・響き短め）
    # → 80ms 後に E5 → B5 の上昇ビープ。高く終わる
    "classic-start": lambda: compose(
                         (0.0,   knock(0.07, body=280, sub=90, ring=0.6, level=1.0)),
                         (0.080, beep(659, 0.050, attack=0.005, release=0.018, level=0.85)),
                         (0.140, beep(988, 0.070, attack=0.005, release=0.030, level=0.95))),
    # 「クラシック」風の停止音: 太く鈍い木のノック（120Hz の板・響き長め）＋
    # 330 → 165Hz へ落ちる 1 本のグライド。開始の「カッ・ピッ・ピッ」と鳴りの数から違う
    "classic-stop":  lambda: compose(
                         (0.0,   knock(0.20, body=120, sub=33, ring=2.2, level=1.1, seed=2)),
                         (0.055, glide(330, 165, 0.34, decay=0.11, level=0.85, attack=0.008))),
}

# アプリに同梱する音。開始と停止のペア（#121 の規則を満たすもの）だけにする。
# tick はペアにならず、pop-like / purr-like はシステム音の Pop / Purr と被るので入れない。
BUNDLED = [
    "koebun-up", "koebun-down",
    "chime-open", "chime-close",
    "marimba-high", "marimba-low",
    "classic-start", "classic-stop",
]

BUNDLE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")

def write_wav(path, samples, gain):
    peak = max(1e-9, max(abs(v) for v in samples))
    scale = gain / peak * 32767
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-32767, min(32767, v * scale)))) for v in samples))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--gain", type=float, default=0.35, help="ピーク音量（0〜1）")
    ap.add_argument("--out", default=os.path.normpath(BUNDLE_DIR))
    ap.add_argument("names", nargs="*", help="生成する候補名（省略時は BUNDLED）")
    a = ap.parse_args()
    if a.list:
        for k in PRESETS: print(k, "（同梱）" if k in BUNDLED else "")
        return
    a.out = os.path.expanduser(a.out)
    os.makedirs(a.out, exist_ok=True)
    names = a.names or BUNDLED
    for name in names:
        if name not in PRESETS:
            raise SystemExit(f"unknown preset: {name}（--list で一覧）")
        path = os.path.join(a.out, f"{name}.wav")
        write_wav(path, PRESETS[name](), a.gain)
        print("wrote", path)

if __name__ == "__main__":
    main()
