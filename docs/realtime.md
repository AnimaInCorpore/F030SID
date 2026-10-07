# Real-time playback without reducing audio quality

The [extended two-minute load check](heavy-load-check.md) on 2026-10-05
finds that Monofail, which passes the 30-second window below, records five
overtakes in normal playback and seventeen with diagnostics. All seventeen
tunes still match the reference checksum; four others retain pacing failures.

The stock Falcon has about 326 DSP instruction cycles per output frame at
49.17 kHz. The optimizations below preserve the existing SID arithmetic and
samples. As of 2026-10-05 all seventeen single-SID PSID tunes tried (ten in
`music/`, seven in `music/heavy/`) play their first 30 seconds on calibrated
Hatari with identical samples and without the transmitter overtaking the
renderer; four of them end 0.1-0.2 s late and so still fail the gate's
pacing tolerance (see the results below). That is a measurement on
seventeen tunes, not a guarantee for others: the kernel's worst cases are
still above the budget, and the render-ahead ring carries them only while
they are short. RSID tunes need C64 interrupt and sample-playback support
that the player does not have, and a second SID is not rendered.

## Changes made on 2026-10-04

- Keep the stream write pointer in `n6`, the sync step remainder in `n3`,
  and the sync step size in short-addressable Y memory.
- Bound each render run by the released horizon before entering the loop,
  instead of checking the same horizon before every frame. Keep polling
  the host and updating the render clock for each frame.
- Use the ordinary oscillator path when no enabled sync source can cross
  an MSB boundary. Keep the original split path for every possible crossing.
- Skip DAC and BLEP evaluation for plain triangle, saw and pulse at an
  envelope DAC value of zero. Keep clocking the envelopes and oscillators;
  retain the original handlers for waveforms with other state changes.
- Let the BLEP distance check reject a zero denominator, removing a separate
  frequency-zero check. A stopped oscillator can also use the longest edge
  countdown because it cannot encounter a new edge.
- Preserve the edge countdown on unchanged frequency and pulse-width writes.
  Pulse writes still refresh the waveform and pulse latch.
- Keep all original SID writes, but omit duplicate filter coefficient packets
  when cutoff and resonance are unchanged.

The output rate, waveforms, polyBLEP interpolation, filters, volume writes,
and numeric precision have not been reduced. These changes do not add RSID
support.

## Measured timing (2026-10-04)

Calibrated Hatari, stock clock settings, 30 seconds per tune with its selected
chip model, player without the diagnostic checksum (`play_gate.py --plain`).
The earlier column is the previous checksum-free player in `player.md`.

| Tune | Earlier | Optimized | Overtakes | Least ring fill |
| --- | ---: | ---: | ---: | ---: |
| Ocean Loader 2 | 30.02 s | 30.02 s | 0 | 1460 |
| Last Ninja 2 | 30.09 s | 30.09 s | 0 | 1421 |
| Cybernoid II | 30.02 s | 30.02 s | 0 | 773 |
| Turrican | 30.06 s | 30.02 s | 0 | 25 |
| Commando | 31.04 s | 30.27 s | 12 | 7 |
| Ghouls 'n Ghosts | 33.26 s | 32.30 s | 99 | 0 |
| Monty on the Run | 33.70 s | 33.20 s | 153 | 0 |
| Edge of Disgrace | 34.19 s | 31.64 s | 73 | 0 |
| Wizball | 35.95 s | 34.27 s | 203 | 0 |
| RoboCop 3 | 36.08 s | 34.44 s | 203 | 0 |

Last Ninja 2 still fails the gate's 60 ms elapsed-time tolerance: its measured
time includes startup. It has no overtakes and ample ring fill, as in the
earlier run. Do not interpret its timing-tolerance failure as an audio
underrun, or relax the gate to hide the six actual timing failures.
Turrican has little remaining buffer margin. These measurements cover the
first 30 seconds, not entire songs, and have not been verified on hardware.

