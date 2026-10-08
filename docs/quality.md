# SID quality and feasibility measurements

The analytical experiments in this document measure oscillator aliasing,
noise sampling and filter precision at the Falcon codec rate. They use the
scripts and recorded results in `tools/feasibility/`; the experiments model
the chip analytically rather than executing the DSP kernel.

## Current implementation and budget

F030SID renders one PAL MOS 6581/8580 at 49,169.921875 Hz. At the modeled
DSP clock of 32,084,988 Hz, the instruction budget is about 326.3 cycles per
output frame, including synthesis, SSI interrupts and command transport.
Each frame spans about 20.0376 SID cycles at the 985,248 Hz PAL clock.
The mono output is duplicated to both stereo channels.

The implemented kernel uses sample-instant waveform evaluation, four-point
polyBLEP for plain saw/pulse edges, model-specific DAC and combined-waveform
tables, exact bulk-clocked envelopes and sync, and a fitted TPT filter with
48-bit state. Filter coefficients are derived on the host. See
[the DSP kernel](dsp-kernel.md) and [reference-model measurements](../src/ref/README.md).

The measured implementation supersedes the original paper cycle estimates.
Some passages exceed the budget even after optimization. In the
[latest two-minute load check](performance.md#two-minute-load-check), twelve of seventeen tunes
pass both playback modes; Monofail overtakes and four other tunes miss pacing.
The ring absorbs short spikes, not sustained overload. Two SIDs and nonlinear
6581 filter distortion are not implemented.

## Quality findings (measured)

The analytical reference for the oscillator experiments is an ideal waveform
evaluated every SID cycle, then
low-passed ideally (windowed sinc, passband 20 kHz, stopband from
fs - 20 kHz so nothing folds into the band) and read at the codec instants.
This follows the same resampling principle used for the reSID-based voice
gate, but these analytical experiments do not execute reSID. The filter
experiments below instead compare discretizations with an analog prototype.

### 1. Oscillators alias badly unless they are band-limited

SID saw and pulse are hard-edged and the chip's output is sampled at ~1 MHz.
In-band alias power relative to the signal (dB, lower is better; full table in
`tools/feasibility/alias_results.txt`):

| Wave, f0 | naive | box | 2x oversample | 4x oversample | polyBLEP-2 | polyBLEP-4 | polyBLEP-6 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| saw 114 Hz | -27.5 | -39.6 | -32.6 | -34.2 | -47.5 | -61.4 | -74.4 |
| saw 441 Hz | -20.8 | -33.6 | -24.7 | -28.0 | -41.8 | -55.9 | -69.1 |
| saw 1013 Hz | -17.1 | -29.5 | -20.9 | -24.0 | -37.5 | -51.1 | -64.0 |
| saw 3801 Hz | -10.8 | -23.1 | -14.5 | -17.5 | -31.1 | -44.8 | -57.9 |
| pulse 50% 441 Hz | -22.6 | -35.2 | -26.5 | -29.6 | -43.3 | -57.2 | -70.2 |
| pulse 12% 3801 Hz | -14.6 | -31.2 | -19.4 | -25.0 | -43.0 | -62.5 | -80.3 |
| triangle 441 Hz | -62.6 | -72.2 | -66.9 | -67.6 | n/a | n/a | n/a |
| triangle 3801 Hz | -35.2 | -46.2 | -41.7 | -43.3 | n/a | n/a | n/a |

- **Naive per-frame sampling (reSID's fast mode) is poor**: -11 to -30 dB on
  saw/pulse, i.e. an audible inharmonic haze.
- **Oversampling does not pay**: each doubling buys about 4-5 dB, and 4x is
  not affordable anyway.
- **PolyBLEP does**: 4-sample gives -45 to -64 dB, 6-sample -58 to -80 dB.
  It touches only frames near an edge, so its average cost is small at
  musical pitches (about 4 f0/fs of the frames at width 4: 3.6% at 441 Hz,
  31% at 3.8 kHz).
- The triangle needs nothing special below ~1 kHz; at the top of its range a
  BLAMP correction or the box average is worth having (-35 to -46 dB).
- Test frequencies are incommensurate with the codec rate on purpose: a first
  run with round numbers folded aliases onto harmonics and read -100 dB.

**Update, from the reference model** (`src/ref/README.md`, measured on reSID's
modeled DAC, envelope and the 20/21-cycle frame grid): the 8580 reproduces the
figures above (saw -55.6/-44.7 dB at 441 Hz/3.8 kHz); the 6581 is 7-9 dB worse
on saw and triangle because its non-linear DAC puts kinks in the ramp that an
edge-only polyBLEP does not correct. The frame grid also jitters the sample
instants by up to a cycle, and evaluating the phase at the true instant
(one multiply per voice) is worth 5-18 dB; without it the figures above are
not reached.

Limits: noise and combined waveforms have no clean edges to correct, and
sync resets are discontinuities whose position must be known to sub-frame
accuracy. Not measured here: sync, ring
modulation, PWM sweeps, combined waveforms.

### 2. Noise: sample or average, both fine; average at high rates

The LFSR is clocked by oscillator bit 19, up to 61.6 kHz (about 1.25 steps per
frame at the maximum frequency register).

| F register | LFSR clock | naive level | box level |
| ---: | ---: | ---: | ---: |
| 1024 | 1.0 kHz | 0.0 dB | -0.0 dB |
| 16384 | 15.4 kHz | +0.2 dB | -0.1 dB |
| 65535 | 61.6 kHz | **+1.8 dB** | -0.1 dB |

Levels are against the band-limited chip over 20 Hz-20 kHz. The spectral tilt
(10-20 kHz vs 0-5 kHz) of the box average also matches the chip at the top
rate (-3.7 vs -3.8 dB) where naive reads -0.1 dB. Conclusion: look up the LFSR
output per frame at all but the highest noise rates, and weight the 1-2
steps inside a frame at the top. The noise LFSR itself can be bit-exact
(23-bit shift, taps 22 and 17).

### 3. Filter: stable, but not matched to the analog filter near the top

State-variable filter discretisations at 49.17 kHz against the analog
prototype that reSID's 1 MHz integration approximates (worst error where the
response is above -20 dB, below 8 kHz / below 16 kHz; Q 0.707):

| fc | Euler, 1 step | Euler, 2 substeps | TPT (bilinear, prewarped) |
| ---: | ---: | ---: | ---: |
| 300 Hz | 0.29 / 0.29 dB | 0.17 / 0.17 | 0.11 / 0.11 |
| 2 kHz | 2.15 / 3.46 | 1.14 / 2.38 | 0.88 / 4.04 |
| 5 kHz | 3.16 / 9.19 | 3.29 / 3.44 | 0.89 / 7.22 |
| 8 kHz | 1.43 / 10.35 | 6.56 / 8.09 | 1.45 / 6.36 |
| 12 kHz | **unstable** | 11.47 / 11.47 | 3.59 / 3.59 |

(Q 1.707 and the Chamberlin form are in
`tools/feasibility/noise_filter_results.txt`.)

- Single-step forward Euler or Chamberlin goes unstable at the top cutoffs
  (reSID itself sub-steps for exactly this reason).
- **TPT with a prewarped coefficient is stable everywhere** and is within
  ~1.5 dB below 8 kHz up to an 8 kHz cutoff; the residual error is bilinear
  warping near Nyquist, mostly above 8 kHz. Cost is the same as Euler plus
  one multiply, so it is the default choice; coefficients (`g = tan(pi fc/fs)`)
  are computed on the host.
- Errors of 4-10 dB in the 8-16 kHz region at cutoffs above 5 kHz are real.
  Mitigations if listening says so: run the filter at 2x only for high
  cutoffs, or add a fixed compensation section. Unmeasured: how audible this
  is on real tunes (most use cutoffs well below 5 kHz).
- **Integrator precision matters.** Quantising the two states:

| fc | 24-bit truncating | 24-bit rounding | 32-bit | 48-bit |
| ---: | ---: | ---: | ---: | ---: |
| 30 Hz | **-19 dB** | -52 dB | -99 dB | -197 dB |
| 300 Hz | -67 dB | -90 dB | -138 dB | -234 dB |
| 3 kHz | -108 dB | -121 dB | -169 dB | -265 dB |

Error is relative to the output. A truncating 24-bit state is unusable at low
cutoffs (low `g` amplifies the truncation error). The DSP56001 has 56-bit
accumulators and `L:` 48-bit moves, so keep both states double-precision (or
at minimum round); this costs about one extra instruction per integrator.

## Interpretation and remaining checks

The oscillator experiments motivate band-limiting; the precision experiments
motivate 48-bit filter states. Their idealized models do not establish
whole-player cycle cost or real-time performance. The current fitted filter
has separate measured response results in [the reference docs](../src/ref/README.md).

Noise averaging, BLAMP and other quality options discussed above are study
findings, not implemented features. Noise and combined waveforms currently
use integer-cycle output; the implemented kernel must match the reference
sample for sample. Its filters approximate chip response rather than the
full nonlinear circuit.

Physical-Falcon rate/bus checks, listening comparisons, complete songs and
all subsongs remain outstanding. High register-write rates, combined waveforms,
sync and noise require whole-stream timing checks as well as output checks.
Use [performance notes](performance.md#current-optimizations) for the current optimized paths and limits.

## Reproducing the measurements

```sh
python3 tools/feasibility/alias_study.py > tools/feasibility/alias_results.txt
python3 tools/feasibility/noise_filter_study.py > tools/feasibility/noise_filter_results.txt
```

Needs Python 3 with numpy and scipy; about 2 minutes and 15 seconds. The
SID oscillator and LFSR follow reSID's definitions (24-bit accumulator,
23-bit LFSR clocked on bit 19 with taps 22 and 17); the filter study uses
reSID's resonance range (Q 0.707-1.707). The scripts model the chip
analytically and do not use reSID code or tables.
