# The SID player

The project's main executable is **`F030SID.TTP`**, a TOS Takes Parameters
program for playing `.sid` files on the Atari Falcon030. `make all` builds
it as `release/f030sid.ttp`; `make package` distributes it as `F030SID.TTP`
inside `release/F030SID.ZIP`. Start it from the desktop parameter dialog or
a shell, passing the tune filename.

`release/f030sid.ttp` runs the tune's 6510 code on the 68030 and sends
cycle-stamped SID writes and filter coefficients to the DSP's protocol v12
stream. Supported playback is single-SID PAL PSID with a play routine called
at a fixed frame or timer rate. The loader also accepts RSID headers; that
does not supply the interrupts or full C64 environment RSID needs.

## Running

```text
F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds] [-v] [-p]
```

- `song` is one-based; omission uses the tune's default subsong.
- `-m` overrides the header-selected model, otherwise defaulting to 6581 when
  the header does not specify one.
- `-t` stops at that many seconds of tune time. A key can stop playback at any
  time. Without `-t`, an internal cycle ceiling also ends playback after about
  36.3 minutes; this is not a song-length lookup.
- `-v` writes the DSP status to `PLAYOUT.BIN` with its diagnostic checksum enabled.
- `-v -p` records status with the checksum disabled, as in normal playback.

With no command tail the player reads the same line from `AUTOPLAY.INF` in
the current folder. Paths are whitespace-delimited. The loader reads at most
66000 bytes; larger files are unsupported and may be truncated rather than
rejected. The player prints the title, author and release text.
An error waits for a key so the desktop user can read it.

The DSP program and tables are embedded in the TTP. The host configures the
Falcon sound path. On exit it stops the DSP stream, disables DSP sound
connections and releases sound/DSP locks; it does not save and restore the
previous attenuation, codec mode or crossbar routing.
The stopping key becomes the exit code; a timed stop returns zero. There is
no fade or song-length database. The stop occurs at the render endpoint,
leaving up to 72.9 ms buffered audio unplayed.

## Under FreeMiNT

The player is an ordinary user-mode process, so the same binary runs under
TOS and FreeMiNT. The earlier player switched to supervisor mode
for the whole tune and paced itself by polling the 200 Hz tick there. MiNT
cannot preempt a process in supervisor mode, so the music played and the
rest of the system stopped: a busy process beside it kept 0.4% of its speed.
The player now:

- shrinks its memory to its own stack, declares itself a MiNT program
  (`Pdomain(1)`), and stops the tune on SIGINT, SIGTERM, SIGQUIT and SIGHUP
  the same way a key does;
- locks the DSP (`Dsp_Lock`) and the sound system (`Locksnd`) and reports
  "the DSP is in use" or "the sound system is in use" when another program
  holds them;
- talks to the DSP only through XBIOS `Dsp_BlkHandShake`, and reads the
  200 Hz tick only through `Supexec`. Each DSP transaction (a command's words, then one
  reply word) is short; the player never waits for the DSP in supervisor
  mode between transactions;
- sleeps between passes in `Fselect(5 ms)`. MiNT rounds that up to its 20 ms
  scheduler tick: 200 calls took 809 ticks of 5 ms. Under TOS, which has no
  `Fselect` (`EINVFN`), the player waits for the next 200 Hz tick instead.

