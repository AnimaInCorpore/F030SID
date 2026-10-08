# DSP kernel

`src/dsp/sid.asm.in` implements all three SID voices, the fitted filter,
mixer and SSI stream on the DSP56001. It is generated from one per-voice
source template and gated bit for bit against the [C reference](../src/ref/README.md).
The current host/DSP protocol is v11.

## Processor split

F030SID uses one SID kernel for both frame verification and SSI playback.
The host executes the tune; the DSP synthesizes the chip output.

| Processor | Responsibilities |
| --- | --- |
| 68030 | Load the tune, maintain 64 KB RAM, execute init/play routines, timestamp SID writes, derive filter coefficients, feed the DSP, handle keys and release sound/DSP locks |
| DSP56001 | Three SID voices, envelopes, waveforms, sync/ring/test behavior, filter and mixer, render clock, write queue, SSI output |

The host boots the embedded DSP image and uploads its model tables before
feeding ordered cycle-stamped writes and a render horizon. The player controls
startup, keyboard handling and shutdown; see [player behavior](player.md).
The host core, filter coefficient routine and DSP output have independent
reference gates, described in [player tools](../tools/player/README.md) and
[the C reference](../src/ref/README.md).

## Synthesis

The PAL clock is 985,248 Hz; the codec clock is 25175000 / 512 Hz.
A Q24 fraction accumulator selects 20 or 21 SID cycles per output frame.
Each voice has a 24-bit phase, 23-bit noise LFSR, waveform/control state,
15-bit envelope rate counter, exponential counter and model-specific DAC.

Every waveform setting is implemented, including combined-waveform tables,
floating output, noise write-back, test-bit reset and the 6581 phase clearing.
Noise steps are applied lazily and flushed before observable state changes.
ADSR includes the rate-counter delay bug and hold-at-zero behavior; resting
envelopes can advance rate steps in batches.

Hard sync and ring modulation use live phases across all three voices
(voice 3 → 1 → 2 → 3). Frames split at required source MSB toggles, using
reSID's bulk-clock sync rule. A countdown skips the split path when no toggle
can occur. The model matches reSID's bulk frame clocking, rather than all of
its single-cycle pipelines.

## Filter and output

- the routing (`$17`), voice 3 off, the LP/BP/HP bits and the volume (`$18`);
- a TPT state-variable filter: coefficients `a1 a2 a3 k/4` are 24-bit words the
  68030 derives when cutoff or resonance changes (so filter coefficient
  derivation does not divide on the DSP); states are 48-bit (X = integer part, Y = fraction, one
  `L:` move each); the products use the integer part of the state, so each
  multiplication is one MPY/MAC and the fraction is only carried in the
  accumulate. The routed voices enter divided by four for the resonance
  headroom (`x = sum >> 2`, +-2^22 against the 2^23 limit);
- the high-pass term is `x - 4*(k/4)*bp - lp`; the selected outputs are summed with
  weights the host sends with the coefficients (each output's gain per cutoff, and a
  share of the low-pass in the high-pass output), set up when `$18` or the
  coefficients change;
- mixer: direct voices plus the filter path, times
  `volume * scale` (computed on the DSP when `$18` is written), into the
  external filter (15.9 kHz and 15.9 Hz one-pole TPT, 48-bit states), rounded
  to the 16-bit chip scale; `FRAME` returns that as a fourth word.

The 68030 derivation of the coefficient words is `sid_filter_coeffs()` in
`src/ref/sid_ref.c`: tables of `g`, `g*g` and `g*k0` per fc, `kr` per res, and a
257-entry reciprocal table with linear interpolation, so no divide and two
multiplies at most; the 68030 routine is `src/m68k/filtcoef.s` (gated word for word,
`make coef-gate`); the frame-by-frame harness still takes the words from its vector.

The band-limited path follows the reference's `bl` output
(`voice_output_bl` in `src/ref/sid_ref.c`, written in the DSP's arithmetic; the gates
compare the band-limited voices and the chip output made from them):

- plain triangle, saw and pulse are read at the sample instant: the phase plus
  `freq * eps`, one MAC with `eps >> 13` (computed once per frame);
- a saw or pulse edge within two frames of the sample instant gets a 4-point
  polyBLEP correction on the DAC word: the distance to the edge in frames is a
  `DIV` by `D = freq * cycles per frame` (computed on a frequency write),
  the step residual comes from a 129-word table (internal Y, host-loaded) with
  linear interpolation, times the DAC step of the pulse;
- a frame far from an edge pays only a countdown (`S_BLCNT`). Frequency,
  pulse-width, control and sync changes invalidate it where necessary;
  separated pulse edges use the shorter `blp_fast`/`bc_hit` path;
- `S_WAVEOUT`, the chip's waveform output register, is not stored by these
  handlers (their code is the sample instant's, not the integer cycle's); it is
  made from the phase when a register write could observe it (`wave_refresh`).

