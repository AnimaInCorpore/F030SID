# Hatari timing for F030SID

Playback timing results use a DSP-calibrated Hatari build with the clock and
host-port corrections described below. Select its executable explicitly so
the checks do not depend on the layout of other local checkouts.

## Selecting the binary

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
from emulator measurements.
