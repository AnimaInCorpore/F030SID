#!/usr/bin/env python3
"""Pick a test set of real tunes from an unpacked HVSC: famous and demanding.

  pick_songs.py scan   --hvsc music --sidtrace build/lsfp/sidtrace.exe --out build/songs
  pick_songs.py select --out build/songs --count 40 > tests/songs.txt

`scan` traces a window of every candidate with sidtrace and extracts what
makes a tune hard on the emulation from the register writes:

  filter     cutoff/routing/mode writes (the SVF has to track a moving cutoff)
  digi       $D418 written at sample rate (volume-register sample playback)
  sync/ring  hard sync or ring modulation on any voice
  combined   combined waveforms (triangle/saw/pulse mixes), noise combinations
  noise, test-bit use, pulse-width modulation, write rate, extra SIDs

Candidates are the tunes of a list of famous composers (HVSC's MUSICIANS tree;
popularity is not recorded in HVSC, so fame is a curated list of composers and
well-known titles) and the curated titles themselves. `select` ranks by
demand, adds a bonus for the curated titles, and keeps the list diverse (a cap
per composer). The tunes are not redistributable and are not copied anywhere:
traces go under build/ (ignored) and tests/songs.txt lists paths into HVSC.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Composers (MUSICIANS/<initial>/<dir>) with a large share of the C64's famous
# music and of its technically demanding drivers.
COMPOSERS = [
    "H/Hubbard_Rob", "G/Galway_Martin", "T/Tel_Jeroen", "D/Daglish_Ben",
    "H/Huelsbeck_Chris", "G/Gray_Matt", "O/Ouwehand_Reyn", "W/Whittaker_David",
    "C/Cooksey_Mark", "F/Follin_Tim", "F/Follin_Geoff", "G/Gray_Fred",
    "H/Huus_Jens-Christian_JCH", "L/Laxity", "M/Mogensen_Thomas_DRAX",
    "O/Olkkonen_Jori", "L/Lieblich_Markus", "B/Bjerregaard_Johannes",
    "V/Vogel_Peter", "B/Brimble_Nick", "N/Nagata_Ron", "S/Soedersten_Joachim",
]

# Famous titles (substring of the file name, lower case) per composer
# directory: the tunes a C64 listener would name first.
POPULAR = {
    "Hubbard_Rob": ["commando", "monty_on_the_run", "crazy_comets", "delta", "sanxion",
                    "thing_on_a_spring", "international_karate", "warhawk", "spellbound",
                    "zoids", "lightforce", "gerry_the_germ", "thrust", "human_race",
                    "knucklebusters", "master_of_magic", "kentilla", "one_man_and_his_droid"],
    "Galway_Martin": ["comic_bakery", "wizball", "parallax", "arkanoid", "green_beret",
                      "rambo", "ocean_loader", "game_over", "miami_vice", "mikie",
                      "terra_cresta", "rolling_thunder", "combat_school", "athena",
                      "daley_thompsons", "highlander", "short_circuit", "yie_ar"],
    "Daglish_Ben": ["last_ninja", "trap", "deflektor", "krakout", "gauntlet",
                    "auf_wiedersehen_monty", "the_real_ghostbusters", "future_knight",
                    "wizard_of_wor", "metro"],
    "Gray_Matt": ["last_ninja", "cyberdyne", "armalyte", "mercenary", "ikari", "atmosphere"],
    "Huelsbeck_Chris": ["turrican", "great_giana", "axel_f", "shades", "rock_n_roll",
                        "r-type", "katakis", "apidya"],
    "Tel_Jeroen": ["cybernoid", "hawkeye", "robocop", "myth", "alloyrun", "turbo_outrun",
                   "eldritch", "alien_syndrome", "ordeal", "supremacy", "afterburner"],
    "Ouwehand_Reyn": ["last_ninja", "mega_apocalypse", "armada"],
    "Whittaker_David": ["glider_rider", "speedball", "shadow_of_the_beast", "lotus",
                        "mad_mix", "ghostbusters", "wizball", "feud"],
    "Cooksey_Mark": ["airwolf", "1942", "bionic_commando", "tiger_shark", "ikari", "bomb_jack"],
    "Follin_Tim": ["ghouls_n_ghosts", "bionic_commando", "gauntlet_iii", "black_lamp"],
    "Gray_Fred": ["ocean", "myth", "kinetix", "pogo", "flimbo"],
}


def candidates(hvsc):
    out = []
    for comp in COMPOSERS:
        d = os.path.join(hvsc, "MUSICIANS", *comp.split("/"))
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(".sid"):
                out.append(os.path.join(d, f))
    return out


def is_popular(path):
    comp = os.path.basename(os.path.dirname(path))
    name = os.path.basename(path).lower()
    return any(k in name for k in POPULAR.get(comp, []))


def run_sidtrace(exe, tune, out_dir, seconds, skip):
    base = os.path.join(out_dir, re.sub(r"[^A-Za-z0-9_.-]", "_", os.path.relpath(tune)) + ".trace")
    r = subprocess.run([exe, "-t", str(seconds), "-k", str(skip), "-o", base, tune],
                       capture_output=True, text=True, timeout=300)
    if r.returncode:
        return None
    chips = [base] + [f for f in (base.replace(".trace", ".2.trace"), base.replace(".trace", ".3.trace"))
                      if os.path.exists(f)]
    return chips


def features(trace_path, seconds):
    writes = []
    end = 0
    with open(trace_path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            if line.startswith("end"):
                end = int(line.split()[1])
                continue
            c, r, v = line.split()
            writes.append((int(c), int(r), int(v)))
    n = max(1, len(writes))
    secs = max(1.0, end / 985248.0) if end else float(seconds)
    ctl = [r for _, r, _ in writes]
    d418 = sum(1 for _, r, _ in writes if r == 24)
    cutoff = sum(1 for _, r, _ in writes if r in (21, 22))
    routing = {v & 7 for _, r, v in writes if r == 23 and (v & 7)}
    modes = {v & 0x70 for _, r, v in writes if r == 24 and (v & 0x70)}
    res = {v >> 4 for _, r, v in writes if r == 23 and (v >> 4)}
    wave = {}
    sync = ring = test = 0
    for _, r, v in writes:
        if r in (4, 11, 18):
            w = v >> 4
            wave[w] = wave.get(w, 0) + 1
            sync += 1 if v & 2 else 0
            ring += 1 if v & 4 else 0
            test += 1 if v & 8 else 0
    combined = sum(c for w, c in wave.items() if bin(w & 7).count("1") > 1)
    noise_comb = sum(c for w, c in wave.items() if (w & 8) and (w & 7))
    noise = sum(c for w, c in wave.items() if w == 8)
    pwm = sum(1 for _, r, _ in writes if r in (2, 3, 9, 10, 16, 17))
    return {
        "writes_per_s": round(n / secs, 1), "d418_per_s": round(d418 / secs, 1),
        "cutoff_per_s": round(cutoff / secs, 1), "filter_routes": sorted(routing),
        "filter_modes": len(modes), "resonance": len(res),
        "sync": sync, "ring": ring, "test": test, "combined": combined,
        "noise_combined": noise_comb, "noise": noise, "pwm_per_s": round(pwm / secs, 1),
        "waveforms": sorted(wave),
    }


def demand(feat, sids, popular):
    s = 0.0
    if feat["filter_routes"] and feat["cutoff_per_s"] > 20:
        s += 2.0 + min(2.0, feat["cutoff_per_s"] / 200.0)
    elif feat["filter_routes"]:
        s += 1.0
    if feat["resonance"] > 2:
        s += 0.5
    if feat["d418_per_s"] > 300:
        s += 3.0 + min(2.0, feat["d418_per_s"] / 3000.0)    # sample playback
    if feat["sync"]:
        s += 1.5
    if feat["ring"]:
        s += 1.5
    if feat["combined"]:
        s += 1.0
    if feat["noise_combined"]:
        s += 1.0
    if feat["noise"]:
        s += 0.5
    if feat["test"]:
        s += 0.5
    if feat["pwm_per_s"] > 30:
        s += 1.0
    s += min(2.0, feat["writes_per_s"] / 400.0)
    if sids > 1:
        s += 3.0 * (sids - 1)
    if popular:
        s += 3.0
    return round(s, 2)


def scan(args):
    os.makedirs(args.out, exist_ok=True)
    tunes = candidates(args.hvsc)
    print(f"{len(tunes)} candidate tunes", file=sys.stderr)

    def one(tune):
        try:
            chips = run_sidtrace(args.sidtrace, tune, args.out, args.seconds, args.skip)
        except subprocess.TimeoutExpired:
            return tune, None
        if not chips:
            return tune, None
        feat = features(chips[0], args.seconds)
        feat["sids"] = len(chips)
        return tune, feat

    results = {}
    with ThreadPoolExecutor(args.jobs) as pool:
        for i, (tune, feat) in enumerate(pool.map(one, tunes)):
            if feat:
                feat["popular"] = is_popular(tune)
                feat["score"] = demand(feat, feat["sids"], feat["popular"])
                results[os.path.relpath(tune, args.hvsc).replace("\\", "/")] = feat
            if i % 50 == 0:
                print(f"  {i}/{len(tunes)}", file=sys.stderr)
    with open(os.path.join(args.out, "features.json"), "w") as f:
        json.dump(results, f, indent=1, sort_keys=True)
    print(f"{len(results)} tunes analysed -> {args.out}/features.json", file=sys.stderr)


def select(args):
    with open(os.path.join(args.out, "features.json")) as f:
        feats = json.load(f)
    ranked = sorted(feats.items(), key=lambda kv: -kv[1]["score"])
    picked, per, seen = [], {}, set()

    def take(pool, limit):
        for path, f in pool:
            comp = path.split("/")[2] if path.count("/") >= 3 else path
            if path in seen or per.get(comp, 0) >= args.per_composer or len(picked) >= limit:
                continue
            per[comp] = per.get(comp, 0) + 1
            seen.add(path)
            picked.append((path, f))

    # The famous ones first (their demand score decides among them), so the list
    # is not only the most technical tunes; then the most demanding of the rest.
    take([kv for kv in ranked if kv[1]["popular"]], args.famous)
    take(ranked, args.count)
    picked.sort(key=lambda pf: -pf[1]["score"])
    print("# Test tunes picked from HVSC by tools/trace/pick_songs.py (famous and demanding).")
    print("# path (under the HVSC root) | score | what makes it demanding")
    for path, f in picked:
        why = []
        if f["popular"]:
            why.append("famous")
        if f["sids"] > 1:
            why.append(f"{f['sids']}SID")
        if f["d418_per_s"] > 300:
            why.append(f"digi {f['d418_per_s']:.0f}/s")
        if f["filter_routes"]:
            why.append(f"filter (cutoff {f['cutoff_per_s']:.0f}/s)")
        for k in ("sync", "ring", "combined", "noise_combined", "test"):
            if f[k]:
                why.append(k.replace("_", " "))
        if f["pwm_per_s"] > 30:
            why.append("pwm")
        print(f"{path} | {f['score']} | {', '.join(why)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--hvsc", default="music")
    s.add_argument("--sidtrace", default="build/lsfp/sidtrace.exe")
    s.add_argument("--out", default="build/songs")
    s.add_argument("--seconds", type=int, default=20)
    s.add_argument("--skip", type=int, default=5)
    s.add_argument("--jobs", type=int, default=4)
    t = sub.add_parser("select")
    t.add_argument("--out", default="build/songs")
    t.add_argument("--count", type=int, default=40)
    t.add_argument("--famous", type=int, default=15, help="of which at least this many famous tunes")
    t.add_argument("--per-composer", type=int, default=5)
    args = ap.parse_args()
    scan(args) if args.cmd == "scan" else select(args)


if __name__ == "__main__":
    main()
