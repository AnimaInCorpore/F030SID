; F030SID host bring-up
;
; Boots the DSP kernel, checks the host-port protocol round trip and the SID
; register shadow, prints the verdict, and exits. The 6502/PSID host, the SID
; register write stream and the SSI audio path are still to come; this file
; fixes the build, boot and handshake structure they hang off.

        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  start
        ifd     VERBOSE_BOOT
        global  vb_hex
        global  vb_string
        endc

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3

        text

start:
        Cconws  banner

        VB      vb_txt_reserve
        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        tst.l   d0
        bmi     reserve_failed

        ; XBIOS boots at most 512 contiguous internal-P words: install the
        ; stage-two loader there, then stream the sparse kernel to it. The
        ; loader acknowledges once every section is resident and enters it.
        VB      vb_txt_execboot
        Dsp_ExecBoot dsp_bootstrap_image,#DSP_BOOT_WORDS,#DSP_ABILITY
        clr.l   dsp_stage2_reply
        Dsp_BlkUnpacked dsp_program_image,#DSP_STAGE2_TRANSFER_WORDS,dsp_stage2_reply,#1
        cmp.l   #DSP_STAGE2_REPLY_OK,dsp_stage2_reply
        bne     fail

        Cconws  txt_ping
        move.w  #1,tx_count
        move.l  #DSP_CMD_PING,tx_words
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     fail
        Cconws  txt_ok

        Cconws  txt_regs
        move.w  #3,tx_count             ; WRITE_REG $04 <- $000041
        move.l  #DSP_CMD_WRITE_REG,tx_words
        move.l  #$04,tx_words+4
        move.l  #$41,tx_words+8
        bsr     dsp_exchange
        tst.l   d0
        bne     fail
        move.w  #2,tx_count             ; READ_REG $04
        move.l  #DSP_CMD_READ_REG,tx_words
        move.l  #$04,tx_words+4
        bsr     dsp_exchange
        cmp.l   #$41,d0
        bne     fail
        Cconws  txt_ok

        Cconws  txt_pass
        bra.s   done
reserve_failed:
fail:
        Cconws  txt_fail
done:
        Dsp_Unlock
        Cconin
        Pterm0

; Send tx_count packed words from tx_words, return the single reply in d0.l.
dsp_exchange:
        movem.l d1-d7/a0-a6,-(sp)
        clr.l   rx_word
        moveq   #0,d0
        move.w  tx_count,d0
        Dsp_BlkUnpacked tx_words,d0,rx_word,#1
        move.l  rx_word,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

        ifd     VERBOSE_BOOT
; Print d0.l as eight hex digits plus CRLF, preserving every register.
vb_hex:
        movem.l d0-d3/a0-a2,-(sp)
        lea     vb_hexbuf+8,a0
        clr.b   (a0)
        moveq   #7,d2
vb_hex_digit:
        move.b  d0,d1
        and.b   #$0f,d1
        add.b   #'0',d1
        cmp.b   #'9',d1
        ble.s   vb_hex_store
        addq.b  #7,d1
vb_hex_store:
        move.b  d1,-(a0)
        lsr.l   #4,d0
        dbra    d2,vb_hex_digit
        Cconws  vb_hexbuf
        Cconws  vb_crlf
        movem.l (sp)+,d0-d3/a0-a2
        rts

; Print the NUL-terminated string at a0 plus CRLF.
vb_string:
        movem.l d0-d2/a0-a2,-(sp)
        move.l  a0,-(sp)
        move.w  #9,-(sp)
        trap    #1
        addq.l  #6,sp
        Cconws  vb_crlf
        movem.l (sp)+,d0-d2/a0-a2
        rts
        endc

        data

banner:         dc.b    13,10,'F030SID bring-up',13,10,0
txt_ping:       dc.b    'DSP ping .......... ',0
txt_regs:       dc.b    'SID reg shadow .... ',0
txt_ok:         dc.b    'ok',13,10,0
txt_pass:       dc.b    'PASS',13,10,0
txt_fail:       dc.b    'FAIL',13,10,0
vb_txt_reserve: dc.b    'Dsp_Reserve      ',0
vb_txt_execboot: dc.b   'Dsp_ExecBoot     ',0
vb_crlf:        dc.b    13,10,0
        even

        include "dsp_stage2_image.i"

        bss

tx_words:       ds.l 8
rx_word:        ds.l 1
dsp_stage2_reply: ds.l 1
tx_count:       ds.w 1
vb_hexbuf:      ds.b 10

        end
