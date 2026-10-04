#!/usr/bin/env python3
"""The 6510 opcode table, once, for both 6502 cores.

  gen_6502.py <cpu6502_tab.h> <cpu6502_ops.i>

The C reference core (tools/player/psidref.c) reads the table as data; the
68030 core (src/m68k/cpu6502.s) gets one generated handler per opcode, built
from the addressing-mode and operation snippets below. Both follow the same
rules (tools/player/README.md): documented opcodes, the stable undocumented
ones (SLO RLA SRE RRA SAX LAX DCP ISB ANC ALR ARR SBX, the NOPs, SBC $EB), the
unstable ones as no-operations of the right length, KIL and BRK end the call.
"""
import sys

# mnemonic: {opcode: (mode, cycles)}; a '+' mode suffix adds a cycle on a page crossing
T = {}


def add(name, s):
    for item in s.split():
        op, mode, cyc = item.split(":")
        assert int(op, 16) not in T, op
        T[int(op, 16)] = (name, mode.rstrip("+"), int(cyc), mode.endswith("+"))


READ8 = "{0}:imm:2 {1}:zp:3 {2}:zpx:4 {3}:abs:4 {4}:abx+:4 {5}:aby+:4 {6}:izx:6 {7}:izy+:5"
add("ora", READ8.format("09", "05", "15", "0D", "1D", "19", "01", "11"))
add("and", READ8.format("29", "25", "35", "2D", "3D", "39", "21", "31"))
add("eor", READ8.format("49", "45", "55", "4D", "5D", "59", "41", "51"))
add("adc", READ8.format("69", "65", "75", "6D", "7D", "79", "61", "71"))
add("lda", READ8.format("A9", "A5", "B5", "AD", "BD", "B9", "A1", "B1"))
add("cmp", READ8.format("C9", "C5", "D5", "CD", "DD", "D9", "C1", "D1"))
add("sbc", READ8.format("E9", "E5", "F5", "ED", "FD", "F9", "E1", "F1") + " EB:imm:2")
add("sta", "85:zp:3 95:zpx:4 8D:abs:4 9D:abx:5 99:aby:5 81:izx:6 91:izy:6")
add("stx", "86:zp:3 96:zpy:4 8E:abs:4")
add("sty", "84:zp:3 94:zpx:4 8C:abs:4")
add("ldx", "A2:imm:2 A6:zp:3 B6:zpy:4 AE:abs:4 BE:aby+:4")
add("ldy", "A0:imm:2 A4:zp:3 B4:zpx:4 AC:abs:4 BC:abx+:4")
add("cpx", "E0:imm:2 E4:zp:3 EC:abs:4")
add("cpy", "C0:imm:2 C4:zp:3 CC:abs:4")
add("bit", "24:zp:3 2C:abs:4")
RMW5 = "{0}:zp:5 {1}:zpx:6 {2}:abs:6 {3}:abx:7"
add("asl", "0A:acc:2 " + RMW5.format("06", "16", "0E", "1E"))
add("rol", "2A:acc:2 " + RMW5.format("26", "36", "2E", "3E"))
add("lsr", "4A:acc:2 " + RMW5.format("46", "56", "4E", "5E"))
add("ror", "6A:acc:2 " + RMW5.format("66", "76", "6E", "7E"))
add("dec", RMW5.format("C6", "D6", "CE", "DE"))
add("inc", RMW5.format("E6", "F6", "EE", "FE"))
RMW7 = "{0}:zp:5 {1}:zpx:6 {2}:abs:6 {3}:abx:7 {4}:aby:7 {5}:izx:8 {6}:izy:8"
add("slo", RMW7.format("07", "17", "0F", "1F", "1B", "03", "13"))
add("rla", RMW7.format("27", "37", "2F", "3F", "3B", "23", "33"))
add("sre", RMW7.format("47", "57", "4F", "5F", "5B", "43", "53"))
add("rra", RMW7.format("67", "77", "6F", "7F", "7B", "63", "73"))
add("dcp", RMW7.format("C7", "D7", "CF", "DF", "DB", "C3", "D3"))
add("isb", RMW7.format("E7", "F7", "EF", "FF", "FB", "E3", "F3"))
add("sax", "87:zp:3 97:zpy:4 8F:abs:4 83:izx:6")
add("lax", "A7:zp:3 B7:zpy:4 AF:abs:4 BF:aby+:4 A3:izx:6 B3:izy+:5 AB:imm:2")
add("anc", "0B:imm:2 2B:imm:2")
add("alr", "4B:imm:2")
add("arr", "6B:imm:2")
add("sbx", "CB:imm:2")
for name, op in (("bpl", "10"), ("bmi", "30"), ("bvc", "50"), ("bvs", "70"),
                 ("bcc", "90"), ("bcs", "B0"), ("bne", "D0"), ("beq", "F0")):
    add(name, f"{op}:rel:2")
