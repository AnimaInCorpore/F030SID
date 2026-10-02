#!/usr/bin/env python3
"""How badly does a SID oscillator alias at the Falcon's 49.17 kHz codec rate?

Ground truth is the chip itself: the oscillator evaluated once per 985,248 Hz
SID cycle, low-passed ideally (windowed sinc, passband 20 kHz, stopband
starting at fs-20 kHz so nothing can fold into the band) and read at the codec
instants. That is what reSID's resampling mode produces. The candidates are
the ways a DSP that has ~326 instruction cycles per output frame could
produce one frame:

  naive     the waveform at the sample instant (reSID's SAMPLE_FAST)
  box       the mean of the waveform over the 20.04-cycle sample interval
            (first-order antiderivative anti-aliasing; sinc droop)
  blep2     naive minus a 2-sample polyBLEP at each discontinuity
  os2, os4  naive at 2x / 4x the rate, then a decimation FIR
            (not affordable on the DSP; here as the cost-ignoring reference)

Waveforms are evaluated unquantised so the numbers isolate aliasing; the
chip's own 12-bit quantisation is a separate -74 dB white floor.

Alias power is the in-band (0-20 kHz) power in FFT bins that are not within a
few bins of a true harmonic of the fundamental, relative to the signal power.
"""

import sys

import numpy as np
from scipy.signal import firwin, windows

CLOCK = 985248.0                       # PAL SID clock, Hz
FS = 25175000.0 / 256 / 2              # codec rate at prescale 1, Hz
CYC = CLOCK / FS                       # SID cycles per output frame (20.0376)
BAND = 20000.0                         # band that must be clean, Hz
NFRAMES = 1 << 15


def sinc_kernel(width_cycles=300):
    """Continuous windowed-sinc low-pass h(t) for the truth, cutoff in the
    middle of the transition band 20 kHz .. fs-20 kHz."""
    fcut = (BAND + (FS - BAND)) / 2.0 / 1.0   # = FS/2, centre of transition
    # Kaiser beta ~ 9 gives ~90 dB; the transition width is FS-2*BAND.
    beta = 9.0

    def h(t_cycles):
        t = t_cycles / CLOCK                       # seconds
        x = 2.0 * fcut * t
        w = np.where(np.abs(t_cycles) <= width_cycles,
                     np.i0(beta * np.sqrt(np.clip(1 - (t_cycles / width_cycles) ** 2, 0, 1)))
                     / np.i0(beta), 0.0)
        return 2.0 * fcut / CLOCK * np.sinc(x) * w
    return h, width_cycles


def waveform(kind, phase, pw=0.5):
    """phase in [0,1) -> value in [-1,1)."""
    if kind == "saw":
        return 2.0 * phase - 1.0
    if kind == "pulse":
        return np.where(phase >= pw, 1.0, -1.0)
    if kind == "tri":
        return 4.0 * np.abs(phase - np.floor(phase + 0.5)) - 1.0 + 0.0 * phase
    raise ValueError(kind)


def truth(kind, f0, pw, tn):
    """Ideal band-limited value at the output instants tn (in SID cycles)."""
    h, width = sinc_kernel()
    m0 = np.floor(tn[0]) - width
    m1 = np.ceil(tn[-1]) + width
    m = np.arange(m0, m1 + 1)
    x = waveform(kind, (m * f0 / CLOCK) % 1.0, pw)
    out = np.empty(len(tn))
    taps = np.arange(-width, width + 1)
    for i, t in enumerate(tn):
        centre = int(np.floor(t))
        idx = centre + taps
        out[i] = np.dot(x[(idx - int(m0))], h(idx - t))
    return out


def polyblep(t, dt):
    """2-sample polyBLEP residual for a unit step at t=0 (t in [0,1))."""
    r = np.zeros_like(t)
    a = t < dt
    x = t[a] / dt
    r[a] = x + x - x * x - 1.0
    b = t > 1.0 - dt
    x = (t[b] - 1.0) / dt
    r[b] = x * x + x + x + 1.0
    return r


