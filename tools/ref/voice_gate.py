#!/usr/bin/env python3
"""Gate the voice reference model (src/ref) against reSID.

1. Exact: for every register trace and both chip models, the reference's
   per-frame voice output, phase, LFSR, envelope counter and rate counter must
   equal reSID clocked with SID::clock(n) frame by frame. Compared as text, so
   one differing digit fails.

2. Band-limited: for steady saw / pulse / triangle notes from 110 Hz to
   3.8 kHz, reSID is run one SID cycle at a time, the chip output is low-passed
   ideally (windowed sinc, 20 kHz passband, nothing can fold into the band) and
   read at the uniform codec instants. The reference's `naive` output (the
   voice at the integer cycle, reSID's fast mode) and its `bl` output
   (sample-instant phase plus 4-point polyBLEP) are graded by the in-band
   power of everything that is not a harmonic of the note, relative to the
   note: the aliasing figure of docs/sid-feasibility.md, here measured on the
   real DAC, envelope and frame timing rather than an idealised waveform.

Usage: voice_gate.py [--build build/ref] [--quick]
"""

import argparse
import os
import subprocess
import sys

import numpy as np
from scipy.signal import windows

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
TRACES = os.path.join(ROOT, "tests", "traces")
RESID = os.path.join(ROOT, "third_party", "resid")

CLOCK = 985248.0
FS = 25175000.0 / 256 / 2
CYC_Q24 = ((985248 * 512) << 24) + 25175000 // 2
CYC_Q24 //= 25175000
CYC = CYC_Q24 / 2.0 ** 24
BAND = 20000.0

TONE_F = (1873, 7509, 17250, 34190, 64720)


def exe(build, name):
    return os.path.join(build, name + (".exe" if os.name == "nt" else ""))


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stderr}")


def exact_gate(build, out, quick):
    names = [f"rand_{i}" for i in range(1, 9)] + ["adsr_bug", "noise", "sync_ring"]
    if quick:
        names = names[:2] + names[-3:]
    ok = True
    print("exact: reference vs reSID, per-frame state and voice output\n")
    print(f"{'trace':<12}{'model':>6}{'frames':>9}  result")
    for name in names:
        trace = os.path.join(TRACES, f"voice_{name}.trace")
        for model in ("6581", "8580"):
            ref = os.path.join(out, f"{name}.{model}.ref.tsv")
            ora = os.path.join(out, f"{name}.{model}.ora.tsv")
            bl = os.path.join(out, f"{name}.{model}.bl.tsv")
            run([exe(build, "ref_run"), model, trace, RESID, ref, bl])
            run([exe(build, "oracle_resid"), "frames", model, trace, ora])
            a = open(ref).read().splitlines()
            b = open(ora).read().splitlines()
            bad = None
            if len(a) != len(b):
                bad = f"{len(a)} vs {len(b)} frames"
            else:
                for i, (x, y) in enumerate(zip(a, b)):
                    if x != y:
                        bad = f"frame {i + 1}\n    ref {x}\n    ora {y}"
                        break
            print(f"{name:<12}{model:>6}{len(a):>9}  {'identical' if not bad else 'DIFFERS at ' + bad}")
            ok &= bad is None
    return ok


def kernel(width=300, beta=9.0):
    taps = np.arange(-width, width + 1, dtype=np.float64)

    def h(t):
        w = np.i0(beta * np.sqrt(np.clip(1 - (t / width) ** 2, 0, 1))) / np.i0(beta)
        return FS / CLOCK * np.sinc(FS * t / CLOCK) * w
    return taps, h


def truth_at(x, tk, taps, h):
    """Band-limited chip output at times tk (cycles); x[m] is the chip after m cycles."""
    out = np.empty(len(tk))
    for s in range(0, len(tk), 1024):
        t = tk[s:s + 1024]
        centre = np.floor(t).astype(np.int64)
        idx = centre[:, None] + taps[None, :].astype(np.int64)
        out[s:s + 1024] = (x[idx] * h(idx - t[:, None])).sum(axis=1)
    return out


def alias_db(y, ref, f0):
    n = len(y)
    win = windows.blackmanharris(n)
    spec = np.abs(np.fft.rfft((y - y.mean()) * win)) ** 2
    sig = np.abs(np.fft.rfft((ref - ref.mean()) * win)) ** 2
    f = np.fft.rfftfreq(n, 1.0 / FS)
    inband = f <= BAND
    k = np.rint(f / f0)
    near = np.abs(f - k * f0) < 12 * FS / n
    alias = spec[inband & ~near & (f > 30.0)].sum()
    return 10 * np.log10(alias / sig[inband].sum() + 1e-30)


