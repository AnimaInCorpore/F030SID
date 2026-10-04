; F030SID SSI stream test
;
; Boots the DSP kernel, loads its tables, routes the DSP transmitter to the DAC
; at 49.17 kHz and plays one test vector (voicetest_vec.i from tools/dsp/make_vec)
; through the kernel's stream: the register writes go out stamped with their SID
; cycle, a PAL frame ahead of the DSP's render clock, as the player will send
; them. Afterwards the DSP's stream status is written to STREAM.BIN (big-endian
; longs: final render clock, checksum, least ring fill and overtakes while fed,
; SSI underrun flag, overtakes at the end, pushes, 200 Hz ticks taken). tools/dsp/stream_gate.py
; compares frames and checksum with the reference model's and requires that the
; transmitter never caught up with the renderer and that the run took the
; frames' playing time.

        include "xbios.i"
        include "protocol.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3

DSP_HOST_ISR    equ     $ffffa202
DSP_HOST_DATA   equ     $ffffa204

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

LEAD_CYCLES     equ     19656           ; a PAL frame: the host keeps one to two of them released
BATCH_MAX       equ     200             ; queue entries per push
SNAPSHOT_BEFORE equ     40000           ; cycles before the end at which the real-time counters are read

; Load `count` words from `table` into DSP X (LOADX) or Y (LOADY) memory at `addr`.
        macro   LOADX addr,count,table
        move.l  #DSP_CMD_LOAD_X,d0
        bsr     dsp_put
        move.l  #\1,d0
        bsr     dsp_put
        move.l  #\2,d0
        bsr     dsp_put
        lea     \3,a2
        move.w  #\2-1,d3
lx\@:   move.l  (a2)+,d0
        bsr     dsp_put
        dbra    d3,lx\@
        bsr     dsp_get
        endm

        macro   LOADY addr,count,table
        move.l  #DSP_CMD_LOAD_Y,d0
        bsr     dsp_put
        move.l  #\1,d0
        bsr     dsp_put
        move.l  #\2,d0
        bsr     dsp_put
        lea     \3,a2
        move.w  #\2-1,d3
ly\@:   move.l  (a2)+,d0
        bsr     dsp_put
        dbra    d3,ly\@
        bsr     dsp_get
        endm

        text

start:
        Cconws  banner

        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        tst.l   d0
        bmi     fail
        Dsp_ExecBoot dsp_bootstrap_image,#DSP_BOOT_WORDS,#DSP_ABILITY
        clr.l   dsp_stage2_reply
        Dsp_BlkUnpacked dsp_program_image,#DSP_STAGE2_TRANSFER_WORDS,dsp_stage2_reply,#1
        cmp.l   #DSP_STAGE2_REPLY_OK,dsp_stage2_reply
        bne     fail

        Locksnd                         ; the player's sound bring-up (see ratetest.s for why each step)
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

        Supexec run_stream

        Dsptristate #0,#0
        Unlocksnd

        Fcreate out_name,#0
        tst.l   d0
        bmi     fail
        move.w  d0,out_handle
        Fwrite  out_handle,#8*4,results
        Fclose  out_handle
        Cconws  done
        bra.s   exit
fail:
        Cconws  failed
exit:
        Dsp_Unlock
        Pterm0

; ------------------------------------------------------------ supervisor code

run_stream:
        movem.l d0-d7/a0-a6,-(sp)
        move.l  #DSP_CMD_PING,d0
        bsr     dsp_put
        bsr     dsp_get
        LOADX   DSP_X_RATE_TAB,16,tab_rate
        LOADX   DSP_X_SUST_TAB,16,tab_sust
        LOADX   DSP_X_ENV_TAB,512,tab_env
        LOADX   DSP_X_WAVE_DAC,4096,tab_wavedac
        LOADY   DSP_Y_WAVE3,4096,tab_wave3
        LOADY   DSP_Y_WAVE5,4096,tab_wave5
        LOADX   DSP_X_WAVE6,4096,tab_wave6
        LOADX   DSP_X_WAVE7,4096,tab_wave7
        move.l  #DSP_CMD_CONFIG,d0
        bsr     dsp_put
        move.l  #cfg_wave_zero,d0
        bsr     dsp_put
        move.l  #cfg_ttl_start,d0
        bsr     dsp_put
        move.l  #cfg_model,d0
        bsr     dsp_put
        move.l  #cfg_sr_start,d0
        bsr     dsp_put
        move.l  #cfg_hp_cancel,d0
        bsr     dsp_put
        move.l  #cfg_mix_k,d0
        bsr     dsp_put
        move.l  #cfg_filter_gain,d0
        bsr     dsp_put
        bsr     dsp_get
        lea     vec_coef0,a2
        bsr     send_coef


        move.l  #DSP_CMD_STREAM_START,d0
        bsr     dsp_put
        bsr     dsp_get

        move.l  $4ba.w,results+28       ; the 200 Hz tick, to time the run
        lea     vec_stream,a0           ; next write to send
        moveq   #0,d5                   ; horizon sent
        moveq   #0,d6                   ; render clock, extended to 32 bits
        moveq   #0,d7                   ; its last 24-bit reading
        clr.l   snap_done
