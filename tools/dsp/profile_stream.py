#!/usr/bin/env python3
"""Where the DSP's cycles go while the player plays a tune.

  profile_stream.py --run build/play/Wizball.6581 --hatari H --tos ROM [--skip 250000] [--frames 100000] [--top 30]

The run directory is one the player gate left (F030SID.TOS, TUNE.SID,
AUTOPLAY.INF). Hatari's DSP profiler is switched on at the --skip-th pass
through `frame` and off --frames passes later, so the profile holds everything
the DSP did for those frames: synthesis, the stream loop, the transmit
interrupt, register writes and the host's commands. Prints the cycles per frame
against the 326 of a 49.17 kHz frame and the biggest labels (the three voice
copies name_0, name_1, name_2 together).
"""
import argparse
import bisect
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import profile_dsp as pd  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--skip", type=int, default=250000)
    ap.add_argument("--frames", type=int, default=100000)
    ap.add_argument("--top", type=int, default=30)
    args = ap.parse_args()
    run, hatari, tos = map(os.path.abspath, (args.run, args.hatari, args.tos))
    listing = Path(ROOT, "build", "dsp", "SID.LST")
    sym = pd.parse_listing(listing)
    frame = pd.symbol(sym, "P", "frame")
    out = Path(ROOT, "build", "prof", "stream." + os.path.basename(run)).resolve()
    out.mkdir(parents=True, exist_ok=True)
    profile = out / "profile.txt"
    if profile.exists():
        profile.unlink()
    (out / "start.ini").write_text(f"db pc = ${frame:04x} :{args.skip} :once :trace :file {out / 'begin.ini'}\n")
    (out / "begin.ini").write_text(f"dp on\ndb pc = ${frame:04x} :{args.frames} :once :trace :file {out / 'end.ini'}\n")
    (out / "end.ini").write_text(f"dp save {profile}\ndp off\n")
    seconds = (args.skip + args.frames) / 49170
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with open(out / "debug.log", "w") as log:
        subprocess.run([hatari, "--machine", "falcon", "--dsp", "emu", "--memsize", "14", "--tos", tos,
                        "--patch-tos", "true", "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
                        "--confirm-quit", "false", "--run-vbls", str(int(seconds * 150 + 900)), "--conout", "2",
                        "--parse", str(out / "start.ini"), "F030SID.TOS"],
                       cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT)
    if not profile.exists():
        sys.exit(f"no profile; see {out / 'debug.log'}")
    _, rows = pd.parse_profile(profile)
    starts = sorted((a, name) for (space, name), a in sym.items() if space == "P")
    addrs = [a for a, _ in starts]
    per = defaultdict(float)
    total = 0.0
    for addr, _, osc in rows:
        i = bisect.bisect_right(addrs, addr) - 1
        name = re.sub(r"_[012]$", "", starts[i][1]) if i >= 0 else f"p_{addr:04x}"
        per[name] += osc / 2
        total += osc / 2
    print(f"{os.path.basename(run)}: {total / args.frames:.1f} cycles per frame over {args.frames} frames "
          f"from frame {args.skip} ({total / args.frames * 100 / 326.3:.0f}% of 326)")
    for name, c in sorted(per.items(), key=lambda kv: -kv[1])[:args.top]:
        print(f"  {c / args.frames:7.1f}  {name}")


if __name__ == "__main__":
    main()
