#!/usr/bin/env python3
"""Measure reSID's filter: fit f0 and Q of a 2-pole low-pass to its response.

reSID is driven with white noise on the external input (oracle_resid response),
the transfer function is estimated with Welch's method and a second-order
low-pass (times the fixed external filter and a free gain) is fitted to it.
Writes tools/ref/filter_curve_<model>.txt: "fc f0_hz" rows (every 32nd fc) and
filter_q_<model>.txt: "res Q gain_db" rows. The reference model's host-side
coefficient tables (src/ref/filter_tables.h) are generated from these.
"""
import subprocess, os
import numpy as np
from scipy.signal import welch
from scipy.optimize import least_squares

FS = 985248.0 / 16
ORACLE = os.path.join("build", "ref", "oracle_resid")
F_HP = 1 / (2 * np.pi * 1e3 * 10e-6)
F_LP = 1 / (2 * np.pi * 1e4 * 1e-9)


def response(model, fc, res, mode):
    out = f"build/filt/r_{model}_{fc}_{res}_{mode}.f32"
    subprocess.run([ORACLE, "response", model, str(fc), str(res), str(mode), out], check=True)
    d = np.fromfile(out, dtype=np.float32).reshape(-1, 2)
    d = d[len(d) // 8:]                      # drop the DC settling transient
    f, pi = welch(d[:, 0], FS, nperseg=32768)
    f, po = welch(d[:, 1] - d[:, 1].mean(), FS, nperseg=32768)
    return f, po / pi


def ext(f):
    return (f / F_HP) ** 2 / (1 + (f / F_HP) ** 2) / (1 + (f / F_LP) ** 2)


def model_lp(p, f):
    g, f0, q = p
    x = f / f0
    return g * g * ext(f) / ((1 - x * x) ** 2 + (x / q) ** 2)


def cutoff(model, fc, res=0):
    """-3 dB point and passband power gain (against the 50-120 Hz plateau)."""
    f, h = response(model, fc, res, 1)
    h = h / ext(f)
    plateau = np.median(h[(f > 50) & (f < 120)])
    hs = np.convolve(h, np.ones(9) / 9, mode="same")
    s = (f > 120) & (f < 30000)
    ix = np.nonzero(s & (hs < plateau / 2))[0]
    return (f[ix[0]] if len(ix) else 30000.0), plateau


def fit2(model, fc, res=0):
    """Least-squares (f0, Q) of the 2-pole low-pass on reSID's response; also the rms dB error."""
    f, h = response(model, fc, res, 1)
    floor = np.median(h[(f > 24000) & (f < 30000)])       # reSID's dither noise
    s = (f > 12) & (f < 16000) & (h > 8 * floor)
    f, h = f[s], h[s]
    lh = np.log10(h)
    best = None
    for f0 in np.geomspace(150, 40000, 100):
        for q in np.geomspace(0.35, 3, 40):
            lm = np.log10(model_lp((1.0, f0, q), f))
            off = np.mean(lh - lm)
            c = np.mean((lh - lm - off) ** 2)
            if best is None or c < best[0]:
                best = (c, f0, q)
    return best[1], best[2], 10 * np.sqrt(best[0])


if __name__ == "__main__":
    for model in ("6581", "8580"):
        with open(f"tools/ref/filter_curve_{model}.txt", "w") as o:
            o.write("# fc  f0 Hz  Q   (res 0; 2-pole fit, or the -3 dB point with Q 0.707 where the fit is worse than 5 dB)  fit dB\n")
            for fc in list(range(0, 2048, 64)) + [2047]:
                f0, q, err = fit2(model, fc)
                if err > 5.0:
                    f0, _ = cutoff(model, fc)
                    q = 0.707
                print(model, "fc", fc, f"f0={f0:.0f} Q={q:.2f} fit {err:.2f} dB", flush=True)
                o.write(f"{fc} {f0:.1f} {q:.4f} {err:.2f}\n")
        with open(f"tools/ref/filter_q_{model}.txt", "w") as o:
            o.write("# res  Q ratio to res 0 (fitted at fc=1100)\n")
            qs = [fit2(model, 1100, r)[1] for r in range(16)]
            for r, q in enumerate(qs):
                print(model, "res", r, f"Q ratio {q / qs[0]:.3f}", flush=True)
                o.write(f"{r} {q / qs[0]:.4f}\n")
