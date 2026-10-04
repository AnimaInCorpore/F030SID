#!/usr/bin/env python3
"""Turn a SID register trace into a PSID that replays it.

  make_trace_sid.py <trace> <out.sid> [title]

The play routine is a few 6510 instructions that walk a table: per 50 Hz call a
count and that many (register, value) pairs. The trace's writes are grouped by
PAL frame, so the tune reproduces the trace's register stream at frame
granularity. Used to give the player gate (play_gate.py) music with a filter
sweep, PWM and vibrato (tests/traces/voice_music_2.trace) without shipping a
copyrighted tune.
"""
import struct
import sys

FRAME = 19656
LOAD = 0x1000

# zero page $fb/$fc: the table pointer
INIT = bytes([0xA9, 0x00, 0x85, 0xFB,           # lda #<table ; sta $fb    (patched)
              0xA9, 0x00, 0x85, 0xFC,           # lda #>table ; sta $fc
              0x60])
PLAY = bytes([0xA0, 0x00,                       # play: ldy #0
              0xB1, 0xFB, 0xAA,                 #       lda ($fb),y ; tax        count
              0x20, 0, 0,                       #       jsr incp
              0xE0, 0x00, 0xF0, 0x13,           # loop: cpx #0 ; beq done
              0xB1, 0xFB, 0x8D, 0, 0,           #       lda ($fb),y ; sta store+1   register
              0x20, 0, 0,                       #       jsr incp
              0xB1, 0xFB,                       #       lda ($fb),y              value
              0x8D, 0x00, 0xD4,                 # store: sta $d400
              0x20, 0, 0,                       #       jsr incp
              0xCA, 0x4C, 0, 0,                 #       dex ; jmp loop
              0x60,                             # done: rts
              0xE6, 0xFB, 0xD0, 0x02, 0xE6, 0xFC, 0x60])   # incp: inc $fb ; bne + ; inc $fc ; rts


def main():
    writes, end = [], 0
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line or line[0] == "#":
            continue
        if line.startswith("end"):
            end = int(line.split()[1])
            continue
        c, r, v = (int(x, 0) for x in line.split())
        writes.append((c, r, v))
    frames = [[] for _ in range(end // FRAME + 1)]
    for c, r, v in writes:
        frames[c // FRAME].append((r, v))
    table = bytearray()
    for f in frames:
        assert len(f) < 256
        table.append(len(f))
        for r, v in f:
            table += bytes([r, v])
    table += bytes(64)                          # silence after the end
    init_at = LOAD
    play_at = init_at + len(INIT)
    table_at = play_at + len(PLAY)
    play = bytearray(PLAY)
    incp, loop, store = play_at + 33, play_at + 8, play_at + 22
    for off in (6, 18, 26):
        play[off:off + 2] = struct.pack("<H", incp)
    play[15:17] = struct.pack("<H", store + 1)
    play[30:32] = struct.pack("<H", loop)
    init = bytearray(INIT)
    init[1], init[5] = table_at & 255, table_at >> 8
    title = (sys.argv[3] if len(sys.argv) > 3 else "F030SID trace replay").encode()
    header = b"PSID" + struct.pack(">HHHHHHHI", 2, 0x7C, 0, init_at, play_at, 1, 1, 0)
    for s in (title, b"F030SID", b"2026 F030SID"):
        header += s.ljust(32, bytes(1))
    header += struct.pack(">HBBBB", 0x0014, 0, 0, 0, 0)
    with open(sys.argv[2], "wb") as f:
        f.write(header + struct.pack("<H", LOAD) + init + play + table)


if __name__ == "__main__":
    main()
