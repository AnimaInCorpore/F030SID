#!/usr/bin/env python3
"""Noise sampling, filter discretisation and 24-bit precision at 49.17 kHz.

Three questions the SID kernel's quality depends on:

1. Noise.  The LFSR is clocked by oscillator bit 19, up to 61.6 kHz. Does a
   per-frame lookup (naive) or a per-frame mean (box) give the right level and
   spectrum compared with the chip band-limited to 20 kHz?
2. Filter.  Which 49.17 kHz discretisation of the state-variable filter tracks
   the analog prototype that reSID's 1 MHz integration approximates, up to a
   12 kHz cutoff?
3. Precision.  Do 24-bit integrator states (the DSP56001 word) hold up at low
   cutoffs, or is a 48-bit (L:) state needed?
"""

import numpy as np

CLOCK = 985248.0
FS = 25175000.0 / 256 / 2
CYC = CLOCK / FS
BAND = 20000.0


# ---------------------------------------------------------------- noise ----

def lfsr_stream(freq, ncycles, seed=0x7FFFF8):
    """Per-SID-cycle 8-bit noise output (0..255) as reSID computes it."""
    acc = 0
    sr = seed
    out = np.empty(ncycles, dtype=np.float64)
    cur = noise_out(sr)
    for i in range(ncycles):
        prev = acc
        acc = (acc + freq) & 0xFFFFFF
        if (acc & 0x080000) and not (prev & 0x080000):
            bit0 = ((sr >> 22) ^ (sr >> 17)) & 1
            sr = ((sr << 1) | bit0) & 0x7FFFFF
            cur = noise_out(sr)
        out[i] = cur
    return out


def noise_out(sr):
    return float(((sr & 0x400000) >> 15) | ((sr & 0x100000) >> 14) |
                 ((sr & 0x010000) >> 11) | ((sr & 0x002000) >> 9) |
                 ((sr & 0x000800) >> 8) | ((sr & 0x000080) >> 5) |
                 ((sr & 0x000010) >> 2) | ((sr & 0x000004) >> 1))


def sinc_h(t_cycles, width=300, beta=9.0):
    fcut = FS / 2.0
    t = t_cycles / CLOCK
    w = np.i0(beta * np.sqrt(np.clip(1 - (t_cycles / width) ** 2, 0, 1))) / np.i0(beta)
    w = np.where(np.abs(t_cycles) <= width, w, 0.0)
    return 2.0 * fcut / CLOCK * np.sinc(2.0 * fcut * t) * w


def band_power(y, lo, hi):
    n = len(y)
    spec = np.abs(np.fft.rfft((y - y.mean()) * np.hanning(n))) ** 2
    f = np.fft.rfftfreq(n, 1.0 / FS)
    return spec[(f >= lo) & (f < hi)].sum()


def noise_study():
    nframes = 1 << 14
    start = 400
    ncyc = int((start + nframes + 2) * CYC) + 800
    tn = start * CYC + np.arange(nframes) * CYC
    taps = np.arange(-300, 301)
    print("noise: LFSR clock = F * 0.9396 Hz; levels vs the band-limited chip\n")
    print(f"{'F':>6}{'LFSR kHz':>10}{'naive dB':>10}{'box dB':>9}"
          f"{'tilt truth':>12}{'naive':>8}{'box':>8}")
    for freq in (1024, 4096, 16384, 32768, 65535):
        x = lfsr_stream(freq, ncyc)
        csum = np.concatenate([[0.0], np.cumsum(x)])
        tr = np.empty(nframes)
        for i, t in enumerate(tn):
            c = int(np.floor(t))
            tr[i] = np.dot(x[c + taps], sinc_h(c + taps - t))
        naive = x[np.floor(tn).astype(int)]
        lo = tn - CYC
        def cs(t):
            i = np.floor(t).astype(int)
            return csum[i] + (t - i) * x[i]
        box = (cs(tn) - cs(lo)) / CYC
        p_tr = band_power(tr, 20, BAND)
        row = [10 * np.log10(band_power(naive, 20, BAND) / p_tr),
               10 * np.log10(band_power(box, 20, BAND) / p_tr)]
        def tilt(y):
            return 10 * np.log10(band_power(y, 10000, BAND) / band_power(y, 20, 5000))
        print(f"{freq:>6}{freq*CLOCK/2**20/1000:>10.1f}{row[0]:>10.1f}{row[1]:>9.1f}"
              f"{tilt(tr):>12.1f}{tilt(naive):>8.1f}{tilt(box):>8.1f}")


# --------------------------------------------------------------- filter ----

def analog(kind, f, fc, q):
    s = 1j * f / fc
    d = s * s + s / q + 1.0
    # bp is the integrator-chain output: s/d, peak gain Q (not normalised)
    return {"lp": 1.0 / d, "bp": s / d, "hp": (s * s) / d}[kind]


