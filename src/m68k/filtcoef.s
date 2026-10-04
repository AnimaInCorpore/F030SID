; F030SID player: the filter coefficient words
;
; The 68030 side of the DSP's state-variable filter: sid_filter_coeffs() of
; src/ref/sid_ref.c in 68030 arithmetic, word for word (tools/player/
; coef_gate.py compares the two over the whole fc/res range). Table lookups, two
; 64-bit products and a reciprocal by table with linear interpolation: no divide.
;
;   D  = 1 + g*g + g*k0*kr        a1 = 1/D       a2 = g*a1      a3 = g*g*a1
;   k4 = k0*kr                    (Q21 until the Q23 words are formed)
; plus four words straight from the tables: the gains of the three outputs.

; d0 = fc (0..2047), d1 = res (0..15), a0 = sidtab_<model>,
; a1 -> eight longs: a1, a2, a3, k4, wl, wb, wh, wleak
filter_coeffs:
        movem.l d0-d7/a2,-(sp)
        and.l   #$7ff,d0
        and.l   #$f,d1
        move.l  a0,a2
        add.l   #SIDTAB_KR,a2
        move.l  (a2,d1.l*4),d7          ; kr
        move.l  a0,a2
        add.l   #SIDTAB_K0,a2
        move.l  (a2,d0.l*4),d2
        bsr     .mulkr
        move.l  d2,12(a1)               ; k4 = (k0 * kr) >> 21
        move.l  a0,a2
        add.l   #SIDTAB_GK0,a2
        move.l  (a2,d0.l*4),d2
        bsr     .mulkr                  ; gk = (gk0 * kr) >> 21
        move.l  a0,a2
        add.l   #SIDTAB_G2,a2
        move.l  (a2,d0.l*4),d5          ; g2
        add.l   d5,d2
        add.l   #1<<21,d2               ; d = 1 + g2 + gk
        moveq   #0,d6                   ; e: d = m * 2^e, m in [1, 2)
.norm:  cmp.l   #2<<21,d2
        bcs.s   .m
        lsr.l   #1,d2
        addq.l  #1,d6
        bra.s   .norm
.m:     sub.l   #1<<21,d2
        move.l  d2,d3
        and.l   #$1fff,d3               ; fraction, 13 bits
        moveq   #13,d4
        lsr.l   d4,d2                   ; index, 8 bits
        move.l  a0,a2
        add.l   #SIDTAB_RECIP,a2
        move.l  (a2,d2.l*4),d7          ; 1/m: the table, interpolated
        move.l  d7,d1
        sub.l   4(a2,d2.l*4),d1
        mulu.l  d3,d1
        lsr.l   d4,d1
        sub.l   d1,d7
        lsr.l   d6,d7                   ; a1, Q24
        move.l  a0,a2
        add.l   #SIDTAB_G,a2
        move.l  (a2,d0.l*4),d2
        bsr.s   .mula1
        move.l  d2,4(a1)                ; a2 = (g * a1) >> 22
        move.l  d5,d2
        bsr.s   .mula1
        move.l  d2,8(a1)                ; a3 = (g2 * a1) >> 22
        lsr.l   #1,d7
        cmp.l   #$7fffff,d7
        bls.s   .a1
        move.l  #$7fffff,d7
.a1:    move.l  d7,(a1)
        move.l  a0,a2                   ; the outputs' gains depend on the cutoff alone
        add.l   #SIDTAB_WL,a2
        move.l  (a2,d0.l*4),16(a1)
        add.l   #SIDTAB_WB-SIDTAB_WL,a2
        move.l  (a2,d0.l*4),20(a1)
        add.l   #SIDTAB_WH-SIDTAB_WB,a2
        move.l  (a2,d0.l*4),24(a1)
        add.l   #SIDTAB_WLEAK-SIDTAB_WH,a2
        move.l  (a2,d0.l*4),28(a1)
        movem.l (sp)+,d0-d7/a2
        rts

.mulkr:                                 ; d2 = (d2 * d7) >> 21
        mulu.l  d7,d3:d2
        moveq   #21,d4
        lsr.l   d4,d2
        moveq   #11,d4
        lsl.l   d4,d3
        or.l    d3,d2
        rts

.mula1:                                 ; d2 = min((d2 * d7) >> 22, $7fffff)
        mulu.l  d7,d3:d2
        moveq   #22,d4
        lsr.l   d4,d2
        moveq   #10,d4
        lsl.l   d4,d3
        or.l    d3,d2
        cmp.l   #$7fffff,d2
        bls.s   .ok
        move.l  #$7fffff,d2
.ok:    rts
