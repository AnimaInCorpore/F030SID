# The SID player

The project's main executable is **`F030SID.TTP`**, a TOS Takes Parameters
program for playing `.sid` files on the Atari Falcon030. `make all` builds
it as `release/f030sid.ttp`; `make package` distributes it as `F030SID.TTP`
inside `release/F030SID.ZIP`. Start it from the desktop parameter dialog or
a shell, passing the tune filename.

`release/f030sid.ttp` runs the tune's 6510 code on the 68030 and sends
cycle-stamped SID writes and filter coefficients to the DSP's protocol v11
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
- `-t` stops at that many seconds of tune time. Without it, a key stops playback.
- `-v` writes the DSP status to `PLAYOUT.BIN` with its diagnostic checksum enabled.
- `-v -p` records status with the checksum disabled, as in normal playback.

With no command tail the player reads the same line from `AUTOPLAY.INF` in
the current folder. Paths are whitespace-delimited. Files larger than 66000
bytes are rejected. The player prints the title, author and release text.
An error waits for a key so the desktop user can read it.

The DSP program and tables are embedded in the TTP. The host configures the
Falcon sound path, then restores its saved state and releases locks on exit.
The stopping key becomes the exit code; a timed stop returns zero. There is
no fade or song-length database. The stop occurs at the render endpoint,
leaving up to 72.9 ms buffered audio unplayed.

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

The latest [two-minute check](heavy-load-check.md), dated 2026-10-05, runs
seventeen single-SID PSIDs with their default subsong and header-selected
model. All diagnostic checksums and render clocks match the reference.
Twelve tunes pass both normal and diagnostic gates. Monofail has five normal
and seventeen diagnostic overtakes; Last Ninja 2, Ghouls n Ghosts, Edge of
Disgrace and RoboCop 3 fail the 60 ms pacing tolerance without overtakes.

The register/value sequences match libsidplayfp over the common roughly
110-second comparison window. This comparison does not establish exact
per-write timing or correctness of the final ten seconds. Earlier 30-second
passes do not establish whole-song performance; Monofail first overtakes
between 60 and 90 seconds. Nothing has run on a physical Falcon.

## Scope and gates

The [core specification](../tools/player/README.md) defines RAM, opcodes,
raster reads and the call schedule. ROM calls, banking, CIA/VIC interrupts,
interrupt-driven digis, NTSC, live OSC3/ENV3 reads and extra SIDs are unsupported.
[Real-time notes](realtime.md) explain synthesis limits and buffering.

`make cpu-ref-check`, `make cpu-gate` and `make coef-gate` verify the host
components. `make play-gate` checks generated tunes end to end;
`make package-gate` checks the packaged demo. `make tune-check` compares local
music with libsidplayfp; `make tune-gate` checks 30-second playback with the
selected chip model. Timing, output and overtake checks must all pass.
