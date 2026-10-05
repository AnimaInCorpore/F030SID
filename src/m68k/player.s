; F030SID: the SID player
;
;   F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds] [-v] [-p]
;
; Plays a PSID file: the 68030 runs the tune's 6510 code (cpu6502.s, psid.s),
; stamps every SID register write with its cycle and sends the writes to the
; DSP kernel's stream a couple of PAL frames ahead of the DSP's render clock;
; the DSP renders the chip and plays it through the SSI at 49.17 kHz
; (docs/dsp-kernel.md, docs/player.md). With no command tail the line is read
; from AUTOPLAY.INF beside the program. A key stops; -t stops after that many
; seconds of tune time; -v writes the DSP's stream status to PLAYOUT.BIN (with -p
; the DSP renders as it does without -v, with no checksum: the timing a listener gets)
; afterwards (tools/player/play_gate.py: big-endian longs, final render clock,
; checksum, least ring fill and overtakes while fed, SSI underrun flag,
; overtakes at the end, 6510 cycles run, 200 Hz ticks taken).
;
; What the reference model of all this is: tools/player/psidref.c for the 6510
; side, src/ref/sid_ref.c for the chip. The gate requires the DSP's checksum
; over the played frames to equal the reference's.

        include "xbios.i"
        include "protocol.i"
        include "sidtab.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3
DSP_HOST_ISR    equ     $ffffa202
DSP_HOST_DATA   equ     $ffffa204
HZ200           equ     $4ba

SOUND_STEREO16  equ 1
SOUND_DSP_XMIT  equ 1
SOUND_DAC       equ 8
SOUND_CLK25M    equ 0
SOUND_PRESCALE  equ 1                   ; 25.175 MHz / 256 / 2 = 49,169.92 Hz
SOUND_NO_SHAKE  equ 1
SOUND_LTATTEN   equ 0
SOUND_RTATTEN   equ 1
SOUND_ADDERIN   equ 4
SOUND_MATRIXIN  equ 2
SOUND_MONPAIR0  equ 0
SOUND_DMA_STOP  equ 0
SNDSTAT_RESET   equ 1

SID_CLOCK       equ     985248          ; PAL
GEN_LEAD        equ     40000           ; cycles of tune kept generated ahead of the DSP's render clock
PUSH_MAX        equ     200             ; queue entries per push
MAX_LOG         equ     4000            ; SID writes of one generation step
MAX_PEND        equ     40000           ; queue entries waiting to be pushed
FILE_MAX        equ     66000
SNAPSHOT_BEFORE equ     40000

        text

start:
        move.l  4(sp),a0                ; basepage: the command tail
        lea     $80(a0),a0
        moveq   #0,d0
        move.b  (a0)+,d0
        lea     cmdline,a1
        bra.s   .cnext
.ccopy: move.b  (a0)+,(a1)+
.cnext: dbra    d0,.ccopy
        clr.b   (a1)
        Cconws  banner

        tst.b   cmdline
        bne.s   .have
        Fopen   inf_name,#0             ; no tail: AUTOPLAY.INF
        tst.l   d0
        bmi     usage
        move.w  d0,handle
        Fread   handle,#126,cmdline
        move.l  d0,d7
        Fclose  handle
        tst.l   d7
        ble     usage
        lea     cmdline,a0
        clr.b   (a0,d7.l)
.have:  bsr     parse
        tst.b   path
        beq     usage

        Fopen   path,#0
        tst.l   d0
        bmi     nofile
        move.w  d0,handle
        Fread   handle,#FILE_MAX,filebuf
        move.l  d0,file_len
        Fclose  handle

        move.l  #ram+255,d0             ; the C64's RAM, 256-aligned
        clr.b   d0
        move.l  d0,a5
        lea     filebuf,a0
        move.l  file_len,d0
        move.l  opt_song,d1
        bsr     psid_load
        tst.l   d0
        bmi     notpsid

        lea     filebuf,a0              ; the chip model: -m, else the tune's flag, else 6581
        tst.l   opt_model
        bne.s   .model
        cmp.w   #2,4(a0)
        bcs.s   .model
        move.w  $76(a0),d0
        lsr.w   #4,d0
        and.w   #3,d0
        cmp.w   #2,d0
        bne.s   .model
        move.l  #8580,opt_model
.model: lea     tab6581,a3
        cmp.l   #8580,opt_model
        bne.s   .tab
        lea     tab8580,a3
