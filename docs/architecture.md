# Architecture (plan)

This document records the intended design. Items marked **done** exist in the
scaffold; everything else is a proposal to be validated.

## Split of work

| Processor | Owns |
| --- | --- |
| 68030 | PSID/RSID parsing, C64 64 KB memory image, 6502 core, CIA/VIC timing for the play routine, SID write stream, UI |
| DSP56001 | SID register file, three voices, envelopes, filter, mixing, output saturation, SSI transport |

The 6502 runs on the host and every write to `$D400-$D41C` is timestamped in
C64 cycles and queued to the DSP, exactly as F030MXDRV queues YM2151 writes.

## Host/DSP protocol (**done**, v1)

24-bit host words; each exchange is a burst followed by one reply word.
Commands: `PING` (reply `"SID"`), `WRITE_REG reg,value`, `READ_REG reg`,
`RESET`. See `src/dsp/protocol.inc`. Planned additions, following the
F030MXDRV protocol: a batched, timestamped write refill; audio start/stop;
buffer-handoff queries.

## DSP kernel

Today (**done**): standalone `Dsp_ExecBoot` image (<512 words) holding the
32-word register shadow in X memory.

Planned:

- Clock: PAL 985,248 Hz / NTSC 1,022,727 Hz SID clock mapped onto the Falcon
  codec rate with a drift-free DDA, as F030MXDRV does for the YM2151
  (1920:1007 against 62.5 kHz). The ratio for each SID clock must be chosen
  so the integers stay small.
- Per voice: 24-bit phase accumulator, pulse/saw/triangle/noise waveforms and
  their combined-waveform behaviour, sync and ring modulation, 15-bit LFSR
  noise, ADSR with the 15-bit rate counter and exponential decay steps
  (including the ADSR-delay bug).
- Filter: 11-bit cutoff, resonance, LP/BP/HP/3-off routing, external input,
  per-model (6581/8580) cutoff curves.
- Output: master volume, DC offset (the sample-playback "digi" trick on `$D418`
  must remain audible), saturation, interleaved stereo over SSI.
- Once the kernel exceeds 512 words, move to the two-stage path
  (`stage2_loader.asm`, `generate_dsp_stage2.py --bootstrap/--program`).

## Budget

The DSP gives roughly 489 cycles per frame at 32.78 kHz on stock hardware
(see `docs/hatari-timing.md`). Three voices plus filter must fit alongside
transport; the same two-kernel idea as F030MXDRV applies: an exact,
cycle-accurate oracle kernel for conformance and a codec-rate production
kernel.

## Verification model (proposed)

1. Exact kernel compared sample-for-sample with reSID (`third_party/resid`)
   on register-write traces in `tests/traces/`.
2. Production kernel graded perceptually (pitch, envelope timing, filter
   response, noise) against the same reference.
3. Hatari integration gates for boot, refill cadence and shutdown, plus the
   inherited `ratetest`/`dspprobe` hardware checks.

## Roadmap

1. Build and run the scaffold (`make check`, `make run`).
2. Add `resid` as a submodule; write a native oracle that renders a trace to
   PCM.
3. DSP: phase accumulators and waveforms, then ADSR, then filter.
4. Host: PSID loader and 6502 core; timestamped write queue.
5. SSI output, double buffering, timing gates.
6. Hardware validation on a physical Falcon.