for name, op, cyc in (("brk", "00", 7), ("php", "08", 3), ("clc", "18", 2), ("jsr", "20", 6), ("plp", "28", 4),
                      ("sec", "38", 2), ("rti", "40", 6), ("pha", "48", 3), ("cli", "58", 2), ("rts", "60", 6),
                      ("pla", "68", 4), ("sei", "78", 2), ("dey", "88", 2), ("txa", "8A", 2), ("tya", "98", 2),
                      ("txs", "9A", 2), ("tay", "A8", 2), ("tax", "AA", 2), ("clv", "B8", 2), ("tsx", "BA", 2),
                      ("iny", "C8", 2), ("dex", "CA", 2), ("cld", "D8", 2), ("inx", "E8", 2), ("nop", "EA", 2),
                      ("sed", "F8", 2)):
    add(name, f"{op}:imp:{cyc}")
add("jmp", "4C:abs:3 6C:ind:5")
# no-operations: the undocumented NOPs, and the unstable opcodes (their effect is not modelled)
add("nop", "1A:imp:2 3A:imp:2 5A:imp:2 7A:imp:2 DA:imp:2 FA:imp:2")
add("nop", "80:imm:2 82:imm:2 89:imm:2 C2:imm:2 E2:imm:2 8B:imm:2")
add("nop", "04:zp:3 44:zp:3 64:zp:3 14:zpx:4 34:zpx:4 54:zpx:4 74:zpx:4 D4:zpx:4 F4:zpx:4")
add("nop", "0C:abs:4 1C:abx+:4 3C:abx+:4 5C:abx+:4 7C:abx+:4 DC:abx+:4 FC:abx+:4 BB:aby+:4")
add("nop", "93:izy:6 9F:aby:5 9C:abx:5 9E:aby:5 9B:aby:5")
for op in "02 12 22 32 42 52 62 72 92 B2 D2 F2".split():
    add("kil", f"{op}:imp:2")
assert len(T) == 256, len(T)

MODES = ["imp", "acc", "imm", "zp", "zpx", "zpy", "abs", "abx", "aby", "izx", "izy", "rel", "ind"]
OPS = sorted({v[0] for v in T.values()})

# ---------------------------------------------------------------- 68030 snippets
# d0 A, d1 X, d2 Y, d3 S (longs, upper bits clear), d4.b Z source (0 = Z set),
# d5.b C/I/D/V in their P positions, d6 scratch (effective address, operand),
# d7 cycles, a0 host PC, a5 RAM base (256-aligned), a6 state (N source at 0(a6)).
ABS = "        moveq   #0,d6\n        move.b  1(a0),d6\n        lsl.w   #8,d6\n        move.b  (a0),d6\n        addq.l  #2,a0\n"
ZPP = ("        moveq   #0,d6\n        move.b  (a0)+,d6\n{pre}        move.l  d6,a1\n        addq.b  #1,d6\n"
       "        move.b  (a5,d6.l),d6\n        lsl.w   #8,d6\n        move.b  (a5,a1.l),d6\n")
CROSS = "        cmp.b   {r},d6\n        bcc.s   .nc\n        addq.l  #1,d7\n.nc:\n"
EA = {
    "zp": "        moveq   #0,d6\n        move.b  (a0)+,d6\n",
    "zpx": "        moveq   #0,d6\n        move.b  (a0)+,d6\n        add.b   d1,d6\n",
    "zpy": "        moveq   #0,d6\n        move.b  (a0)+,d6\n        add.b   d2,d6\n",
    "abs": ABS,
    "abx": ABS + "        add.w   d1,d6\n",
    "aby": ABS + "        add.w   d2,d6\n",
    "izx": ZPP.format(pre="        add.b   d1,d6\n"),
    "izy": ZPP.format(pre="") + "        add.w   d2,d6\n",
}
XREG = {"abx": "d1", "aby": "d2", "izy": "d2"}
NZ = "        move.b  {0},d4\n        move.b  {0},(a6)\n"
NEXT = "        NEXT\n"


def store(src):
    """ea in d6; src is a data register or 1(a6)."""
    return ("        cmp.w   #$d000,d6\n        bcs.s   .st\n        cmp.w   #$e000,d6\n        bcc.s   .st\n"
            + (f"        move.b  {src},1(a6)\n" if src != "1(a6)" else "")
            + "        bsr     io_write\n        bra.s   .sd\n"
            f".st:    move.b  {src},(a5,d6.l)\n.sd:\n")


