# DSP kernel

`src/dsp/sid.asm` is the DSP56001 implementation of the SID, written
milestone by milestone against the C reference model (`src/ref/`, see
`src/ref/README.md`). Every milestone is gated bit for bit: the reference model
and the DSP must return identical words for the same register trace.

## Milestone 1 (done): voice 0, exact

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

Not yet: noise, combined waveforms, sync and ring modulation, voices 2 and 3,
the filter, band-limiting (polyBLEP and the sample-instant phase), the SSI
stream. Writes to those registers are accepted and ignored.

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

Supported traces: `dsp_1..8` (random voice 0 traffic: all four waveform
settings, test bit, gate toggles, AD/SR changes under a running envelope),
`adsr_bug`, and the saw/pulse/triangle `tone_*` notes. Results:
`tools/dsp/gate_results.txt`.

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
| X internal | $00-$1f | voice, envelope and frame state (`S_*` in sid.asm) |
| X internal | $40-$4f | rate counter periods (host-loaded) |
| X internal | $50-$5f | sustain levels (host-loaded) |
| X internal | $60-$7f | register shadow for `READ_REG` |
| X external | $0200-$02ff | envelope DAC (host-loaded) |
| X external | $0400-$13ff | waveform DAC (host-loaded) |

External P aliases external Y (docs/dsp56001-notes.md), so the kernel's
external-P tail and later Y tables must not collide; none exist yet.

## Protocol (v2)

`src/dsp/protocol.inc`: every command is a burst of 24-bit host words and gets
exactly one reply word. `PING`, `WRITE_REG reg,value`, `READ_REG reg`, `RESET`,
`LOAD_X addr,count,words...`, `CONFIG zero,ttl`, `FRAME` (reply: the voice 0
output as a 24-bit two's-complement word).

## Next

1. Cycle cost of the frame path in the calibrated Hatari (`make profile-voice`).
2. Noise and the combined-waveform tables, sync and ring modulation, voices 2
   and 3: each extends the gate's trace set to the full random traces.
3. Band-limited output (sample-instant phase, polyBLEP-4), then the filter.
4. The SSI stream and the player (PSID loader, 6502 core, timestamped writes).
