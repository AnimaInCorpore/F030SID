# Is high-quality SID emulation possible at 49 kHz on the Falcon DSP?

2026-10-02. Question: can the DSP56001 render a high-quality MOS 6581/8580
SID at the codec's 49,169.92 kHz (prescale 1), 16-bit stereo, in real time?

## Verdict

**Yes for one SID, with a deliberate definition of "high quality".** The
cycle budget is not the obstacle; what the budget cannot buy is reSID's
cycle-by-cycle analog models.

| Target | Verdict |
| --- | --- |
| One SID, band-limited oscillators, 8580-class linear filter, exact ADSR/noise/sync logic, sample-accurate `$D418` writes | **Feasible.** Estimated 100-200 of 326 cycles per frame (30-60%). |
| Same, plus 6581 character through tables (wave/envelope DAC, cutoff curve, static filter distortion) | **Feasible.** Roughly +30 cycles. |
| 6581 filter as reSID models it (nonlinear VCR integrated every 1 MHz cycle) | **Not feasible.** About 4-6x the whole budget. Approximate it. |
| Two SIDs (2SID tunes) at 49.17 kHz | **Tight.** Typical load fits, the worst case does not. Fall back to 32.78 kHz or a cheaper tier for the second chip. |
| Sample-for-sample equality with reSID | **Not a goal.** Same stance as F030MXDRV's exact/practical split. |

"Stereo" costs nothing extra: the SID is mono, so the two SSI words per frame
carry the same sample. Real stereo needs a second SID (2SID tunes) or
non-authentic per-voice panning.

