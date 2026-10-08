========================================
  F030SID  -  C64 SID music player
  for the Atari Falcon030
========================================

Preview release v0.1

F030SID.TTP is a TOS Takes Parameters
player for Commodore 64 .sid music
files on the Atari Falcon030.  Start
it from the desktop or a shell and
pass the tune filename.

Supported files are single-SID PAL
PSID tunes.  RSID, interrupt-driven
samples, NTSC and extra SIDs are not
supported.  Some demanding tunes
still exceed the DSP playback budget.

The 68030 runs the tune's original
6510 code.  The DSP56001 emulates the
SID chip, MOS 6581 or 8580, with all
three voices, every waveform, hard
sync, ring modulation, the envelopes
and the filter, and plays it through
the Falcon's own DAC at 49 kHz.

This is a preview.  It has been built
and tested under a DSP-calibrated
Hatari only.  Nothing has run on a
real Falcon yet.  Most tested tunes
keep up for two minutes; Monofail
still overtakes the renderer.  See
WHICH TUNES PLAY.
Reports are welcome.


FILES
-----
  F030SID.TTP  the player
  DEMO.SID     a short demo tune
  README.TXT   this file
  COPYING.TXT  upstream GPL text
  SOURCE.TXT   source and notices

SIDMENU.TOS is a separate source
build with a nine-tune keyboard menu;
it is not included in this ZIP.

The player is one file.  The DSP
program is inside it; there is no
.LOD to keep beside it.


REQUIREMENTS
------------
Atari Falcon030 with a working
DSP56001.  The DSP is the SID.

About 1 MB of free RAM.

TOS 4.02 is what it was tested with,
under Hatari.  Other TOS versions are
untried.

No accelerator needed.  The code is
plain 68030 code for a stock 16 MHz
machine.

Sound comes out of the Falcon's
speaker and headphone/line output.


RUNNING IT
----------
From the desktop, double click
F030SID.TTP and type the command line
into the dialog, for example

  DEMO.SID

From a shell:

  F030SID.TTP tune.sid [song]
      [-m 6581|8580] [-t seconds]

  tune.sid    the file to play, with a
              path if it is elsewhere
  song        sub-tune number, 1 is
              the first.  Without it
              the tune's own default
              song plays.
  -m model    force the SID model.
              Without it the model
              the file asks for is
              used, else the 6581.
  -t seconds  stop after that much
              playing time.  Without
              it the tune plays until
              you stop it.

Press any key to stop.  The player
prints title, author and release line
of the tune and plays until then.

Without a command line the player
reads one from a file AUTOPLAY.INF in
the current folder.  Put for example

  DEMO.SID -t 30

into it and the player starts by a
plain double click.

You can also install F030SID.TTP as
the application for *.SID files in
the desktop (Options, Install
Application).  A double click on a
tune then starts the player with it.

On an error (no file, not a SID file,
DSP busy) the player says so and waits
for a key.


WHICH TUNES PLAY
----------------
Not every .sid plays yet.  What works
is the common case: a PSID tune whose
play routine is called once per frame
or at a fixed timer rate.

Not supported in this preview:

  RSID files and anything that needs
  the C64 ROMs, the CIA timers as
  interrupt sources or the VIC.

  Sample playback ("digis") driven by
  interrupts, and multi-speed tunes
  that program their own interrupts.

  Tunes that read the SID back
  (OSC3/ENV3) get zeros.

  NTSC timing.  Everything plays at
  the PAL clock.

  Tunes for two or three SIDs.  Only
  the first chip sounds.

  Files larger than 66000 bytes.

A tune that needs one of these either
stays silent, plays at the wrong
speed or plays only in part.  It does
no harm to try.

Speed is the other limit.  The DSP
has 326 cycles per sample.  A ring of
4096 frames carries short busy parts;
sustained overload can still stutter.

Latest check: 2026-10-05, calibrated
Hatari, first 120 seconds of seventeen
single-SID PSID tunes, default songs
and each tune's selected chip model.

  Twelve pass timing in both modes
    Commando, Cybernoid II, Monty on
    the Run, Ocean Loader 2, Turrican,
    Wizball, 808 Love, Comaland songs
    1 and 4, Knucklebusters,
    Lightforce, Thats the Way It Is

  Pacing fails, no overtakes
    Last Ninja 2, Ghouls n Ghosts,
    Edge of Disgrace, RoboCop 3

  Renderer overtakes
    Monofail: five in normal playback,
    seventeen with diagnostics

All seventeen diagnostic checksums
match the reference.  This does not
turn a timing failure into a pass.
Monofail first overtakes between 60
and 90 seconds.  These checks cover
two minutes, not whole songs, every
sub-song or real hardware.

RSID sample tunes such as Great Giana
Sisters and Tetris remain unsupported.

There is no fade and no song length:
a tune plays until a key or -t.
Stopping can leave up to 73 ms of
buffered audio unplayed.


THE SOUND
---------
The SID is rendered on the DSP at the
Falcon codec's 49170 Hz, one sample at
a time, from the cycle the tune wrote
each register.

Triangle, sawtooth and pulse are
band-limited.  Noise and the combined
waveforms are not.

The filter follows the response of
the 6581 and the 8580 as reSID models
them, to about 1.6 dB.  The 6581's
filter distortion is not modelled.


UNDER THE HOOD
--------------
68030
  PSID loader, a 6510 core with the
  stable undocumented opcodes, the
  filter coefficients, and the feed:
  SID writes go to the DSP with their
  cycle stamps, two frames ahead of
  the DSP's clock.  Safe repeated
  writes are omitted.

DSP56001
  The SID itself, with a render-ahead
  ring into the SSI transmitter, which
  the Falcon's sound matrix routes to
  the DAC.

Verification
  The DSP is checked bit for bit
  against a C reference model of the
  chip, and that model's voices bit
  for bit against reSID.  The player
  is checked end to end: the samples
  the DSP renders for a tune equal the
  reference's.  Timing and overtakes
  are checked separately.


CREDITS
-------
Direction and ideas
  Sascha Springer

Programming
  Claude (Anthropic), for the 68030
  and the DSP56001 code and the
  reference models

SID model and waveform tables
  reSID by Dag Lem and contributors.
  Oscillator, noise, envelope, DAC and
  sync behavior follow its bulk clock.
  Combined waveform tables come from
  its sampled chip data (GPL).
  reSID also verifies the host model
  and supplies measured filter targets.

C64 playback reference
  libsidplayfp and its contributors.
  The trace tools use its C64/6510
  player and ReSIDfp backend to check
  register writes independently.

Player organization
  SIDPlayer by Phil Schatzmann,
  based on Hermit's cSID light,
  inspired the load/init/play/render
  API and program organization.

Filter and band-limiting
  Vadim Zavalishin's TPT formulation
  underlies the state-variable filter.
  Saw/pulse edges use four-point
  polyBLEP correction.

Build and verification
  Motorola ASM56000, vasm/vlink,
  DOSBox and DSP-calibrated Hatari.

Upstream notices
  Preserve the copyright and license
  notices for reSID-derived code and
  tables and GPL reference tools.

Source and documentation
  github.com/AnimaInCorpore/F030SID

A non commercial hobby project.  SID
tunes belong to their authors.
