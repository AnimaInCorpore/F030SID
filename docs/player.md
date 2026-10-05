# The SID player

**Status.** `release/f030sid.ttp` (`src/m68k/player.s`) plays PSID files:
`F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds] [-v]`, or the same line
from `AUTOPLAY.INF`. The 68030 runs the tune's 6510 code (`cpu6502.s`, `psid.s`),
derives the filter coefficient words (`filtcoef.s`) and feeds the DSP kernel's
stream a couple of PAL frames ahead of its render clock; a key stops. The end to
end gate (`make play-gate`) is bit-exact against the reference models and in
real time under the calibrated Hatari (the DSP renders band-limited voices through
the fitted filter, see dsp-kernel.md); what the 6510 side does and does not
emulate is in `tools/player/README.md` (no ROMs, CIA, VIC or interrupts: PSID
tunes with a play routine at a fixed rate; no RSID, no interrupt-driven digis,
PAL only, one SID). Not yet there: fade-out and song lengths, a display beyond
title and author. Nothing has run on a real
Falcon. On an error the player now waits for a key, so the message can be read
when it was started from the desktop. The key that stops a tune is the
player's exit code (0 when `-t` or the tune's end stopped it), which is what
the tune menu below switches tunes with.

**The tune menu.** `release/sidmenu.tos` (`src/m68k/sidmenu.s`) lists up to nine
tunes and starts `F030SID.TTP` on the one whose key, 1 to 9, is pressed. It
and the player must be in one folder, with a `MENU.INF` of one line per tune:

    command tail for F030SID.TTP;title shown in the menu

for example `ROBOCOP3.SID;RoboCop 3` or `TUNE.SID 2 -m 8580;Tune, song 2`
(a line without `;` shows its command tail; file names are GEMDOS names, 8.3).
While a tune plays, 1 to 9 starts that tune at once, any other key returns to
the menu, and Esc or Q there leaves. The menu frees all memory but its own
before it starts the player. Checked under Hatari with injected key presses
(menu, a tune, a switch from the playing tune, back to the menu, leaving); it
is not part of `F030SID.ZIP` and no gate runs it.

**Real tunes** (twelve from HVSC in `music/`, 2026-10-04, calibrated Hatari; `make
tune-check`, `make tune-gate`). `tune-check`: on all ten PSID tunes the reference
core's register writes equal libsidplayfp's over 55 s (17,000 to 112,000 writes
each; the elapsed cycles differ by less than a frame); the two RSID tunes (Great
Giana Sisters, Tetris: samples from interrupts) differ within the first writes, as
expected. Player gate, 30 s each with the tune's model: the DSP's checksum equals
the reference's on every PSID tune, but real time is held by three only.

Later exact-output optimizations, a deeper ring and the player's dropping of
writes that change nothing (`log_to_pend`) bring all ten into real time in
the 30-second run, without overtakes; the measured results and the remaining
limitations are in [realtime.md](realtime.md). The table below records the
earlier player (its ring fills count words of the 1024-stereo-frame ring).

| tune | model | first run | now (`--plain`) | overtakes now | least ring fill of 1536 |
| --- | --- | ---: | ---: | ---: | ---: |
| Ocean Loader 2 | 6581 | 30.02 s | 30.02 s | 0 | 1451 |
| Last Ninja 2 | 6581 | 30.09 s | 30.09 s | 0 | 1417 |
| Cybernoid II | 6581 | 30.09 s | 30.02 s | 0 | 711 |
| Turrican | 6581 | 30.30 s | 30.06 s | 2 | 22 |
| Commando | 6581 | 31.49 s | 31.04 s | 49 | 0 |
| Ghouls 'n Ghosts | 6581 | 43.38 s | 33.26 s | 146 | 0 |
| Monty on the Run | 6581 | 34.19 s | 33.70 s | 177 | 0 |
| Edge of Disgrace | 8580 | 36.49 s | 34.19 s | 195 | 0 |
| Wizball | 6581 | 37.42 s | 35.95 s | 283 | 0 |
| RoboCop 3 | 8580 | 49.06 s | 36.08 s | 281 | 0 |

"First run" is the kernel as the tunes first met it; "now" has the resting envelope taken in
blocks, the stream without its checksum (`play_gate.py --plain`: how the player runs without
`-v`) and the ring doubled, see `dsp-kernel.md` (Cost). The 0.02-0.09 s over 30 s of the tunes
that hold real time is the start (the init routine runs after the stream starts).

So the kernel's mean cost on real music was 100-165% of the frame and is 100-120%
now, not the 85% of the synthetic `music_*` traces. The overtake counts above are too low (a lap during a
run that the host's call ended was not seen; fixed since: Wizball counts 713, Monty
on the Run 401), the elapsed time is the reliable figure. Where the time goes: the profile of two tunes in
`dsp-kernel.md` (Cost); ideas from the OPL kernel in `scummvm-opl-hints.md`.

These runs also found a rounding difference: the DSP's `rnd` on the output word
rounds an exact tie to even, the reference rounded it up. It showed after 7.6 s of
the package's demo tune on the 8580 and 13 s into Cybernoid II; the reference now
rounds as the DSP does (`mix_output`).

The rest of this document is the original plan.

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