def setc(cond):       # C from a 68k condition, after the instruction that set it; d5 bit 0 was cleared before
    return f"        b{cond}.s   .c0\n        addq.b  #1,d5\n.c0:\n"


def compare(reg):
    return ("        and.b   #$fe,d5\n        move.b  " + reg + ",d4\n        sub.b   d6,d4\n" + setc("cs")
            + "        move.b  d4,(a6)\n")


READ_OPS = {
    "ora": "        or.b    d6,d0\n" + NZ.format("d0"),
    "and": "        and.b   d6,d0\n" + NZ.format("d0"),
    "eor": "        eor.b   d6,d0\n" + NZ.format("d0"),
    "adc": "        bsr     op_adc\n",
    "sbc": "        bsr     op_sbc\n",
    "lda": "        move.b  d6,d0\n" + NZ.format("d0"),
    "ldx": "        move.b  d6,d1\n" + NZ.format("d1"),
    "ldy": "        move.b  d6,d2\n" + NZ.format("d2"),
    "lax": "        move.b  d6,d0\n        move.b  d6,d1\n" + NZ.format("d0"),
    "cmp": compare("d0"),
    "cpx": compare("d1"),
    "cpy": compare("d2"),
    "bit": ("        move.b  d6,(a6)\n        and.b   #$bf,d5\n        btst    #6,d6\n        beq.s   .v0\n"
            "        or.b    #$40,d5\n.v0:    and.b   d0,d6\n        move.b  d6,d4\n"),
    "nop": "",
    "anc": "        and.b   d6,d0\n" + NZ.format("d0") + "        and.b   #$fe,d5\n        tst.b   d0\n        bpl.s   .c0\n        addq.b  #1,d5\n.c0:\n",
    "alr": "        and.b   d6,d0\n        and.b   #$fe,d5\n        lsr.b   #1,d0\n" + setc("cc") + NZ.format("d0"),
    "arr": "        bsr     op_arr\n",
    "sbx": ("        and.b   d0,d1\n        and.b   #$fe,d5\n        sub.b   d6,d1\n" + setc("cs") + NZ.format("d1")),
}
SHIFT = {       # on d6.b; C and NZ
    "asl": "        and.b   #$fe,d5\n        add.b   d6,d6\n" + setc("cc") + NZ.format("d6"),
    "lsr": "        and.b   #$fe,d5\n        lsr.b   #1,d6\n" + setc("cc") + NZ.format("d6"),
    "rol": "        bsr     op_rol\n",
    "ror": "        bsr     op_ror\n",
    "inc": "        addq.b  #1,d6\n" + NZ.format("d6"),
    "dec": "        subq.b  #1,d6\n" + NZ.format("d6"),
}
# undocumented read-modify-write: the shift, then an accumulator operation on the result (in 1(a6))
RMW_THEN = {
    "slo": ("asl", "        or.b    1(a6),d0\n" + NZ.format("d0")),
    "rla": ("rol", "        and.b   1(a6),d0\n" + NZ.format("d0")),
    "sre": ("lsr", "        move.b  1(a6),d6\n        eor.b   d6,d0\n" + NZ.format("d0")),
    "rra": ("ror", "        moveq   #0,d6\n        move.b  1(a6),d6\n        bsr     op_adc\n"),
    "dcp": ("dec", "        moveq   #0,d6\n        move.b  1(a6),d6\n" + compare("d0")),
    "isb": ("inc", "        moveq   #0,d6\n        move.b  1(a6),d6\n        bsr     op_sbc\n"),
}
BRANCH = {"bpl": ("tst.b   (a6)", "mi"), "bmi": ("tst.b   (a6)", "pl"), "bvc": ("btst    #6,d5", "ne"),
          "bvs": ("btst    #6,d5", "eq"), "bcc": ("btst    #0,d5", "ne"), "bcs": ("btst    #0,d5", "eq"),
          "bne": ("tst.b   d4", "eq"), "beq": ("tst.b   d4", "ne")}
