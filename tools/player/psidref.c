/*
 * F030SID player reference: the 6510 core and the PSID driver in C.
 *
 *   psidref [-s song] [-t seconds] tune.sid out.trace
 *
 * This is the specification of what the 68030 player does (src/m68k/cpu6502.s,
 * psid.s): the same opcode table (tools/player/gen_6502.py), the same memory
 * and I/O rules, the same call schedule. It writes the SID register writes in
 * the trace format of tools/trace (cycle reg value, `end cycle`), so the
 * output runs through the reference model and can be compared with sidtrace's.
 * tools/player/cpu_gate.py requires the 68030 core to produce the same file.
 *
 * Rules (see tools/player/README.md):
 *  - 64 KB of RAM, no ROMs; $01 is plain RAM. Writes to $D400-$D7FF are SID
 *    writes (register = address & $1f, logged for registers 0-24) and SID reads
 *    return 0. $D012/$D011 read the raster derived from the cycle count
 *    (63 cycles a line, 312 lines). Everything else in $D000-$DFFF is RAM.
 *  - A call runs until RTS or RTI with the stack empty (S = $ff), BRK or KIL,
 *    or its cycle limit.
 *  - init is called with A = song - 1 at cycle 0. play is called every period:
 *    19656 cycles (PAL frame), or, when the tune's speed bit is set, the CIA 1
 *    timer A latch + 1 the tune left in $DC04/$DC05 (16421 if none). A play
 *    address of 0 means the vector the init routine left in $0314, else $FFFE.
 *    The first call is at the first multiple of the period after init ends; a
 *    call that overruns skips to the next multiple after it ends.
 *  - A write is stamped with the last cycle of its instruction.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu6502_tab.h"

enum { FC = 1, FZ = 2, FI = 4, FD = 8, FV = 0x40, FN = 0x80 };

typedef struct {
    uint8_t a, x, y, s, p;
    uint16_t pc;
    uint32_t cyc, limit;
    uint8_t m[65536];
    FILE *out;
    long writes;
} cpu_t;

static uint32_t raster(const cpu_t *c) { return (c->cyc / 63) % 312; }

static uint8_t rd(cpu_t *c, uint16_t a)
{
    if (a >= 0xd000 && a < 0xe000) {
        if (a >= 0xd400 && a < 0xd800) return 0;
        if (a == 0xd012) return (uint8_t)raster(c);
        if (a == 0xd011) return (uint8_t)((c->m[a] & 0x7f) | ((raster(c) >> 1) & 0x80));
    }
    return c->m[a];
}

static void wr(cpu_t *c, uint16_t a, uint8_t v)
{
    c->m[a] = v;
    if (a >= 0xd400 && a < 0xd800 && (a & 0x1f) <= 0x18) {
        fprintf(c->out, "%u %u %u\n", c->cyc - 1, a & 0x1f, v);
        c->writes++;
    }
}

static void nz(cpu_t *c, uint8_t v) { c->p = (uint8_t)((c->p & ~(FN | FZ)) | (v & 0x80) | (v ? 0 : FZ)); }
static void setc(cpu_t *c, int on) { c->p = (uint8_t)((c->p & ~FC) | (on ? FC : 0)); }
static void push(cpu_t *c, uint8_t v) { c->m[0x100 + c->s--] = v; }
static uint8_t pull(cpu_t *c) { return c->m[0x100 + ++c->s]; }

/* NMOS 6502 ADC/SBC, decimal mode included (flags as the NMOS chip sets them). */
static void adc(cpu_t *c, uint8_t v)
{
    unsigned carry = c->p & FC, sum = c->a + v + carry;

    if (c->p & FD) {
        unsigned lo = (c->a & 15) + (v & 15) + carry, hi;
        c->p = (uint8_t)((c->p & ~FZ) | ((sum & 0xff) ? 0 : FZ));
        if (lo > 9) lo += 6;
        hi = (c->a >> 4) + (v >> 4) + (lo > 15);
        c->p = (uint8_t)((c->p & ~(FN | FV)) | ((hi << 4) & 0x80) |
                         ((~(c->a ^ v) & (c->a ^ (hi << 4)) & 0x80) ? FV : 0));
        if (hi > 9) hi += 6;
        setc(c, hi > 15);
        c->a = (uint8_t)((hi << 4) | (lo & 15));
    } else {
        c->p = (uint8_t)((c->p & ~FV) | ((~(c->a ^ v) & (c->a ^ sum) & 0x80) ? FV : 0));
        setc(c, sum > 0xff);
        c->a = (uint8_t)sum;
        nz(c, c->a);
    }
}

