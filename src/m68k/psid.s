; F030SID player: PSID loading and the call schedule
;
; The rules are the reference's (tools/player/psidref.c): init with A = song - 1
; at cycle 0, then play once per period (a PAL frame, or the CIA 1 timer A latch
; the tune set, when its speed bit says so), the first call at the first
; multiple of the period after init ends.

PSID_FRAME_PAL  equ     19656
PSID_CIA_60HZ   equ     16421
PSID_INIT_LIMIT equ     2000000

; a0 = the file, d0.l = its length, d1.l = song (0 = the tune's default),
; a5 = 64 KB RAM image (cleared here). Returns d0 = 0, or -1 if it is not a PSID.
psid_load:
        movem.l d1-d4/a0-a2,-(sp)
        cmp.l   #$7c,d0
        blt     .bad
        cmp.l   #'PSID',(a0)
        beq.s   .magic
        cmp.l   #'RSID',(a0)
        bne     .bad
.magic: move.l  a5,a1
        move.w  #65536/4-1,d2
.clear: clr.l   (a1)+
        dbra    d2,.clear
        moveq   #0,d2
        move.w  6(a0),d2                ; data offset
        moveq   #0,d3
        move.w  8(a0),d3                ; load address
        move.w  10(a0),psid_init
        move.w  12(a0),psid_play
        move.w  14(a0),d4               ; songs
        move.l  18(a0),psid_speed
        tst.l   d1
        beq.s   .dflt
        cmp.w   d4,d1
        bls.s   .song
.dflt:  moveq   #0,d1
        move.w  16(a0),d1               ; start song
        bne.s   .song
        moveq   #1,d1
.song:  move.w  d1,psid_song
        lea     (a0,d2.l),a1
        sub.l   d2,d0                   ; data bytes
        tst.w   d3
        bne.s   .addr
        move.b  1(a1),d3                ; the load address leads the data, little-endian
        lsl.w   #8,d3
        move.b  (a1),d3
        addq.l  #2,a1
        subq.l  #2,d0
.addr:  tst.w   psid_init
        bne.s   .init
        move.w  d3,psid_init
.init:  move.l  #65536,d2
        sub.l   d3,d2                   ; room above the load address
        cmp.l   d2,d0
        bls.s   .fits
        move.l  d2,d0
.fits:  lea     (a5,d3.l),a2
        bra.s   .cnext
.copy:  move.b  (a1)+,(a2)+
.cnext: subq.l  #1,d0
        bpl.s   .copy
        move.b  #$37,1(a5)
        moveq   #0,d0
        bra.s   .out
.bad:   moveq   #-1,d0
.out:   movem.l (sp)+,d1-d4/a0-a2
        rts

; Run the init routine. a5 = RAM, a6 = cpu state. Returns d7 = cycles.
psid_start:
        moveq   #0,d7
        move.l  #PSID_INIT_LIMIT,CPU_LIMIT(a6)
        moveq   #0,d6
        move.w  psid_init,d6
        moveq   #0,d0
        move.w  psid_song,d0
        subq.w  #1,d0
        bra     cpu_run

; The next play call. d7 = cycle count so far, d5 = the cycle to stop before.
; Returns d7 after the call and d0 = 0, or d0 = -1 (d7 unchanged) when the
; call would start at or after d5.
psid_frame:
        movem.l d1-d3/d6,-(sp)
        move.l  #PSID_FRAME_PAL,d1      ; the period
        move.w  psid_song,d2
        subq.w  #1,d2
        cmp.w   #31,d2
        bls.s   .bit
        moveq   #31,d2
.bit:   move.l  psid_speed,d3
        btst    d2,d3
        beq.s   .period
        move.l  #$dc04,d6
        moveq   #0,d1
        move.b  1(a5,d6.l),d1
        lsl.w   #8,d1
        move.b  (a5,d6.l),d1            ; CIA 1 timer A latch
        addq.l  #1,d1
        cmp.l   #1,d1
        bne.s   .period
        move.l  #PSID_CIA_60HZ,d1
.period:
        move.l  d7,d2
        divu.l  d1,d2
        addq.l  #1,d2
        mulu.l  d1,d2                   ; the next multiple of the period
        cmp.l   d5,d2
        bcc.s   .end
        move.l  d2,d7
        move.l  d1,d3
        mulu.l  #10,d3
        add.l   d2,d3
        move.l  d3,CPU_LIMIT(a6)
        moveq   #0,d6
        move.w  psid_play,d6
        bne.s   .call
        move.w  #$0314,d6               ; the vector the init routine installed
        bsr.s   .vector
        bne.s   .call
        move.l  #$fffe,d6
        bsr.s   .vector
.call:  moveq   #0,d0
        bsr     cpu_run
        moveq   #0,d0
        bra.s   .out
.end:   moveq   #-1,d0
.out:   movem.l (sp)+,d1-d3/d6
        rts
.vector:                                ; d6 = address -> d6 = the little-endian word there (flags: zero?)
        move.b  1(a5,d6.l),d0
        lsl.w   #8,d0
        move.b  (a5,d6.l),d0
        moveq   #0,d6
        move.w  d0,d6
        rts

        bss
psid_speed:     ds.l    1
psid_init:      ds.w    1
psid_play:      ds.w    1
psid_song:      ds.w    1
        text
