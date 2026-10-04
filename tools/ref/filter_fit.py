#!/usr/bin/env python3
"""Measure reSID's filter and fit the reference model's parameters to it.

The stimulus is the gate's: a noise voice at full level (bit-exact in reSID and
the model) routed through the filter. For a grid of cutoffs and a few
resonances reSID's chip output is taken per cycle for each of the low-pass,
band-pass and high-pass outputs and for the voice routed past the filter; the
ratio of the Welch spectra is the filter path's response as the mixer sees it
(so the level-dependent behaviour of reSID's 6581 model is included at this
level).

The model is the DSP's (src/ref/sid_ref.c): a TPT state-variable filter with
g = tan(pi f0 / fs) and damping k, three outputs lp = 1/D, bp = s/D, hp = s^2/D
(D = s^2 + k s + 1, s = j tan(pi f / fs) / g), each with its own gain, and a
share of lp in the high-pass output:

    LP mode: gl * lp     BP mode: gb * bp     HP mode: gh * (hp + leak * lp)

Per cutoff the fit finds f0, k at resonance 0, the three gains and the leak,
jointly on all three outputs and over the resonances; the damping is
k = k0(fc) * kr(res), kr from a fit over all 16 resonances at a few cutoffs.
Writes tools/ref/filter_fit_<model>.txt (fc f0 k0 gl gb gh leak, and the rms
error in dB per output) and filter_q_<model>.txt (res kr);
tools/ref/gen_filter_tables.py turns them into src/ref/filter_tables.h.

  filter_fit.py [--build build/ref] [--jobs 8]
"""
import argparse
import os
import subprocess
import numpy as np
from concurrent.futures import ThreadPoolExecutor
from scipy.optimize import least_squares
from scipy.signal import welch

CLOCK = 985248.0
FS = 25175000.0 / 512
NOISE_FREQ = 0x4000
CYCLES = 2_000_000
FC_GRID = list(range(0, 2048, 32)) + [2047]
RES_FIT = [0, 5, 10, 15]
KR_FCS = {"6581": [960, 1152, 1344], "8580": [384, 768, 1152]}
MODES = (1, 2, 4)
G_MAX = 3.7                 # tan() stays below 4 for the Q21 words (f0 about 20.4 kHz)
K_MAX = 3.9                 # k/4 is a Q23 word
W_MAX = 1.9                 # a mode weight / 2 is a Q23 word
LEAK_MAX = 0.5


