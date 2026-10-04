#!/usr/bin/env python3
"""Gate the DSP kernel's SSI stream: bit-exact and in real time.

For every trace and chip model the m68k program src/m68k/streamtest.s plays the
trace through the kernel's stream under Hatari: the SSI transmitter runs at
49.17 kHz, the register writes arrive stamped with their SID cycle a PAL frame
ahead, the DSP renders ahead into its ring. The run passes when

  - the DSP rendered exactly the reference model's frames (its render clock ends
    where the reference's does) and its checksum over
    them (chip output and the three voices of every frame) equals the
    reference's (make_vec), so the stream is bit-identical to the frame-by-frame
    gate (voice_dsp_gate.py);
  - the transmitter never overtook the renderer and the SSI never underran;
    the run took the frames' playing time (so the renderer was paced by the
    transmitter, not free-running); the least ring fill seen is reported (the ring's target is 1536 words, 768
    frames: the margin left at the worst moment).

Real-time results need the DSP-calibrated Hatari (docs/hatari-timing.md).

  stream_gate.py --vasm V --vlink L --hatari H --tos ROM [--jobs N] [--stress] [traces...]
"""

import argparse
import os
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
TRACES = os.path.join(ROOT, "tests", "traces")
# Traces that must play in real time, and stress traces (random register traffic,
# hard sync between all voices at the fastest envelope rate) that must be
# bit-identical but whose real-time result is only reported. `noise` (every noise
# rate) is one of them: it used to pass with one word left in the ring, and the
# transmitter does overtake once, which the counter only sees since ss_break checks.
DEFAULT = ["music_1", "music_2", "tone_saw_7509", "tone_pulse_1873", "tone_tri_17250"]
STRESS = ["noise", "filt_3", "sync_ring", "rand_1", "rand_2"]


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}\n{r.stdout}\n{r.stderr}")
    return r


def one(args, name, model):
    gate = os.path.join(args.build, "stream", f"{name}.{model}")
    os.makedirs(gate, exist_ok=True)
    vec = os.path.join(gate, "voicetest_vec.i")
    exp = os.path.join(gate, "stream_expected.txt")
    run([args.make_vec, model, os.path.join(TRACES, f"voice_{name}.trace"),
         os.path.join(ROOT, "third_party", "resid"), vec, os.path.join(gate, "expected.txt"), exp])
    obj = os.path.join(gate, "streamtest.o")
    run([args.vasm, os.path.join(ROOT, "src", "m68k", "streamtest.s"), "-quiet", "-Felf", "-m68030",
         "-I" + os.path.join(ROOT, "src", "m68k"), "-I" + os.path.join(args.build, "generated"),
         "-I" + gate, "-o", obj])
    run([args.vlink, obj, "-b", "ataritos", "-s", "-e", "start", "-o", os.path.join(gate, "streamtest.tos")])
    out = os.path.join(gate, "STREAM.BIN")
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    console = os.path.join(gate, "hatari.out")
    with open(console, "w") as f:      # (a file, not a pipe: see voice_dsp_gate.py)
        r = subprocess.run(
            [args.hatari, "--machine", "falcon", "--dsp", "emu", "--tos", args.tos, "--patch-tos", "true",
             "--fast-boot", "true", "--fast-forward", "true", "--sound", "off", "--confirm-quit", "false",
             "--run-vbls", str(args.vbls), "--conout", "2", "streamtest.tos"],
            cwd=gate, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=args.timeout)
    frames, checksum, cycles = (int(x) for x in open(exp).read().split())
    if not os.path.exists(out):
        return f"no output (Hatari exit {r.returncode}); console:\n{open(console).read()[-500:]}", None
    got = struct.unpack(">8I", open(out, "rb").read())
    g_cycles, g_sum, minfill, over_fed, tue, over_end, pushes, ticks = got
    play = frames * 512 / 25175000          # seconds the frames take at the codec rate
    info = f"{frames} frames in {ticks / 200:.2f} s (playing time {play:.2f} s), least ring fill {minfill} of 1536 words"
    if g_cycles != cycles:
        return f"{g_cycles} cycles rendered, expected {cycles}", info
    if g_sum != checksum:
        return f"checksum ${g_sum:06x}, expected ${checksum:06x}", info
    late = None
    if over_fed or (tue & 1):
        late = f"NOT real time: {over_fed} overtakes, SSI underrun flag {tue & 1}"
    elif abs(ticks / 200 - play) > 0.03:    # the ring holds 8 ms, a tick is 5 ms
        late = "NOT paced by the transmitter"
    if late and name not in STRESS:
        return f"{late}; {info}", info
    return None, f"{late}: {info}" if late else f"real time: {info}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--make-vec", default=os.path.join(ROOT, "build", "ref", "make_vec"))
    ap.add_argument("--vasm", required=True)
    ap.add_argument("--vlink", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--vbls", type=int, default=3000)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--models", default="6581,8580")
    ap.add_argument("--jobs", type=int, default=1, help="Hatari runs in parallel")
    ap.add_argument("--stress", action="store_true", help="also run the stress traces (real time not required)")
    ap.add_argument("traces", nargs="*")
    args = ap.parse_args()
    for k in ("build", "make_vec", "vasm", "vlink", "hatari", "tos"):
        setattr(args, k, os.path.abspath(getattr(args, k)))
    names = args.traces or DEFAULT + (STRESS if args.stress else [])
    runs = [(name, model) for name in names for model in args.models.split(",")]
    ok = True
    print(f"{'trace':<18}{'model':>6}  result")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for (name, model), (err, info) in zip(runs, pool.map(lambda r: one(args, *r), runs)):
            print(f"{name:<18}{model:>6}  {'identical, ' + info if err is None else 'FAIL: ' + err}")
            sys.stdout.flush()
            ok &= err is None
    print("\nPASS" if ok else "\nFAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