def _bspline_step_table(order, n=4001):
    """Integral of the cardinal B-spline of the given order (support `order`
    samples, centred on 0): a smooth band-limited-ish step. order 2 is the
    triangle (polyBLEP2), order 4 the cubic (polyBLEP4)."""
    half = order / 2.0
    x = np.linspace(-half, half, n)
    k = np.ones(n)
    box = np.ones(n // order if n // order > 0 else 1)
    dx = x[1] - x[0]
    kern = np.ones(int(round(1.0 / dx)))
    kern /= kern.sum()
    b = kern.copy()
    for _ in range(order - 1):
        b = np.convolve(b, kern)
    xs = (np.arange(len(b)) - (len(b) - 1) / 2.0) * dx
    s_ = np.cumsum(b) * 1.0
    s_ /= s_[-1]
    return xs, s_


_STEP_TABLES = {}


def bleps(ph, dt, edges, order):
    """Sum of residuals jump*(S(d)-H(d)) for edges=[(phase, jump)]."""
    if order not in _STEP_TABLES:
        _STEP_TABLES[order] = _bspline_step_table(order)
    xs, s_ = _STEP_TABLES[order]
    out = np.zeros_like(ph)
    for e, jump in edges:
        d = (((ph - e + 0.5) % 1.0) - 0.5) / dt
        near = np.abs(d) < order / 2.0
        S = np.interp(d[near], xs, s_)
        H = (d[near] >= 0).astype(float)
        out[near] += jump * (S - H)
    return out


def candidate(method, kind, f0, pw, tn):
    dt = f0 / FS                                # phase step per output frame
    if method == "naive":
        return waveform(kind, (tn * f0 / CLOCK) % 1.0, pw)
    if method == "box":
        # mean over (tn-CYC, tn] by fine sub-sampling of the continuous wave
        sub = 64
        offs = (np.arange(sub) + 0.5) / sub * CYC
        ph = ((tn[:, None] - CYC + offs[None, :]) * f0 / CLOCK) % 1.0
        return waveform(kind, ph, pw).mean(axis=1)
    if method == "blep2":
        ph = (tn * f0 / CLOCK) % 1.0
        y = waveform(kind, ph, pw)
        if kind == "saw":
            y = y - polyblep(ph, dt)                    # falling edge at the wrap
        elif kind == "pulse":
            y = y + polyblep((ph - pw) % 1.0, dt)       # rising edge at pw
            y = y - polyblep(ph, dt)                    # falling edge at the wrap
        return y
    if method in ("blep4", "blep6"):
        order = 4 if method == "blep4" else 6
        ph = (tn * f0 / CLOCK) % 1.0
        y = waveform(kind, ph, pw)
        if kind == "saw":
            return y + bleps(ph, dt, [(0.0, -2.0)], order)
        if kind == "pulse":
            return y + bleps(ph, dt, [(pw, 2.0), (0.0, -2.0)], order)
        return y
    if method in ("os2", "os4"):
        k = 2 if method == "os2" else 4
        ntaps = 16 * k + 1
        # decimating low-pass at the oversampled rate
        lp = firwin(ntaps, (BAND + (FS - BAND) / 2) / (FS * k / 2.0),
                    window=("kaiser", 8.0))
        half = ntaps // 2
        out = np.empty(len(tn))
        sub_t = (tn[:, None] + (np.arange(-half, half + 1) * CYC / k)[None, :])
        vals = waveform(kind, (sub_t * f0 / CLOCK) % 1.0, pw)
        return (vals * lp[None, :]).sum(axis=1)
    raise ValueError(method)


def alias_db(y, truth_y, f0):
    """In-band alias power vs signal power, dB."""
    n = len(y)
    win = windows.blackmanharris(n)
    spec = np.abs(np.fft.rfft(y * win)) ** 2
    freqs = np.fft.rfftfreq(n, 1.0 / FS)
    sig = np.abs(np.fft.rfft(truth_y * win)) ** 2
    inband = freqs <= BAND
    # bins near a true harmonic belong to the signal (incl. droop)
    k = np.rint(freqs / f0)
    near = np.abs(freqs - k * f0) < 12 * FS / n
    alias = spec[inband & ~near & (freqs > 30.0)].sum()
    total = sig[inband].sum()
    return 10 * np.log10(alias / total + 1e-30)


def droop_db(y, truth_y):
    """Level error of the 20 kHz-limited signal itself (box filter droop)."""
    return 10 * np.log10(np.sum(y ** 2) / np.sum(truth_y ** 2))


def main():
    f0s = [113.7, 441.3, 1013.1, 2007.7, 3801.3]
    cases = [("saw", 0.5), ("pulse", 0.5), ("pulse", 0.125), ("tri", 0.5)]
    methods = ["naive", "box", "blep2", "blep4", "blep6", "os2", "os4"]
    start = 100.0 * CYC
    tn = start + np.arange(NFRAMES) * CYC
    print(f"output rate {FS:.3f} Hz, {CYC:.4f} SID cycles per frame")
    print("alias power in 0-20 kHz relative to signal, dB (lower is better)\n")
    print(f"{'wave':<10}{'f0 Hz':>7}" + "".join(f"{m:>9}" for m in methods))
    for kind, pw in cases:
        for f0 in f0s:
            tr = truth(kind, f0, pw, tn)
            row = []
            for m in methods:
                if kind == "tri" and m.startswith("blep"):
                    row.append(float("nan"))
                    continue
                y = candidate(m, kind, f0, pw, tn)
                row.append(alias_db(y, tr, f0))
            name = kind if kind != "pulse" else f"pulse{int(pw*100)}"
            print(f"{name:<10}{f0:>7.0f}" + "".join(f"{v:>9.1f}" for v in row))
            sys.stdout.flush()


if __name__ == "__main__":
    main()
