#!/usr/bin/env python3
"""Write opcode-exerciser PSIDs for the 6510 core gate (tools/player/cpu_gate.py).

  make_exerciser.py <out dir> [count]

Each tune's init routine is a long straight line of random instructions over
every opcode both cores implement (tools/player/gen_6502.py) and every
addressing mode, in blocks; after each block it dumps A, X, Y, the flags, S and
two memory bytes to the SID registers, so the logged writes carry the complete
processor state and, in their cycle stamps, every instruction's timing. Flags
are randomised through PLP (decimal mode included).

Beside each exerciser_N.sid a portable_N.sid is written: the same without the
unstable opcodes, ARR, SED, TSX and the S dump, I/O reads and reads through arbitrary
pointers (ROM, I/O and the processor port differ), below $A000, starting from set
registers, so that a real 6510 produces the same writes. tools/player/
check_portable.py compares the reference core with libsidplayfp on them.

Layout: data $2000-$23ff, subroutines $2800, code from $3000. Random
instructions write only to the zero page and the data area; writes through
(zp,X) and (zp),Y get their pointer set up first.
"""
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_6502 import T  # noqa: E402

DATA, SUBS, CODE, CODE_END = 0x2000, 0x2800, 0x3000, 0xC000
LEN = {"imp": 1, "acc": 1, "imm": 2, "zp": 2, "zpx": 2, "zpy": 2, "abs": 3, "abx": 3, "aby": 3,
       "izx": 2, "izy": 2, "rel": 2, "ind": 3}
SPECIAL = {"brk", "kil", "jsr", "rts", "rti", "jmp", "txs", "pha", "pla", "php", "plp",
           "bpl", "bmi", "bvc", "bvs", "bcc", "bcs", "bne", "beq"}
WRITES = {"sta", "stx", "sty", "sax", "asl", "lsr", "rol", "ror", "inc", "dec",
          "slo", "rla", "sre", "rra", "dcp", "isb"}
PLAIN = [op for op, (name, mode, _, _) in T.items() if name not in SPECIAL]
# The opcodes whose effect the cores do not model (no-operations here): left out of
# the portable tunes, which a real 6510 (libsidplayfp, via sidtrace) must agree with.
UNSTABLE = {0x8B, 0x93, 0x9F, 0x9C, 0x9E, 0x9B, 0xBB, 0xAB}
BRANCHES = [op for op, (name, mode, _, _) in T.items() if mode == "rel"]


def lda(v):
    return bytes([0xA9, v])


def instr(rnd, op, portable=False):
    name, mode, _, _ = T[op]
    pre = b""
    if mode in ("imp", "acc"):
        return bytes([op])
    if mode == "imm":
        return bytes([op, rnd.randrange(256)])
    if mode in ("zpx", "zpy") and portable:             # keep clear of the processor port at $00/$01
        k, ea = rnd.randrange(256), rnd.randrange(0x10, 0xF0)
        return bytes([0xA2 if mode == "zpx" else 0xA0, k, op, (ea - k) & 255])
    if mode in ("zp", "zpx", "zpy"):
        return bytes([op, rnd.randrange(0x10, 0xF0)])
    if mode in ("abs", "abx", "aby"):
        if name not in WRITES and not portable and rnd.random() < 0.03:
            return bytes([op]) + struct.pack("<H", 0xD012 if mode == "abs" else 0xD400)   # raster, SID reads
        return bytes([op]) + struct.pack("<H", DATA + rnd.randrange(0x300))
    if mode in ("izx", "izy"):
        zp = rnd.randrange(0x10, 0xF0)
        if name in WRITES or name == "nop" or portable or rnd.random() < 0.5:
            # a pointer into the data area at $fb/$fc, and for (zp,X) an X that reaches it
            target = DATA + rnd.randrange(0x300)
            pre = b"\x48" + lda(target & 255) + b"\x85\xfb" + lda(target >> 8) + b"\x85\xfc" + b"\x68"   # pha .. pla
            if mode == "izx":
                x = rnd.randrange(256)
                pre += bytes([0xA2, x])
                zp = (0xFB - x) & 255
            else:
                zp = 0xFB
        return pre + bytes([op, zp])
    raise AssertionError(mode)