Noise, combined waveforms, ring modulation and the test bit are not band-limited.

## Source layout and loading

`tools/dsp/gen_sid_asm.py` expands the `;@voice` sections three times.
`S_X` names the current voice's state, `SRC_X` its sync/ring source and
`DST_X` its sync destination; labels receive `_0`, `_1`, `_2` suffixes.
Absolute state addresses avoid indexed-address setup in the frame path.

The kernel exceeds the 512-word `Dsp_ExecBoot` limit. The host embeds the
bootstrap from `src/dsp/stage2_loader.asm` and the sparse final program.
The loader occupies P:$0040–$007f; the kernel begins at P:$0080 and stays
below P:$1c00. `tools/generate_dsp_stage2.py` validates both images.
Startup clears BCR for zero external-memory wait states.

## Memory map

| Space | Range | Contents |
| --- | --- | --- |
| P | $0000, $0010, $0012 | Reset and SSI interrupt vectors |
| P | $0040–$007f | Reserved stage-two loader |
| P | $0080–below $1c00 | Kernel, spilling into external P above $01ff |
| X/Y internal | $00–$7e | Frame constants, coefficients, weights, voice state and stream state; exact allocation is in the source |
| X internal | $88–$97, $98–$a7 | Rate periods and sustain levels |
| X internal | $a8–$c7 | Register shadow |
| Y internal | $7f–$ff | 129-word polyBLEP residual table |
| X external | $0200–$03ff | Envelope DAC/period pairs |
| X external | $0400–$13ff | Waveform DAC |
| X external | $1400–$23ff | Combined tables 6 and 7 packed into lower/upper twelve bits |
| X external | $2400–$26ff | 256-entry cycle/register/value queue |
| X external | $3000–$3fff | 4096-frame mono output ring |
| Y external | $1c00–$2bff, $2c00–$3bff | Combined tables 3 and 5 |