static void sbc(cpu_t *c, uint8_t v)
{
    unsigned carry = c->p & FC, diff = c->a - v - (1 - carry);

    if (c->p & FD) {
        int lo = (c->a & 15) - (v & 15) - (int)(1 - carry), hi = (c->a >> 4) - (v >> 4);
        if (lo < 0) { lo -= 6; hi--; }
        if (hi < 0) hi -= 6;
        c->p = (uint8_t)((c->p & ~FV) | (((c->a ^ v) & (c->a ^ diff) & 0x80) ? FV : 0));
        setc(c, diff < 0x100);
        nz(c, (uint8_t)diff);
        c->a = (uint8_t)((hi << 4) | (lo & 15));
    } else {
        c->p = (uint8_t)((c->p & ~FV) | (((c->a ^ v) & (c->a ^ diff) & 0x80) ? FV : 0));
        setc(c, diff < 0x100);
        c->a = (uint8_t)diff;
        nz(c, c->a);
    }
}

static void compare(cpu_t *c, uint8_t r, uint8_t v) { setc(c, r >= v); nz(c, (uint8_t)(r - v)); }

static uint8_t shift(cpu_t *c, int op, uint8_t v)
{
    unsigned carry = c->p & FC;

    switch (op) {
    case O_asl: case O_slo: setc(c, v & 0x80); v = (uint8_t)(v << 1); break;
    case O_lsr: case O_sre: setc(c, v & 1); v >>= 1; break;
    case O_rol: case O_rla: setc(c, v & 0x80); v = (uint8_t)((v << 1) | carry); break;
    case O_ror: case O_rra: setc(c, v & 1); v = (uint8_t)((v >> 1) | (carry << 7)); break;
    case O_inc: case O_isb: v++; break;
    case O_dec: case O_dcp: v--; break;
    }
    nz(c, v);
    return v;
}

