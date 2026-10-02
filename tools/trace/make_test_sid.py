#!/usr/bin/env python3
"""Write tests/psid/test_pulse.sid and test_2sid.sid, hand-assembled PSIDs
used to test sidtrace.

init  ($1000): volume 15, fast attack, sustain 15, freq $1C00, pulse width
               $800, pulse + gate on voice 1. The 2SID variant also starts a
               sawtooth on the second SID at $D420.
play  ($1040): every frame bumps a counter at $1100 and writes
               freq hi = $10 + (counter & $3F) and pulse width hi = counter & 15.

So the tune is a pulse note gliding up in 64 steps with a sweeping pulse
width, at 50 Hz (PAL VBI): 2 register writes per play call, 19656 cycles
apart.
"""

import os
import struct

INIT = bytes([
    0xA9, 0x00, 0x8D, 0x00, 0x11,       # LDA #0 ; STA $1100
    0xA9, 0x0F, 0x8D, 0x18, 0xD4,       # volume 15
    0xA9, 0x00, 0x8D, 0x05, 0xD4,       # AD = 0
    0xA9, 0xF0, 0x8D, 0x06, 0xD4,       # SR = $F0
    0xA9, 0x00, 0x8D, 0x00, 0xD4,       # freq lo
    0xA9, 0x1C, 0x8D, 0x01, 0xD4,       # freq hi
    0xA9, 0x00, 0x8D, 0x02, 0xD4,       # pw lo
    0xA9, 0x08, 0x8D, 0x03, 0xD4,       # pw hi
    0xA9, 0x41, 0x8D, 0x04, 0xD4,       # pulse + gate
])
SECOND_SID_INIT = bytes([
    0xA9, 0x0F, 0x8D, 0x38, 0xD4,       # SID 2 at $D420: volume 15
    0xA9, 0x0A, 0x8D, 0x21, 0xD4,       # freq hi
    0xA9, 0x21, 0x8D, 0x24, 0xD4,       # saw + gate
])
RTS = bytes([0x60])
PLAY = bytes([
    0xEE, 0x00, 0x11,                   # INC $1100
    0xAD, 0x00, 0x11,                   # LDA $1100
    0x29, 0x3F,                         # AND #$3F
    0x18,                               # CLC
    0x69, 0x10,                         # ADC #$10
    0x8D, 0x01, 0xD4,                   # STA $D401
    0xAD, 0x00, 0x11,                   # LDA $1100
    0x29, 0x0F,                         # AND #$0F
    0x8D, 0x03, 0xD4,                   # STA $D403
    0x60,
])


def build(path, second_sid):
    load = 0x1000
    init = INIT + (SECOND_SID_INIT if second_sid else b"") + RTS
    data = init.ljust(0x40, bytes(1)) + PLAY
    version = 3 if second_sid else 2
    header = b"PSID" + struct.pack(">HHHHHHHI", version, 0x7C, 0, 0x1000, 0x1040, 1, 1, 0)
    title = b"F030SID test 2SID" if second_sid else b"F030SID test pulse"
    for s in (title, b"F030SID", b"2026 F030SID"):
        header += s.ljust(32, bytes(1))
    # flags: PAL, 6581; startPage, pageLength, second SID ($D420 = 0x42), third SID
    header += struct.pack(">HBBBB", 0x0014, 0, 0, 0x42 if second_sid else 0, 0)
    assert len(header) == 0x7C, len(header)
    with open(path, "wb") as f:
        f.write(header + struct.pack("<H", load) + data)


def main():
    out = os.path.join(os.path.dirname(__file__), "..", "..", "tests", "psid")
    os.makedirs(out, exist_ok=True)
    build(os.path.join(out, "test_pulse.sid"), False)
    build(os.path.join(out, "test_2sid.sid"), True)


if __name__ == "__main__":
    main()
