# SID register reference

Base address on the C64: `$D400`. Registers are write-only except `$19-$1C`.

| Offset | Register | Notes |
| --- | --- | --- |
| `$00-$01` | Voice 1 frequency lo/hi | `f = value * clock / 2^24` Hz |
| `$02-$03` | Voice 1 pulse width lo/hi | 12 bits |
| `$04` | Voice 1 control | bit0 gate, 1 sync, 2 ring, 3 test, 4 triangle, 5 saw, 6 pulse, 7 noise |
| `$05` | Voice 1 attack/decay | high nibble attack, low nibble decay |
| `$06` | Voice 1 sustain/release | high nibble sustain, low nibble release |
| `$07-$0D` | Voice 2 | same layout as voice 1 |
| `$0E-$14` | Voice 3 | same layout as voice 1 |
| `$15-$16` | Filter cutoff | 11 bits: `$15` low 3 bits, `$16` high 8 bits |
| `$17` | Resonance / filter routing | high nibble resonance, bit0-2 route voices 1-3, bit3 external |
| `$18` | Mode / volume | bit4 LP, 5 BP, 6 HP, 7 voice 3 off; low nibble volume |
| `$19` | POTX | read-only |
| `$1A` | POTY | read-only |
| `$1B` | OSC3 | read-only, voice 3 waveform output high 8 bits |
| `$1C` | ENV3 | read-only, voice 3 envelope |

Clock: PAL 985,248 Hz, NTSC 1,022,727 Hz.

This file will grow into the contract the DSP kernel is verified against, in
the same role as `ym2151-ground-truth.md` in F030MXDRV: model differences
(6581 vs 8580), combined waveforms, the ADSR bug, and the filter curves go
here once they are pinned against reSID.

The scaffold shadows all 32 offsets in X memory (`DSP_SID_REG_COUNT`) so that
reads of `$19-$1C` can later be served from live voice 3 state.
