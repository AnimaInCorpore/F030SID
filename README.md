# F030SID

F030SID plays Commodore 64 SID music (PSID/RSID) on an Atari Falcon. The 68030
hosts the tune (a 6502 core plus the C64 memory map that PSID players need) and
the Falcon DSP56001 emulates the MOS 6581/8580 SID and feeds 16-bit stereo
audio to the Falcon DAC.

The structure is modelled on the sibling project F030MXDRV (an X68000 MDX
player with a DSP YM2151): same toolchain, same host/DSP split, same two-tier
verification idea. See [`docs/architecture.md`](docs/architecture.md).

## Project status

Scaffold only. What exists today:

- the build system (vasm/vlink for the 68030, Motorola `asm56000` under DOSBox
  for the DSP56001, embedded boot images via `tools/generate_dsp_stage2.py`);
- `src/m68k/main.s`, a bring-up program that boots the DSP, pings it and
  round-trips a value through the SID register shadow;
- `src/dsp/sid.asm`, a DSP kernel that owns the 32-register SID file and
  answers the host protocol (no synthesis yet);
- the two physical-Falcon validation programs inherited unchanged from
  F030MXDRV, `ratetest.tos` (SSI rate) and `dspprobe.tos` (DSP bus probe),
  which are independent of the sound chip being emulated.

Nothing here has been built yet: the scaffold was written on a host without
`make`, DOSBox or a C compiler, so the first `make check` is the first test.

## Build

Dependencies:

- Git, plus the `f030dsp3d` submodule (vasm/vlink sources, Motorola DSP
  assembler, TOS 4.02 ROM, Hatari);
- Python 3, `make`, `tar`, `file`, `rg`, a C compiler (to build vasm/vlink);
- DOSBox Staging or DOSBox for the DSP assembler;
- Hatari for emulator targets, ideally the DSP-calibrated build described in
  [`docs/hatari-timing.md`](docs/hatari-timing.md).

```sh
git submodule add git@github.com:AnimaInCorpore/f030dsp3d.git third_party/f030dsp3d
git submodule update --init --recursive
make check
```

| Target | Purpose | Extra input |
| --- | --- | --- |
| `make all` | build the Falcon executables and DSP image | DOSBox |
| `make check` | build and verify assembler listings are clean | DOSBox |
| `make run` | run `f030sid.tos` in Hatari | Hatari |
| `make ratetest-hatari` | SSI rate test under Hatari | Hatari |
| `make dspprobe-hatari` | DSP bus probe under Hatari | Hatari |

Outputs land in `release/`: `f030sid.tos`, `f030sid.ttp`, `sid.lod`,
`ratetest.tos`, `dspprobe.tos`.

## Repository map

- `src/m68k/main.s`: Falcon bootstrap and bring-up harness.
- `src/m68k/xbios.i`, `verbose.i`: GEMDOS/XBIOS macros and hardware bring-up tracing.
- `src/m68k/protocol.i` / `src/dsp/protocol.inc`: host/DSP protocol (keep in step).
- `src/dsp/sid.asm`: DSP SID kernel (register file today; voices, envelopes, filter next).
- `src/dsp/stage2_loader.asm`: sparse embedded P-memory loader for when the kernel outgrows 512 words.
- `src/m68k/ratetest.s`, `dspprobe.s` and their DSP counterparts: hardware validation.
- `tools/`: DSP image generator, Hatari resolution, DSP build script.
- `docs/`: architecture, SID register reference, DSP and Hatari timing notes,
  and [hints from the ScummVM DSP AdLib emulator](docs/scummvm-opl-hints.md).
- `src/ref/`: the 24-bit integer reference model of the SID voices, gated
  bit-for-bit against reSID (`make ref-gate`); see `src/ref/README.md`.
- `tools/ref/`: reSID oracle, trace generator and gate scripts.
- `tools/trace/`: `sidtrace`, which turns a PSID into a cycle-stamped register
  trace through libsidplayfp (`make trace`); `tests/psid/` has two test tunes.
- `tools/feasibility/`: aliasing, noise, filter and precision studies behind
  [`docs/sid-feasibility.md`](docs/sid-feasibility.md).
- `tests/traces/`: future register-write fixtures for oracle comparison.
- `third_party/`: pinned references (`f030dsp3d` for the toolchain, `resid` as the SID oracle).
