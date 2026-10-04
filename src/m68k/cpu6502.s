; F030SID player: the 6510 core
;
; One handler per opcode, generated from the table the C reference core uses
; (tools/player/gen_6502.py -> cpu6502_ops.i); this file holds what the
; handlers share. tools/player/psidref.c is the specification: same opcodes,
; same memory and I/O rules, same cycle counts, and tools/player/cpu_gate.py
; requires both to log the same SID writes at the same cycles.
;
; Registers while the core runs:
;   d0 A   d1 X   d2 Y   d3 S          (longs, upper 24 bits clear)
;   d4.b   Z source: zero = Z set
;   d5.b   C, I, D, V in their P positions (bits 0, 2, 3, 6)
;   d6     scratch: effective address, operand
;   d7     cycle count
;   a0     PC as a host pointer (a5 + pc)
;   a4     op_table
;   a5     the 64 KB RAM image; must be 256-aligned (page crossings are
;          tested on host addresses)
;   a6     cpu state (below); 0(a6) is the N source: bit 7 = N
;   a1, a2 scratch

CPU_NFLAG       equ     0
CPU_TMP         equ     1               ; a byte in transit to memory
CPU_LIMIT       equ     4               ; cycle count at which a call is abandoned
CPU_WLOG        equ     8               ; next free SID write record (cycle, register, value longs)
CPU_WCOUNT      equ     12
CPU_WEND        equ     16              ; end of the write log
CPU_SP          equ     20
CPU_STATE_SIZE  equ     24

        macro   NEXT
        moveq   #0,d6
        move.b  (a0)+,d6
        jmp     ([a4,d6.w*4])
        endm

; Run a 6510 subroutine: d6.w = address, d0.b = A, d7 = cycle count, a5 = RAM,
; a6 = state. Returns when it executes RTS or RTI with its stack empty, BRK or
; KIL (d0 = 0), or when the cycle count reaches CPU_LIMIT at a jump (d0 = 1).
; d7 = the cycle count afterwards.
cpu_run:
        movem.l d1-d6/a0-a4,-(sp)
        move.l  sp,CPU_SP(a6)
        and.l   #$ff,d0
        moveq   #0,d1
        moveq   #0,d2
        move.l  #$ff,d3
        moveq   #1,d4                   ; Z clear
        moveq   #4,d5                   ; I set
        clr.b   CPU_NFLAG(a6)
        and.l   #$ffff,d6
        lea     (a5,d6.l),a0
        lea     op_table,a4
        NEXT

cpu_stop:
        moveq   #0,d0
        bra.s   cpu_leave
cpu_limit:
        moveq   #1,d0
cpu_leave:
        move.l  CPU_SP(a6),sp
        movem.l (sp)+,d1-d6/a0-a4
        rts

; ---- memory

; d6 = address -> d6 = the byte there, zero-extended
rd8:
        cmp.w   #$d000,d6
        bcs.s   rd_ram
        cmp.w   #$e000,d6
        bcs.s   io_read
rd_ram: move.b  (a5,d6.l),d6
        and.l   #$ff,d6
        rts

; $D000-$DFFF: the SID reads as 0, $D012/$D011 give the raster of the cycle
; count (63 cycles a line, 312 lines), the rest is RAM
io_read:
        cmp.w   #$d400,d6
        bcs.s   .vic
        cmp.w   #$d800,d6
        bcc.s   rd_ram
        moveq   #0,d6
        rts
.vic:   cmp.w   #$d012,d6
        beq.s   .line
        cmp.w   #$d011,d6
        bne.s   rd_ram
        bsr.s   raster
        lsr.w   #1,d6
        and.b   #$80,d6
        move.b  d6,CPU_TMP(a6)
        move.l  #$d011,d6
        move.b  (a5,d6.l),d6
        and.l   #$7f,d6
        or.b    CPU_TMP(a6),d6
        rts
.line:  bsr.s   raster
        and.l   #$ff,d6
        rts

raster:                                 ; d6 = (cycles / 63) mod 312
        move.l  d1,-(sp)
        move.l  d7,d6
        divu.l  #63,d6
        divul.l #312,d1:d6
        move.l  d1,d6
        move.l  (sp)+,d1
        rts

; d6 = address in $D000-$DFFF, CPU_TMP = the byte. A SID write is logged with
; the last cycle of its instruction.
io_write:
        move.b  CPU_TMP(a6),(a5,d6.l)
        cmp.w   #$d400,d6
        bcs.s   .done
        cmp.w   #$d800,d6
        bcc.s   .done
        and.l   #$1f,d6
        cmp.w   #$18,d6
        bhi.s   .done
        move.l  a1,-(sp)
        move.l  CPU_WLOG(a6),a1
        cmp.l   CPU_WEND(a6),a1
        bcc.s   .full
        move.l  d7,(a1)
        subq.l  #1,(a1)+
        move.l  d6,(a1)+
        moveq   #0,d6
        move.b  CPU_TMP(a6),d6
        move.l  d6,(a1)+
        move.l  a1,CPU_WLOG(a6)
        addq.l  #1,CPU_WCOUNT(a6)