/* Run from pc until the call returns. Returns 0 on a normal return, 1 on the cycle limit. */
static int run(cpu_t *c, uint16_t pc, uint8_t a)
{
    c->pc = pc; c->a = a; c->x = c->y = 0; c->s = 0xff; c->p = FI;

    for (;;) {
        uint8_t opc = c->m[c->pc++], v;
        int op = optab[opc].op, mode = optab[opc].mode;
        uint16_t ea = 0, base;

        c->cyc += optab[opc].cycles;
        switch (mode) {
        case M_imm: ea = c->pc++; break;
        case M_zp:  ea = c->m[c->pc++]; break;
        case M_zpx: ea = (uint8_t)(c->m[c->pc++] + c->x); break;
        case M_zpy: ea = (uint8_t)(c->m[c->pc++] + c->y); break;
        case M_abs: case M_abx: case M_aby: case M_ind:
            base = (uint16_t)(c->m[c->pc] | (c->m[(uint16_t)(c->pc + 1)] << 8));
            c->pc += 2;
            ea = (uint16_t)(base + (mode == M_abx ? c->x : mode == M_aby ? c->y : 0));
            if (optab[opc].cross && (ea & 0xff00) != (base & 0xff00)) c->cyc++;
            break;
        case M_izx:
            v = (uint8_t)(c->m[c->pc++] + c->x);
            ea = (uint16_t)(c->m[v] | (c->m[(uint8_t)(v + 1)] << 8));
            break;
        case M_izy:
            v = c->m[c->pc++];
            base = (uint16_t)(c->m[v] | (c->m[(uint8_t)(v + 1)] << 8));
            ea = (uint16_t)(base + c->y);
            if (optab[opc].cross && (ea & 0xff00) != (base & 0xff00)) c->cyc++;
            break;
        case M_rel: ea = c->pc++; break;
        }

        switch (op) {
        case O_brk: case O_kil: return 0;
        case O_nop: break;
        case O_ora: c->a |= rd(c, ea); nz(c, c->a); break;
        case O_and: c->a &= rd(c, ea); nz(c, c->a); break;
        case O_eor: c->a ^= rd(c, ea); nz(c, c->a); break;
        case O_adc: adc(c, rd(c, ea)); break;
        case O_sbc: sbc(c, rd(c, ea)); break;
        case O_lda: c->a = rd(c, ea); nz(c, c->a); break;
        case O_ldx: c->x = rd(c, ea); nz(c, c->x); break;
        case O_ldy: c->y = rd(c, ea); nz(c, c->y); break;
        case O_lax: c->a = c->x = rd(c, ea); nz(c, c->a); break;
        case O_cmp: compare(c, c->a, rd(c, ea)); break;
        case O_cpx: compare(c, c->x, rd(c, ea)); break;
        case O_cpy: compare(c, c->y, rd(c, ea)); break;
        case O_bit:
            v = rd(c, ea);
            c->p = (uint8_t)((c->p & ~(FN | FV | FZ)) | (v & (FN | FV)) | ((v & c->a) ? 0 : FZ));
            break;
        case O_sta: wr(c, ea, c->a); break;
        case O_stx: wr(c, ea, c->x); break;
        case O_sty: wr(c, ea, c->y); break;
        case O_sax: wr(c, ea, c->a & c->x); break;
        case O_asl: case O_lsr: case O_rol: case O_ror: case O_inc: case O_dec:
            if (mode == M_acc) c->a = shift(c, op, c->a);
            else wr(c, ea, shift(c, op, rd(c, ea)));
            break;
        case O_slo: v = shift(c, op, rd(c, ea)); wr(c, ea, v); c->a |= v; nz(c, c->a); break;
        case O_rla: v = shift(c, op, rd(c, ea)); wr(c, ea, v); c->a &= v; nz(c, c->a); break;
        case O_sre: v = shift(c, op, rd(c, ea)); wr(c, ea, v); c->a ^= v; nz(c, c->a); break;
        case O_rra: v = shift(c, op, rd(c, ea)); wr(c, ea, v); adc(c, v); break;
        case O_dcp: v = shift(c, op, rd(c, ea)); wr(c, ea, v); compare(c, c->a, v); break;
        case O_isb: v = shift(c, op, rd(c, ea)); wr(c, ea, v); sbc(c, v); break;
        case O_anc: c->a &= rd(c, ea); nz(c, c->a); setc(c, c->a & 0x80); break;
        case O_alr: c->a &= rd(c, ea); setc(c, c->a & 1); c->a >>= 1; nz(c, c->a); break;
        case O_arr:                              /* binary mode behaviour */
            c->a &= rd(c, ea);
            c->a = (uint8_t)((c->a >> 1) | ((c->p & FC) << 7));
            nz(c, c->a);
            setc(c, c->a & 0x40);
            c->p = (uint8_t)((c->p & ~FV) | (((c->a >> 6) ^ (c->a >> 5)) & 1 ? FV : 0));
            break;
        case O_sbx: v = rd(c, ea); c->x &= c->a; setc(c, c->x >= v); c->x = (uint8_t)(c->x - v); nz(c, c->x); break;
        case O_bpl: case O_bmi: case O_bvc: case O_bvs: case O_bcc: case O_bcs: case O_bne: case O_beq: {
            static const uint8_t flag[8] = { FN, FN, FV, FV, FC, FC, FZ, FZ };
            int k = op == O_bpl ? 0 : op == O_bmi ? 1 : op == O_bvc ? 2 : op == O_bvs ? 3 :
                    op == O_bcc ? 4 : op == O_bcs ? 5 : op == O_bne ? 6 : 7;
            if (((c->p & flag[k]) != 0) == (k & 1)) {
                uint16_t target = (uint16_t)(c->pc + (int8_t)c->m[ea]);
                c->cyc += 1 + ((target & 0xff00) != (c->pc & 0xff00));
                c->pc = target;
                if (c->cyc >= c->limit) return 1;
            }
            break;
        }
        case O_jmp:
            if (mode == M_ind)
                ea = (uint16_t)(c->m[ea] | (c->m[(ea & 0xff00) | ((ea + 1) & 0xff)] << 8));
            c->pc = ea;
            if (c->cyc >= c->limit) return 1;
            break;
        case O_jsr:
            ea = (uint16_t)(c->m[c->pc] | (c->m[(uint16_t)(c->pc + 1)] << 8));
            push(c, (uint8_t)((c->pc + 1) >> 8));
            push(c, (uint8_t)(c->pc + 1));
            c->pc = ea;
            if (c->cyc >= c->limit) return 1;
            break;
        case O_rts:
            if (c->s == 0xff) return 0;
            c->pc = pull(c);
            c->pc = (uint16_t)((c->pc | (pull(c) << 8)) + 1);
            break;
        case O_rti:
            if (c->s == 0xff) return 0;
            c->p = (uint8_t)(pull(c) & ~0x30);
            c->pc = pull(c);
            c->pc = (uint16_t)(c->pc | (pull(c) << 8));
            break;
        case O_php: push(c, c->p | 0x30); break;
        case O_plp: c->p = (uint8_t)(pull(c) & ~0x30); break;
        case O_pha: push(c, c->a); break;
        case O_pla: c->a = pull(c); nz(c, c->a); break;
        case O_clc: c->p &= (uint8_t)~FC; break;
        case O_sec: c->p |= FC; break;
        case O_cli: c->p &= (uint8_t)~FI; break;
        case O_sei: c->p |= FI; break;
        case O_cld: c->p &= (uint8_t)~FD; break;
        case O_sed: c->p |= FD; break;
        case O_clv: c->p &= (uint8_t)~FV; break;
        case O_tax: c->x = c->a; nz(c, c->x); break;
        case O_tay: c->y = c->a; nz(c, c->y); break;
        case O_txa: c->a = c->x; nz(c, c->a); break;
        case O_tya: c->a = c->y; nz(c, c->a); break;
        case O_tsx: c->x = c->s; nz(c, c->x); break;
        case O_txs: c->s = c->x; break;
        case O_inx: c->x++; nz(c, c->x); break;
        case O_iny: c->y++; nz(c, c->y); break;
        case O_dex: c->x--; nz(c, c->x); break;
        case O_dey: c->y--; nz(c, c->y); break;
        }
    }
}

