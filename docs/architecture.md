# Architecture

F030SID runs a single PAL SID on the Falcon030: the 68030 executes the tune's
6510 code and the DSP56001 synthesizes audio at 25175000 / 512 Hz
(49,169.921875 Hz). One kernel serves both verification and playback.

## Processor split

| Processor | Responsibilities |
| --- | --- |
| 68030 | Load the tune, maintain 64 KB RAM, execute init/play routines, timestamp SID writes, derive filter coefficients, feed the DSP, handle keys and restore sound state |
| DSP56001 | Three SID voices, envelopes, waveforms, sync/ring/test behavior, filter and mixer, render clock, write queue, SSI output |

The player accepts PSID and RSID headers, but only PSID tunes with a callable
play routine at a fixed rate are supported. The 6510 environment has no ROMs,
CIA/VIC interrupts or banking. It provides raster reads and a fixed play
schedule using the PAL frame period or the timer latch left by init.
See [player behavior](player.md) and [the core's rules](../tools/player/README.md).

## Data flow

1. The TTP loads the tune and selects its default subsong and SID model unless
   the command line overrides them.
2. The host boots an embedded stage-two loader and DSP kernel, then uploads
   model tables and configuration. No separate LOD file is needed for playback.
3. The host runs the init/play calls and sends ordered cycle-stamped writes.
   Coefficient words use pseudo registers 32–39 in the same stream.
4. Protocol v11 queues up to 256 writes. The host releases a cycle horizon;
   the DSP renders only frames whose start lies below it, applying the writes
   belonging to each frame before synthesis.
5. The DSP renders into a 4096-frame mono ring, targeting 3584 buffered frames
   (72.9 ms). SSI transmits each signed 16-bit sample to both stereo channels.
6. A key or `-t` stops playback. The player restores sound state. It currently
   stops at the render endpoint, so up to 72.9 ms of queued audio is unplayed.

Normal playback disables the diagnostic checksum. `-v` enables diagnostics;
`-v -p` records status while using the normal checksum-free rendering path.
The separate [tune menu](player.md#tune-menu) starts the TTP with GEMDOS Pexec.

## Verification

- The C reference's bulk-clocked voice state is compared exactly with reSID;
  band-limiting and the fitted filter are assessed separately by spectrum.
- The DSP frame gate compares all voice outputs and the chip output exactly
  with that C reference for both models.
- The 68030 core and coefficient routine have independent reference gates.
  libsidplayfp supplies the external register-write oracle.
- Stream and player gates check render clocks, checksums, elapsed time,
  transmitter overtakes and SSI underrun status independently.

The latest [two-minute load check](heavy-load-check.md) passes twelve of
seventeen supported tunes in both modes. Monofail overruns the renderer;
four other tunes miss pacing without overtakes. A matching checksum is not
a real-time pass. [Real-time notes](realtime.md) describe the remaining limits.

## Hardware validation still needed

All F030SID playback results are from the DSP-calibrated Hatari described in
[hatari-timing.md](hatari-timing.md). No F030SID build has run on a physical
Falcon. Rate and bus probes, audio continuity, sound restoration, sustained
playback and host bandwidth under real video contention still need hardware
checks. Measurements inherited from sibling players do not validate this SID
player.

Implementation details: [DSP kernel](dsp-kernel.md),
[DSP56001 constraints](dsp56001-notes.md), [reference model](../src/ref/README.md).