.tab:   move.l  a3,tab_base

        lea     filebuf+$16,a0          ; title, author, released
        bsr     print_field
        lea     filebuf+$36,a0
        bsr     print_field
        lea     filebuf+$56,a0
        bsr     print_field

        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        tst.l   d0
        bmi     nodsp
        Dsp_ExecBoot dsp_bootstrap_image,#DSP_BOOT_WORDS,#DSP_ABILITY
        clr.l   dsp_stage2_reply
        Dsp_BlkUnpacked dsp_program_image,#DSP_STAGE2_TRANSFER_WORDS,dsp_stage2_reply,#1
        cmp.l   #DSP_STAGE2_REPLY_OK,dsp_stage2_reply
        bne     nodsp

        Locksnd                         ; the sound bring-up (ratetest.s documents each step)
        Sndstatus #SNDSTAT_RESET
        Soundcmd #SOUND_LTATTEN,#0
        Soundcmd #SOUND_RTATTEN,#0
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        Setmontracks #SOUND_MONPAIR0
        Soundcmd #SOUND_ADDERIN,#SOUND_MATRIXIN
        Buffoper #SOUND_DMA_STOP
        Dsptristate #1,#0
        Devconnect #SOUND_DSP_XMIT,#SOUND_DAC,#SOUND_CLK25M,#SOUND_PRESCALE,#SOUND_NO_SHAKE

        clr.l   -(sp)                   ; Super(0): the host port and the 200 Hz tick need it
        move.w  #$20,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_ssp

        bsr     dsp_setup
        bsr     play

        move.l  old_ssp,-(sp)
        move.w  #$20,-(sp)
        trap    #1
        addq.l  #6,sp

        Dsptristate #0,#0
        Unlocksnd
        Dsp_Unlock

        tst.l   opt_verify
        beq.s   .bye
        Fcreate out_name,#0
        tst.l   d0
        bmi.s   .bye
        move.w  d0,handle
        Fwrite  handle,#8*4,results
        Fclose  handle
.bye:   Cconws  txt_done
        Pterm0

usage:  Cconws  txt_usage
        bra.s   wait_exit
nofile: Cconws  txt_nofile
        bra.s   wait_exit
notpsid:
        Cconws  txt_notpsid
        bra.s   wait_exit
nodsp:  Cconws  txt_nodsp
        Dsp_Unlock
wait_exit:                              ; from the desktop the screen is gone at once: wait for a key
        Cconws  txt_key
        Cconin
        Pterm0

; ------------------------------------------------------------ command line
; "path [song] [-m model] [-t seconds] [-v]", whitespace separated

parse:
        lea     cmdline,a0
        lea     path,a1
        bsr.s   .skip
.path:  move.b  (a0),d0
        beq.s   .pend
        cmp.b   #' ',d0
        bls.s   .pend
        move.b  d0,(a1)+
        addq.l  #1,a0
        bra.s   .path
.pend:  clr.b   (a1)
.next:  bsr.s   .skip
        move.b  (a0),d0
        beq.s   .done
        cmp.b   #'-',d0
        bne.s   .song
        move.b  1(a0),d1
        addq.l  #2,a0
        or.b    #$20,d1
        cmp.b   #'v',d1
        bne.s   .plain
        move.l  #1,opt_verify
        bra.s   .next
.plain: cmp.b   #'p',d1
        bne.s   .arg
        move.l  #1,opt_plain
        bra.s   .next
.arg:   bsr.s   .skip
        bsr.s   .number
        cmp.b   #'m',d1
        bne.s   .t
        move.l  d0,opt_model
        bra.s   .next
.t:     cmp.b   #'t',d1
        bne.s   .next
        move.l  d0,opt_seconds
        bra.s   .next
.song:  bsr.s   .number
        move.l  d0,opt_song
        bra.s   .next
.done:  rts
.skip:  move.b  (a0),d0
        beq.s   .sk
        cmp.b   #' ',d0
        bhi.s   .sk
        addq.l  #1,a0
        bra.s   .skip
.sk:    rts
.number:                                ; decimal at (a0) -> d0; stops at the first other character
        moveq   #0,d0
.digit: moveq   #0,d2
        move.b  (a0),d2
        sub.b   #'0',d2
        cmp.b   #9,d2
        bhi.s   .nend
        mulu.l  #10,d0
        add.l   d2,d0
        addq.l  #1,a0
        bra.s   .digit
