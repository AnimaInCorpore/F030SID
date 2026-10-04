========================================
  F030SID  -  C64 SID music player
  for the Atari Falcon030
========================================

Preview release v0.1

Plays Commodore 64 music files (.sid,
the PSID format of the High Voltage
SID Collection) on a Falcon030.

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
real Falcon yet.  Light tunes play as
they should; many well known ones are
still too much for the DSP and play
too slowly, see WHICH TUNES PLAY.
Reports are welcome.


FILES
-----
  F030SID.TTP  the player
  DEMO.SID     a short demo tune
  README.TXT   this file

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
has 326 cycles per sample and a busy
tune needs more.  Then the sound
stutters and the tune drags.  Twelve
tunes were tried under Hatari, 30
seconds each:

  In time
    Ocean Loader 2, Cybernoid II,
    Last Ninja 2, DEMO.SID

  Too slow, by 1 to 25 percent
    Commando, Turrican, Monty on the
    Run, Edge of Disgrace, Wizball

  Far too slow, by 45 to 65 percent
    Ghouls 'n Ghosts, RoboCop 3

  Not playable, RSID with samples
    Great Giana Sisters, Tetris

In all ten PSID tunes the notes are
right: the register writes equal
libsidplayfp's and the samples equal
the reference model's.  What is
missing is DSP time.

There is no fade and no song length:
a tune plays until a key or -t.


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
  every SID write goes to the DSP with
  its cycle stamp, two frames ahead of
  the DSP's clock.

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
  reference's, in real time.


CREDITS
-------
Direction and ideas
  Sascha Springer

Programming
  Claude (Anthropic), for the 68030
  and the DSP56001 code and the
  reference models

SID reference and waveform tables
  reSID by Dag Lem, and libsidplayfp.
  The combined waveform tables in the
  player come from reSID's chip
  samples (GPL).

Player shape
  SIDPlayer by Phil Schatzmann and
  cSID light by Hermit, as a model
  for the structure

Source and documentation
  github.com/AnimaInCorpore/F030SID

A non commercial hobby project.  SID
tunes belong to their authors.