Status of the evidence: the **aliasing, noise, filter and precision results
below are measured** (scripts in `tools/feasibility/`, results committed). The
**cycle costs are estimates** from instruction counting, calibrated against
two measured DSP kernels in sibling projects. Nothing was assembled or run on
the DSP here: this machine has no DOSBox or Hatari. The first implementation
gate must be a profiled inner loop in the DSP-calibrated Hatari (see
[Next steps](#next-steps)).

## Budget

The DSP runs 32,084,988 Hz / 2 = 16.04 MIPS (see `hatari-timing.md`).

| Output rate | Instruction cycles per frame |
| --- | ---: |
| 32.780 kHz (F030MXDRV) | 489.4 |
| **49.170 kHz** | **326.3** |

The SID clock is 985,248 Hz (PAL), so one output frame spans 20.0376 SID
cycles. Rendering the chip at its own clock is out of the question (16 DSP
cycles per SID cycle), so the kernel is a frame-rate model that must recover
the sub-frame behaviour explicitly.

Calibration points from the sibling projects, both measured in calibrated
Hatari:

- F030MXDRV, 8 FM channels x 4 operators at 32.78 kHz: 336.6 cycles per frame
  for synthesis, about 10.5 per operator, 391.8 with transport.
- ScummVM AdLib, OPL2 at **49.17 kHz** with 32-frame blocks: 189.7-279.4
  cycles per frame (58-86% of 326.3) for 18 operators with feedback, tremolo,
  vibrato and rhythm mode, i.e. 10-15 cycles per operator including all
  block overhead. Stream-mode slack was measured down to 0.46-2.17 ms of a
  15.62 ms period at the tightest.

A SID voice is roughly 1.5-2.5 OPL operators of work (phase, waveform,
envelope, plus band-limiting). Three voices plus a filter therefore land in
the same order of magnitude as OPL's *lighter* cases, not its heaviest.

## Quality findings (measured)

Ground truth for everything below is the chip evaluated every SID cycle, then
low-passed ideally (windowed sinc, passband 20 kHz, stopband from
fs - 20 kHz so nothing folds into the band) and read at the codec instants.
That is what reSID's resampling mode produces.

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
  saw/pulse, i.e. an audible inharmonic haze. This is the same lesson the
  OPL project learned (blurry at 32.78 kHz).
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

Limits: noise and combined waveforms have no clean edges to correct, and
sync resets are discontinuities whose position must be known to sub-frame
accuracy (see Design implications). Not measured here: sync, ring
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

(Q 1.707 and the Chamberlin form are in `noise_filter_results.txt`.)

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

## Cycle estimate (not measured)

Per output frame at 49.17 kHz, operator-major block loops as in the OPL and
YM2151 kernels, voice state in internal X/Y. "Typical" is a mixed-waveform
tune; "worst" is all three voices on the most expensive paths simultaneously.

| Stage | Typical | Worst | Notes |
| --- | ---: | ---: | --- |
| Phase accumulator, envelope ramp, multiply, store | 15 | 21 | 5-7 per voice; 24-bit phase wraps in the accumulator, saw is the phase itself |
| Waveform shaping (tri `abs`, pulse compare+limit) | 8 | 24 | saturating move gives a branchless pulse |
| Combined waveform / DAC table lookups | 0 | 24 | 4 tables (PS, PT, ST, PST), ~8 cycles each incl. pointer-latency `nop` |
| PolyBLEP-4 at edges | 10 | 36 | typical: edge check ~5 per edge, correction on ~10% of frames |
| Noise (LFSR step, 8-bit gather, box weights) | 0 | 36 | only voices with noise selected pay |
| Sync/ring-mod bookkeeping | 3 | 12 | master edge time ring, sub-frame slave reset (amortised divide) |
| Mix to filter/direct buses | 6 | 6 | |
| TPT filter, double-precision states | 16 | 32 | worst: two substeps at high cutoff |
| External RC filters (HP ~16 Hz, LP ~16 kHz), volume, DC, clip | 12 | 12 | `$D418` volume and voice DC offset are what make digis audible |
| Event FIFO check per frame, `$D418` sample-accurate writes | 4 | 10 | |
| Block-boundary pass: envelope rate/ADSR counters, parameter loads | 7 | 14 | OPL measured ~60 for 18 operators at 32-frame blocks; SID has 3 voices |
| SSI transmit interrupt (2 words/frame), ring, refill receive | 25 | 30 | OPL measured 14-23 plus loaders; F030MXDRV 55 incl. PCM |
| **Total** | **~106 (33%)** | **~257 (79%)** | of 326.3 |

How to read it: the typical case has ample margin; the worst case stays under
the budget but not under the 20% worst-period margin OPL asked of itself, so
the worst-case paths (all-noise, all-combined, high-cutoff substeps) must be
measured and, if needed, cut (e.g. 6581-flavoured extras off). The block
structure also means per-frame cost is variable, and a 15.62 ms period has to
fit on average, not per frame. Quality extras fit in the margin:
- 6581 flavour via tables (wave DAC, envelope DAC, static filter waveshaper,
  cutoff curve on the host): about +30.
- PolyBLEP-6 instead of -4: edge corrections cost 50% more on the frames they
  touch.

Why exact reSID 6581 is out: its filter is clocked every 985 kHz cycle with
a nonlinear voltage-controlled-resistor integrator at several dozen
operations per cycle. At 20 cycles per frame that is 1,000-2,000 DSP
instructions per frame, 3-6x the entire budget, before the oscillators.
This is an estimate from reading the algorithm, not a profile.

## Design implications

These refine `architecture.md` and `scummvm-opl-hints.md`:

1. **Target 49.17 kHz first.** Naive 32.78 kHz would alias more (the same
   bright-material finding as the OPL project) and the budget is not the
   constraint. Keep 32.78 kHz as the fallback for 2SID.
2. **Band-limit saw and pulse with 4-point polyBLEP** (6-point if the budget
   allows). Do not spend cycles on oversampling.
3. **Sub-frame timing is a first-class feature**: a frame is 20.04 cycles.
   Sync resets and noise steps need the fractional time of the event inside
   the frame (a reciprocal-table or iterative divide, amortised since sync is
   rare). Register writes need timestamps in SID cycles; `$D418` writes
   (digis) must land on the right frame, not the right 32-frame block.
4. **Block-rate control for envelopes only** (ramped per frame within a
   block), per the OPL result that 32-frame blocks cost more for little gain;
   consider 64.
5. **Filter**: TPT SVF, coefficients and the cutoff curve (6581/8580) on the
   host, double-precision states.
6. **Tables, not circuits**: wave DAC, envelope DAC, combined waveforms,
   cutoff curve, filter waveshaper. Combined waveforms are 4 x 4096 words per
   model in external X/Y (the OPL kernel already uses ~16K words per space).
   They can be generated from reSID/residfp's analytic models on the host.
   The reSID code and its tables are GPL-licensed; decide how F030SID is
   licensed before shipping anything derived from them.
7. **Host load is modest for normal tunes** (estimate, not measured): a
   6502 interpreter at roughly 6-10 68030 clocks per 6502 cycle would use
   37-62% of the 16 MHz 68030 only if the 6502 ran flat out (985,248
   cycles/s); a typical 50 Hz play routine is busy a few percent of the time.
   Digi and multispeed tunes are the heavy case. The 68030 only has to
   timestamp and queue writes.
8. **Stereo**: duplicate the mono sample. For 2SID tunes either run two
   kernels at 32.78 kHz or accept reduced quality on the second chip.

## Risks and unknowns

- **Cycle counts are unverified.** Pipeline `nop`s after address-register
  writes, branch costs and Hatari's two-cycle penalty for instructions that
  touch two external spaces are the usual ways an estimate misses by 30%.
- **Physical hardware at 49.17 kHz is unproven.** The OPL project's 49.17 kHz
  path has only been run in Hatari; F030MXDRV's hardware-proven rate is
  32.78 kHz and its first hardware run found no SSI clock until the sound
  matrix bring-up was corrected. `ratetest.tos` already measures
  prescale 1; run it on a real Falcon before committing to 49.17 kHz.
- **SSI interrupt rate doubles** relative to F030MXDRV; the OPL measurements
  suggest it fits but the worst-period slack was only 0.5-2 ms.
- **Audibility is untested.** The alias and filter numbers are objective; no
  listening was done. -45 dB in-band alias should be inaudible on dense
  material but not necessarily on sparse high saw leads.
- **Combined waveforms, sync, ring mod, PWM and the 6581 filter's real
  behaviour** are not covered by these experiments.
- **Tunes with CIA-driven digis** (4-bit sample playback via `$D418` at 8 kHz
  or more) put several writes per output frame through the event path.
- **Licensing** of any reSID-derived tables (above).

## Next steps

1. Write the 24-bit integer C reference for one voice + envelope + filter
   (per `scummvm-opl-hints.md` section 2), gated against reSID on register
   traces.
2. Write the DSP inner loop for saw+envelope+polyBLEP-4 and the TPT filter;
   profile it in the DSP-calibrated Hatari. This replaces the estimates above
   with measurements; do it before anything else.
3. Run `ratetest.tos` on a physical Falcon at prescale 1.
4. Measure worst-case variants (3 noise voices, 3 combined waveforms, high
   cutoff), then decide which 6581 extras fit.
5. Listening comparison against reSID output for a handful of PSIDs.

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