.nend:  move.b  (a0),d2                 ; skip the rest of a token that is not a number
        beq.s   .nout
        cmp.b   #' ',d2
        bls.s   .nout
        addq.l  #1,a0
        bra.s   .nend
.nout:  rts

print_field:                            ; a0 -> 32 characters, not necessarily terminated
        lea     linebuf,a1
        moveq   #31,d0
.c:     move.b  (a0)+,d1
        beq.s   .e
        move.b  d1,(a1)+
        dbra    d0,.c
.e:     move.b  #13,(a1)+
        move.b  #10,(a1)+
        clr.b   (a1)
        Cconws  linebuf
        rts

; ------------------------------------------------------------ DSP set-up (supervisor)

; address, count, table offset: DSP_CMD_LOAD_X / _Y
        macro   LOADTAB cmd,addr,count,offset
        move.l  #\1,d0
        move.l  #\2,d1
        move.l  #\3,d2
        move.l  tab_base,a2
        add.l   #\4,a2
        bsr     load_table
        endm

dsp_setup:
        move.l  #DSP_CMD_PING,d0
        bsr     dsp_put
        bsr     dsp_get
        LOADTAB DSP_CMD_LOAD_X,DSP_X_RATE_TAB,16,SIDTAB_RATE
        LOADTAB DSP_CMD_LOAD_X,DSP_X_SUST_TAB,16,SIDTAB_SUST
        LOADTAB DSP_CMD_LOAD_X,DSP_X_ENV_TAB,512,SIDTAB_ENV
        LOADTAB DSP_CMD_LOAD_X,DSP_X_WAVE_DAC,4096,SIDTAB_WAVEDAC
        LOADTAB DSP_CMD_LOAD_Y,DSP_Y_BLEP,129,SIDTAB_BLEP
        LOADTAB DSP_CMD_LOAD_Y,DSP_Y_WAVE3,4096,SIDTAB_WAVE3
        LOADTAB DSP_CMD_LOAD_Y,DSP_Y_WAVE5,4096,SIDTAB_WAVE5
        LOADTAB DSP_CMD_LOAD_X,DSP_X_WAVE6,4096,SIDTAB_WAVE6
        LOADTAB DSP_CMD_LOAD_X_HI,DSP_X_WAVE7,4096,SIDTAB_WAVE7 ; (after table 6: into its upper bits)
        move.l  #DSP_CMD_CONFIG,d0
        bsr     dsp_put
        move.l  tab_base,a2
        moveq   #7-1,d3
.cfg:   move.l  (a2)+,d0
        bsr     dsp_put
        dbra    d3,.cfg
        bsr     dsp_get
        moveq   #0,d0                   ; the filter as the chip powers up: fc 0, res 0
        moveq   #0,d1
        move.l  tab_base,a0
        lea     coef,a1
        bsr     filter_coeffs
        move.l  #DSP_CMD_FILTER,d0
        bsr     dsp_put
        lea     coef,a2
        moveq   #DSP_FILTER_WORDS-1,d3
.coef:  move.l  (a2)+,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        dbra    d3,.coef
        bra     dsp_get

load_table:                             ; d0 = command, d1 = DSP address, d2 = count, a2 = longs
        bsr     dsp_put
        move.l  d1,d0
        bsr     dsp_put
        move.l  d2,d0
        bsr     dsp_put
        subq.l  #1,d2
.w:     move.l  (a2)+,d0
        bsr     dsp_put
        dbra    d2,.w
        bra     dsp_get

; d0.l = word (24 bits), paced on TXDE
dsp_put:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_put
        move.l  d0,DSP_HOST_DATA
        rts

; -> d0.l = word, paced on RXDF; the low byte is read last (it clears RXDF)
dsp_get:
        btst    #0,DSP_HOST_ISR
        beq.s   dsp_get
        moveq   #0,d0
        move.b  DSP_HOST_DATA+1,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+2,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+3,d0
        rts

; d0 = status index -> d0 = value
stream_read:
        move.l  d0,-(sp)
        move.l  #DSP_CMD_STREAM_READ,d0
        bsr     dsp_put
        move.l  (sp)+,d0
        bsr     dsp_put
        bra     dsp_get

; ------------------------------------------------------------ playing (supervisor)

play:
        movem.l d0-d7/a0-a6,-(sp)
        move.l  #$7fffffff,end_cycle    ; -t seconds: the tune time to play
        move.l  opt_seconds,d0
        beq.s   .noend
        mulu.l  #SID_CLOCK,d0
        move.l  d0,end_cycle
