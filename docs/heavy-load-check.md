# Extended DSP load check — 2026-10-05

On DSP-calibrated Hatari, the first **120 seconds** of seventeen single-SID PSIDs were checked with their default subsong and header-selected chip model. Each tune was run with the diagnostic checksum enabled and again in normal playback mode. All seventeen render clocks and diagnostic checksums match the C reference (100,306,647 rendered frames in the diagnostic runs). **Monofail exceeds real time**: normal playback records five overtakes; diagnostic playback records seventeen. Four other tunes exceed the unchanged 60 ms pacing tolerance without overtakes. Twelve tunes pass the complete player gate in both modes.

This supersedes the earlier 30-second playback window. The current buffering
and optimization details are in [realtime.md](realtime.md). Monofail’s earlier 30-second pass must not be taken as evidence that its later passages fit the DSP budget.

## Real songs

The target ring fill is 3584 frames at 25175000 / 512 Hz. Every run has SSI underrun flag zero; an overtake is independently a failure even when that flag is clear. The elapsed timer includes tune initialization. A matching checksum does not turn a timing failure into a pass.

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

## Synthetic stress

`stream_gate.py --stress --jobs 2` checks ten traces on both SID models. All twenty checksums and render clocks match the reference. Eighteen cases meet the stream timing checks; `filt_3` records one overtake on each model (6581: 0.78 s elapsed for 0.61 s of audio, minimum fill 30; 8580: 0.73 s, minimum fill 11). The script prints PASS because named stress traces are allowed to miss real time; that verdict must not be read as twenty real-time passes.

`noise` and `sync_ring` pass both models. `rand_2` on the 6581 passes with only 109 frames (2.2 ms) of minimum buffer margin. These short synthetic traces do not establish sustained performance.

## Validation and provenance

- `make check`: passes, with clean DSP assembler listings.
- `tune_check.py --seconds 120`: all seventeen register/value sequences match libsidplayfp over the common roughly 110-second output window. This comparator aligns the initial writes and compares the common prefix, not exact per-write C64 timing or the final ten seconds.
- Player gate: 34 two-minute runs, with independent output directories for normal playback and diagnostics.
- Stream gate: twenty cases, two chip models.
- Fixed `tools/player/play_gate.py` to quit on GEMDOS `Pterm` ($4c), which the player now uses. The old breakpoint waited for `Pterm0` and idled after completion. A fresh five-second Commando run passes and its log confirms the $4c breakpoint fired. Already-running old gates were stopped only after a complete 32-byte result and the player’s `done` message; their reported tick counts come from the player, before that stop.

Source commit: `15a2b12bf3a0eb6f722fdf6c87a72d39504c01df`. Player SHA-256: `0ec20ffef469928b38275079924a5fc02dbba5f060f2e8c14ef4e3ec56f7072b`. The only source-code change during this check is the gate exit breakpoint; DSP/player synthesis is unchanged.

Logs and binary results are under `build/heavy-check-20261005/` (ignored): `checksum.log`, `plain.log`, `stream-stress.log`, `cpu-reference.log`, `exit-check.log`, `results.json`, and each run’s `PLAYOUT.BIN` / `stream_expected.txt`. `selection.json` records the exact seventeen input paths; `results.json` also records their SHA-256 values.

## Reproduce the failing song

`python3 tools/player/fetch_heavy_corpus.py` verifies/downloads the pinned
heavy workload into ignored `music/`. Build the player and reference tools
with `make all build/ref/psidref build/ref/make_vec` before the direct gate
command below. The ten original tunes require your own local `music/` inputs.

```sh
python3 tools/player/play_gate.py \
  --build build/monofail-120 \
  --hatari "$HOME/Work/F030Arcade/third_party/hatari/build/src/hatari" \
  --tos third_party/f030dsp3d/tools/tos402.rom \
  --seconds 120 --models tune --vbls-per-second 130 --plain \
  music/heavy/Monofail.sid
```

Omit `--plain` and use another build directory for the checksum run. For the full suite, replace the final input with the seventeen single-SID PSID paths listed above and add `--jobs 2`.

## Limits

Calibrated Hatari only, not physical Falcon hardware; first two minutes only, not full songs or all subsongs. RSID, interrupt-driven sample playback and multi-SID files remain unsupported and are excluded. The player stops at the render endpoint, leaving up to one render-ahead ring of audio unplayed, as documented in `realtime.md`. No gate tolerance was relaxed.
