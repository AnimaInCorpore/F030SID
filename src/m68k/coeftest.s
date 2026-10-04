; F030SID filter coefficient test harness: the coefficient words for every
; third fc and every res, both chip models, to COEFOUT.BIN (big-endian longs
; a1 a2 a3 k4 wl wb wh wleak). tools/player/coef_gate.py compares them with the C routine's.

        include "xbios.i"
        include "sidtab.i"

        global  start

FC_STEP         equ     3

        text
start:
        lea     outbuf,a1
        lea     tab6581,a0
        bsr.s   sweep
        lea     tab8580,a0
        bsr.s   sweep
        move.l  a1,d7
        sub.l   #outbuf,d7
        Fcreate out_name,#0
        tst.l   d0
        bmi.s   exit
        move.w  d0,out_handle
        Fwrite  out_handle,d7,outbuf
        Fclose  out_handle
exit:   Pterm0

sweep:  moveq   #0,d0
.fc:    moveq   #0,d1
.res:   bsr     filter_coeffs
        lea     32(a1),a1
        addq.l  #1,d1
        cmp.l   #16,d1
        bne.s   .res
        addq.l  #FC_STEP,d0
        cmp.l   #2048,d0
        bcs.s   .fc
        rts

        include "filtcoef.s"

        data
out_name:       dc.b    'COEFOUT.BIN',0
        even
tab6581:        incbin  "sidtab_6581.bin"
tab8580:        incbin  "sidtab_8580.bin"

        bss
out_handle:     ds.w    1
outbuf:         ds.l    2*683*16*8
        end