def spectrum(build, out, model, fc, res, filt, mode):
    tag = f"{model}_{fc}_{res}_{filt}_{mode}"
    npy = os.path.join(out, tag + ".npy")
    if os.path.exists(npy):
        return np.load(npy)
    tr, raw = os.path.join(out, tag + ".trace"), os.path.join(out, tag + ".i32")
    with open(tr, "w") as t:
        for reg, v in ((21, fc & 7), (22, fc >> 3), (23, (res << 4) | filt), (24, (mode << 4) | 15),
                       (0, NOISE_FREQ & 255), (1, NOISE_FREQ >> 8), (5, 0), (6, 0xf0), (4, 0x81)):
            t.write(f"0 {reg} {v}\n")
        t.write(f"end {CYCLES}\n")
    subprocess.run([os.path.join(build, "oracle_resid"), "mix", model, tr, raw], check=True)
    chip = np.fromfile(raw, dtype=np.int32).astype(np.float64)
    n = int(len(chip) * FS / CLOCK)
    edges = (np.arange(n + 1) * (len(chip) / n)).astype(int)
    cs = np.concatenate([[0], np.cumsum(chip)])
    x = (cs[edges[1:]] - cs[edges[:-1]]) / np.maximum(1, edges[1:] - edges[:-1])
    x = x[n // 5:]
    _, p = welch(x - x.mean(), FS, nperseg=8192)
    np.save(npy, p)
    os.remove(raw)
    os.remove(tr)
    return p


F = np.fft.rfftfreq(8192, 1 / FS)
BAND = (F > 60) & (F < 12000)
W0 = np.tan(np.pi * F / FS)


def model_response(g, k, gl, gb, gh, leak):
    w = W0 / g
    d = (1 - w * w) + 1j * k * w
    return {1: gl / d, 2: gb * 1j * w / d, 4: gh * (-w * w + leak) / d}


class Fit:
    def __init__(self, build, out, model, jobs):
        self.build, self.out, self.model, self.jobs = build, out, model, jobs
        self.direct = spectrum(build, out, model, 0, 0, 0, 0)

    def measure(self, cases):
        with ThreadPoolExecutor(self.jobs) as pool:
            list(pool.map(lambda c: spectrum(self.build, self.out, self.model, c[0], c[1], 1, c[2]), cases))

    def target(self, fc, res, mode):
        p = spectrum(self.build, self.out, self.model, fc, res, 1, mode)
        floor = np.percentile(p[BAND], 3)              # reSID's own floor: only bins well above it count
        sel = BAND & (p > 10 * floor)
        return p / self.direct, sel

    def errors(self, fc, res, params):
        h = model_response(*params)
        out = []
        for m in MODES:
            t, sel = self.target(fc, res, m)
            e = 10 * np.log10(np.abs(h[m][sel]) ** 2 / t[sel])
            out.append(np.sqrt((e ** 2).mean()) if sel.sum() else 0.0)
        return out

    def residual(self, fc, reslist, unpack):
        t = {(r, m): self.target(fc, r, m) for r in reslist for m in MODES}

        def f(p):
            out = []
            for r in reslist:
                h = model_response(*unpack(p, r))
                for m, wt in ((1, 1.4), (2, 1.0), (4, 1.0)):   # the low-pass is the common mode in music
                    tm, sel = t[(r, m)]
                    if sel.sum():
                        out.append(wt * 10 * np.log10(np.abs(h[m][sel]) ** 2 / tm[sel]) / np.sqrt(sel.sum()))
            return np.concatenate(out)
        return f

    def fit_fc(self, fc, kr=None, start=None):
        """g, k (per resonance, or k0 with the given kr), gl, gb, gh, leak."""
        nk = 1 if kr is not None else len(RES_FIT)

        def unpack(p, r):
            k = np.exp(p[1]) * kr[r] if kr is not None else np.exp(p[1 + RES_FIT.index(r)])
            return np.exp(p[0]), min(k, K_MAX), np.exp(p[1 + nk]), np.exp(p[2 + nk]), np.exp(p[3 + nk]), p[4 + nk]

        lo = [np.log(1e-3)] + [np.log(0.05)] * nk + [np.log(0.02)] * 3 + [-LEAK_MAX]
        hi = [np.log(G_MAX)] + [np.log(K_MAX)] * nk + [np.log(W_MAX)] * 3 + [LEAK_MAX]
        f = self.residual(fc, RES_FIT, unpack)
        best = None
        starts = [start] if start is not None else []
        starts += [[np.log(g0)] + [np.log(k0)] * nk + [0.0, 0.0, 0.0, 0.0] for g0 in (0.02, 0.1, 0.4, 1.2) for k0 in (0.8, 2.0)]
        for s in starts:
            s = np.clip(s, np.array(lo) + 1e-6, np.array(hi) - 1e-6)
            r = least_squares(f, s, bounds=(lo, hi))
            if best is None or r.cost < best.cost:
                best = r
        return best.x, unpack

    def fit_k(self, fc, res, fixed):
        """k alone at one resonance, everything else fixed."""
        g, _, gl, gb, gh, leak = fixed
        f = self.residual(fc, [res], lambda p, r: (g, np.exp(p[0]), gl, gb, gh, leak))
        return float(np.exp(least_squares(f, [np.log(1.0)], bounds=([np.log(0.05)], [np.log(K_MAX)])).x[0]))


def run(build, model, jobs):
    out = os.path.join(build, "filt", "fit")
    os.makedirs(out, exist_ok=True)
    fit = Fit(build, out, model, jobs)
    fit.measure([(fc, r, m) for fc in FC_GRID for r in RES_FIT for m in MODES]
                + [(fc, r, m) for fc in KR_FCS[model] for r in range(16) for m in MODES])
    # the damping against the resonance register, from a few cutoffs
    ratios = []
    for fc in KR_FCS[model]:
        p, unpack = fit.fit_fc(fc)
        fixed = unpack(p, 0)
        ks = [fit.fit_k(fc, r, fixed) for r in range(16)]
        ratios.append(np.array(ks) / ks[0])
    kr = np.minimum.accumulate(np.exp(np.mean(np.log(ratios), axis=0)))
    kr[0] = 1.0
    with open(f"tools/ref/filter_q_{model}.txt", "w") as o:
        o.write("# res  kr = k(res) / k(0) (fitted at fc " + ", ".join(map(str, KR_FCS[model])) + ")\n")
        for r in range(16):
            o.write(f"{r} {kr[r]:.4f}\n")
    rows, prev = [], None
    with ThreadPoolExecutor(jobs) as pool:
        fits = list(pool.map(lambda fc: fit.fit_fc(fc, kr), FC_GRID))
    with open(f"tools/ref/filter_fit_{model}.txt", "w") as o:
        o.write("# fc  f0 Hz  k0  gl  gb  gh  leak   rms dB of lp bp hp (mean over res " + ",".join(map(str, RES_FIT)) + ")\n")
        for fc, (p, unpack) in zip(FC_GRID, fits):
            g, k0, gl, gb, gh, leak = unpack(p, 0)
            err = np.mean([fit.errors(fc, r, unpack(p, r)) for r in RES_FIT], axis=0)
            f0 = np.arctan(g) * FS / np.pi
            o.write(f"{fc} {f0:.1f} {k0:.4f} {gl:.4f} {gb:.4f} {gh:.4f} {leak:.4f}   {err[0]:.2f} {err[1]:.2f} {err[2]:.2f}\n")
            print(model, fc, f"f0 {f0:7.0f} k0 {k0:.2f} gl {gl:.2f} gb {gb:.2f} gh {gh:.2f} leak {leak:+.3f}  err {err[0]:.1f} {err[1]:.1f} {err[2]:.1f}", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build/ref")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("models", nargs="*", default=["6581", "8580"])
    a = ap.parse_args()
    for m in a.models:
        run(a.build, m, a.jobs)