.full:  move.l  (sp)+,a1
.done:  rts

; ---- flow

; a branch is taken: a0 points at its offset
do_branch:
        move.b  (a0)+,d6
        ext.w   d6
        move.l  a0,a1
        adda.w  d6,a0
        addq.l  #1,d7
        move.l  d1,-(sp)
        move.l  a0,d6
        move.l  a1,d1
        eor.w   d1,d6
        move.l  (sp)+,d1
        and.w   #$ff00,d6
        beq.s   .same
        addq.l  #1,d7                   ; into another page
.same:  cmp.l   CPU_LIMIT(a6),d7
        bcc     cpu_limit
        rts

op_jmp_ind:                             ; d6 = the vector's address; its high byte comes from the same page
        move.l  d6,a1
        addq.b  #1,d6
        move.b  (a5,d6.l),d6
        lsl.w   #8,d6
        move.b  (a5,a1.l),d6
op_jmp:                                 ; d6 = target
        and.l   #$ffff,d6
        lea     (a5,d6.l),a0
        cmp.l   CPU_LIMIT(a6),d7
        bcc     cpu_limit
        NEXT

op_jsr:                                 ; a0 points at the operand
        move.l  a0,d6
        sub.l   a5,d6
        addq.w  #1,d6                   ; the address of the instruction's last byte
        ror.w   #8,d6
        move.b  d6,($100,a5,d3.l)
        subq.b  #1,d3
        ror.w   #8,d6
        move.b  d6,($100,a5,d3.l)
        subq.b  #1,d3
        moveq   #0,d6
        move.b  1(a0),d6
        lsl.w   #8,d6
        move.b  (a0),d6
        bra.s   op_jmp

op_rts:
        cmp.b   #$ff,d3
        beq     cpu_stop                ; the call returns
        bsr.s   pull_pc
        addq.w  #1,d6
        lea     (a5,d6.l),a0
        NEXT

op_rti:
        cmp.b   #$ff,d3
        beq     cpu_stop
        addq.b  #1,d3
        move.b  ($100,a5,d3.l),d6
        bsr     set_p
        bsr.s   pull_pc
        lea     (a5,d6.l),a0
        NEXT

pull_pc:                                ; -> d6.l
        addq.b  #1,d3
        move.b  ($100,a5,d3.l),CPU_TMP(a6)
        addq.b  #1,d3
        moveq   #0,d6
        move.b  ($100,a5,d3.l),d6
        lsl.w   #8,d6
        move.b  CPU_TMP(a6),d6
        rts

; ---- flags

get_p:                                  ; -> d6.b = P (without B)
        move.b  d5,d6
        and.b   #$4d,d6
        or.b    #$20,d6
        tst.b   CPU_NFLAG(a6)
        bpl.s   .n0
        or.b    #$80,d6
.n0:    tst.b   d4
        bne.s   .z0
        or.b    #$02,d6
.z0:    rts

set_p:                                  ; d6.b = P
        move.b  d6,CPU_NFLAG(a6)
        move.b  d6,d5
        and.b   #$4d,d5
        btst    #1,d6
        seq     d4
        rts

; ---- arithmetic (NMOS 6502, decimal mode as the chip does it)

op_adc:                                 ; A += d6.b + C
        btst    #3,d5
        bne.s   adc_dec
        movem.l d1-d2,-(sp)
        moveq   #0,d1
        move.b  d6,d1
        moveq   #1,d2
        and.b   d5,d2
        add.w   d0,d2
        add.w   d1,d2                   ; the 9-bit sum
        move.b  d0,d6
        eor.b   d1,d6
        not.b   d6
        move.b  d0,d1
        eor.b   d2,d1
        and.b   d1,d6                   ; bit 7: overflow
        and.b   #$be,d5
        tst.b   d6
        bpl.s   .v0
        or.b    #$40,d5
.v0:    cmp.w   #$100,d2
        bcs.s   .c0
        addq.b  #1,d5
.c0:    moveq   #0,d0
        move.b  d2,d0
        move.b  d0,d4
        move.b  d0,CPU_NFLAG(a6)
        movem.l (sp)+,d1-d2
        rts

adc_dec:
        movem.l d1-d3,-(sp)
        moveq   #0,d1
        move.b  d6,d1                   ; v
        moveq   #1,d2
        and.b   d5,d2                   ; carry
        move.w  d0,d3
        add.w   d1,d3
        add.w   d2,d3
        move.b  d3,d4                   ; Z from the binary sum
        moveq   #15,d3
        and.b   d0,d3
        add.w   d3,d2
        moveq   #15,d3
        and.b   d1,d3
        add.w   d3,d2                   ; lo = (a & 15) + (v & 15) + carry
        cmp.w   #9,d2
        bls.s   .lo
        addq.w  #6,d2
