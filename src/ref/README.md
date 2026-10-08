# SID voice reference model

`sid_ref.c` is the executable specification of the DSP voice kernel: the three
SID voices (oscillator, noise, waveform tables, DAC, envelope, hard sync, ring
modulation, test bit) rendered one 49,169.921875 Hz codec frame at a time in
the integer arithmetic of the DSP56001. It is gated against reSID
(`third_party/resid`) on register traces. The filter, external filter and
mixer are included too. Their response is graded against reSID by spectrum;
the DSP must match this C model exactly, including the mixer output.

```sh
git submodule update --init third_party/resid
make ref-gate        # builds the oracle and the reference, runs both gates
```

`make` needs a host C/C++ compiler (`HOST_CC`, `HOST_CXX`), `perl` (reSID's
table converter) and `python3` with numpy and scipy. On Windows run it from an
MSYS2 shell with the UCRT64 toolchain on `PATH`. Last results:
`tools/ref/gate_results.txt`.

## What the gates establish

1. **Exact.** For 11 traces on both chip models (8 random traces of all
   registers on all voices, an ADSR-bug trace, a noise trace, a sync/ring
   trace; 22 runs, about 670k frames) the reference's per-frame voice output,
   24-bit phase, 23-bit noise LFSR, envelope counter and rate counter are
   identical to reSID clocked with `SID::clock(n)` once per frame. This covers
   every waveform and combination, the combined-waveform tables of both
   models, the 6581 accumulator clearing, noise write-back, test-bit LFSR
   reset, hard sync and ring modulation across the three voices, the ADSR
   delay bug, and gate edges within a frame. A deliberate one-cycle error in
   the envelope step is caught immediately, so the gate is sensitive.

2. **Band-limited.** For steady saw, pulse and triangle notes at 110, 441,
   1013, 2008 and 3801 Hz, reSID is clocked one SID cycle at a time and the
   chip output is ideally low-passed and read at the uniform codec instants.
   The model's `bl` output has 4-point polyBLEP on saw/pulse edges and the
   waveform evaluated at the true sample instant. In-band alias power
   relative to the note, in dB (full table in `../../tools/ref/gate_results.txt`):

   | | naive (reSID fast mode) | bl, 8580 | bl, 6581 |
   | --- | ---: | ---: | ---: |
   | saw 441 Hz | -21.8 | -55.6 | -48.4 |
   | saw 3801 Hz | -10.8 | -44.7 | -36.1 |
   | pulse 441 Hz | -20.0 | -52.7 | -52.7 |
   | pulse 3801 Hz | -9.5 | -57.4 | -57.4 |
   | triangle 441 Hz | -58.6 (8580) | -61.3 | -46.7 |

   Level against the band-limited chip is within 2 dB (the cubic polyBLEP
   kernel is a mild low-pass: -0.1 dB at 441 Hz, up to -2 dB for a narrow
   pulse at 3.8 kHz).

Findings from building the gate, relevant to the DSP design:

- **The sample-instant correction matters.** The codec grid is 20.0376 SID
  cycles per frame, so the integer-cycle sample instants jitter by up to one
  cycle. Evaluating the phase at the true instant (`ph = acc + freq * eps`,
  one multiply per voice) is worth 5-18 dB: without it saw/pulse polyBLEP
  reaches only about -39 to -49 dB.
- **The 6581 DAC limits saw and triangle.** Its R-2R ladder (2R/R = 2.2) is
  not linear: the ramp has kinks at every multiple of 0x100 codes, 129 DAC
  units at 0x800 (3% of the 4064-unit span), 67 at 0x400/0xC00, 35 and 19
  elsewhere. They are real chip behaviour and real discontinuities that an
  edge-only polyBLEP leaves alone, costing 7-9 dB against the 8580. Putting
  polyBLEP on the biggest three kinks should remove roughly 7 dB of that
  (an estimate from the kink sizes, not measured) for three more edge
  evaluations per saw voice; not done.
- Triangle gains little from the instant correction (its error is the DAC
  kinks plus the slope discontinuity, which a polyBLAMP would address).

## Filter, mixer and external filter

`sid_ref_write` takes registers 21..24 for `$15..$18`. `sid_frame_t.mix_bl` is the
chip output (16-bit scale) per codec frame, fed with the band-limited voices (what
the DSP renders; `mix` is the same fed with the naive voices):

- routing (`$17` low nibble), voice 3 off, mode bits LP/BP/HP, volume `$18`;
- a TPT state-variable filter (Zavalishin) with 48-bit states: `g = tan(pi f0 / fs)`
  and `k = k0(fc) * kr(res)` from `filter_tables.h` (the 68030 derives the words
  `a1 a2 a3 k/4` on a register write), three outputs lp, bp, hp, each with its own
  gain per cutoff, and a share of lp in the high-pass output;
- the external filters, a 15.9 kHz low-pass and a 15.9 Hz high-pass, one-pole TPT;
- the mixer scale per model, calibrated on reSID (`mix_cal`, `oracle_resid cal`).