def level_db(y, ref):
    n = len(y)
    win = windows.blackmanharris(n)
    f = np.fft.rfftfreq(n, 1.0 / FS)
    a = (np.abs(np.fft.rfft((y - y.mean()) * win)) ** 2)[f <= BAND].sum()
    b = (np.abs(np.fft.rfft((ref - ref.mean()) * win)) ** 2)[f <= BAND].sum()
    return 10 * np.log10(a / b)


# Pass thresholds, dB of in-band alias power relative to the note, per chip
# model, kind and fundamental (F register). Set from the measured results with
# about 2 dB of margin so a regression shows. The 6581 saw and triangle sit
# 7-9 dB above the 8580: its DAC ladder is not linear, so the ramp has kinks
# at every multiple of 0x100 codes (up to 129 DAC units of a 4064 span at
# 0x800) that the edge-only polyBLEP does not correct.
LIMITS = {
    "6581": {
        "saw":   {1873: -65, 7509: -46, 17250: -41, 34190: -38, 64720: -34},
        "pulse": {1873: -60, 7509: -50, 17250: -46, 34190: -50, 64720: -55},
        "tri":   {1873: -61, 7509: -44, 17250: -38, 34190: -34, 64720: -31},
    },
    "8580": {
        "saw":   {1873: -65, 7509: -53, 17250: -48, 34190: -46, 64720: -42},
        "pulse": {1873: -60, 7509: -50, 17250: -46, 34190: -50, 64720: -55},
        "tri":   {1873: -71, 7509: -59, 17250: -49, 34190: -40, 64720: -33},
    },
}


def band_gate(build, out):
    taps, h = kernel()
    nfr = 1 << 14
    first = 3000                                  # past the attack
    ok = True
    print("\nband-limited: alias power in 0-20 kHz relative to the note (dB, lower is better)\n")
    print(f"{'chip':<6}{'wave':<7}{'F reg':>7}{'f0 Hz':>8}{'naive':>9}{'bl':>9}{'limit':>8}{'bl level':>10}  result")
    for model in ("6581", "8580"):
        for kind in ("saw", "pulse", "tri"):
            for f in TONE_F:
                f0 = f * CLOCK / 2 ** 24
                trace = os.path.join(TRACES, f"voice_tone_{kind}_{f}.trace")
                cyc = os.path.join(out, f"tone_{kind}_{f}.{model}.cyc")
                ex = os.path.join(out, f"tone_{kind}_{f}.{model}.ex.tsv")
                bl = os.path.join(out, f"tone_{kind}_{f}.{model}.bl.tsv")
                run([exe(build, "oracle_resid"), "cycles", model, trace, "0", cyc])
                run([exe(build, "ref_run"), model, trace, RESID, ex, bl])
                chip = np.fromfile(cyc, dtype=np.int32).astype(np.float64)
                x = np.concatenate([[0.0], chip])          # x[m]: after m cycles
                exa = np.loadtxt(ex, dtype=np.int64, usecols=(0, 2))
                bla = np.loadtxt(bl, dtype=np.int64, usecols=(0, 2))
                k = exa[first:first + nfr, 0]
                naive = exa[first:first + nfr, 1].astype(np.float64)
                band = bla[first:first + nfr, 1].astype(np.float64)
                ref = truth_at(x, k * CYC, taps, h)
                a_n, a_b = alias_db(naive, ref, f0), alias_db(band, ref, f0)
                lim = LIMITS[model][kind][f]
                lv = level_db(band, ref)
                # the polyBLEP kernel is a low-pass: up to ~2 dB of high-band droop
                good = a_b <= lim and a_b <= a_n + 1.0 and abs(lv) < 2.5
                print(f"{model:<6}{kind:<7}{f:>7}{f0:>8.0f}{a_n:>9.1f}{a_b:>9.1f}{lim:>8}{lv:>+10.2f}  {'ok' if good else 'FAIL'}")
                ok &= good
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build", "ref"))
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    out = os.path.join(args.build, "out")
    os.makedirs(out, exist_ok=True)
    ok = exact_gate(args.build, out, args.quick)
    ok &= band_gate(args.build, out)
    print("\nPASS" if ok else "\nFAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
