; F030SID DSP kernel test harness
;
; Boots the DSP kernel, loads its tables, replays the register writes of one
; test vector (build/gate/voicetest_vec.i, written by tools/dsp/make_vec) one
; codec frame at a time, and writes the DSP's three voice outputs and the chip output of every frame to
; VOICEOUT.BIN as big-endian 32-bit signed integers. tools/dsp/voice_dsp_gate.py compares
; that file with the C reference model's output.
;
; The host port is driven directly in supervisor mode, every word paced on
; TXDE/RXDF, as in the player: TOS's Dsp_BlkUnpacked only paces its first
; word and loses words to code running from external P RAM.

        include "xbios.i"
        include "protocol.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3
MAX_FRAMES      equ     40000
WORDS_PER_FRAME equ     4
COEF_WORDS      equ     DSP_FILTER_WORDS

DSP_HOST_ISR    equ     $ffffa202
DSP_HOST_DATA   equ     $ffffa204

; Load `count` words from `table` into DSP X (LOADX) or Y (LOADY) memory at `addr`.
        macro   LOADX addr,count,table
        LOADC   DSP_CMD_LOAD_X,\1,\2,\3
        endm
        macro   LOADC cmd,addr,count,table
        move.l  #\1,d0
        bsr     dsp_put
        move.l  #\2,d0
        bsr     dsp_put
        move.l  #\3,d0
        bsr     dsp_put
        lea     \4,a2
        move.w  #\3-1,d3
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

        Supexec run_vector

        Fcreate out_name,#0
        tst.l   d0
        bmi     fail
        move.w  d0,out_handle
        Fwrite  out_handle,#vec_frames*16,outbuf
        Fclose  out_handle
        Cconws  done
        bra.s   exit
fail:
        Cconws  failed
exit:
        Dsp_Unlock
        Pterm0

; ------------------------------------------------------------ supervisor code

run_vector:
        movem.l d0-d7/a0-a6,-(sp)
        move.l  #DSP_CMD_PING,d0
        bsr     dsp_put
        bsr     dsp_get
        LOADX   DSP_X_RATE_TAB,16,tab_rate
        LOADX   DSP_X_SUST_TAB,16,tab_sust
        LOADX   DSP_X_ENV_TAB,512,tab_env
        LOADX   DSP_X_WAVE_DAC,4096,tab_wavedac
        LOADY   DSP_Y_BLEP,129,tab_blep
        LOADY   DSP_Y_WAVE3,4096,tab_wave3
        LOADY   DSP_Y_WAVE5,4096,tab_wave5
        LOADX   DSP_X_WAVE6,4096,tab_wave6
        LOADC   DSP_CMD_LOAD_X_HI,DSP_X_WAVE7,4096,tab_wave7   ; (after table 6: into its upper bits)
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

        lea     vec_events,a0
        lea     outbuf,a1
        moveq   #1,d4                   ; frame number
        move.l  #vec_frames,d5
frame_loop:
ev_loop:
        cmp.l   (a0),d4
        bne.s   ev_done
        move.l  #DSP_CMD_WRITE_REG,d0
        bsr     dsp_put
        move.l  4(a0),d0
        bsr     dsp_put
        move.l  8(a0),d0
        bsr     dsp_put
        bsr     dsp_get
        move.l  4(a0),d0
        cmp.l   #21,d0                  ; fc and res/routing changes carry new filter coefficients
        blt.s   ev_next
        cmp.l   #23,d0
        bgt.s   ev_next
        lea     12(a0),a2
        bsr     send_coef
ev_next:
        lea     12+4*COEF_WORDS(a0),a0
        bra.s   ev_loop
ev_done:
        move.l  #DSP_CMD_FRAME,d0
        bsr     dsp_put
        moveq   #3,d6                   ; the three voice outputs and the chip output
frame_out:
        bsr     dsp_get
        lsl.l   #8,d0                   ; sign-extend the 24-bit word
        asr.l   #8,d0
        move.l  d0,(a1)+
        dbra    d6,frame_out
        addq.l  #1,d4
        cmp.l   d5,d4
        ble.s   frame_loop
        movem.l (sp)+,d0-d7/a0-a6
        rts

; a2 -> the coefficient words: DSP_CMD_FILTER
send_coef:
        move.l  #DSP_CMD_FILTER,d0
        bsr     dsp_put
        moveq   #COEF_WORDS-1,d3
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

banner:         dc.b    13,10,'F030SID voice test',13,10,0
done:           dc.b    'done',13,10,0
failed:         dc.b    'FAILED',13,10,0
out_name:       dc.b    'VOICEOUT.BIN',0
        even

; The vector and the DSP image are data: a TOS program starts at the first
; byte of its text segment, so nothing but code may precede `start`.
        include "voicetest_vec.i"
        include "dsp_stage2_image.i"

        bss

dsp_stage2_reply: ds.l 1
out_handle:     ds.w 1
outbuf:         ds.l MAX_FRAMES*WORDS_PER_FRAME

        end