The filter's parameters are measured from reSID, not derived:
`tools/ref/filter_fit.py` routes a full-level noise voice through reSID's filter
for 65 cutoffs, four resonances and each of the three outputs, divides the chip
output's spectrum by that of the voice routed past the filter, and fits f0, k0,
the three gains and the leak per cutoff jointly on all three outputs (the damping
ratio per resonance from three cutoffs and all 16 settings).
`tools/ref/gen_filter_tables.py` turns `filter_fit_<model>.txt` and
`filter_q_<model>.txt` into `filter_tables.h`. What the fit found: the 8580 is a
clean two-pole filter with f0 linear in fc up to about 15.5 kHz and gains near
1.1; the 6581 sits at 240 Hz up to fc 250, rises steeply between fc 400 and 900,
and reaches 15 kHz; its high-pass output has about half the low-pass's gain
below fc 1400, and its band-pass output up to 1.7 times at the top.

`make filter-gate` (`tools/ref/filter_gate.py`) routes the same noise voice
(bit-exact in both) through each mode, five cutoffs and three resonances and
compares the filter path's response (the output spectrum over that of the voice
routed past the filter, so the stimulus and its aliasing cancel) of reSID and the
reference over 100 Hz - 12 kHz, in bins 10 dB above reSID's own floor. Results
(`tools/ref/filter_gate_results.txt`), mean rms error per mode, for the current fitted tables:

| | low-pass | band-pass | high-pass | notch | all |
| --- | ---: | ---: | ---: | ---: | ---: |
| current fit | 1.2 | 1.7 | 0.7 | 2.8 | 1.6 dB |

Known gaps: the 6581 between fc 400 and 900 (the fit is 3-5 dB off in the
low-pass there: the response depends on the resonance in a way k0 * kr does not
capture, and the damping runs into the k < 4 limit of the coefficient word); the
6581's band-pass at high cutoff (3-5 dB); the notch (the two outputs' phases
matter there); everything is fitted at one signal level, so the 6581's
level-dependent cutoff (its distortion) is frozen at that level and the
distortion products themselves are not modelled. The unfiltered path is 2-3 dB
louder than reSID's box-averaged output towards 10 kHz in this test: that is the
aliasing of the frame-sampled noise voice, not the mixer.

## Model scope

Follows reSID's **bulk** clocking (`clock(delta_t)`): one call per frame
advances every unit by that frame's whole cycle count (20 or 21; a 24-bit
accumulator add decides). reSID's single-cycle path has pipeline delays
(2-cycle gate-to-state delay, 2-cycle noise shift delay) that a frame model
cannot reproduce; this model matches the bulk path, which is what the oracle
runs. The rule for register writes: a write is applied at the start of the
frame containing its cycle, up to 20 cycles (about 20 us) early.

Not modelled: the 6581's nonlinear filter distortion, the external-input pin; the OSC3/ENV3/POT readbacks; the 8580 triangle-saw read
pipeline; bus value decay; the single-cycle pipelines above; noise and
combined waveforms in `bl` (they pass through at the integer cycle).

## 24-bit audit

All state fits a 24-bit word (phase 24, freq 16, pw 12, LFSR 23, rate
counter 15, envelope 8; the voice product is under 2^21). Where a 24-bit word
is not enough, the DSP's 56-bit accumulator or the host takes over:

| Quantity | Width | On the DSP |
| --- | --- | --- |
| `freq * eps` (phase extrapolation) | 40 bits | one MPY, accumulator |
| polyBLEP position `d * 4 / D` (distance to the edge over the phase step per frame) | 48 / 24 bits | `DIV` near an edge: 16 quotient bits on the general path, 24 on the fast pulse path |
| `D` = freq * cycles per frame | 21 bits | one MPY on a frequency write |
| polyBLEP correction `jump * t` and the final `wave * env` | 33-37 bits | MPY/MAC into the accumulator, one rounding to 24 |
| cycles per frame, Q24 | 29 bits | only its fraction (24 bits) is added per frame; the integer part is a constant 20 |
| DAC and combined-wave tables | 12 bit data | host-generated; combined tables are reSID's data files |

The tables (wave DAC, envelope DAC, polyBLEP, the 16 combined waveforms) are
built at start by `sid_tables_init` in host tools. Player builds embed them
using `gen_player_tables.c`; the Falcon loads and uploads those embedded tables. reSID's `wave*.dat` and code are GPL-licensed, and this
directory is derived from them.

## Files

- `sid_ref.h`, `sid_ref.c`: the model.
- `../../tools/ref/oracle_resid.cc`: reSID driven frame-by-frame (`frames`) or
  cycle-by-cycle (`cycles`); built against `third_party/resid`.
- `../../tools/ref/ref_run.c`: runs the model on a trace.
- `../../tools/ref/voice_gate.py`: both gates.
- `../../tools/ref/make_voice_traces.py`: regenerates `tests/traces/voice_*.trace`.

The final chip output follows the DSP's tie-to-even rounding. Bit-exact output
and real-time playback are separate checks; the latest player timing results
are in [the two-minute load check](../../docs/heavy-load-check.md).
