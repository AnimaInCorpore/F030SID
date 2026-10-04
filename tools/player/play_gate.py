#!/usr/bin/env python3
"""Gate the player end to end: PSID file in, the DSP's rendered frames out.

For every tune and chip model, F030SID.TTP plays the tune under Hatari for
--seconds of tune time (AUTOPLAY.INF: "TUNE.SID -t S -m MODEL -v") and writes
the DSP's stream status. The expectation comes from the two reference models:
tools/player/psidref.c runs the tune's 6510 code into a register trace, and
the chip reference (src/ref/sid_ref.c, through tools/dsp/make_vec) renders that
trace. The run passes when

  - the DSP's render clock and its checksum over every rendered frame equal the
    reference's: the 68030's 6510 core, its filter coefficients, the stream
    protocol and the DSP kernel together are bit-exact;
  - the transmitter never overtook the renderer, the SSI never underran, and
    the run took the tune's playing time (real time, under the DSP-calibrated
    Hatari).

  play_gate.py --hatari H --tos ROM [--seconds S] [--models 6581,8580|tune] [--jobs N] [tunes.sid ...]
"""
import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}\n{r.stdout}\n{r.stderr}")
    return r


def one(args, tune, model):
    name = os.path.splitext(os.path.basename(tune))[0]
    gate = os.path.join(args.build, "play", f"{name}.{model}")
    os.makedirs(gate, exist_ok=True)
    trace = os.path.join(gate, "ref.trace")
    run([args.psidref, "-t", str(args.seconds), tune, trace])
    exp = os.path.join(gate, "stream_expected.txt")
    run([args.make_vec, model, trace, os.path.join(ROOT, "third_party", "resid"),
         os.path.join(gate, "vec.i"), os.path.join(gate, "expected.txt"), exp])
    frames, checksum, cycles = (int(x) for x in open(exp).read().split())
    shutil.copyfile(tune, os.path.join(gate, "TUNE.SID"))
    shutil.copyfile(args.player, os.path.join(gate, "F030SID.TOS"))
    with open(os.path.join(gate, "AUTOPLAY.INF"), "w") as f:
        f.write(f"TUNE.SID -t {args.seconds} -m {model} -v")
    out = os.path.join(gate, "PLAYOUT.BIN")
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with open(os.path.join(gate, "hatari.out"), "w") as f:
        subprocess.run(
            [args.hatari, "--machine", "falcon", "--dsp", "emu", "--memsize", "14", "--tos", args.tos,
             "--patch-tos", "true", "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
             "--confirm-quit", "false", "--run-vbls", str(int(args.seconds * args.vbls_per_second + 900)), "--conout", "2",
             "F030SID.TOS"],
            cwd=gate, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=args.timeout)
    label = f"{name:<20}{model:>6}"
    if not os.path.exists(out):
        return label, f"no output; console:\n{open(os.path.join(gate, 'hatari.out')).read()[-400:]}"
    g_cycles, g_sum, minfill, over_fed, tue, over_end, cpu_cycles, ticks = struct.unpack(">8I", open(out, "rb").read())
    play = frames * 512 / 25175000
    info = (f"{frames} frames in {ticks / 200:.2f} s (playing time {play:.2f} s), least ring fill {minfill} of 768 words")
    if g_cycles != cycles:
        return label, f"FAIL: {g_cycles} cycles rendered, expected {cycles}; {info}"
    if g_sum != checksum:
        return label, f"FAIL: checksum ${g_sum:06x}, expected ${checksum:06x}; {info}"
    if over_fed or (tue & 1):
        return label, f"FAIL: not real time: {over_fed} overtakes, SSI underrun flag {tue & 1}; {info}"
    if abs(ticks / 200 - play) > 0.06:
        return label, f"FAIL: not paced by the transmitter; {info}"
    return label, f"identical, real time: {info}"


def tune_model(tune):
    """The chip model a PSID v2+ header asks for; the 6581 otherwise (as the player decides)."""
    head = open(tune, "rb").read(0x78)
    version, flags = struct.unpack(">H", head[4:6])[0], struct.unpack(">H", head[0x76:0x78])[0]
    return "8580" if version >= 2 and (flags >> 4) & 3 == 2 else "6581"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--psidref", default=os.path.join(ROOT, "build", "ref", "psidref"))
    ap.add_argument("--make-vec", default=os.path.join(ROOT, "build", "ref", "make_vec"))
    ap.add_argument("--player", default=os.path.join(ROOT, "release", "f030sid.ttp"))
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--seconds", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--models", default="6581,8580", help='chip models, or "tune": the one each tune asks for')
    ap.add_argument("--vbls-per-second", type=int, default=60,
                    help="emulated VBLs allowed per second of tune (more lets a tune that is slower than real time finish)")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("tunes", nargs="*")
    args = ap.parse_args()
    for k in ("build", "psidref", "make_vec", "player", "hatari", "tos"):
        setattr(args, k, os.path.abspath(getattr(args, k)))
    tunes = [os.path.abspath(t) for t in args.tunes] or (
        sorted(glob.glob(os.path.join(ROOT, "tests", "psid", "*.sid")))
        + sorted(glob.glob(os.path.join(args.build, "play", "*.sid"))))
    if args.models == "tune":
        runs = [(t, tune_model(t)) for t in tunes]
    else:
        runs = [(t, m) for t in tunes for m in args.models.split(",")]
    ok = True
    print(f"{'tune':<20}{'model':>6}  result")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for label, result in pool.map(lambda r: one(args, *r), runs):
            print(f"{label}  {result}")
            sys.stdout.flush()
            ok &= "FAIL" not in result and "no output" not in result
    print("\nPASS" if ok else "\nFAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