Quality must be checked separately with the diagnostic checksum enabled:
the checksum covers the three voice outputs and chip output of every rendered
frame. Timing failures remain failures even when the checksum matches.
The final 30-second checksum runs match the reference on all ten PSID tunes
(14,750,980 rendered frames in total). The timing failures above are therefore
not hidden by changes to the expected audio. Turrican still has one overtake
when the checksum is enabled; its zero-overtake result is for normal playback.
The final kernel also passes all 104 frame-gate cases across both chip models,
covering 2,882,644 frames, including noise, combined waveforms, ADSR, hard sync,
filter traffic, random register writes and high-frequency tones. `make check`
passes with no DSP assembler errors or warnings.

Fresh profiles of the optimized player without the checksum, 300,000 frames
starting at frame 300,000, give the following total costs, including stream
work, interrupts, register handlers and command transport:

| Tune | Cycles/frame | Excess over 326.3 |
| --- | ---: | ---: |
| Monty on the Run | 385.0 | 58.7 |
| Wizball | 345.4 | 19.1 |
| Edge of Disgrace | 341.2 | 14.9 |
| Ghouls 'n Ghosts | 338.8 | 12.5 |

These windows are not substitutes for the full 30-second timing checks:
cost varies with the music. They show why one local optimization cannot yet
be claimed to solve all songs.

## Changes made on 2026-10-05

Further changes, each bit-identical (frame gate 104 of 104 after each;
the 30-second checksum runs match on all twelve tunes in `music/`):

- **Noise edges are no longer oscillator events.** `S_THR` stops only at the
  msb toggle and the wrap. `S_NEDGE` is the first noise edge not yet applied.
  With the noise bit off nothing reads the register, and `oscs` applies the
  pending edges eight at a time with one closed-form step
  (`sr = (sr << 8) | (((sr >> 15) ^ (sr >> 10)) & $ff)`); up to seven stay
  pending. With the noise bit on, the output handler (`hnoise`, `hgen`)
  applies them once per frame. A control write, a hard-sync restart and the
  6581's msb clear apply the rest first (`noise_flush`).
- **A pulse whose two edges are apart takes a short edge path** (`blp_fast`).
  `bl_sep` (on frequency and pulse-width writes) sets the voice's bit in
  `G_BLHIT` when `2 * S_BLWC < pw < $1000 - 2 * S_BLWC`, `S_BLWC` being just
  above two frames' phase. Then at most one edge can be inside its window and
  the pulse level says which two distances to look at; a distance at or
  beyond `S_BLWC` is rejected with one compare. `bc_abs` still makes the
  exact decision and the correction; the frame it rejects goes the long way.

- **A noise voice steps its register once per frame** in its output handler:
  straight-line code for the one or two edges a frame can pass (`hn_fast`),
  a counted loop for more (`hn_step`), and one gather of the eight output
  bits, by `btst`/`rol` (31 cycles; the chain of bit tests was 37).
- **Sync frames count down to the next possible toggle** (`G_SCNT`, `fr_sync`):
  with `d` a source's whole-index distance to its next msb toggle less one,
  `21 * ((d * S_BLREC) >> 23)` cycles are certainly free of a toggle, and for
  that long the frame is the ordinary one. Every register write, a split
  frame and the 6581's msb clear reset the count.
- **A floating output that has run out stops counting** (`hfdone`; `hquiet`
  at envelope DAC zero). Under the test bit the old code remains (`hft`).

- **The edge correction of `blp_fast` is its own routine** (`bc_hit`): the
  caller makes `bc_abs`'s test and knows the sign, so the hit flag, the sign
  flag and their tests go; three shifts and 24 quotient bits give the same
  quotient as eleven and sixteen with nothing to mask above it. About 17
  cycles per corrected edge. A reciprocal in place of the `DIV` was costed
  and rejected: the normalising shifts and the fix-up cost what the divide's
  one cycle per bit does.
- **The player does not send a write that changes nothing** (`log_to_pend` in
  `src/m68k/player.s`, where the rule and its reasons are written out). A
  repeated value in a frequency, attack/decay, sustain/release, filter or
  volume register is dropped; a repeated pulse width is dropped while the
  voice's test and sync bits are clear and its waveform is none or a single
  one; the control register is always sent. 808 Love rewrites all 25
  registers about 200 times a second (4,900 writes a second, nine in ten
  repeats): receiving and applying them had cost the DSP 43 cycles per
  frame, and costs 16 now.
