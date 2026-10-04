; F030SID 6510 core test harness
;
; Runs the PSID tune assembled into it (tune.sid and cputest_cfg.i in the gate
; directory) through the 68030 core and the PSID driver for CPU_END cycles and
; writes the SID writes it logged to CPUOUT.BIN: big-endian longs, the count
; first, then cycle, register, value per write. tools/player/cpu_gate.py
; compares the file with the C reference's trace of the same tune.

        include "xbios.i"

        global  start

MAX_WRITES      equ     40000

        include "cputest_cfg.i"         ; CPU_END (cycles), CPU_SONG

        text

start:
        Cconws  banner
        move.l  #ram+255,d0             ; the RAM image, 256-aligned
        clr.b   d0
        move.l  d0,a5
        lea     cpu_state,a6
        move.l  #wlog+4,CPU_WLOG(a6)
        move.l  #wlog+4+MAX_WRITES*12,CPU_WEND(a6)
        clr.l   CPU_WCOUNT(a6)

        lea     tune,a0
        move.l  #tune_end-tune,d0
        moveq   #CPU_SONG,d1
        bsr     psid_load
        tst.l   d0
        bmi     fail
        bsr     psid_start
        move.l  #CPU_END,d5
frames: bsr     psid_frame
        tst.l   d0
        beq.s   frames

        move.l  CPU_WCOUNT(a6),d0
        move.l  d0,wlog
        mulu.l  #12,d0
        addq.l  #4,d0
        move.l  d0,d7
        Fcreate out_name,#0
        tst.l   d0
        bmi     fail
        move.w  d0,out_handle
        Fwrite  out_handle,d7,wlog
        Fclose  out_handle
        Cconws  done
        bra.s   exit
fail:
        Cconws  failed
exit:
        Pterm0

        include "cpu6502.s"
        include "psid.s"

        data

banner:         dc.b    13,10,'F030SID 6510 core test',13,10,0
done:           dc.b    'done',13,10,0
failed:         dc.b    'FAILED',13,10,0
out_name:       dc.b    'CPUOUT.BIN',0
        even
tune:           incbin  "tune.sid"
tune_end:
        even

        bss

out_handle:     ds.w    1
cpu_state:      ds.b    CPU_STATE_SIZE
ram:            ds.b    65536+256+16
wlog:           ds.l    1+MAX_WRITES*3

        end