def run_svf(topology, fc, q, n=1 << 15):
    """Impulse response of one discretisation; returns (lp, bp, hp)."""
    lp = bp = 0.0
    out = np.zeros((3, n))
    x = np.zeros(n)
    x[0] = 1.0
    if topology == "euler":                   # reSID-style, one step per frame
        w = 2 * np.pi * fc / FS
        steps = 1
    elif topology == "euler2":                # two half-steps per frame
        w = 2 * np.pi * fc / FS / 2
        steps = 2
    elif topology == "cham":                  # Chamberlin, f = 2 sin(pi fc/fs)
        w = 2 * np.sin(np.pi * fc / FS)
        steps = 1
    if topology in ("euler", "euler2", "cham"):
        for i in range(n):
            for _ in range(steps):
                hp = x[i] - lp - bp / q
                bp += w * hp
                lp += w * bp
            out[:, i] = (lp, bp, hp)
        return out
    # TPT / zero-delay-feedback state variable filter, prewarped to fc
    g = np.tan(np.pi * fc / FS)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    s1 = s2 = 0.0
    for i in range(n):
        hp = (x[i] - (g + k) * s1 - s2) * a1
        v1 = g * hp
        bpv = v1 + s1
        s1 = bpv + v1
        v2 = g * bpv
        lpv = v2 + s2
        s2 = lpv + v2
        out[:, i] = (lpv, bpv, hp)
    return out


def filter_study():
    print("\nfilter: worst |dB error| versus the analog SVF, where the response"
          " is above -20 dB\n        (cells: error below 8 kHz / below 16 kHz)\n")
    kinds = ("lp", "bp", "hp")
    tops = ("euler", "euler2", "cham", "tpt")
    print(f"{'fc Hz':>7}{'Q':>6}  " + "  ".join(f"{t:>11}" for t in tops))
    n = 1 << 15
    f = np.fft.rfftfreq(n, 1.0 / FS)
    for fc in (300.0, 2000.0, 5000.0, 8000.0, 12000.0):
        for q in (0.707, 1.707):
            cells = []
            for top in tops:
                o = run_svf(top, fc, q, n)
                if not np.all(np.isfinite(o)) or np.abs(o).max() > 1e6:
                    cells.append("unstable")
                    continue
                worst = [0.0, 0.0]
                for idx, kind in enumerate(kinds):
                    h = np.fft.rfft(o[idx])
                    ref = analog(kind, f, fc, q)
                    for j, top_f in enumerate((8000.0, 16000.0)):
                        sel = (f >= 20) & (f <= top_f) & (np.abs(ref) > 0.1)
                        err = 20 * np.log10(np.abs(h[sel]) + 1e-9) - 20 * np.log10(np.abs(ref[sel]))
                        worst[j] = max(worst[j], np.abs(err).max())
                cells.append(f"{worst[0]:5.2f}/{worst[1]:5.2f}")
            print(f"{fc:>7.0f}{q:>6.3f}  " + "  ".join(f"{c:>11}" for c in cells))


# ------------------------------------------------------------ precision ----

def quant(x, bits, mode="round"):
    s = 2.0 ** (bits - 1)
    return np.floor(x * s + 0.5) / s if mode == "round" else np.floor(x * s) / s


def tpt_quantised(x, fc, q, bits, mode):
    g = np.tan(np.pi * fc / FS)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    s1 = s2 = 0.0
    y = np.empty(len(x))
    for i, xi in enumerate(x):
        hp = (xi - (g + k) * s1 - s2) * a1
        v1 = g * hp
        bpv = v1 + s1
        s1 = quant(bpv + v1, bits, mode)
        v2 = g * bpv
        lpv = v2 + s2
        s2 = quant(lpv + v2, bits, mode)
        y[i] = lpv
    return y


def precision_study():
    print("\nprecision: LP output error from quantising the two integrator states\n")
    n = 1 << 15
    t = np.arange(n) / FS
    rng = np.random.default_rng(1)
    x = 0.1 * np.sin(2 * np.pi * 997.0 * t) + 0.05 * rng.standard_normal(n) * 0.1
    print(f"{'fc Hz':>7}{'24b trunc':>11}{'24b round':>11}{'32b round':>11}{'48b round':>11}"
          "   (error dB re output)")
    for fc in (30.0, 300.0, 3000.0, 12000.0):
        ref = tpt_quantised(x, fc, 1.0, 60, "round")
        pw = np.mean(ref ** 2)
        cells = []
        for bits, mode in ((24, "trunc"), (24, "round"), (32, "round"), (48, "round")):
            y = tpt_quantised(x, fc, 1.0, bits, mode)
            cells.append(10 * np.log10(np.mean((y - ref) ** 2) / pw + 1e-30))
        print(f"{fc:>7.0f}" + "".join(f"{c:>11.1f}" for c in cells))


if __name__ == "__main__":
    import sys
    which = sys.argv[1:] or ["noise", "filter", "precision"]
    np.seterr(all="ignore")
    if "noise" in which:
        noise_study()
    if "filter" in which:
        filter_study()
    if "precision" in which:
        precision_study()