.noend: lea     cpu_state,a6
        move.l  #pend,pend_head
        move.l  #pend,pend_tail
        move.l  #DSP_STREAM_QUEUE,dsp_free
        clr.l   h_sent
        clr.l   clock32
        clr.l   clock24
        clr.l   gen_done
        clr.l   fc_now
        clr.l   res_now
        clr.l   fc_coef
        clr.l   res_coef
        clr.l   snap_done
        lea     reg_shadow,a0           ; no register has been written yet
        moveq   #24,d0
.shad:  move.w  #$ffff,(a0)+
        dbra    d0,.shad

        move.l  #DSP_CMD_STREAM_START,d0
        bsr     dsp_put
        bsr     dsp_get
        tst.l   opt_plain               ; the checksum is the gate's: without -v, or with -p, the DSP leaves it out
        bne.s   .nosum
        tst.l   opt_verify
        bne.s   .sum
.nosum: move.l  #DSP_CMD_STREAM_PLAIN,d0
        bsr     dsp_put
        bsr     dsp_get
.sum:
        move.l  HZ200.w,results+28

        bsr     log_reset               ; the init routine: its writes start at cycle 0
        bsr     psid_start
        move.l  d7,gen_cycle
        bsr     log_to_pend

.loop:  move.l  HZ200.w,d0              ; once per 5 ms tick
        cmp.l   last_tick,d0
        beq.s   .loop
        move.l  d0,last_tick

        moveq   #4,d0                   ; the DSP's render clock, extended to 32 bits
        bsr     stream_read
        move.l  d0,d1
        sub.l   clock24,d1
        and.l   #$ffffff,d1
        add.l   d1,clock32
        move.l  d0,clock24
        move.l  clock32,d6
        cmp.l   end_cycle,d6
        bcc     .finish

        tst.l   snap_done               ; the real-time counters, read while the stream is still fed
        bne.s   .gen
        move.l  d6,d0
        add.l   #SNAPSHOT_BEFORE,d0
        cmp.l   end_cycle,d0
        bcs.s   .gen
        moveq   #2,d0
        bsr     stream_read
        move.l  d0,results+8
        moveq   #5,d0
        bsr     stream_read
        move.l  d0,results+12
        move.l  #1,snap_done

.gen:   tst.l   gen_done                ; keep the tune generated GEN_LEAD cycles ahead of the clock
        bne.s   .push
        move.l  gen_cycle,d0
        sub.l   d6,d0
        cmp.l   #GEN_LEAD,d0
        bge.s   .push
        move.l  pend_tail,d0            ; (unless the queue to the DSP is badly behind)
        sub.l   #pend,d0
        cmp.l   #(MAX_PEND-MAX_LOG*(1+DSP_FILTER_WORDS))*12,d0
        bhi.s   .push
        bsr     log_reset
        move.l  gen_cycle,d7
        move.l  end_cycle,d5
        bsr     psid_frame
        tst.l   d0
        bpl.s   .ran
        move.l  #1,gen_done
        bra.s   .push
.ran:   move.l  d7,gen_cycle
        bsr     log_to_pend
        bra.s   .gen

.push:  bsr     push_pending
        move.w  #11,-(sp)               ; Cconis: a key stops
        trap    #1
        addq.l  #2,sp
        tst.w   d0
        beq     .loop
        move.w  #7,-(sp)                ; Crawcin: take it
        trap    #1
        addq.l  #2,sp

.finish:
        move.l  HZ200.w,d0
        sub.l   results+28,d0
        move.l  d0,results+28
        move.l  clock32,results
        moveq   #1,d0
        bsr     stream_read
        move.l  d0,results+4
        moveq   #6,d0
        bsr     stream_read
        move.l  d0,results+16
        moveq   #5,d0
        bsr     stream_read
        move.l  d0,results+20
        move.l  gen_cycle,results+24
        move.l  #DSP_CMD_STREAM_STOP,d0
        bsr     dsp_put
        bsr     dsp_get
        movem.l (sp)+,d0-d7/a0-a6
        rts

log_reset:
        move.l  #wlog,CPU_WLOG(a6)
        move.l  #wlog+MAX_LOG*12,CPU_WEND(a6)
        clr.l   CPU_WCOUNT(a6)
        rts