Because a pass can be 20 ms or more apart under MiNT, and other programs can
hold the CPU for longer, the player keeps a quarter second of tune generated
ahead (`GEN_LEAD`, 250,000 cycles) and the DSP queue holds 1024 writes. It
generates 40,000 cycles at a time and pushes each step before the next, so
the first push does not wait for the whole lead, and a pass that comes late
catches up in one go.
`Dsp_BlkUnpacked` is not usable for the protocol: TOS 4.02 waits for the
host port only before a block's first word and writes the rest blind, so
words overwrite each other while the DSP is rendering
([host transport](dsp-kernel.md#host-transport)).

Measured on 2026-10-09 under the DSP-calibrated Hatari, TOS 4.02 and the
FreeMiNT 1.19 snapshot `648983e1` with memory protection off. The tune was
`music_1`, 8 seconds:

| Situation | Result |
| --- | --- |
| Player alone | 8.00 s of tune in 7.99 s, no overtakes, least ring fill 3572 of 3584 |
| Beside a process in a busy loop | 8.00 s in 8.16 s, no overtakes, least ring fill 3534 |
| The same, 2 s of tune | 2.00 s in 2.12 s, no overtakes, least ring fill 2458 |
| Load (busy loop's slowdown) | about 18% over 10 s (3322 of 4045 loop blocks kept) |
| SIGINT after 10 s, 60 s tune | stopped at 9.59 s, locks released |

Beside the busy process the tune starts 0.1-0.16 s late; once it runs, the
ring stays nearly full. Earlier measurements of this case read "least fill 0"
because a late pass skipped the snapshot window (see `PLAYOUT.BIN` below), and
a cap of 40,000 cycles per pass, tried in between, fell behind (7.12 s of tune
in 9.59 s, 28 overtakes).

How much CPU the player needs depends on the tune's 6510 code. Under TOS,
where everything not spent waiting for the next tick is the player's work,
`music_1` needs under 1% and Monofail, the heaviest tune checked, about 79%
([profile](performance.md#cpu-time-on-the-68030)). Under MiNT `music_1` cost
a busy neighbour about 24% while it played; that is mostly MiNT-side
overhead, not yet attributed. Monofail plays in real time alone (4.00 s in
3.98 s, no overtakes) but beside a busy process MiNT gives each about half the
CPU, and it falls behind (4 s of tune in 5.30 s, 14 overtakes). Heavy tunes
therefore need an otherwise idle system. Not tested: memory protection on,
the XaAES desktop, and a physical Falcon.

To repeat this in Hatari: unpack the snapshot's `tt_falcon_clones` archive
into a folder used as GEMDOS drive C, put `MEM_PROT=NO` in
`mint/1-19-648/mint.ini`, and name a test program with `INIT=` in
`mint.cnf`. Hatari needs `--fpu 68882` (the snapshot's bash refuses to run
without one). Do not test through bash's `&`: this bash sizes its job
table by doubling from 512 up to the child limit, which MiNT reports as
`0x7fffffff`; the doubling overflows to zero and the shell spins until a
signal arrives. A small program that starts the player with `Pvfork` and
`Pexec` mode 200 avoids bash entirely.

## Tune menu

`release/sidmenu.tos` lists up to nine tunes and launches `F030SID.TTP` on
keys 1–9. Keep both programs and `MENU.INF` in the same folder. Each line is:

```text
command tail for F030SID.TTP;title shown in the menu
```

For example:

```text
ROBOCOP3.SID;RoboCop 3
TUNE.SID 2 -m 8580;Tune, song 2
```

Without `;`, the command tail is the displayed title. Use GEMDOS 8.3 filenames.
While playing, 1–9 switches immediately to that tune; any other key returns
to the menu. Esc or Q at the menu exits. The menu releases unused memory
before launching the player. Injected-key checks under Hatari covered launch,
switch, return and exit; there is no automated menu gate. `make all` builds
it; `make package` does not include it in `F030SID.ZIP`.

## Playback status

The latest [two-minute check](performance.md#current-check-2026-10-09), dated 2026-10-09, runs
seventeen single-SID PSIDs with their default subsong and header-selected
model. All diagnostic checksums and render clocks match the reference.
Sixteen tunes pass both normal and diagnostic gates. Monofail has four normal
and fifteen diagnostic overtakes. The check before it (2026-10-05) also
failed Last Ninja 2, Ghouls n Ghosts, Edge of Disgrace and RoboCop 3 on
pacing; that gate counted their long init routines, which the current gate
no longer does.

The register/value sequences match libsidplayfp over the common roughly
110-second comparison window. This comparison does not establish exact
per-write timing or correctness of the final ten seconds. Earlier 30-second
passes do not establish whole-song performance; Monofail first overtakes
between 60 and 90 seconds. Nothing has run on a physical Falcon.

## Scope and gates

The [core specification](../tools/player/README.md) defines RAM, opcodes,
raster reads and the call schedule. ROM calls, banking, CIA/VIC interrupts,
interrupt-driven digis, NTSC, live OSC3/ENV3 reads and extra SIDs are unsupported.
[Playback limits and optimizations](performance.md#remaining-deadlines) explain synthesis limits and buffering.

`make cpu-ref-check`, `make cpu-gate` and `make coef-gate` verify the host
components. `make play-gate` checks generated tunes end to end;
`make package-gate` checks the packaged demo. `make tune-check` compares local
music with libsidplayfp; `make tune-gate` checks 30-second playback with the
selected chip model. Timing, output and overtake checks must all pass.

With `-v`, `PLAYOUT.BIN` contains ten big-endian 32-bit words: final render
clock, checksum, minimum fill sampled before the endpoint, overtakes sampled
before the endpoint, final SSI underrun flag, final overtake count, generated
6510 cycles, 200 Hz ticks from before the tune's init routine to the render
endpoint, 200 Hz ticks from the DSP's first released frame to the render
endpoint, and the ring fill in frames at the endpoint. The last two give the
audio's length: the ticks plus what is still buffered. Results before
2026-10-09 had eight words and judged pacing on the eighth, which counted
the start-up and left out the buffered tail. The fill/overtake snapshot is taken
within roughly 40.6 ms of the render endpoint, while feeding is still active.
A pass that arrives later than that (under MiNT, beside a busy process) would
skip the window; the player then takes the snapshot at the endpoint, before
it stops the stream. Before this fallback such a run reported a fill of 0
and 0 overtakes.
The current gate checks that snapshot's overtakes and the final SSI flag;
it records the final overtake count but does not use it for the verdict.
