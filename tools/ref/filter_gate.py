#!/usr/bin/env python3
"""Gate the reference filter/mixer against reSID by spectrum.

The filter is not bit-exact (reSID integrates an analog model at 985 kHz, the
reference a TPT filter at 49 kHz); the gate is the response error. The same
bandlimited-noise voice (bit-exact in both) is routed through the filter in each
mode / cutoff / resonance, reSID's chip output is taken per cycle and low-passed
to the codec grid, and the Welch spectra of both outputs are compared in dB
over 100 Hz - 12 kHz wherever reSID's output is 10 dB above its own floor.

Usage: filter_gate.py [--build build/ref] [--quick]
"""
import argparse, os, subprocess, sys
import numpy as np
from scipy.signal import welch

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CLOCK = 985248.0
FS = 25175000.0 / 512
NOISE_FREQ = 0x4000          # LFSR shifted at ~15 kHz: little energy above the codec Nyquist
CYCLES = 2_000_000
LIMIT_LP_DB = 10.0           # no low-pass case worse than this (the common mode in music)
LIMIT_MEAN_DB = 6.0          # mean rms error over all cases


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"failed: {' '.join(cmd)}\n{r.stderr}")


def trace_for(path, fc, res, filt, mode):
    with open(path, "w") as t:
        for reg, v in ((21, fc & 7), (22, fc >> 3), (23, (res << 4) | filt), (24, (mode << 4) | 15),
                       (0, NOISE_FREQ & 255), (1, NOISE_FREQ >> 8), (5, 0), (6, 0xf0), (4, 0x81)):
            t.write(f"0 {reg} {v}\n")
        t.write(f"end {CYCLES}\n")


def spectra(build, model, trace, out):
    resid = os.path.join(ROOT, "third_party", "resid")
    run([os.path.join(build, "oracle_resid"), "mix", model, trace, out + ".i32"])
    run([os.path.join(build, "ref_run"), model, trace, resid, out + ".ex", out + ".bl"])
    chip = np.fromfile(out + ".i32", dtype=np.int32).astype(np.float64)
    ref = np.loadtxt(out + ".bl", dtype=np.int64, usecols=(5,)).astype(np.float64)
    # chip: box-average 20 cycles per frame is crude; use block average at the true ratio
    n = len(ref)
    edges = (np.arange(n + 1) * (len(chip) / n)).astype(int)
    csum = np.concatenate([[0], np.cumsum(chip)])
    chip = (csum[edges[1:]] - csum[edges[:-1]]) / np.maximum(1, edges[1:] - edges[:-1])
    skip = n // 5
    f, pc = welch(chip[skip:] - chip[skip:].mean(), FS, nperseg=8192)
    f, pr = welch(ref[skip:] - ref[skip:].mean(), FS, nperseg=8192)
    return f, pc, pr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build/ref")
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    out = os.path.join(args.build, "filt")
    os.makedirs(out, exist_ok=True)
    cases = []
    for model in ("6581", "8580"):
        for mode, name in ((1, "LP"), (2, "BP"), (4, "HP"), (5, "notch")):
            for fc in (700, 1000, 1300, 1600, 1900):
                for res in (0, 8, 15):
                    cases.append((model, name, mode, fc, res))
    if args.quick:
        cases = [c for c in cases if c[3] == 1300 and c[4] in (0, 15)]
    print(f"{'chip':<6}{'mode':<7}{'fc':>6}{'res':>5}{'mean dB':>9}{'rms dB':>8}{'worst dB':>9}")
    rows = []
    for model, name, mode, fc, res in cases:
        tr = os.path.join(out, "f.trace")
        trace_for(tr, fc, res, 1, mode)
        f, pc, pr = spectra(args.build, model, tr, os.path.join(out, "f"))
        band = (f > 100) & (f < 12000)
        # reSID's output has a floor (its dither and finite-gain summers) that the
        # reference does not reproduce: grade only bins 10 dB above it.
        floor = np.percentile(pc[band], 3)
        sel = band & (pc > 10 * floor)
        d = 10 * np.log10(pr[sel] / pc[sel])
        mean, rms, worst = d.mean(), np.sqrt((d ** 2).mean()), np.abs(d).max()
        print(f"{model:<6}{name:<7}{fc:>6}{res:>5}{mean:>9.2f}{rms:>8.2f}{worst:>9.2f}")
        rows.append((model, name, rms))
    print()
    for name in ("LP", "BP", "HP", "notch"):
        r = [x[2] for x in rows if x[1] == name]
        if r:
            print(f"{name:<6} mean rms {np.mean(r):.2f} dB, worst {np.max(r):.2f} dB")
    mean_all = np.mean([x[2] for x in rows])
    lp_worst = max([x[2] for x in rows if x[1] == "LP"] or [0.0])
    ok = mean_all < LIMIT_MEAN_DB and lp_worst < LIMIT_LP_DB
    print(f"all    mean rms {mean_all:.2f} dB (limit {LIMIT_MEAN_DB}), worst LP {lp_worst:.2f} dB (limit {LIMIT_LP_DB}): "
          + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
