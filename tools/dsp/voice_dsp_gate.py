#!/usr/bin/env python3
"""Gate the DSP kernel against the C reference model, bit for bit.

For every trace and chip model: make_vec turns the trace into a test vector
and the reference model's expected three-voice output; the m68k harness
(src/m68k/voicetest.s) is assembled with that vector, run under Hatari, and
feeds the DSP kernel the same register writes frame by frame (with the filter
coefficient words the 68030 would derive); the 24-bit words the DSP returns
(three voices and the chip output after filter, mixer and external filter;
VOICEOUT.BIN) must equal the expected output exactly.

  voice_dsp_gate.py --vasm V --vlink L --hatari H --tos ROM [--quick] [traces...]

Traces default to the ones the kernel's current milestone supports (see
SUPPORTED); a named trace is run whether or not it is listed.
"""

import argparse
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
TRACES = os.path.join(ROOT, "tests", "traces")

# Milestone 1: voice 0, waveforms none/triangle/saw/pulse, test bit, ADSR.
# Milestone 2: every waveform setting incl. noise and the combined waveforms
# (dsp2_*, noise), ring bit with an idle voice 3.
# Milestone 3: all three voices with hard sync and ring modulation between them
# Milestone 4: the filter, mixer and external filter (filt_*: rand_* traffic plus the
# registers $15-$18), the chip output compared as a fourth word per frame.
# (rand_*: every register of every voice at random; sync_ring).
SUPPORTED = (["music_1", "music_2"] + [f"filt_{i}" for i in range(1, 7)] + [f"rand_{i}" for i in range(1, 9)] + ["sync_ring"] +
             [f"dsp2_{i}" for i in range(1, 11)] + ["noise"] +
             [f"dsp_{i}" for i in range(1, 9)] + ["adsr_bug"] +
             [f"tone_{k}_{f}" for k in ("saw", "pulse", "tri")
              for f in (1873, 7509, 17250, 34190, 64720)])


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}\n{r.stdout}\n{r.stderr}")
    return r


def one(args, name, model):
    gate = os.path.join(args.build, "gate", f"{name}.{model}")
    os.makedirs(gate, exist_ok=True)
    vec = os.path.join(gate, "voicetest_vec.i")
    exp = os.path.join(gate, "expected.txt")
    trace = os.path.join(TRACES, f"voice_{name}.trace")
    resid = os.path.join(ROOT, "third_party", "resid")
    run([args.make_vec, model, trace, resid, vec, exp])
    obj = os.path.join(gate, "voicetest.o")
    run([args.vasm, os.path.join(ROOT, "src", "m68k", "voicetest.s"), "-quiet", "-Felf", "-m68030",
         "-I" + os.path.join(ROOT, "src", "m68k"), "-I" + os.path.join(args.build, "generated"),
         "-I" + gate, "-o", obj])
    tos = os.path.join(gate, "voicetest.tos")
    run([args.vlink, obj, "-b", "ataritos", "-s", "-e", "start", "-o", tos])
    out = os.path.join(gate, "VOICEOUT.BIN")
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    # Hatari writes the console and logs to a file, not a pipe: with its output
    # piped it boots to the desktop without starting the program.
    console = os.path.join(gate, "hatari.out")
    with open(console, "w") as f:
        r = subprocess.run(
            [args.hatari, "--machine", "falcon", "--dsp", "emu", "--tos", args.tos, "--patch-tos", "true",
             "--fast-boot", "true", "--fast-forward", "true", "--sound", "off", "--confirm-quit", "false",
             "--run-vbls", str(args.vbls), "--conout", "2", "voicetest.tos"],
            cwd=gate, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=args.timeout)
    want = [int(x) for x in open(exp).read().split()]
    if not os.path.exists(out):
        return f"no output (Hatari exit {r.returncode}); console:\n{open(console).read()[-500:]}", len(want), None
    raw = open(out, "rb").read()
    got = list(struct.unpack(f">{len(raw) // 4}i", raw))
    if len(got) != len(want):
        return f"{len(got)} words, expected {len(want)}", len(want) // 4, None
    bad = [i for i in range(len(want)) if got[i] != want[i]]
    frames = len(want) // 4
    if bad:
        i = bad[0]
        return (f"{len(bad)} of {len(want)} words differ; first at frame {i // 4 + 1} {['voice 1', 'voice 2', 'voice 3', 'chip output'][i % 4]}: "
                f"DSP {got[i]} expected {want[i]}"), frames, bad
    return None, frames, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--make-vec", default=os.path.join(ROOT, "build", "ref", "make_vec.exe"))
    ap.add_argument("--vasm", required=True)
    ap.add_argument("--vlink", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--vbls", type=int, default=2500)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--models", default="6581,8580")
    ap.add_argument("--quick", action="store_true", help="two traces, one model")
    ap.add_argument("traces", nargs="*")
    args = ap.parse_args()
    for k in ('build', 'make_vec', 'vasm', 'vlink', 'hatari', 'tos'):
        setattr(args, k, os.path.abspath(getattr(args, k)))

    names = args.traces or SUPPORTED
    models = args.models.split(",")
    if args.quick:
        names, models = names[:2], models[:1]
    ok = True
    print(f"{'trace':<18}{'model':>6}{'frames':>8}  result")
    for name in names:
        for model in models:
            err, n, _ = one(args, name, model)
            print(f"{name:<18}{model:>6}{n:>8}  {'identical' if err is None else 'FAIL: ' + err}")
            sys.stdout.flush()
            ok &= err is None
    print("\nPASS" if ok else "\nFAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