- **The ring holds 4096 frames, one word each** (protocol v11; it was 1024
  stereo frames). The transmit interrupt sends each word twice, as left and
  right: `movep x:(r3)+n3,x:m_tx` with `n3` alternating between 0 and 1,
  read from a two-word modulo ring through `r7`. (A `bchg #0,n3` there
  changes the carry and a fast interrupt saves no flags: the stream gate
  failed on it at once.) The mixer reads its coefficients at short addresses
  instead, which frees `r7` at no cost. The room for 4096 words comes from
  combined-waveform tables 6 and 7 sharing their words, twelve bits each
  (`DSP_CMD_LOAD_X_HI`). Rendering runs up to 3584 frames (72.9 ms) ahead,
  against 15.6 ms before.

Why the ring, when "a larger ring cannot fix sustained overload" still
holds: the passages that were left are not sustained. With two voices on
noise at the top rate and the third through the filter the frame costs
360-409 cycles; 808 Love does that for about a quarter of a second at a
time, and is at about 316 on average over the same second. The gather of
the noise output's eight bits is 31 cycles a voice and a frame as built, and
the forms costed on paper (multiplies with masks, 64-entry and 1024-entry
tables) came to 28-33, so the passage itself was not brought under the
budget; 73 ms of render-ahead carry it.

### Results

Calibrated Hatari, 30 seconds per tune with its chip model. "Checksum" is the
gate's run with the diagnostic checksum (ten cycles a frame more);
"plain" is how the player runs. Logs: `build/tune-gate-ring4k-sum.log`,
`build/tune-gate-ring4k-plain.log`. No run has an overtake or an SSI
underrun, and every checksum equals the reference's.

| Tune | 2026-10-04 | Now (plain) | Least ring fill of 3584: plain | checksum |
| --- | ---: | ---: | ---: | ---: |
| Ocean Loader 2 | 30.02 s | 30.02 s | 3552 | 3549 |
| Last Ninja 2 | 30.09 s | 30.10 s | 3548 | 3545 |
| Cybernoid II | 30.02 s | 30.03 s | 3484 | 3466 |
| Turrican | 30.02 s | 30.02 s | 3524 | 3509 |
| Commando | 30.27 s | 30.02 s | 3417 | 3375 |
| Monty on the Run | 33.20 s | 30.02 s | 3542 | 3539 |
| Wizball | 34.27 s | 30.04 s | 3551 | 3551 |
| Ghouls 'n Ghosts | 32.30 s | 30.21 s | 3505 | 3490 |
| Edge of Disgrace | 31.64 s | 30.11 s | 3276 | 3095 |
| RoboCop 3 | 34.44 s | 30.20 s | 3387 | 2974 |
| Knucklebusters | | 30.02 s | 3559 | 3556 |
| Lightforce | | 30.02 s | 3565 | 3563 |
| That's the Way It Is | | 30.03 s | 3430 | 3397 |
| Comaland tune 1 | | 30.02 s | 3570 | 3541 |
| Comaland tune 4 | | 30.02 s | 3511 | 3512 |
| Monofail | | 30.04 s | 3493 | 3470 |
| 808 Love | | 30.04 s | 1439 | 709 |

808 Love had 36 overtakes (30.79 s) before the write filter and the ring, 11
with the filter, 5 with a ring of 2048 frames.

What this does and does not show:

- **`make tune-gate` still exits with FAIL**, on four tunes: Ghouls 'n Ghosts,
  RoboCop 3 (0.2 s), Edge of Disgrace (0.11 s) and Last Ninja 2 (0.10 s) end
  later than the 60 ms tolerance allows, with a nearly full ring and no
  overtake. `player.md` attributes the offset to the start (the timer starts
  before the tune's init routine runs), and three of the four have long init
  routines (first register write at 0.12 s, 0.08 s and 0.06 s of C64 time).
  RoboCop 3's first write is at cycle 22, so for it the cause is not
  established; the tolerance was left alone.
- RSID and 2SID tunes were run and are not results. The RSID tunes (Great
  Giana Sisters and Tetris in `music/`, six in `music/heavy/`) are not played
  as written: no interrupts, no samples. The two in `music/` match the
  reference's rendering of the same minimal 6510 environment and hold real
  time (30.02 s, least ring fill 3542 and 3544), which says nothing about
  the tune; Deep Kiss produces no register write at all. Tuneful Eight's
  checksum differs from the reference's because the second SID is not
  rendered (it did before these changes too).
- The frame gate (104 of 104 identical after every change), the stream gate
  (ten of ten) and `make play-gate` pass. The stream gate's pacing tolerance
  went from 30 ms to 90 ms: rendering now ends up to a ring before playing
  does.
- First 30 seconds only; calibrated Hatari only, not hardware.
- At the end of a tune the player stops the stream when the render clock
  reaches the end, so what is still in the ring (up to 73 ms now, 15.6 ms
  before) is not played.

What remains above the budget by construction, measured on these tunes
(cycles per frame, `tools/dsp/profile_stream.py`, 2,500- to 50,000-frame
windows; averages over seconds hide all of it):

| State | Cost | Seen in |
| --- | ---: | --- |
| Two noise voices at the top rate, third voice through the filter | 360-409 | 808 Love, 0.25 s at a time |
| One such noise voice, a filter, hard sync | 333-339 before `hn_fast`, about 327 after | Edge of Disgrace, 1-2 s |
| A high pulse with an edge in nearly every frame, filter | 340-359 before `bc_hit`, 318-336 after | RoboCop 3, first second |

Not measured on real tunes: combined waveforms and ring modulation (the
general handler `hgen`), heavy hard sync between several voices (the
synthetic `sync_ring` and `rand_*` traces were 5-40% slower than real time
before this work and have not been re-timed), sawtooth edges (still the long
correction path).

## A way to remove the tune-dependent synthesis deadline

If preprocessing is acceptable, render to an uncompressed audio cache before
playback, then stream that cache through the Falcon's DMA sound playback.
This is a different playback mode and has not been implemented here.

For the supported PSID tunes, the existing C reference can produce the same
samples, including the current band-limiting and fitted filter. Cache the
chip output after the same signed 16-bit saturation used by the SSI path.
Use the codec's actual rate, `25175000 / 512` Hz. The SID output is mono; the
current stereo output duplicates it on the two channels.

- Mono cache: about 98,340 bytes/s, or 5.90 MB/minute (decimal).
- Duplicated stereo DMA stream: about 196,680 bytes/s.
- Two 4096-frame stereo buffers: 32 KiB total, with about 83 ms of audio
  in each buffer. Larger read-ahead buffers can absorb storage latency.

Playback then has file transfer and buffer refill deadlines rather than the
SID synthesis deadline. It preserves the cached samples; it does not require
a lower sample rate, a simpler filter, or lossy compression. Storage must
sustain the required throughput and latency, and DMA buffers must use
appropriate Falcon-accessible RAM. Playback still needs an underrun test on
the emulator and physical hardware before it can be called verified.

For RSID, preprocessing needs a complete C64 player, including CIA/VIC
interrupts and any required ROMs. The current `psidref` cannot provide this.
libsidplayfp is a candidate full C64/SID renderer:
https://github.com/libsidplayfp/libsidplayfp . Its output should not be described
as bit-identical to this project's fitted SID model.

## Direct synthesis remains open

If songs must start directly from SID files on a stock Falcon, the cache
approach does not meet that requirement. The seventeen tunes above play, but
the states in the last table do not fit the frame, and a tune that stays in
one of them for longer than the ring covers will underrun. Work that would
help, in the order the profiles suggest: the fixed part of a filtered frame
(set-up 21, phase add 31, mixer and filters 81, stream loop about 27); the
noise voice (about 57, of which the gather is 31); the sawtooth's edge path, which did not get `blp_fast`. A cheaper
`DIV` is not on the list (see `bc_hit` above). Profile in windows of a
second or less: four-second averages read 326 through passages at 360. Any
arithmetic replacement must pass the sample gates; any claimed real-time
result must have zero overtakes and adequate margin over whole tunes, which
has not been measured.