.lo:    move.w  d0,d3
        lsr.w   #4,d3
        move.w  d1,d6
        lsr.w   #4,d6
        add.w   d6,d3                   ; hi = (a >> 4) + (v >> 4) + (lo > 15)
        cmp.w   #15,d2
        bls.s   .hi
        addq.w  #1,d3
.hi:    move.w  d3,d6
        lsl.w   #4,d6                   ; hi << 4: N, and V against it
        move.b  d6,CPU_NFLAG(a6)
        eor.b   d0,d6                   ; a ^ (hi << 4)
        eor.b   d0,d1
        not.b   d1                      ; ~(a ^ v)
        and.b   d1,d6
        and.b   #$be,d5
        tst.b   d6
        bpl.s   .v0
        or.b    #$40,d5
.v0:    cmp.w   #9,d3
        bls.s   .h9
        addq.w  #6,d3
.h9:    cmp.w   #15,d3
        bls.s   .c0
        addq.b  #1,d5
.c0:    lsl.w   #4,d3
        and.w   #15,d2
        or.w    d2,d3
        moveq   #0,d0
        move.b  d3,d0
        movem.l (sp)+,d1-d3
        rts

op_sbc:                                 ; A -= d6.b + (1 - C)
        movem.l d1-d3,-(sp)
        moveq   #0,d1
        move.b  d6,d1                   ; v
        moveq   #1,d2
        and.b   d5,d2
        eor.b   #1,d2                   ; borrow
        move.w  d0,d3
        sub.w   d1,d3
        sub.w   d2,d3                   ; diff (16 bits)
        move.b  d0,d6
        eor.b   d1,d6
        move.b  d0,-(sp)
        eor.b   d3,(sp)
        and.b   (sp)+,d6                ; bit 7: overflow = (a ^ v) & (a ^ diff)
        btst    #3,d5
        bne.s   sbc_dec
        and.b   #$be,d5
        tst.b   d6
        bpl.s   .v0
        or.b    #$40,d5
.v0:    cmp.w   #$100,d3
        bcc.s   .c0
        addq.b  #1,d5                   ; no borrow
.c0:    moveq   #0,d0
        move.b  d3,d0
        move.b  d0,d4
        move.b  d0,CPU_NFLAG(a6)
        movem.l (sp)+,d1-d3
        rts

sbc_dec:                                ; flags from the binary difference, the result decimal
        and.b   #$be,d5
        tst.b   d6
        bpl.s   .v0
        or.b    #$40,d5
.v0:    cmp.w   #$100,d3
        bcc.s   .c0
        addq.b  #1,d5
.c0:    move.b  d3,d4
        move.b  d3,CPU_NFLAG(a6)
        moveq   #15,d3
        and.w   d0,d3
        moveq   #15,d6
        and.w   d1,d6
        sub.w   d6,d3
        sub.w   d2,d3                   ; lo = (a & 15) - (v & 15) - borrow
        move.w  d0,d2
        lsr.w   #4,d2
        lsr.w   #4,d1
        sub.w   d1,d2                   ; hi = (a >> 4) - (v >> 4)
        tst.w   d3
        bpl.s   .lo
        subq.w  #6,d3
        subq.w  #1,d2
.lo:    tst.w   d2
        bpl.s   .hi
        subq.w  #6,d2
.hi:    lsl.w   #4,d2
        and.w   #15,d3
        or.w    d3,d2
        moveq   #0,d0
        move.b  d2,d0
        movem.l (sp)+,d1-d3
        rts

op_arr:                                 ; A = ((A & d6) >> 1) | (C << 7); C = bit 6, V = bit 6 ^ bit 5
        and.b   d6,d0
        lsr.b   #1,d0
        btst    #0,d5
        beq.s   .c
        or.b    #$80,d0
.c:     move.b  d0,d4
        move.b  d0,CPU_NFLAG(a6)
        and.b   #$be,d5
        btst    #6,d0
        beq.s   .c0
        addq.b  #1,d5
.c0:    move.b  d0,d6
        lsr.b   #1,d6
        eor.b   d0,d6
        btst    #5,d6
        beq.s   .v0
        or.b    #$40,d5
.v0:    rts

op_rol:                                 ; d6.b through the carry
        move.w  d1,-(sp)
        moveq   #1,d1
        and.b   d5,d1
        and.b   #$fe,d5
        add.b   d6,d6
        bcc.s   .c0
        addq.b  #1,d5
.c0:    or.b    d1,d6
        move.w  (sp)+,d1
        move.b  d6,d4
        move.b  d6,CPU_NFLAG(a6)
        rts

op_ror:
        move.w  d1,-(sp)
        moveq   #1,d1
        and.b   d5,d1
        ror.b   #1,d1
        and.b   #$fe,d5
        lsr.b   #1,d6
        bcc.s   .c0
        addq.b  #1,d5
.c0:    or.b    d1,d6
        move.w  (sp)+,d1
        move.b  d6,d4
        move.b  d6,CPU_NFLAG(a6)
        rts

        include "cpu6502_ops.i"
