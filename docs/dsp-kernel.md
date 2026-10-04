# DSP kernel

`src/dsp/sid.asm.in` is the DSP56001 implementation of the SID (a template, see
[Source layout](#source-layout)), written milestone by milestone against the C reference model (`src/ref/`, see
`src/ref/README.md`). Every milestone is gated bit for bit: the reference model
and the DSP must return identical words for the same register trace.

## Milestones 1-4 (done): three voices, filter, mixer, exact

What runs on the DSP, frame by frame on request (`DSP_CMD_FRAME`):

- the 20/21-cycle frame clock (a Q24 fraction accumulator whose carry is the
  21st cycle);
- voice 0's 24-bit phase accumulator and the test bit;
- waveforms none (floating output with its TTL), triangle, saw and pulse,
  including the pulse-compare state the reference keeps between writes;
- the complete ADSR state machine: 15-bit rate counter and its wrap bug,
  exponential counter periods, hold-at-zero, the gate-to-state pipeline;
- the output stage: `(wave DAC[code] - zero) * envelope DAC[env]`, a 24-bit
  signed word, for either chip model (the host loads the tables).

Milestone 2 added the rest of the oscillator for voice 0:

- the 23-bit noise register, clocked from the phase exactly as reSID's bulk path
  does (its shift-period loop), the eight-bit gather into the noise output, and
  the register reset while the test bit is held (35,000 cycles on the 6581,
  2,519,864 on the 8580);
- every waveform setting 0-15: the combined waveforms read reSID's sampled
  tables (3, 5, 6, 7 for the model), noise and pulse mask the result;
- the 6581's clearing of phase bits for saw combinations, noise combinations
  writing their output back into the register, `do_pre_writeback` and the shift
  on the test bit's falling edge, and the noise+pulse special function that
  runs after a control write;
- ring modulation, against an idle voice 3 (its phase never changes, so it is a
  constant until voices 2 and 3 exist).

Milestone 3 made it three voices and added the interaction between them:

- the whole voice (phase, noise, envelope, registers) exists three times; each
  voice is hard-synced and ring-modulated by the one before it (voice 3 -> 1,
  1 -> 2, 2 -> 3), so ring modulation now reads a live phase;
- the oscillators are clocked in steps split at every msb toggle of a source
  whose destination has sync set, exactly as reSID's `SID::clock(delta_t)` does,
  and `synchronize` restarts the destination's phase on the cycle the source's
  msb rises, with reSID's rule for a voice that is both synced and a source;
- the split needs the cycles to the next toggle, `ceil(delta / freq)`. The
  DSP56001 has no divide worth using, but the answer only matters when it is
  below the cycles left in the frame, which is exactly `delta <= freq * (left - 1)`;
  the kernel tests that with one multiply and finds the count by a search of at
  most 20 additions, only when a toggle really is that near;
- the frame returns the three voice outputs.

Milestone 4 added the mixer, the state-variable filter and the external filter
(registers $15-$18), bit for bit against the reference:

- the routing (`$17`), voice 3 off, the LP/BP/HP bits and the volume (`$18`);
- a TPT state-variable filter: coefficients `a1 a2 a3 k/4` are 24-bit words the
  68030 derives and sends with `DSP_CMD_FILTER` whenever fc or res changes (so
  the DSP never divides); states are 48-bit (X = integer part, Y = fraction, one
  `L:` move each); the products use the integer part of the state, so each
  multiplication is one MPY/MAC and the fraction is only carried in the
  accumulate. The routed voices enter divided by four for the resonance
  headroom (`x = sum >> 2`, +-2^22 against the 2^23 limit);
- the high-pass term is `x - 4*(k/4)*bp - cc*lp`, `cc` the per-model leak;
- mixer: direct voices plus the filter path times its per-model gain, times
  `volume * scale` (computed on the DSP when `$18` is written), into the
  external filter (15.9 kHz and 15.9 Hz one-pole TPT, 48-bit states), rounded
  to the 16-bit chip scale; `FRAME` now returns that as a fourth word.

The 68030 derivation of the coefficient words is `sid_filter_coeffs()` in
`src/ref/sid_ref.c`: tables of `g`, `g*g` and `g*k0` per fc, `kr` per res, and a
257-entry reciprocal table with linear interpolation, so no divide and two
multiplies at most; the harness takes the words from the vector for now (the
m68k port of the routine is the next step).

Cost of the filter path: `mix_frame` measured 83 DSP cycles per codec frame
with a voice routed through the filter (25% of the 326 cycles at 49.17 kHz), 29 of
them the external filter and output stage; the first version, with branches for
the routing and long-address moves, took 130. The savings come from: the routing
as multiplies by weights held in Y memory (a branch costs more than a MAC), all
coefficients, masks and states streamed through address registers with parallel
moves (r3-r7 and n3/n4/n5/n7 are reserved and left balanced), and skipping the SVF
when nothing is routed (the integrators are cleared then, in the reference too,
so the skip is exact). Measured with `profile_dsp.py` on one call in the first
frame of the gate vector, so it is a sample, not a worst case.

Not yet on the DSP:
band-limiting (polyBLEP and the sample-instant phase), the SSI stream.

### Source layout

The DSP56001 has no register-plus-immediate-offset addressing: working on "the
current voice" through a pointer would cost a set-up, a pipeline nop and an
indexed move per variable. So the per-voice code is written once, in
`sid.asm.in` between `;@voice` and `;@endvoice`, and `tools/dsp/gen_sid_asm.py`
instantiates it three times with absolute addresses. In a voice section `S_X` is
this voice's variable, `SRC_X` the voice that syncs and ring-modulates it, `DST_X`
the voice it syncs, and every label gets a `_0/_1/_2` suffix. The generated
`build/dsp/SID.ASM` is 4,600 lines; the kernel ends at P:$11f7,
still under the P:$1400 limit above which external Y begins.

### Gate

```sh
make dsp-gate                       # all supported traces, both chip models
make dsp-gate DSP_GATE_ARGS=--quick # two traces, one model
```

`tools/dsp/voice_dsp_gate.py` runs, per trace and model:

1. `make_vec` (the reference model) writes a test vector (`voicetest_vec.i`:
   tables, constants, the register writes tagged with their frame) and the
   expected voice 0 output;
2. the harness `src/m68k/voicetest.s` is assembled with that vector and run in
   Hatari; it boots the DSP, loads the tables, replays the writes and requests
   frames over the host port, and saves the output words to `VOICEOUT.BIN`;
3. the words are compared with the expected output. One differing word fails.

The milestone 3 traces are `rand_1..8` (every register of every voice at random:
all waveforms, test, sync, ring, gate and envelope traffic, the cross-voice
interactions) and `sync_ring`; all three voices' outputs are compared, so the
idle voices' constant outputs and the sync and ring effects are checked too.
Reversing the msb test in `synchronize` fails `sync_ring` at frame 1. Earlier sets:
`dsp2_1..10` (random voice 0 traffic over all 16 waveform
settings with test, ring and sync bits, gate toggles, AD/SR changes under a
running envelope), `noise` (every noise rate, test-bit resets, noise+triangle),
`dsp_1..8` (the milestone 1 set: no noise or combinations), `adsr_bug`, and the
saw/pulse/triangle `tone_*` notes. Results: `tools/dsp/gate_results.txt`
(`gate_results_m1.txt` is the milestone 1 run). A deliberate one-bit error in
the noise feedback tap fails `dsp2_1` at frame 3172, so the gate is sensitive.

Two details that cost time and are worth knowing:

- Hatari boots to the desktop without starting the program when its console
  output goes to a pipe. The gate redirects it to a file.
- A TOS program starts at the first byte of its text segment, whatever `-e`
  says, so data (the test vector) must come after `start`.

## Loading

The kernel is 700+ words and runs past the 512-word internal P RAM, so it uses
F030MXDRV's two-stage load: `Dsp_ExecBoot` installs `stage2_loader.asm` (a
bootstrap that reserves P:$0040-$007f), then the host streams the kernel's
sparse sections to it (`generate_dsp_stage2.py`, program limit P:$1400). The
kernel therefore begins at P:$0080. `reset` then enters it with the bus control
register cleared (zero wait states on external memory).