static unsigned be16(const uint8_t *p) { return (unsigned)(p[0] << 8 | p[1]); }

int main(int argc, char **argv)
{
    static cpu_t c;
    static uint8_t file[65536 + 256];
    int song = 0, i;
    double seconds = 10.0;
    unsigned data, load, init, play, songs, start, period;
    uint32_t speed, end, t;
    size_t n;
    FILE *f;

    for (i = 1; i < argc - 2; i += 2) {
        if (!strcmp(argv[i], "-s")) song = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-t")) seconds = atof(argv[i + 1]);
        else break;
    }
    if (argc - i != 2) { fprintf(stderr, "usage: %s [-s song] [-t seconds] tune.sid out.trace\n", argv[0]); return 2; }
    f = fopen(argv[i], "rb");
    if (!f) { perror(argv[i]); return 1; }
    n = fread(file, 1, sizeof file, f);
    fclose(f);
    if (n < 0x7c || (memcmp(file, "PSID", 4) && memcmp(file, "RSID", 4))) { fprintf(stderr, "not a PSID file\n"); return 1; }
    data = be16(file + 6); load = be16(file + 8); init = be16(file + 10); play = be16(file + 12);
    songs = be16(file + 14); start = be16(file + 16);
    speed = (uint32_t)be16(file + 18) << 16 | be16(file + 20);
    if (!load) { load = (unsigned)(file[data] | file[data + 1] << 8); data += 2; }
    if (!init) init = load;
    if (song < 1 || (unsigned)song > songs) song = (int)(start ? start : 1);
    if (load + (n - data) > 65536) n = data + 65536 - load;
    memcpy(c.m + load, file + data, n - data);
    c.m[1] = 0x37;

    c.out = fopen(argv[i + 1], "w");
    if (!c.out) { perror(argv[i + 1]); return 1; }
    fprintf(c.out, "# psidref %s song %d\n", argv[i], song);
    end = (uint32_t)(seconds * 985248.0);
    c.cyc = 0;
    c.limit = 2000000;
    run(&c, (uint16_t)init, (uint8_t)(song - 1));

    t = 0;
    while (c.cyc < end) {
        unsigned vec = play;
        period = 19656;
        if (speed >> (song - 1 > 31 ? 31 : song - 1) & 1) {
            unsigned latch = (unsigned)(c.m[0xdc04] | c.m[0xdc05] << 8);
            period = latch ? latch + 1 : 16421;
        }
        if (!vec) {
            vec = (unsigned)(c.m[0x314] | c.m[0x315] << 8);
            if (!vec) vec = (unsigned)(c.m[0xfffe] | c.m[0xffff] << 8);
        }
        t = (c.cyc / period + 1) * period;              /* the next multiple of the period */
        if (t >= end) break;
        c.cyc = t;
        c.limit = t + 10 * period;
        run(&c, (uint16_t)vec, 0);
    }
    fprintf(c.out, "end %u\n", end);
    fclose(c.out);
    fprintf(stderr, "%ld writes\n", c.writes);
    return 0;
}