; The logged SID writes become queue entries (cycle, register, value); a write
; to the filter's cutoff or resonance is followed by the coefficient words as
; pseudo registers 32-39.
;
; A write that repeats the register's value and changes nothing in the model
; (src/ref/sid_ref.c, sid_ref_write) is not sent: tunes that rewrite every
; register several times a frame otherwise spend the DSP's time on it. That is
;   - frequency, attack/decay, sustain/release, the filter registers and the
;     volume: the write stores the same value, and what it derives from it
;     (rate period, coefficients) is a function of the stored values alone;
;   - the pulse width, while the voice's test and sync bits are clear and its
;     waveform is none or a single one: the write's only other effect is
;     pulse_output = (acc >> 12) >= pw, which is what every clock left there
;     (the test bit, a hard sync restart and the 6581's saw combinations are
;     the cases in which it is not).
; The control register is always sent.
log_to_pend:
        movem.l d0-d4/a0-a3,-(sp)
        lea     wlog,a2
        move.l  pend_tail,a3
        move.l  CPU_WCOUNT(a6),d4
        bra     .next
.entry: move.l  (a2)+,d2                ; cycle
        move.l  (a2)+,d3                ; register
        move.l  (a2)+,d0                ; value
        cmp.w   #24,d3
        bhi.s   .keep
        lea     reg_shadow,a0
        cmp.w   (a0,d3.w*2),d0
        bne.s   .new
        lea     reg_kind,a1
        move.b  (a1,d3.w),d1
        beq     .next                   ; nothing but the value: not sent
        bmi.s   .keep                   ; control
        ext.w   d1                      ; pulse width: d1 = the voice's control register
        move.w  (a0,d1.w*2),d1
        cmp.w   #$ff,d1
        bhi.s   .keep                   ; (not written yet)
        btst    #3,d1
        bne.s   .keep                   ; test
        btst    #1,d1
        bne.s   .keep                   ; sync
        lsr.w   #4,d1
        lea     wave_single,a1
        tst.b   (a1,d1.w)
        bne     .next
        bra.s   .keep
.new:   move.w  d0,(a0,d3.w*2)
.keep:  move.l  d2,(a3)+
        move.l  d3,(a3)+
        move.l  d0,(a3)+
        cmp.w   #21,d3
        bcs     .next
        cmp.w   #23,d3
        bhi     .next
        bne.s   .fc
        lsr.l   #4,d0                   ; $17: resonance in the high nibble
        move.l  d0,res_now
        bra.s   .coef
.fc:    cmp.w   #21,d3
        bne.s   .fchi
        and.l   #7,d0                   ; $15: fc bits 2-0
        move.l  fc_now,d1
        and.l   #$7f8,d1
        or.l    d0,d1
        move.l  d1,fc_now
        bra.s   .coef
.fchi:  lsl.l   #3,d0                   ; $16: fc bits 10-3
        move.l  fc_now,d1
        and.l   #7,d1
        or.l    d0,d1
        move.l  d1,fc_now
.coef:  move.l  fc_now,d0
        move.l  res_now,d1
        cmp.l   fc_coef,d0
        bne.s   .changed
        cmp.l   res_coef,d1
        beq     .next                   ; original SID write remains queued; coefficients are already current
.changed:
        move.l  d0,fc_coef
        move.l  d1,res_coef
        move.l  tab_base,a0
        lea     coef,a1
        bsr     filter_coeffs
        moveq   #32,d3
.cw:    move.l  d2,(a3)+
        move.l  d3,(a3)+
        move.l  (a1)+,d0
        and.l   #$ffffff,d0
        move.l  d0,(a3)+
        addq.l  #1,d3
        cmp.w   #32+DSP_FILTER_WORDS,d3
        bne.s   .cw
.next:  subq.l  #1,d4
        bpl     .entry
        move.l  a3,pend_tail
        movem.l (sp)+,d0-d4/a0-a3
        rts

; Send what fits of the waiting entries, with the horizon: the cycle below
; which the DSP may start frames, 21 below the first cycle not yet sent.
push_pending:
        movem.l d0-d4/a0,-(sp)
        move.l  pend_head,a0
        move.l  pend_tail,d2
        sub.l   a0,d2
        divu.l  #12,d2                  ; entries waiting
        beq.s   .count
        tst.l   dsp_free
        bne.s   .count
        moveq   #3,d0                   ; the queue was full at the last push: ask again
        bsr     stream_read
        move.l  #DSP_STREAM_QUEUE,d1
        sub.l   d0,d1
        move.l  d1,dsp_free
.count: move.l  d2,d3                   ; entries in this push
        cmp.l   dsp_free,d3
        bls.s   .c1
        move.l  dsp_free,d3
