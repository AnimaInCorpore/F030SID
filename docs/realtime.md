# Real-time playback

The stock Falcon has about 326.3 DSP instruction cycles per output frame at
49,169.921875 Hz. The current kernel preserves the reference arithmetic,
waveforms, polyBLEP interpolation and fitted filter. Buffering carries brief
cost spikes; it cannot fix sustained overload.

## Current results

The [2026-10-05 two-minute load check](heavy-load-check.md) is the current
playback measurement: seventeen single-SID PSIDs, normal and diagnostic modes,
default subsongs and header-selected models on calibrated Hatari. All seventeen
diagnostic checksums match the reference. Twelve tunes pass both complete
gates. Monofail records five normal and seventeen diagnostic overtakes;
four other tunes miss the unchanged 60 ms pacing tolerance without overtakes.
Monofail's first overtake lies between 60 and 90 seconds, despite its earlier
30-second pass.

The target ring fill is 3584 frames out of 4096 (72.9 ms). Normal playback
omits the diagnostic checksum, saving ten DSP cycles per frame; use `-v -p`
or `play_gate.py --plain` to measure that path. A zero SSI underrun flag does
not imply zero renderer overtakes, and matching samples do not excuse a
missed synthesis deadline.

The latest synthetic stress check matches clocks and checksums in all twenty
cases. Eighteen meet timing; `filt_3` overtakes once on each model. Stress mode
permits timing failures, so its printed PASS is not a real-time guarantee.
No complete songs, all subsongs or physical-Falcon playback have been checked.

## Current optimizations

The common path keeps the stream pointer and sync state in registers or short
memory, bounds render runs by the released horizon, and uses a countdown to
avoid split-sync work when no source can toggle. Quiet plain waveforms skip
DAC/BLEP output work while their oscillators and envelopes continue clocking.
A resting envelope advances up to 240 rate steps at once. Unchanged frequency
and pulse writes preserve edge countdowns where safe; unchanged filter state
does not resend coefficients.

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
holds: the measured 808 Love passages are short enough for the ring. Monofail's longer overload is not (see the two-minute check). With two voices on
noise at the top rate and the third through the filter the frame costs
360-409 cycles; 808 Love does that for about a quarter of a second at a
time, and is at about 316 on average over the same second. The gather of
the noise output's eight bits is 31 cycles a voice and a frame as built, and
the forms costed on paper (multiplies with masks, 64-entry and 1024-entry
tables) came to 28-33, so the passage itself was not brought under the
budget; 73 ms of render-ahead carry it.

## Remaining deadlines

Measured short windows still exceed the frame budget: two top-rate noise
voices with a filtered third voice cost 360–409 cycles/frame in 808 Love;
noise plus filter and sync was about 327 after the fast noise path in Edge
of Disgrace. These are local measurements, not worst-case bounds. Monofail's
60–90-second overload has not been profiled closely enough to assign it to
one handler.

Profile real tunes in sub-second windows and include stream work, interrupts
and register traffic. Candidates for further work include the filtered frame's
fixed cost, noise output gathering, the sawtooth edge path and heavy combined
waveform/sync traffic. Any arithmetic change must retain exact sample-gate
results; a real-time claim also needs zero overtakes and adequate buffer margin.

The player stops when the render clock reaches the endpoint, leaving up to
72.9 ms of buffered audio unplayed. Pacing measurements include initialization.
Three of the four pacing failures have long init routines; RoboCop 3's offset
is not explained by its first write. No tolerance was relaxed to hide them.
RSID interrupts, interrupt-driven digis and extra SIDs remain unsupported.
