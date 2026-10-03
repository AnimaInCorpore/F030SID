# SID voice reference model

`sid_ref.c` is the executable specification of the DSP voice kernel: the three
SID voices (oscillator, noise, waveform tables, DAC, envelope, hard sync, ring
modulation, test bit) rendered one 49,169.921875 Hz codec frame at a time in
the integer arithmetic of the DSP56001. It is gated against reSID
(`third_party/resid`) on register traces. The filter, external filter and
mixer are in it too (graded by spectrum, not bit-exact, see below).

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
   relative to the note, in dB (full table in `gate_results.txt`):

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

`sid_ref_write` takes registers 21..24 for `$15..$18`. `sid_frame_t.mix` is the
chip output (16-bit scale) per codec frame, fed with the band-limited voices:

- routing (`$17` low nibble), voice 3 off, mode bits LP/BP/HP, volume `$18`;
- a TPT state-variable filter (Zavalishin) with 48-bit states and Q40
  coefficients, `g = tan(pi f0 / fs)` and `k = 1/Q` looked up per `fc` / `res`
  from `filter_tables.h` (the 68030 derives `a1 a2 a3` on a register write);
- the external filters, a 15.9 kHz low-pass and a 15.9 Hz high-pass, one-pole TPT;
- gain staging calibrated on reSID (`mix_cal`, `oracle_resid cal`): the mixer
  scale per model, the 6581's filter-path attenuation (0.70, the 8580's is
  1.03), and a small high-pass leak on the 6581 (its summer does not cancel the
  low-pass term completely).

The 6581/8580 cutoff and resonance curves are measured from reSID, not derived:
`tools/ref/filter_measure.py` drives white noise into reSID's external input,
fits a two-pole low-pass (f0, Q) per `fc` and the Q ratio per `res`, and
`tools/ref/gen_filter_tables.py` turns that into `filter_tables.h`.

`make filter-gate` (`tools/ref/filter_gate.py`) routes the same noise voice
(bit-exact in both) through each mode, cutoff and resonance and compares the
Welch spectra of reSID's chip output and the reference over 100 Hz - 12 kHz,
in bins 10 dB above reSID's own floor. Results: `tools/ref/filter_gate_results.txt`.
Mean rms error per mode: low-pass about 2 dB, band-pass 4, notch 4, high-pass 6.

Known gaps, in order of size: the 6581 below fc ~ 750 is not a two-pole filter
(its roll-off is about 7 dB/octave and a two-pole fit is 10-20 dB too steep);
6581 high-pass and band-pass at high cutoff are not the low-pass's f0 (reSID's
LP fit says 15-20 kHz, its HP peaks near 7 kHz) so those modes are off by
10-16 dB around the peak; reSID's low-frequency floor in HP/BP/notch modes
(dither and finite-gain summers) is not reproduced; the 6581's filter
distortion is not modelled.

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
| polyBLEP position `delta * recip` | 58 bits | MPY by a host-supplied reciprocal kept as mantissa plus shift |
| `recip` = 2^62 / (freq * cycles per frame) | 34 bits | computed by the 68030 on a frequency write |
| polyBLEP correction `jump * t` and the final `wave * env` | 33-37 bits | MPY/MAC into the accumulator, one rounding to 24 |
| cycles per frame, Q24 | 29 bits | only its fraction (24 bits) is added per frame; the integer part is a constant 20 |
| DAC and combined-wave tables | 12 bit data | host-generated; combined tables are reSID's data files |

The tables (wave DAC, envelope DAC, polyBLEP, the 16 combined waveforms) are
built at start by `sid_tables_init`; on the Falcon the 68030 builds them and
uploads them. reSID's `wave*.dat` and code are GPL-licensed, and this
directory is derived from them.

## Files

- `sid_ref.h`, `sid_ref.c`: the model.
- `../../tools/ref/oracle_resid.cc`: reSID driven frame-by-frame (`frames`) or
  cycle-by-cycle (`cycles`); built against `third_party/resid`.
- `../../tools/ref/ref_run.c`: runs the model on a trace.
- `../../tools/ref/voice_gate.py`: both gates.
- `../../tools/ref/make_voice_traces.py`: regenerates `tests/traces/voice_*.trace`.