## Memory map

| Space | Range | Contents |
| --- | --- | --- |
| P | $0000 | `jmp start` (reset vector) |
| P | $0040-$007f | stage-two loader (reserved) |
| P | $0080- | kernel; spills into external P above $01ff |
| X internal | $00-$0f | frame globals, filter coefficients, frame constants (short addresses) |
| X, Y internal | $10-$3f | the three voices' frame variables, 16 X and 16 Y words each (`gen_sid_asm.py`) |
| Y internal | $00-$0f | mixer weights and constants |
| Y internal | $40- | the voices' variables only register writes touch |
| X internal | $40-$43 | configuration |
| X internal | $88-$97 | rate counter periods (host-loaded) |
| X internal | $98-$a7 | sustain levels (host-loaded) |
| X internal | $a8-$c7 | register shadow for `READ_REG` |
| X external | $0200-$03ff | envelope table (host-loaded) |
| X external | $0400-$13ff | waveform DAC (host-loaded) |
| X external | $1400-$23ff, $2400-$33ff | combined waveform tables 6, 7 (host-loaded) |
| Y external | $1400-$23ff, $2400-$33ff | combined waveform tables 3, 5 (host-loaded) |

External P aliases external Y (docs/dsp56001-notes.md): the kernel stays below
P:$1400 and the Y tables sit above it. The Hatari gate exercises this aliasing.