feed_loop:
        move.l  $4ba.w,d0               ; once per 5 ms tick, as a player's timer would
        cmp.l   last_tick,d0
        beq.s   feed_loop
        move.l  d0,last_tick
        moveq   #4,d0                   ; the DSP's render clock
        bsr     stream_read
        move.l  d0,d1
        sub.l   d7,d1
        and.l   #$ffffff,d1
        add.l   d1,d6
        move.l  d0,d7
        cmp.l   #vec_end,d6
        bhs     feed_done

        tst.l   snap_done               ; the real-time counters, read while the stream is still fed
        bne.s   .fed
        move.l  d6,d0
        add.l   #SNAPSHOT_BEFORE,d0
        cmp.l   #vec_end,d0
        blo.s   .fed
        moveq   #2,d0
        bsr     stream_read
        move.l  d0,results+8
        moveq   #5,d0
        bsr     stream_read
        move.l  d0,results+12
        move.l  #1,snap_done
.fed:
        move.l  d5,d0                   ; less than a PAL frame released ahead of the clock:
        sub.l   d6,d0                   ; send the next frame's writes
        cmp.l   #LEAD_CYCLES,d0
        bge     feed_loop
        move.l  d5,d4
        add.l   #LEAD_CYCLES,d4
        cmp.l   #vec_end,d4
        bls.s   .hor
        move.l  #vec_end,d4
.hor:
        moveq   #3,d0                   ; queue entries in use
        bsr     stream_read
        move.l  #DSP_STREAM_QUEUE,d2
        sub.l   d0,d2                   ; free
        cmp.l   #BATCH_MAX,d2
        bls.s   .cap
        moveq   #BATCH_MAX,d2
.cap:
        move.l  d4,d1
        add.l   #21,d1                  ; every write below horizon + 21 must go with it
        moveq   #0,d3                   ; entries in this push
        movea.l a0,a2
.count: cmp.l   (a2),d1
        bls.s   .counted                ; this write is later
        cmp.l   d2,d3
        bhs.s   .short                  ; no room: the horizon stops before it
        addq.l  #1,d3
        lea     12(a2),a2
        bra.s   .count
.short: move.l  (a2),d4
        sub.l   #21,d4
.counted:
        tst.l   d3
        bne.s   .push
        cmp.l   d5,d4
        beq     feed_loop               ; nothing new
.push:
        move.l  #DSP_CMD_STREAM_PUSH,d0
        bsr     dsp_put
        move.l  d3,d0
        bsr     dsp_put
        bra.s   .next
.entry: move.l  (a0)+,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        move.l  (a0)+,d0
        bsr     dsp_put
        move.l  (a0)+,d0
        bsr     dsp_put
.next:  dbra    d3,.entry
        move.l  d4,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        bsr     dsp_get
        move.l  d4,d5
        addq.l  #1,results+24
        bra     feed_loop

feed_done:
        move.l  $4ba.w,d0
        sub.l   results+28,d0
        move.l  d0,results+28           ; ticks the stream took
        move.l  d6,results              ; the render clock at the end
        moveq   #1,d0
        bsr     stream_read
        move.l  d0,results+4
        moveq   #6,d0
        bsr     stream_read
        move.l  d0,results+16
        moveq   #5,d0
        bsr     stream_read
        move.l  d0,results+20
        move.l  #DSP_CMD_STREAM_STOP,d0
        bsr     dsp_put
        bsr     dsp_get
        movem.l (sp)+,d0-d7/a0-a6
        rts

; d0 = status index -> d0 = value
stream_read:
        move.l  d0,-(sp)
        move.l  #DSP_CMD_STREAM_READ,d0
        bsr     dsp_put
        move.l  (sp)+,d0
        bsr     dsp_put
        bra     dsp_get

; a2 -> four longs (a1, a2, a3, k4): DSP_CMD_FILTER
send_coef:
        move.l  #DSP_CMD_FILTER,d0
        bsr     dsp_put
        moveq   #3,d3
sc_loop:
        move.l  (a2)+,d0
        and.l   #$ffffff,d0
        bsr     dsp_put
        dbra    d3,sc_loop
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

        data

banner:         dc.b    13,10,'F030SID stream test',13,10,0
done:           dc.b    'done',13,10,0
failed:         dc.b    'FAILED',13,10,0
out_name:       dc.b    'STREAM.BIN',0
        even

        include "voicetest_vec.i"
        include "dsp_stage2_image.i"

        bss

dsp_stage2_reply: ds.l 1
out_handle:     ds.w 1
snap_done:      ds.l 1
last_tick:      ds.l 1
results:        ds.l 8

        end
