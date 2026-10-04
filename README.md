# F030SID

F030SID plays Commodore 64 SID music (PSID/RSID) on an Atari Falcon. The 68030
hosts the tune (a 6502 core plus the C64 memory map that PSID players need) and
the Falcon DSP56001 emulates the MOS 6581/8580 SID and feeds 16-bit stereo
audio to the Falcon DAC.

The structure is modelled on the sibling project F030MXDRV (an X68000 MDX
player with a DSP YM2151): same toolchain, same host/DSP split, same two-tier
verification idea. See [`docs/architecture.md`](docs/architecture.md).

## Project status

`release/f030sid.ttp` plays PSID files: `F030SID.TTP tune.sid [song] [-m 6581|8580]
[-t seconds]`; `make package` wraps it into `release/F030SID.ZIP` (the player, a
demo tune and a 40-column `README.TXT`). Everything has been built and tested
under the DSP-calibrated Hatari only; nothing has run on a physical Falcon.

Real tunes (twelve from HVSC, see [`docs/player.md`](docs/player.md)): on the ten
PSID tunes the 6510 side writes what libsidplayfp writes and the DSP's samples
equal the reference model's, but only three of them hold real time and a fourth
nearly. The others need more than the DSP's 326 cycles per frame, by 3% to 20%;
the two RSID tunes do not play. The kernel's cost is the open problem, not its correctness.

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
  end: the DSP's rendered frames equal the reference models', in real time.

What it does not do yet: the 6510 has no ROMs, CIA, VIC or interrupts (PSID
tunes with a play routine at a fixed rate only; no RSID, no interrupt-driven
sample playback); no OSC3/ENV3 readback, second SID or NTSC timing; the 6581's
filter distortion is not modelled; noise and combined waveforms are not
band-limited; the stress traces (hard sync between all voices, random
combined-waveform traffic) exceed real time.

## Build

Dependencies:

- Git, plus the `f030dsp3d` submodule (vasm/vlink sources, Motorola DSP
  assembler, TOS 4.02 ROM). `third_party/resid` is only needed for the
  reference-model targets;
- Python 3, `make`, `tar`, `file`, `rg`, a C compiler (to build vasm/vlink);
- DOSBox Staging (or a DOSBox that accepts its flags) to run the DSP assembler;
- Hatari for emulator targets, the DSP-calibrated build described in
  [`docs/hatari-timing.md`](docs/hatari-timing.md). The Makefile looks for it
  in a sibling `F030Arcade` checkout (`third_party/hatari/build*/src/`).

```sh
git submodule update --init third_party/f030dsp3d     # not --recursive: Hatari's sources are not needed
make check smoke
```

Machine-specific paths go in `local.mk` (git-ignored), for example:

```make
DOSBOX := /c/Arbeit/F030Comanche/tools/toolchain/dosbox.exe
PYTHON := /c/Users/me/AppData/Local/Microsoft/WindowsApps/python3
# HATARI := /path/to/hatari       # override the calibrated-build search
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
| `make stream-gate` | the same through the SSI stream: bit-exact and in real time | Hatari |
| `make cpu-gate`, `make cpu-ref-check` | the 68030 6510 core against the C reference core; that core against libsidplayfp | Hatari; `make trace` |
| `make coef-gate` | the 68030 filter coefficient routine against the C one | Hatari |
| `make play-gate` | the player end to end: PSID in, the DSP's frames out | Hatari |
| `make trace`, `make trace-test` | `sidtrace` (PSID to register trace via libsidplayfp) | network, host C++ |
| `make package` | `release/F030SID.ZIP`: `F030SID.TTP`, `DEMO.SID`, `README.TXT` (`package/README.TXT`, sent with CRLF) | `zip` |
| `make package-gate` | the packaged player on the packaged demo tune, through the player gate | Hatari |
| `make tune-check` | real tunes in `music/*.sid` (git-ignored; `TUNES=...`): the reference 6510 core against libsidplayfp | `make trace` |
| `make tune-gate` | the same tunes through the player, 30 s each with the tune's chip model | Hatari |

The gate scripts take `--jobs N` (through `DSP_GATE_ARGS`, `STREAM_GATE_ARGS`,
`CPU_GATE_ARGS`, `PLAY_GATE_ARGS`) to run several Hatari instances at once.

Outputs land in `release/`: `f030sid.tos`, `f030sid.ttp`, `sid.lod`,
`ratetest.tos`, `dspprobe.tos`.

## Repository map

- `src/dsp/sid.asm.in`: the DSP SID kernel (a template; `tools/dsp/gen_sid_asm.py`
  instantiates the per-voice code). `src/dsp/protocol.inc` / `src/m68k/protocol.i`:
  the host/DSP protocol (keep in step). `src/dsp/stage2_loader.asm`: the loader
  for a kernel larger than the 512 words `Dsp_ExecBoot` installs.
- `src/m68k/player.s`: the player (`f030sid.ttp`), with `cpu6502.s` (6510 core),
  `psid.s` (loader and call schedule) and `filtcoef.s` (filter coefficients).
- `src/m68k/main.s`: the bring-up program (`f030sid.tos`, `make smoke`);
  `voicetest.s`, `streamtest.s`, `cputest.s`, `coeftest.s`: the gates' harnesses;
  `ratetest.s`, `dspprobe.s` (+ `src/dsp/*.asm`): hardware validation programs.
- `src/ref/`: the reference model of the chip (C), the DSP's specification.
- `tools/ref/`: reSID oracle, measurement and gates of the reference;
  `tools/dsp/`: the DSP gates and profilers; `tools/player/`: the 6510 reference
  core, exercisers and the player's gates; `tools/trace/`: `sidtrace`.
- `tests/traces/`: register traces the gates replay; `tests/psid/`: test tunes.
- `docs/`: [`dsp-kernel.md`](docs/dsp-kernel.md) (the kernel, the stream, costs),
  [`player.md`](docs/player.md), [`hatari-timing.md`](docs/hatari-timing.md)
  (why the calibrated Hatari), [`dsp56001-notes.md`](docs/dsp56001-notes.md),
  [`sid-feasibility.md`](docs/sid-feasibility.md); [`architecture.md`](docs/architecture.md)
  is the original plan.