def block(rnd, pc, portable):
    out = bytearray()
    plain = [op for op in PLAIN if not (portable and (op in UNSTABLE or T[op][0] in ("arr", "sed", "tsx")))]

    def ins(rnd, op):
        return instr(rnd, op, portable)

    for _ in range(rnd.randrange(12, 40)):
        k = rnd.random()
        here = pc + len(out)
        if k < 0.06:                                    # a branch over the next instruction
            nxt = ins(rnd, rnd.choice(plain))
            out += bytes([rnd.choice(BRANCHES), len(nxt)]) + nxt
        elif k < 0.09:                                  # push, something, pull (PLP randomises the flags)
            out += bytes([rnd.choice((0x48, 0x08))]) + ins(rnd, rnd.choice(plain)) + bytes([rnd.choice((0x68, 0x28))])
        elif k < 0.11:                                  # jsr to one of the subroutines
            out += bytes([0x20]) + struct.pack("<H", SUBS + 4 * rnd.randrange(4))
        elif k < 0.12:                                  # jmp to the next instruction
            out += bytes([0x4C]) + struct.pack("<H", here + 3)
        elif k < 0.13:                                  # jmp (vector) with the vector across a page end
            target = here + 5 + 5 + 3
            out += lda(target & 255) + b"\x8d\xff\x22" + lda(target >> 8) + b"\x8d\x00\x22" + b"\x6c\xff\x22"
        elif k < 0.14:                                  # rti to the next instruction
            target = here + 2 + 1 + 2 + 1 + 1 + 1
            out += lda(target >> 8) + b"\x48" + lda(target & 255) + b"\x48\x08\x40"
        else:
            out += ins(rnd, rnd.choice(plain))
    # the state: A X Y P S and two memory bytes
    out += b"\x08\x8d\x00\xd4\x8e\x01\xd4\x8c\x02\xd4\x68\x8d\x03\xd4"
    if not portable:
        out += b"\xba\x8e\x04\xd4"
    out += bytes([0xA5, rnd.randrange(0x10, 0xF0)]) + b"\x8d\x05\xd4"
    out += bytes([0xAD]) + struct.pack("<H", DATA + rnd.randrange(0x400)) + b"\x8d\x06\xd4"
    return bytes(out)


def build(path, seed, portable=False):
    rnd = random.Random(seed)
    image = bytearray(0x10000)
    for a in range(DATA, DATA + 0x400):
        image[a] = rnd.randrange(256)
    for i, body in enumerate((b"\x60", b"\xe8\x60", b"\x38\x60", b"\xc8\x18\x60")):   # rts; inx; sec; iny clc
        image[SUBS + 4 * i:SUBS + 4 * i + len(body)] = body
    pc = CODE
    code = bytearray(b"\xa9\x00\x48\x28\xa2\x00\xa0\x00" if portable else b"")    # lda #0 pha plp ldx #0 ldy #0
    for zp in range(0x10, 0x100):                       # zero page contents
        if len(code) < 0x3C0:
            code += lda(rnd.randrange(256)) + bytes([0x85, zp])
    cycles = 5 * 0xF0
    while pc + len(code) < (0xA000 if portable else CODE_END) - 400 and cycles < 1500000:   # (BASIC ROM at $A000)
        b = block(rnd, pc + len(code), portable)
        code += b
        cycles += 5 * len(b)                            # generous: the init call is cut at 2,000,000 cycles
    code += b"\x60"
    image[pc:pc + len(code)] = code
    play = pc + len(code)
    image[play] = 0x60
    header = b"PSID" + struct.pack(">HHHHHHHI", 2, 0x7C, 0, CODE, play, 1, 1, 0)
    for s in (b"6510 exerciser %d" % seed, b"F030SID", b"2026 F030SID"):
        header += s.ljust(32, bytes(1))
    header += struct.pack(">HBBBB", 0x0014, 0, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(header + struct.pack("<H", DATA) + image[DATA:play + 1])


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for seed in range(1, (int(sys.argv[2]) if len(sys.argv) > 2 else 4) + 1):
        build(os.path.join(out, f"exerciser_{seed}.sid"), seed)
        build(os.path.join(out, f"portable_{seed}.sid"), 100 + seed, portable=True)


if __name__ == "__main__":
    main()