External P aliases external Y in the Falcon mapping used by Hatari. Program
and Y table reservations must not overlap. See [DSP constraints](#dsp56001-constraints).

## SSI stream

`STREAM_START` resets the stream clock/queue and enables transmission.
A two-word fast interrupt reads the 4096-frame mono ring through `r3/m3`.
Offsets 0 and 1 alternate via `r7`, sending each word as left and right.
The command loop renders ahead until 3584 frames wait, or the host's released
horizon prevents more rendering.

`STREAM_PUSH count, (cycle, register, value)..., horizon` queues ordered writes
with SID cycles modulo 2^24. The horizon is the cycle below which frames may
start; every write below horizon + 21 must already be supplied. A frame applies
its due writes before clocking synthesis. Pseudo registers 32–39 carry the
filter's eight coefficient words. Late feeding can interrupt continuity;
the renderer does not silently run past the known write horizon.

Status indices 0–6 report started, checksum, least ring fill in frames, queued
entries, render clock, overtakes and SSI underrun flag. Overtakes are checked
at the next render step and when a host call ends a render run early.
The checksum covers all three voices and the chip output.

## Protocol v11

The authoritative definitions are `src/dsp/protocol.inc` and
`src/m68k/protocol.i`; keep them synchronized. Commands exchange 24-bit words.
Every command returns one word except `FRAME`, which returns four.

| Command | Arguments / result |
| --- | --- |
| `PING` | Returns `$534944` (SID) |
| `WRITE_REG`, `READ_REG` | Register/value or register; read returns its shadow |
| `RESET` | Resets chip state, retaining uploaded tables |
| `LOAD_X`, `LOAD_Y` | Address, count, words |
| `LOAD_X_HI` | Address, count, words; fills upper twelve bits, preserving lower twelve |
| `CONFIG` | Wave zero, floating TTL, model, shift reset start, reserved word, mixer scale, filter gain |
| `FILTER` | `a1,a2,a3,k4,wl,wb,wh,wleak` |
| `FRAME` | Returns three band-limited voice outputs and chip output, signed 24-bit words |
| `STREAM_START`, `STREAM_STOP` | Starts/stops SSI streaming |
| `STREAM_PUSH` | Count, timestamped writes, horizon; returns queue entries free |
| `STREAM_READ` | Status index; returns that word |
| `STREAM_PLAIN` | After start, disables the ten-cycle/frame diagnostic checksum |

The host loads envelope entries as DAC << 13 plus exponential-counter period,
and waveform DAC entries as (DAC − zero) << 10. `CONFIG` follows table loads.
Normal playback uses `STREAM_PLAIN`; diagnostic playback retains the checksum.

## Gates and performance

```sh
make dsp-gate
make dsp-gate DSP_GATE_ARGS=--quick
make stream-gate
make stream-gate STREAM_GATE_ARGS="--stress --jobs 2"
```

The frame harness replays generated vectors, saves DSP output and compares
all voice and chip words with the reference. Traces cover noise, combinations,
ADSR, sync/ring, filters, random writes and high-frequency notes on both models.
The recorded full frame gate passes 104 cases (2,882,644 frames), in
`tools/dsp/gate_results.txt`. Fresh results are written under ignored `build/`.

Stream gates check clocks/checksums and timing independently. In the latest
extended stress check, all twenty outputs match, eighteen meet timing, and
`filt_3` overtakes on both models. Named stress cases permit deadline failures,
so a printed PASS does not mean every trace holds real time.

The frame budget is 326.3 DSP cycles including transport and interrupts.
[Performance and validation](performance.md) describes the optimized paths
and two-minute tune results, including Monofail's sustained overload.
Physical-Falcon validation and whole-song performance remain open.

## SID registers

Base address on the C64: `$D400`. Registers are write-only except `$19-$1C`.

| Offset | Register | Notes |
| --- | --- | --- |
| `$00-$01` | Voice 1 frequency lo/hi | `f = value * clock / 2^24` Hz |
| `$02-$03` | Voice 1 pulse width lo/hi | 12 bits |
| `$04` | Voice 1 control | bit0 gate, 1 sync, 2 ring, 3 test, 4 triangle, 5 saw, 6 pulse, 7 noise |
| `$05` | Voice 1 attack/decay | high nibble attack, low nibble decay |
| `$06` | Voice 1 sustain/release | high nibble sustain, low nibble release |
| `$07-$0D` | Voice 2 | same layout as voice 1 |
| `$0E-$14` | Voice 3 | same layout as voice 1 |
| `$15-$16` | Filter cutoff | 11 bits: `$15` low 3 bits, `$16` high 8 bits |
| `$17` | Resonance / filter routing | high nibble resonance, bit0-2 route voices 1-3, bit3 external |
| `$18` | Mode / volume | bit4 LP, 5 BP, 6 HP, 7 voice 3 off; low nibble volume |
| `$19` | POTX | read-only |
| `$1A` | POTY | read-only |
| `$1B` | OSC3 | read-only, voice 3 waveform output high 8 bits |
| `$1C` | ENV3 | read-only, voice 3 envelope |

Clock: PAL 985,248 Hz, NTSC 1,022,727 Hz.

F030SID uses PAL timing only. The host aliases SID writes at `$D400–$D7FF`
to the low five address bits. Protocol `READ_REG` returns the DSP's register
shadow; it does not provide live OSC3/ENV3/POT state. The 6510 environment
returns zero on SID reads. External input and extra SID chips are unsupported.

## DSP56001 constraints

The architectural reference is the local [DSP56001 manual](DSP56001_um.pdf).
These rules apply to `src/dsp/sid.asm.in` and the embedded loader.

### Arithmetic

Data words are signed 24-bit fractions; MPY/MAC align their products in the
56-bit accumulator. Integer state uses explicit shifts and scaling. Phase
and filter integrators use paired X/Y words with `L:` moves. The output's
`rnd` rounds exact ties to even; the C reference's `mix_output` follows that
rule. A matching voice gate alone does not verify final mixer rounding.

A test of an accumulator sees its fractional bits too. When testing an
integer result after multiplication, remove the fraction where the algorithm
requires it. Changes to arithmetic must pass the bit-exact DSP/reference gate.

### Address generation

An indirect access needs one independent instruction cycle after writing its
address register (manual section 8.1, pipeline Case 2). Use a useful instruction
or a NOP to satisfy this delay. Indexed and post-update addressing pair
same-numbered registers: `(Rn+Nn)` and `(Rn)+Nn` exist; `(R7+N5)` does not.
Address arithmetic uses the pointer's own modifier register, so helpers must
preserve the caller's modulo configuration.

There is no register-plus-immediate-offset address mode. The source generator
instantiates each voice with absolute state addresses and suffixed labels,
allowing short moves and jumps in the common frame path.

### Loops and interrupts

`DO` and `REP` with a zero count execute 65,536 iterations. Guard counts that
may be zero. Motorola ASM56000 checks instruction restrictions near hardware
loop endpoints (manual section 8.1.2 and instruction descriptions).

The SSI transmitter uses a two-word fast interrupt. It must leave condition
codes intact: toggling an offset with `bchg` changed carry and failed the
stream gate. The current interrupt reads alternating offsets 0 and 1 through
`r7`, sending each mono ring word twice without changing flags.

The loader stream uses magic `$4d584c`, followed by section count and
address/count/data records. It replies `$4c4f41` and jumps through the installed
reset vector. `tools/generate_dsp_stage2.py` rejects invalid sections,
bootstrap overflow, loader overlap and sections past P:$1c00. The memory
mapping and zero-wait-state setup described above still need physical-Falcon
validation.