IMPLIED = {
    "clc": "        and.b   #$fe,d5\n", "sec": "        or.b    #$01,d5\n",
    "cli": "        and.b   #$fb,d5\n", "sei": "        or.b    #$04,d5\n",
    "cld": "        and.b   #$f7,d5\n", "sed": "        or.b    #$08,d5\n",
    "clv": "        and.b   #$bf,d5\n",
    "tax": "        move.b  d0,d1\n" + NZ.format("d1"), "tay": "        move.b  d0,d2\n" + NZ.format("d2"),
    "txa": "        move.b  d1,d0\n" + NZ.format("d0"), "tya": "        move.b  d2,d0\n" + NZ.format("d0"),
    "tsx": "        move.b  d3,d1\n" + NZ.format("d1"), "txs": "        move.b  d1,d3\n",
    "inx": "        addq.b  #1,d1\n" + NZ.format("d1"), "iny": "        addq.b  #1,d2\n" + NZ.format("d2"),
    "dex": "        subq.b  #1,d1\n" + NZ.format("d1"), "dey": "        subq.b  #1,d2\n" + NZ.format("d2"),
    "nop": "",
    "pha": "        move.b  d0,($100,a5,d3.l)\n        subq.b  #1,d3\n",
    "pla": "        addq.b  #1,d3\n        move.b  ($100,a5,d3.l),d0\n" + NZ.format("d0"),
    "php": "        bsr     get_p\n        or.b    #$30,d6\n        move.b  d6,($100,a5,d3.l)\n        subq.b  #1,d3\n",
    "plp": "        addq.b  #1,d3\n        move.b  ($100,a5,d3.l),d6\n        bsr     set_p\n",
}


def handler(op):
    name, mode, cyc, px = T[op]
    out = f"op_{op:02x}:                                  ; {name} {mode}\n        addq.l  #{cyc},d7\n"
    if name in ("brk", "kil"):
        return out + "        bra     cpu_stop\n"
    if name == "jsr":
        return out + "        bra     op_jsr\n"
    if name == "rts":
        return out + "        bra     op_rts\n"
    if name == "rti":
        return out + "        bra     op_rti\n"
    if name == "jmp":
        return out + ABS + ("        bra     op_jmp\n" if mode == "abs" else "        bra     op_jmp_ind\n")
    if name in BRANCH:
        test, skip = BRANCH[name]
        return (out + f"        {test}\n        b{skip}.s   .no\n        bsr     do_branch\n" + NEXT
                + ".no:    addq.l  #1,a0\n" + NEXT)
    if mode == "imp":
        return out + IMPLIED[name] + NEXT
    if mode == "acc":
        return out + "        move.b  d0,d6\n" + SHIFT[name].replace("d6\n" + "        move.b  d6,(a6)", "d6\n        move.b  d6,(a6)") + "        move.b  d6,d0\n" + NEXT
    if mode == "imm":
        return out + "        moveq   #0,d6\n        move.b  (a0)+,d6\n" + READ_OPS[name] + NEXT
    ea = EA[mode] + (CROSS.format(r=XREG[mode]) if px else "")
    out += ea
    if name in ("sta", "stx", "sty"):
        return out + store({"sta": "d0", "stx": "d1", "sty": "d2"}[name]) + NEXT
    if name == "sax":
        return out + "        move.b  d0,1(a6)\n        and.b   d1,1(a6)\n" + store("1(a6)") + NEXT
    if name in SHIFT or name in RMW_THEN:
        shift, then = (name, "") if name in SHIFT else RMW_THEN[name]
        return (out + "        move.l  d6,a2\n        bsr     rd8\n" + SHIFT[shift]
                + "        move.b  d6,1(a6)\n        move.l  a2,d6\n" + store("1(a6)") + then + NEXT)
    if name == "nop" and mode in ("zp", "zpx", "abs", "abx", "aby", "izy"):
        return out + NEXT
    get = "        move.b  (a5,d6.l),d6\n" if mode in ("zp", "zpx", "zpy") else "        bsr     rd8\n"
    return out + get + READ_OPS[name] + NEXT


def main():
    with open(sys.argv[1], "w") as f:
        f.write("/* generated by tools/player/gen_6502.py; do not edit */\n")
        f.write("enum { " + ", ".join("M_" + m for m in MODES) + " };\n")
        f.write("enum { " + ", ".join("O_" + o for o in OPS) + " };\n")
        f.write("static const struct { unsigned char op, mode, cycles, cross; } optab[256] = {\n")
        for op in range(256):
            name, mode, cyc, px = T[op]
            f.write(f"    {{ O_{name}, M_{mode}, {cyc}, {int(px)} }},   /* {op:02X} */\n")
        f.write("};\n")
    with open(sys.argv[2], "w") as f:
        f.write("; generated by tools/player/gen_6502.py; do not edit\n")
        for op in range(256):
            f.write(handler(op) + "\n")
        f.write("op_table:\n")
        for op in range(0, 256, 8):
            f.write("        dc.l    " + ",".join(f"op_{o:02x}" for o in range(op, op + 8)) + "\n")


if __name__ == "__main__":
    main()
