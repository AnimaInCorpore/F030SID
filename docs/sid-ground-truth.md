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

## F030SID behavior

Playback uses the PAL clock only. The host aliases writes at `$D400–$D7FF`
to the low five address bits and sends cycle-stamped writes to the DSP.
The DSP shadows all 32 offsets for protocol `READ_REG`; this shadow is not
live OSC3/ENV3/POT state. The 6510 environment returns zero on SID reads.
External input, POT emulation and extra SID chips are not implemented.

The [reference model](../src/ref/README.md) defines bulk-clocked voice behavior,
6581/8580 DACs and combined-waveform tables, ADSR-delay behavior, hard sync,
ring modulation and test-bit handling. Its filter is fitted to reSID's
response (about 1.6 dB RMS across the measured modes), with no nonlinear
6581 distortion. The DSP must match that reference's words exactly; the
filter is not claimed to be bit-exact to reSID.

Writes are applied before the frame containing their cycle, up to about
20 microseconds early. Plain triangle, saw and pulse use sample-instant
phase and polyBLEP edge correction. Noise, combined waveforms, ring-modulated
triangle and test-bit output are not band-limited. See
[dsp-kernel.md](dsp-kernel.md) for stream and protocol details.
