#!/usr/bin/env python3
"""Gate the 68030 6510 core and PSID driver against the C reference.

For every tune: tools/player/psidref.c (the specification) writes the tune's
SID writes as a trace; src/m68k/cputest.s is assembled around the same tune,
run under Hatari, and must log exactly the same writes at the same cycles
(CPUOUT.BIN). Tunes default to tests/psid/*.sid plus the opcode exercisers
(tools/player/make_exerciser.py): programs of random instructions over every
implemented opcode and addressing mode that dump the registers and flags to
the SID after each block, so one differing flag, result or cycle count shows.

  cpu_gate.py --vasm V --vlink L --hatari H --tos ROM --psidref P [--seconds S] [--jobs N] [tunes.sid ...]
"""
import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}\n{r.stdout}\n{r.stderr}")
    return r


def one(args, tune):
    name = os.path.splitext(os.path.basename(tune))[0]
    gate = os.path.join(args.build, "cpu", name)
    os.makedirs(gate, exist_ok=True)
    trace = os.path.join(gate, "ref.trace")
    run([args.psidref, "-t", str(args.seconds), tune, trace])
    want = [tuple(int(x) for x in line.split()) for line in open(trace)
            if line.strip() and line[0] not in "#e"]
    shutil.copyfile(tune, os.path.join(gate, "tune.sid"))
    with open(os.path.join(gate, "cputest_cfg.i"), "w") as f:
        f.write(f"CPU_END equ {int(args.seconds * 985248.0)}\nCPU_SONG equ 0\n")
    obj = os.path.join(gate, "cputest.o")
    run([args.vasm, os.path.join(ROOT, "src", "m68k", "cputest.s"), "-quiet", "-Felf", "-m68030",
         "-I" + os.path.join(ROOT, "src", "m68k"), "-I" + os.path.join(args.build, "generated"),
         "-I" + gate, "-o", obj])
    run([args.vlink, obj, "-b", "ataritos", "-s", "-e", "start", "-o", os.path.join(gate, "cputest.tos")])
    out = os.path.join(gate, "CPUOUT.BIN")
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with open(os.path.join(gate, "hatari.out"), "w") as f:
        subprocess.run(
            [args.hatari, "--machine", "falcon", "--dsp", "none", "--memsize", "14", "--tos", args.tos, "--patch-tos", "true",
             "--fast-boot", "true", "--fast-forward", "true", "--sound", "off", "--confirm-quit", "false",
             "--run-vbls", str(args.vbls), "--conout", "2", "cputest.tos"],
            cwd=gate, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=args.timeout)
    if not os.path.exists(out):
        return name, f"no output; console:\n{open(os.path.join(gate, 'hatari.out')).read()[-400:]}", len(want)
    raw = open(out, "rb").read()
    n = struct.unpack(">I", raw[:4])[0]
    got = [struct.unpack(">3I", raw[4 + 12 * i:16 + 12 * i]) for i in range(n)]
    if got != want:
        k = next((i for i, (g, w) in enumerate(zip(got, want)) if g != w), min(len(got), len(want)))
        g = got[k] if k < len(got) else None
        w = want[k] if k < len(want) else None
        return name, f"{len(got)} writes, expected {len(want)}; first difference at write {k}: 68030 {g}, reference {w}", len(want)
    return name, None, len(want)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--psidref", default=os.path.join(ROOT, "build", "ref", "psidref"))
    ap.add_argument("--vasm", required=True)
    ap.add_argument("--vlink", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    ap.add_argument("--seconds", type=float, default=4.0)
    ap.add_argument("--vbls", type=int, default=3000)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("tunes", nargs="*")
    args = ap.parse_args()
    for k in ("build", "psidref", "vasm", "vlink", "hatari", "tos"):
        setattr(args, k, os.path.abspath(getattr(args, k)))
    tunes = [os.path.abspath(t) for t in args.tunes] or (
        sorted(glob.glob(os.path.join(ROOT, "tests", "psid", "*.sid")))
        + sorted(glob.glob(os.path.join(args.build, "cpu", "*.sid"))))
    ok = True
    print(f"{'tune':<24}{'writes':>8}  result")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for name, err, n in pool.map(lambda t: one(args, t), tunes):
            print(f"{name:<24}{n:>8}  {'identical' if err is None else 'FAIL: ' + err}")
            sys.stdout.flush()
            ok &= err is None
    print("\nPASS" if ok else "\nFAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