## Protocol (v6)

`src/dsp/protocol.inc`: every command is a burst of 24-bit host words and gets
exactly one reply word. `PING`, `WRITE_REG reg,value`, `READ_REG reg`, `RESET`,
`LOAD_X addr,count,words...`, `LOAD_Y addr,count,words...`,
`CONFIG zero,ttl,model,shift_reset_start,hp_cancel,mix_k,filter_gain` (filter gain Q22),
`FILTER a1,a2,a3,k4` (the TPT coefficient words for the current fc and res),
`FRAME` (four reply words: the voice 1, 2 and 3 outputs and the chip output, each
a 24-bit two's-complement word). v6: the host loads the envelope table as 512 words at
`DSP_X_ENV_TAB` (per envelope value: DAC << 13, and the exponential counter period that starts
there) and the wave DAC as `(DAC - zero) << 10`; `CONFIG` must follow the table loads. The one-reply rule of the earlier versions holds
for every other command.

## Next

0. **The synthesis fits the 49.17 kHz frame, bit-exact.** Measured with
   `tools/dsp/profile_frames.py` (twelve whole frames sampled through a gate run; the budget is
   326 cycles per frame):

   | trace | first version | previous | now: mean | max of the samples |
   | --- | --- | --- | --- | --- |
   | `music_1` (tracker-style, no filter) | 756 | 515 | 150 | 203 |
   | `music_2` (the same with a filter sweep) | 805 | 564 | 187 | 240 |
   | `tone_saw_7509` (AD=0: a rate step every 8 cycles) | 1,102 | 670 | 180 | 217 |
   | `sync_ring` (hard sync and ring between all voices, AD=0) | | | 277 | 571 |
   | `rand_1`, `rand_2` (random registers: combined waveforms, sync, test) | 1,070-1,350 | 920-1,130 | 260, 323 | 397, 404 |

   The numbers cover `cmd_frame` to `fr_done`: synthesis only, not the host-port replies, the
   register writes, or the stages still to come (SSI, band-limiting). A frame in which a sync
   source's msb toggles (the oscillators are clocked twice) or several events coincide still
   exceeds 326 cycles, so the SSI stage must render into a small buffer ahead of the
   transmitter; real time is proven only when the worst rolling buffer load is measured there.

   How the frame is built (`sid.asm.in`, all gated bit for bit, `tools/dsp/gate_results_rt.txt`):
   - phase: one 48-bit word `acc << 12` (X = the 12-bit waveform index, Y = the rest), advanced
     by one MAC with `n << 11`; `S_THR` is the next index at which anything else happens (a
     noise-register step at each rising edge of bit 19, the msb rising, the wrap), so the frame
     is add, compare, store, and falls out of line (`oscs`) only for an event;
   - envelope: the rate counter is kept as the cycles left to its next step (`S_REM`); the
     frame subtracts and compares, and `envs` dispatches to a handler per state (`S_EH`). A
     gate change parks the counter as a number and lets `eh_pipe` apply the state change. A
     voice frozen at zero or resting at its sustain level only cycles the rate counter;
   - output: a handler per voice chosen on the control write (`S_WH`); the host loads the DAC
     tables offset and scaled (envelope DAC << 13, (wave DAC - zero) << 10) so one MPY is the
     voice output, and the envelope DAC word is cached when the envelope value changes;
   - lazy state, refreshed where it is observed: the pulse level (only under the test bit or
     after a hard sync in a frame's last step is it latched, as reSID computes it in
     `clock()`), the noise output (only while the noise bit is on), the noise write-back
     (skipped when it has nothing to clear);
   - hard sync: a frame with a sync bit set runs the same oscillator step inside the split
     loop; a cheap test against `S_THR` decides whether the exact toggle search is needed;
   - everything a normal frame executes is in internal P memory with short jumps, loads ride
     on ALU instructions as parallel moves, and the frame's constants come from short memory.
1. The 68030 side of the coefficients: `sid_filter_coeffs()` in m68k assembly, gated
   against the C routine, and the tables (about 16 KB per model) in the executable.
2. Band-limited output (sample-instant phase, polyBLEP-4) in front of the mixer
   (the reference's `mix_bl` is the filter fed with it).
3. Filter accuracy items against reSID: the 6581 below fc ~750 and its HP/BP at
   high cutoff (`src/ref/README.md`).
4. The SSI stream and the player (PSID loader, 6502 core, timestamped writes).