.c1:    cmp.l   #PUSH_MAX,d3
        bls.s   .c2
        move.l  #PUSH_MAX,d3
.c2:    cmp.l   d2,d3
        beq.s   .all
        move.l  d3,d0                   ; some stay behind: the horizon stops before the first of them
        mulu.l  #12,d0
        move.l  (a0,d0.l),d4
        sub.l   #21,d4
        bra.s   .hor
.all:   move.l  end_cycle,d4            ; everything generated is sent
        tst.l   gen_done
        bne.s   .hor
        move.l  gen_cycle,d4
        sub.l   #21,d4
.hor:   cmp.l   h_sent,d4               ; (never backwards)
        bge.s   .h
        move.l  h_sent,d4
.h:     tst.l   d3
        bne.s   .send
        cmp.l   h_sent,d4
        beq.s   .out                    ; nothing new
.send:  move.l  #DSP_CMD_STREAM_PUSH,d0
        bsr     dsp_put
        move.l  d3,d0
        bsr     dsp_put
        bra.s   .enext
.entry: move.l  (a0)+,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        move.l  (a0)+,d0
        bsr     dsp_put
        move.l  (a0)+,d0
        bsr     dsp_put
.enext: dbra    d3,.entry
        move.l  d4,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        bsr     dsp_get
        move.l  d0,dsp_free
        move.l  d4,h_sent
        cmp.l   pend_tail,a0            ; all sent: the buffer starts over
        bne.s   .keep
        move.l  #pend,a0
        move.l  a0,pend_tail
.keep:  move.l  a0,pend_head
.out:   movem.l (sp)+,d0-d4/a0
        rts

        include "cpu6502.s"
        include "psid.s"
        include "filtcoef.s"

        data

banner:         dc.b    13,10,'F030SID',13,10,0
txt_usage:      dc.b    'usage: F030SID.TTP tune.sid [song] [-m 6581|8580] [-t seconds] [-v]',13,10,0
txt_nofile:     dc.b    'cannot open the tune',13,10,0
txt_notpsid:    dc.b    'not a PSID file',13,10,0
txt_nodsp:      dc.b    'the DSP did not start',13,10,0
txt_done:       dc.b    'done',13,10,0
txt_key:        dc.b    'press a key',13,10,0
inf_name:       dc.b    'AUTOPLAY.INF',0
out_name:       dc.b    'PLAYOUT.BIN',0
; per register 0-24, for a write that repeats the value: 0 = not sent, -1 = sent,
; else the voice's control register (pulse width: see log_to_pend)
reg_kind:       dc.b    0,0,4,4,-1,0,0, 0,0,11,11,-1,0,0, 0,0,18,18,-1,0,0, 0,0,0,0
wave_single:    dc.b    1,1,1,0,1,0,0,0,1,0,0,0,0,0,0,0 ; waveform 0, 1, 2, 4, 8
        even
tab6581:        incbin  "sidtab_6581.bin"
tab8580:        incbin  "sidtab_8580.bin"

        include "dsp_stage2_image.i"

        bss

dsp_stage2_reply: ds.l  1
old_ssp:        ds.l    1
tab_base:       ds.l    1
file_len:       ds.l    1
opt_song:       ds.l    1
opt_model:      ds.l    1
opt_seconds:    ds.l    1
opt_verify:     ds.l    1
opt_plain:      ds.l    1
end_cycle:      ds.l    1
gen_cycle:      ds.l    1               ; 6510 cycles run: every write below it is known
gen_done:       ds.l    1
clock32:        ds.l    1
clock24:        ds.l    1
h_sent:         ds.l    1
dsp_free:       ds.l    1
last_tick:      ds.l    1
snap_done:      ds.l    1
reg_shadow:     ds.w    25              ; the registers as last sent ($ffff: not yet)
        even
fc_now:         ds.l    1
res_now:        ds.l    1
fc_coef:        ds.l    1
res_coef:       ds.l    1
pend_head:      ds.l    1
pend_tail:      ds.l    1
coef:           ds.l    DSP_FILTER_WORDS
results:        ds.l    8
handle:         ds.w    1
cmdline:        ds.b    130
path:           ds.b    130
linebuf:        ds.b    40
        even
cpu_state:      ds.b    CPU_STATE_SIZE
filebuf:        ds.b    FILE_MAX
ram:            ds.b    65536+256+16
wlog:           ds.l    MAX_LOG*3
pend:           ds.l    MAX_PEND*3

        end
