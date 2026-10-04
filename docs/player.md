# The SID player

**Status.** `release/f030sid.ttp` (`src/m68k/player.s`) plays PSID files:
`F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds] [-v]`, or the same line
from `AUTOPLAY.INF`. The 68030 runs the tune's 6510 code (`cpu6502.s`, `psid.s`),
derives the filter coefficient words (`filtcoef.s`) and feeds the DSP kernel's
stream a couple of PAL frames ahead of its render clock; a key stops. The end to
end gate (`make play-gate`) is bit-exact against the reference models and in
real time under the calibrated Hatari; what the 6510 side does and does not
emulate is in `tools/player/README.md` (no ROMs, CIA, VIC or interrupts: PSID
tunes with a play routine at a fixed rate; no RSID, no interrupt-driven digis,
PAL only, one SID). Not yet there: fade-out and song lengths, a display beyond
title and author, tune selection while playing. Nothing has run on a real
Falcon. The rest of this document is the original plan.

Two TOS programs are needed. `voicetest.tos` (done) is the test harness: it
feeds trace vectors to the DSP kernel and dumps the output so the gate can
compare it with the C reference. The player is the actual product: it plays
`.sid` files. It follows the shape of pschatzmann's
[SIDPlayer](https://github.com/pschatzmann/SIDPlayer), an Arduino library
built on Hermit's cSID light.

What I took from SIDPlayer (from its README, API header and file list; I have
not read its source): the player is one small engine behind a four-call API,

| SIDPlayer / cSID light | F030SID player |
| --- | --- |
| `libcsid_init(samplerate, sidmodel)` | boot the DSP, load its tables, select 6581/8580, set the codec rate |
| `libcsid_load(buffer, len)` | parse the PSID/RSID header, copy the data to its load address in a 64 KB C64 RAM image |
| `libcsid_play(tune)` | reset the 6502, run the tune's init routine with the song number in A |
| `libcsid_render(buf, n)` | run the play routine at the tune's frame rate; every SID write goes to the SID emulation |
| `gettitle/getauthor/getinfo`, tune counts | the same header fields, shown on screen |

The whole file is loaded into memory first (SIDPlayer notes that SID data
cannot be streamed), and one 64 KB RAM image is the C64's address space.

What differs on the Falcon: SIDPlayer runs the 6502 and the SID on one CPU and
renders samples. Here the 68030 runs the 6502 and only timestamps and queues
the SID writes; the DSP renders (docs/dsp-kernel.md) and owns the SSI stream.
The per-frame timestamp is a SID cycle count, so the host never needs to know
the codec's frame grid: the DSP maps cycles to its 20/21-cycle frames.

## Program form: a TTP

The player is `f030sid.ttp` (TOS Takes Parameters), like F030MXDRV's: the
desktop asks for a command line, and from a shell or Hatari's GEMDOS drive it is
given directly.

```text
F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds]
```

With no command tail, `AUTOPLAY.INF` beside the program may hold the same line,
so the program can also start from a double click. The tune path is
whitespace-delimited; the file is read whole into memory (PSID files are at most
64 KB of C64 data plus a header of up to 124 bytes). Playback fades after the
tune's length (`-t`, default from a song-length table if present, else a fixed
time) or on the first keypress, and a second keypress stops at once. Every exit
path restores the DSP, the crossbar, the codec attenuation and the sound lock,
as F030MXDRV's player does. The Makefile already produces `release/f030sid.ttp`
(today a copy of the bring-up program); the player replaces it.

`voicetest.tos` and the other test programs stay plain TOS programs: they take
no arguments and exist to be run by the gates.

## Pieces

1. **PSID/RSID loader** (68030): header v1-v4, load address (header or first
   two data bytes), init/play addresses, song count, speed bits, clock and
   SID-model flags, second/third SID addresses. `tools/trace/sidtrace.cc`
   already shows what libsidplayfp does with these fields.
2. **6502 core** (68030): the 6510 with its I/O port, cycle counting per
   instruction (the write timestamps), and the memory map a PSID needs (RAM,
   SID at $D400, CIA/VIC stubs for the timing registers a player reads).
3. **Frame driver**: call play at 50/60 Hz or from the CIA timer the tune sets
   up (play address 0 means the tune installs its own IRQ); a cycle budget per
   call.
4. **Write queue to the DSP**: `(cycle, reg, value)` batches per period,
   delivered like F030MXDRV's refills (docs/scummvm-opl-hints.md): early
   announce, paced host-port words, the DSP acknowledging before it renders.
5. **SSI stream and UI**: the DSP's codec ring, key handling, title/author
   display, tune selection, fade.

`sidtrace` doubles as the player's oracle: its traces are the register streams
a correct 6502 core must reproduce for the same tune.

## Order

The DSP kernel comes first (milestone 1 is gated; noise, combined waveforms,
sync, the other voices, the filter and the band-limited output are next), then
the 6502 core against `sidtrace` traces, then the stream. A player that plays
every voice and the filter correctly needs the DSP side complete; a first
audible build can come earlier with voice 0 only, as a milestone check.
