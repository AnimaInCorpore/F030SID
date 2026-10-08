# Hatari timing for F030SID

Playback timing results in this project use the DSP-calibrated Hatari from
F030Arcade. Its clock and host-port calibration are described in that sibling
checkout's `hatari.md`. Sibling YM2151 playback and hardware results are not
F030SID validation.

## Selecting the binary

The Makefile uses an explicit `HATARI` override first, then a calibrated build
under `F030ARCADE` (default `~/Work/F030Arcade`) or the sibling F030Arcade
checkout, then `hatari` on PATH. It searches `build` and `build-ucrt64`, with
both `hatari` and `hatari.exe` names. Python tools use the same candidates via
`tools/hatari_binary.py`, honor the `HATARI` environment variable and accept
`--hatari`.

```sh
make smoke
make smoke F030ARCADE=/path/to/F030Arcade
make smoke HATARI=/path/to/calibrated/hatari
```

Overrides can go in git-ignored `local.mk`. The Makefile warns when the chosen
binary differs from its detected calibrated build. An explicit override is
allowed, but its timing must be interpreted according to that build's model.

## Why calibration matters

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
The [latest load check](heavy-load-check.md) records independent checksum,
clock, pacing and overtake results on this calibrated emulator.

## Limits

No F030SID player has run on physical hardware. Hatari does not settle audio
continuity, inherited sound state, external-memory bus behavior or 68030 bus
contention under real video output. `make ratetest-hatari` and
`make dspprobe-hatari` exercise the probe programs in the emulator; the same
programs still need physical-Falcon checks. Keep hardware validation separate
from emulator and sibling-project measurements.
