; F030SID DSP kernel (bring-up skeleton)
;
; Standalone Dsp_ExecBoot image: it must fit the 512-word internal P RAM and
; begin at P:$0000. Today it only owns the SID register file and answers the
; host protocol; voice, envelope, filter and SSI output code land here as the
; emulation grows (see docs/architecture.md). Once the kernel outgrows 512
; words, switch it to the two-stage path (stage2_loader.asm +
; tools/generate_dsp_stage2.py --bootstrap/--program) exactly as F030MXDRV does.

        include 'ioequ.inc'
        include 'protocol.inc'

SID_REGS        equ     $0000           ; X:$0000-$001f, indexed by SID address

        org     p:$0000
        jmp     sid_start

        org     p:$0040
sid_start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        jsr     sid_clear_regs

sid_loop:
        jclr    #0,x:m_hsr,sid_loop     ; HRDF: a command word arrived
        movep   x:m_hrx,a
        move    #>DSP_CMD_PING,x0
        cmp     x0,a
        jeq     sid_cmd_ping
        move    #>DSP_CMD_WRITE_REG,x0
        cmp     x0,a
        jeq     sid_cmd_write
        move    #>DSP_CMD_READ_REG,x0
        cmp     x0,a
        jeq     sid_cmd_read
        move    #>DSP_CMD_RESET,x0
        cmp     x0,a
        jeq     sid_cmd_reset
        move    #>DSP_REPLY_ERROR,a
        jmp     sid_reply

sid_cmd_ping:
        move    #>DSP_REPLY_HELLO,a
        jmp     sid_reply

; reg, value. The value word is consumed even when the register is invalid so
; the host stream stays aligned.
sid_cmd_write:
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,y1
        move    x1,a
        move    #>DSP_SID_REG_COUNT,x0
        cmp     x0,a
        jge     sid_cmd_error
        move    x1,r0
        nop
        move    y1,x:(r0)
        clr     a
        jmp     sid_reply

sid_cmd_read:
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        move    x1,a
        move    #>DSP_SID_REG_COUNT,x0
        cmp     x0,a
        jge     sid_cmd_error
        move    x1,r0
        nop
        move    x:(r0),a
        jmp     sid_reply

sid_cmd_reset:
        jsr     sid_clear_regs
        clr     a
        jmp     sid_reply

sid_cmd_error:
        move    #>DSP_REPLY_ERROR,a
sid_reply:
        jclr    #1,x:m_hsr,*            ; HTDE: host consumed the last reply
        movep   a1,x:m_htx
        jmp     sid_loop

sid_clear_regs:
        move    #SID_REGS,r0
        clr     a
        rep     #DSP_SID_REG_COUNT
        move    a,x:(r0)+
        rts

        end
