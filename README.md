# F030SID

F030SID builds **`F030SID.TTP`**, a command-line player for Commodore 64
`.sid` music files on the Atari Falcon030. Run it from the TOS desktop's
parameter dialog or a shell:

```text
F030SID.TTP tune.sid
```

## Download and run on a Falcon

Download [F030SID.ZIP](https://github.com/AnimaInCorpore/F030SID/releases/download/v0.1/F030SID.ZIP)
from [GitHub Releases](https://github.com/AnimaInCorpore/F030SID/releases).
Extract the `F030SID` folder and transfer it to your Atari Falcon030. Keep the
player, demo and documentation together, double-click `F030SID.TTP`, and enter
`DEMO.SID` in the TOS parameter dialog. For your own music, pass its `.sid`
filename instead. The DSP program is embedded; no separate `.LOD` is needed.

Use a Falcon030 with a working DSP56001 and about 1 MB of free RAM. TOS 4.02
is the tested emulator configuration. This is a preview for hardware testing:
physical-Falcon playback remains unverified. See [player instructions](docs/player.md)
for options and [release packaging](docs/releases.md) for source and checksums.

The 68030 executes the tune's original 6510 code; the DSP56001 emulates the
MOS 6581/8580 SID and feeds 16-bit stereo audio to the Falcon DAC. Current
playback support is **single-SID PAL PSID**. RSID, interrupt-driven sample
playback, NTSC timing and multiple SIDs are unsupported; some demanding tunes
still exceed the DSP's playback budget.

The host and DSP communicate through a cycle-stamped register stream. A C
reference model defines the synthesis output, and independent gates verify
the host, DSP and playback timing. See [processor split](docs/dsp-kernel.md#processor-split).

## Project status

`release/f030sid.ttp` plays PSID files: `F030SID.TTP tune.sid [song] [-m 6581|8580]
[-t seconds]`; `make package` wraps it into `release/F030SID.ZIP` (the player, a
demo tune, a 40-column `README.TXT`, license text and source notices).
The current published preview is [v0.1](https://github.com/AnimaInCorpore/F030SID/releases/tag/v0.1).
Its packaged demo passes the 32-second player gate on both SID models. All
playback validation is from DSP-calibrated Hatari; no F030SID build has run
on a physical Falcon.

The latest load check (2026-10-09) covers the first 120 seconds of seventeen
single-SID PSIDs in both normal and diagnostic playback. All seventeen
checksums match the C reference; sixteen tunes pass the complete player gate.
Monofail records four transmitter overtakes in normal playback and fifteen
with diagnostics. The pacing check now times the audio itself; by the old
measure, which counted each tune's init routine, four more tunes failed. These are emulator measurements, not a guarantee for complete
songs or physical hardware. See [performance results and limits](docs/performance.md).

`release/sidmenu.tos` provides a separate nine-tune keyboard menu using
`MENU.INF`; it is built by `make all` but is not included in the ZIP.

What exists:

- **The SID on the DSP** (`src/dsp/sid.asm.in`, [`docs/dsp-kernel.md`](docs/dsp-kernel.md)):
  three voices with every waveform, hard sync, ring modulation, the test bit and
  the ADSR state machine, bit-exact against reSID's frame clocking; band-limited
  triangle, saw and pulse (sample-instant phase, polyBLEP); the mixer, a
  state-variable filter fitted to reSID's response (about 1.6 dB rms), the
  external filter; a 49.17 kHz SSI stream with a render-ahead ring and
  cycle-stamped register writes. The DSP is gated bit for bit against a C
  reference model (`src/ref/`, [`src/ref/README.md`](src/ref/README.md)).
- **The player on the 68030** (`src/m68k/player.s`, [`docs/player.md`](docs/player.md),
  [`tools/player/README.md`](tools/player/README.md)): PSID loader, a 6510 core,
  the filter coefficient derivation, the feed to the DSP stream. Gated end to
  end against the reference models, with independent playback timing checks.
  The current source runs as an ordinary user-mode process, so it also plays
  under FreeMiNT, which has been tested only in Hatari
  ([under FreeMiNT](docs/player.md#under-freemint)). The v0.1 binary
  stays in supervisor mode and leaves FreeMiNT unresponsive while it plays.

What it does not do yet: the 6510 has no ROMs, CIA, VIC or interrupts (PSID
tunes with a play routine at a fixed rate only; no RSID, no interrupt-driven
sample playback); no OSC3/ENV3 readback, second SID or NTSC timing; the 6581's
filter distortion is not modelled. Noise, combined waveforms, ring-modulated
triangle and test-bit output are not band-limited. The player stops SSI and
releases locks on exit but does not restore the previous sound configuration.
Some real-tune passages and synthetic filter stress still exceed real time; the ring cannot absorb sustained overload.

## Build

Dependencies:

- Git and the bundled toolchain submodule at `third_party/f030dsp3d`
  (vasm/vlink sources, Motorola DSP assembler, TOS 4.02 ROM).
  The `third_party/resid` submodule supplies waveform data for player table
  generation as well as the reference-model targets;
- Python 3, `make`, `tar`, `file`, `rg`, a host C compiler (toolchain and player
  tables); a C++ compiler, Perl, numpy and scipy for reference-model gates;
- DOSBox Staging (or a DOSBox that accepts its flags) to run the DSP assembler;
- Hatari for emulator targets, the DSP-calibrated build described in
  [`docs/performance.md`](docs/performance.md). Set `HATARI` explicitly
  to the calibrated executable for reproducible timing checks.

```sh
git submodule update --init third_party/f030dsp3d third_party/resid
# No --recursive: nested toolchain dependencies are not needed here.
make check smoke
```

Machine-specific paths go in `local.mk` (git-ignored), for example:

```make
DOSBOX := /c/tools/dosbox/dosbox.exe
PYTHON := /c/Users/me/AppData/Local/Microsoft/WindowsApps/python3
HATARI := /path/to/calibrated/hatari
```

On Windows run `make` from an MSYS2 login shell (`/c/msys64/usr/bin/bash.exe -lc`)
with `/ucrt64/bin` on `PATH`; from a plain Git-bash some tools fail.

| Target | Purpose | Extra input |
| --- | --- | --- |
| `make all` | build the Falcon executables and DSP image | DOSBox |
| `make check` | build and verify assembler listings are clean | DOSBox |
| `make smoke` | boot `f030sid.tos` headless in Hatari, check the DSP handshake and register round trip | Hatari |
| `make profile-sid` | cycle-count a DSP range between two labels (`PROFILE_START`, `PROFILE_END`) with Hatari's DSP profiler | Hatari |
| `make ratetest-hatari` | SSI rate test under Hatari (prescales 3, 1, 2) | Hatari |
| `make dspprobe-hatari` | DSP bus probe under Hatari | Hatari |
| `make run` | run `f030sid.tos` in a Hatari window | Hatari |
| `make ref-gate`, `make filter-gate` | the reference model against reSID (voices exactly, the filter by spectrum) | host C/C++, numpy, scipy |
| `make dsp-gate` | the DSP kernel against the reference, frame by frame, bit for bit | Hatari |
| `make stream-gate` | compare SSI stream output and timing; stress mode allows timing failures | Hatari |
| `make cpu-gate`, `make cpu-ref-check` | the 68030 6510 core against the C reference core; that core against libsidplayfp | Hatari; `make trace` |
| `make coef-gate` | the 68030 filter coefficient routine against the C one | Hatari |
| `make play-gate` | the player end to end: PSID in, the DSP's frames out | Hatari |
| `make trace`, `make trace-test` | `sidtrace` (PSID to register trace via libsidplayfp) | network, host C++ |
| `make package` | `release/F030SID.ZIP`: player, demo, README and upstream notices (text sent with CRLF) | `zip` |
| `make release-assets` | binary downloads, matching source archive and SHA-256 checksums from a clean commit | Git, `zip` |
| `make package-gate` | the packaged player on the packaged demo tune, through the player gate | Hatari |
| `make tune-check` | real tunes in `music/*.sid` (git-ignored; `TUNES=...`): the reference 6510 core against libsidplayfp | `make trace` |
| `make tune-gate` | the same tunes through the player, 30 s each with the tune's chip model | Hatari |

The gate scripts take `--jobs N` (through `DSP_GATE_ARGS`, `STREAM_GATE_ARGS`,
`CPU_GATE_ARGS`, `PLAY_GATE_ARGS`) to run several Hatari instances at once.

Outputs land in `release/`: `f030sid.tos`, `f030sid.ttp`, `sidmenu.tos`, `sid.lod`,
`ratetest.tos`, `dspprobe.tos`.

## Repository map

- `src/dsp/sid.asm.in`: the DSP SID kernel (a template; `tools/dsp/gen_sid_asm.py`
  instantiates the per-voice code). `src/dsp/protocol.inc` / `src/m68k/protocol.i`:
  the host/DSP protocol (keep in step). `src/dsp/stage2_loader.asm`: the loader
  for a kernel larger than the 512 words `Dsp_ExecBoot` installs.
- `src/m68k/player.s`: the player (`f030sid.ttp`), with `cpu6502.s` (6510 core),
  `psid.s` (loader and call schedule) and `filtcoef.s` (filter coefficients).
  `src/m68k/sidmenu.s`: the tune menu (`sidmenu.tos`): keys 1 to 9 start the
  player on the tunes a `MENU.INF` lists ([`docs/player.md`](docs/player.md)).
- `src/m68k/main.s`: the bring-up program (`f030sid.tos`, `make smoke`);
  `voicetest.s`, `streamtest.s`, `cputest.s`, `coeftest.s`: the gates' harnesses;
  `ratetest.s`, `dspprobe.s` (+ `src/dsp/*.asm`): hardware validation programs.
- `src/ref/`: the reference model of the chip (C), the DSP's specification.
- `tools/ref/`: reSID oracle, measurement and gates of the reference;
  `tools/dsp/`: the DSP gates and profilers; `tools/player/`: the 6510 reference
  core, exercisers and the player's gates; `tools/trace/`: `sidtrace`.
- `tests/traces/`: register traces the gates replay; `tests/psid/`: test tunes.
- `docs/`: [player usage](docs/player.md),
  [DSP implementation and register map](docs/dsp-kernel.md),
  [performance, validation and emulator timing](docs/performance.md),
  [quality measurements](docs/quality.md), and
  [release downloads and packaging](docs/releases.md).

## Foundations and acknowledgements

F030SID builds on the following work:

- **[reSID](https://github.com/libsidplayfp/resid)** by Dag Lem and its
  contributors is the basis of the C reference model's oscillator, noise,
  envelope, DAC and bulk-clocked sync behavior. The combined-waveform tables
  come from reSID's sampled chip data. The host-side oracle runs reSID to
  verify voice state and measure filter response; the Falcon DSP implements
  the resulting reference behavior in its own fixed-point kernel.
- **[libsidplayfp](https://github.com/libsidplayfp/libsidplayfp)** provides the
  independent C64/6510 playback reference. `sidtrace` taps its ReSIDfp backend
  to record cycle-stamped register writes, and the host-core gates compare
  against those traces. The trace tool uses the SHA-256-pinned 2.16.1 release.
- **[SIDPlayer](https://github.com/pschatzmann/SIDPlayer)** by Phil Schatzmann,
  based on Hermit's cSID light, inspired the player API and load/init/play/render
  organization. This is structural inspiration; F030SID's 68030 core and DSP
  renderer are implemented here.
- **Vadim Zavalishin's topology-preserving transform (TPT) filter formulation**
  underlies the state-variable filter. F030SID derives its coefficients on
  the host and fits cutoff, resonance and output gains to measured reSID
  responses. Saw/pulse anti-aliasing uses four-point polyBLEP edge correction.
- **Build and verification tools:** the bundled
  [toolchain submodule](https://github.com/AnimaInCorpore/f030dsp3d) supplies
  assembler/linker sources and DSP build assets. Motorola ASM56000, vasm/vlink,
  DOSBox and Hatari support the build and emulator checks. Their use and
  required configuration are documented above and in
  [emulator timing](docs/performance.md#emulator-timing).

The reSID-derived code and waveform data carry upstream GPL terms; the host
reference and trace tools also use GPL code. Preserve upstream copyright and
license notices with derived material. See [reference-model scope](src/ref/README.md)
for the exact behavior adopted and the differences from cycle-by-cycle reSID.
SID music remains the work of its respective authors.
