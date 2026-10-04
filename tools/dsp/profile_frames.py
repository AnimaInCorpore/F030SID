#!/usr/bin/env python3
"""Cycle cost of single codec frames from the middle of a gate run.

  profile_frames.py --gate build/gate/filt_3.6581 --hatari H --tos ROM [--hits 200,3000,...] [--top 14] [--jobs N]

For each N, Hatari's DSP profiler is switched on at the N-th pass through
`cmd_frame` and off at `fr_done` (tools/profile_dsp.py), and the cycles are
summed per routine, the three voice copies (name_0, name_1, name_2) together.
Prints the frame total and the biggest routines per frame, then the mean over
the frames. The gate directory comes from `make dsp-gate` (it holds voicetest.tos
built with the current kernel); the budget is 326 cycles per 49.17 kHz frame.
"""
import argparse, os, re, subprocess, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import profile_dsp as pd  # noqa: E402


def one(args, n):
    out = os.path.join(ROOT, "build", "prof", f"{os.path.basename(args.gate)}.{n}")
    subprocess.run(["rm", "-rf", out])
    listing = os.path.join(ROOT, "build", "dsp", "SID.LST")
    pd.prepare(pd.Path(listing), pd.Path(out), "cmd_frame", "fr_done", n)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with open(os.path.join(out, "debug.log"), "w") as log:
        subprocess.run([args.hatari, "--machine", "falcon", "--dsp", "emu", "--tos", args.tos, "--patch-tos", "true",
                        "--fast-boot", "true", "--fast-forward", "true", "--sound", "off", "--confirm-quit", "false",
                        "--run-vbls", "6000", "--conout", "2", "--parse", os.path.join(out, "start.ini"), "voicetest.tos"],
                       cwd=args.gate, env=env, stdout=log, stderr=subprocess.STDOUT)
    cps, rows = pd.parse_profile(pd.Path(os.path.join(out, "profile.txt")))
    sym = pd.parse_listing(pd.Path(listing))
    starts = sorted((a, name) for (sp, name), a in sym.items() if sp == "P")
    import bisect
    addrs = [a for a, _ in starts]
    per = defaultdict(float)
    total = 0.0
    for addr, instr, osc in rows:
        i = bisect.bisect_right(addrs, addr) - 1
        name = re.sub(r"_[012]$", "", starts[i][1]) if i >= 0 else "?"
        per[name] += osc / 2
        total += osc / 2
    return total, per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gate", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--hits", default="200,3000,9000,15000,21000,27000")
    ap.add_argument("--top", type=int, default=14)
    ap.add_argument("--jobs", type=int, default=1, help="Hatari runs in parallel")
    args = ap.parse_args()
    args.gate, args.hatari, args.tos = map(os.path.abspath, (args.gate, args.hatari, args.tos))
    totals, agg = [], defaultdict(float)
    hits = [int(x) for x in args.hits.split(",")]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda n: one(args, n), hits))
    for n, (total, per) in zip(hits, results):
        totals.append(total)
        for k, v in per.items():
            agg[k] += v / len(hits)
        top = sorted(per.items(), key=lambda kv: -kv[1])[:6]
        print(f"frame {n:>6}: {total:7.0f} cycles   " + ", ".join(f"{k} {v:.0f}" for k, v in top))
    print(f"\nmean {sum(totals) / len(totals):.0f}, max {max(totals):.0f} cycles per frame (budget 326)\n")
    for k, v in sorted(agg.items(), key=lambda kv: -kv[1])[:args.top]:
        print(f"  {v:7.1f}  {k}")


if __name__ == "__main__":
    main()
