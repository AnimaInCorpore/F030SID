# Performance and validation

This guide records playback measurements, how to select the calibrated
emulator, and the optimizations that preserve reference output. A matching
checksum and a passing playback deadline are separate requirements. Hardware
validation and whole-song coverage remain outstanding.

- [Two-minute load check](#two-minute-load-check): real tunes, stress traces,
  provenance and reproduction commands.
- [Emulator timing](#emulator-timing): executable selection, calibration and
  limitations.
- [Current optimizations](#current-optimizations): exact-output changes and
  remaining synthesis deadlines.

## Two-minute load check

Date: 2026-10-05.

On DSP-calibrated Hatari, the first **120 seconds** of seventeen single-SID PSIDs were checked with their default subsong and header-selected chip model. Each tune was run with the diagnostic checksum enabled and again in normal playback mode. All seventeen render clocks and diagnostic checksums match the C reference (100,306,647 rendered frames in the diagnostic runs). **Monofail exceeds real time**: normal playback records five overtakes; diagnostic playback records seventeen. Four other tunes exceed the unchanged 60 ms pacing tolerance without overtakes. Twelve tunes pass the complete player gate in both modes.

This supersedes the earlier 30-second playback window. Current buffering and optimization details are [below](#current-optimizations). Monofail’s earlier 30-second pass must not be taken as evidence that its later passages fit the DSP budget.

### Real songs

The target ring fill is 3584 frames at 25175000 / 512 Hz. Every run has SSI underrun flag zero; an overtake is independently a failure even when that flag is clear. The elapsed timer includes tune initialization. A matching checksum does not turn a timing failure into a pass.

Player-gate minimum fill and overtake verdicts use the snapshot taken while
feeding is active, within roughly 40.6 ms of the render endpoint. The final
overtake count is recorded separately but is not checked by the current gate;
the final SSI underrun flag is checked. These results do not establish
continuity of the final buffered tail. See [diagnostic fields](player.md#scope-and-gates).

| Tune | Model | Normal elapsed (s) | Normal least fill | Normal overtakes | Diagnostic elapsed (s) | Diagnostic least fill | Diagnostic overtakes | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Commando | 6581 | 120.02 | 3418 | 0 | 120.02 | 3368 | 0 | Pass |
| Cybernoid II | 6581 | 120.03 | 3325 | 0 | 120.03 | 3114 | 0 | Pass |
| Edge of Disgrace | 8580 | 120.14 | 3282 | 0 | 120.14 | 3096 | 0 | Pacing failure |
| Ghouls n Ghosts | 6581 | 120.25 | 3505 | 0 | 120.25 | 3493 | 0 | Pacing failure |
| Last Ninja 2 | 6581 | 120.11 | 3532 | 0 | 120.11 | 3531 | 0 | Pacing failure |
| Monty on the Run | 6581 | 120.02 | 3470 | 0 | 120.02 | 3455 | 0 | Pass |
| Ocean Loader 2 | 6581 | 120.03 | 3552 | 0 | 120.03 | 3549 | 0 | Pass |
| RoboCop 3 | 8580 | 120.23 | 3334 | 0 | 120.23 | 2978 | 0 | Pacing failure |
| Turrican | 6581 | 120.02 | 3521 | 0 | 120.02 | 3508 | 0 | Pass |
| Wizball | 6581 | 120.04 | 3377 | 0 | 120.06 | 2273 | 0 | Pass |
| 808 Love | 8580 | 120.04 | 1465 | 0 | 120.04 | 720 | 0 | Pass |
| Comaland tune 1 | 8580 | 120.02 | 3569 | 0 | 120.02 | 3567 | 0 | Pass |
| Comaland tune 4 | 8580 | 120.02 | 3468 | 0 | 120.02 | 3438 | 0 | Pass |
| Knucklebusters | 6581 | 120.02 | 3494 | 0 | 120.02 | 3194 | 0 | Pass |
| Lightforce | 6581 | 120.02 | 3555 | 0 | 120.02 | 3549 | 0 | Pass |
| Monofail | 8580 | 120.45 | 3 | 5 | 121.45 | 0 | 17 | Overtakes |
| Thats the Way It Is main | 6581 | 120.03 | 3188 | 0 | 120.03 | 3161 | 0 | Pass |

808 Love passes the longer window with at least 1465 buffered frames (29.8 ms) in normal playback and 720 frames (14.6 ms) with diagnostics. Monofail falls to three frames in normal playback and zero with diagnostics. Its unchanged samples and matching register-write sequence separate the synthesis deadline failure from an emulation mismatch.

Fresh normal-playback runs narrow Monofail's first overtake to **60–90 seconds**:

| Window | Elapsed (s) | Least ring fill | Overtakes | Gate |
| --- | ---: | ---: | ---: | --- |
| 60 s | 60.04 | 3278 | 0 | Pass |
| 90 s | 90.12 | 16 | 1 | Fail |
| 120 s | 120.45 | 3 | 5 | Fail |

Logs: `build/heavy-check-20261005/monofail-60.log` and `monofail-90.log`.
These follow-up runs use the corrected exit breakpoint. The trace changes to
noise and combined-waveform states in this interval, but no cycle profile was
captured to attribute the overload to a specific handler.

### Synthetic stress

`stream_gate.py --stress --jobs 2` checks ten traces on both SID models. All twenty checksums and render clocks match the reference. Eighteen cases meet the stream timing checks; `filt_3` records one overtake on each model (6581: 0.78 s elapsed for 0.61 s of audio, minimum fill 30; 8580: 0.73 s, minimum fill 11). The script prints PASS because named stress traces are allowed to miss real time; that verdict must not be read as twenty real-time passes.

`noise` and `sync_ring` pass both models. `rand_2` on the 6581 passes with only 109 frames (2.2 ms) of minimum buffer margin. These short synthetic traces do not establish sustained performance.

### Validation and provenance

- `make check`: passes, with clean DSP assembler listings.
- `tune_check.py --seconds 120`: all seventeen register/value sequences match libsidplayfp over the common roughly 110-second output window. This comparator aligns the initial writes and compares the common prefix, not exact per-write C64 timing or the final ten seconds.
- Player gate: 34 two-minute runs, with independent output directories for normal playback and diagnostics.
- Stream gate: twenty cases, two chip models.
- Fixed `tools/player/play_gate.py` to quit on GEMDOS `Pterm` ($4c), which the player now uses. The old breakpoint waited for `Pterm0` and idled after completion. A fresh five-second Commando run passes and its log confirms the $4c breakpoint fired. Already-running old gates were stopped only after a complete 32-byte result and the player’s `done` message; their reported tick counts come from the player, before that stop.

Source commit: `15a2b12bf3a0eb6f722fdf6c87a72d39504c01df`. Player SHA-256: `0ec20ffef469928b38275079924a5fc02dbba5f060f2e8c14ef4e3ec56f7072b`. The only source-code change during this check is the gate exit breakpoint; DSP/player synthesis is unchanged.

Logs and binary results are under `build/heavy-check-20261005/` (ignored): `checksum.log`, `plain.log`, `stream-stress.log`, `cpu-reference.log`, `exit-check.log`, `results.json`, and each run’s `PLAYOUT.BIN` / `stream_expected.txt`. `selection.json` records the exact seventeen input paths; `results.json` also records their SHA-256 values.

### Reproduce the failing song

`python3 tools/player/fetch_heavy_corpus.py` verifies/downloads the pinned
heavy workload into ignored `music/`. Build the player and reference tools
with `make all build/ref/psidref build/ref/make_vec` before the direct gate
command below. Set `HATARI` to your calibrated emulator executable, as
described under [emulator timing](#emulator-timing). The ten original tunes
require your own local `music/` inputs.

```sh
python3 tools/player/play_gate.py \
  --build build/monofail-120 \
  --hatari "$HATARI" \
  --tos third_party/f030dsp3d/tools/tos402.rom \
  --seconds 120 --models tune --vbls-per-second 130 --plain \
  music/heavy/Monofail.sid
```

Omit `--plain` and use another build directory for the checksum run. For the full suite, replace the final input with the seventeen single-SID PSID paths listed above and add `--jobs 2`.

### Measurement scope

Calibrated Hatari only, not physical Falcon hardware; first two minutes only, not full songs or all subsongs. RSID, interrupt-driven sample playback and multi-SID files remain unsupported and are excluded. The player stops at the render endpoint, leaving up to one render-ahead ring of audio unplayed, as described under [remaining deadlines](#remaining-deadlines). No gate tolerance was relaxed.

## Emulator timing

Playback timing results use a DSP-calibrated Hatari build with the clock and
host-port corrections described below. Select its executable explicitly so
the checks do not depend on the layout of other local checkouts.

### Selecting the binary

Pass `HATARI` to make or put it in git-ignored `local.mk`:

```sh
make smoke HATARI=/path/to/calibrated/hatari
```

```make
HATARI := /path/to/calibrated/hatari
```

An exported `HATARI` also configures make. Direct Python gate commands
require an explicit `--hatari`; player gates also require `--tos`:

```sh
export HATARI=/path/to/calibrated/hatari
python3 tools/player/play_gate.py --hatari "$HATARI" --help
```

The Makefile selects the executable and passes it to the gate scripts. The
shared resolver in `tools/hatari_binary.py` offers the same local candidates,
but direct gate entry points require their command-line paths. Without an
override, make searches configured local candidates and falls back to
`hatari` on PATH. Set the path explicitly
for reproducible runs. The Makefile can warn when it does not recognize an
override as its detected calibrated build; verify that your executable has
the corrections below before interpreting timing results.

### Why calibration matters

The stock build used for the original comparison applied `DSP_CPU_FREQ_RATIO`
twice: callers already scaled CPU cycles, and `DSP_Run()` scaled them again.
It gave the DSP about 32 MIPS instead of the Falcon's 16 MIPS. Instruction
cycle profiles still agreed; elapsed-time and underrun results did not.

The calibrated build also charges host-port wait states once per access,
using direction/size tables measured against DSPBench v3.0b (reads 3/7/10,
writes 4/3/7 cycles for byte/word/long accesses). This matters when the 68030
feeds frequent SID writes and filter coefficients.

At the modeled DSP clock of 32,084,988 Hz, the hardware instruction budget is:

| Codec rate | DSP instruction cycles per output frame |
| --- | ---: |
| 24,584.9609375 Hz | 652.5 |
| 32,779.9479167 Hz | 489.4 |
| 49,169.921875 Hz (F030SID) | 326.3 |

Use whole streaming runs alongside profiles: register traffic, host commands,
SSI interrupts and buffer margin also determine whether playback keeps up.
The [two-minute load check](#two-minute-load-check) records independent checksum,
clock, pacing and overtake results on this calibrated emulator.

### Hardware validation

No F030SID player has run on physical hardware. Hatari does not settle audio
continuity, inherited sound state, external-memory bus behavior or 68030 bus
contention under real video output. `make ratetest-hatari` and
`make dspprobe-hatari` exercise the probe programs in the emulator; the same
programs still need physical-Falcon checks. Keep hardware validation separate
from emulator measurements.

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
holds: the measured 808 Love passages are short enough for the ring.
Monofail's longer overload is not (see the two-minute check). With two voices on
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
