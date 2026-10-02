; F030SID DSP kernel
;
; Milestone 1: voice 0 of the reference model (src/ref/sid_ref.c), bit for bit
; against the C model for waveforms none/triangle/saw/pulse, the test bit, the
; exact ADSR state machine, and the 24-bit output (wave DAC - zero) * envelope
; DAC. Frame by frame on host request (DSP_CMD_FRAME); the SSI stream, noise,
; combined waveforms, sync/ring, voices 2-3, the filter and band-limiting
; follow in later milestones. See docs/dsp-kernel.md.
;
; Loaded in two stages: a 512-word bootstrap (stage2_loader.asm) installs this
; sparse program, which may extend into external P RAM, and jumps to P:$0000.
; The host then loads the tables with DSP_CMD_LOAD_X.
;
; Register conventions: a, b, x0, x1, y0, r0, r1, n0, n1 are scratch;
; y1 holds the written value across the write_reg handlers.

        include 'ioequ.inc'
        include 'protocol.inc'

ST_ATTACK       equ     0
ST_DECSUS       equ     1
ST_RELEASE      equ     2

; Fractional part of the cycles per codec frame, Q24: SID_CYC_Q24 & $ffffff
; (SID_CYC_Q24 = 336175407 = 20.0376 * 2^24, see src/ref/sid_ref.h).
EPS_INC         equ     $09a12f

; X internal scalars ($00-$3f, short-addressed)
S_ACC           equ     $00             ; 24-bit phase at the frame's integer cycle
S_FREQ          equ     $01
S_PW            equ     $02
S_PULSE         equ     $03             ; pulse_output: $fff or 0
S_WAVEFORM      equ     $04             ; control bits 7..4
S_TEST          equ     $05             ; control bit 3 (8 or 0)
S_WAVEOUT       equ     $06             ; 12-bit waveform code
S_TTL           equ     $07             ; floating output countdown
S_EPS           equ     $08             ; Q24 sample-instant fraction
S_ZERO          equ     $09             ; wave zero level (config)
S_TTLSTART      equ     $0a             ; floating TTL start (config)
S_RATECNT       equ     $0b             ; envelope rate counter (15 bit)
S_RATEPER       equ     $0c
S_EXPCNT        equ     $0d
S_EXPPER        equ     $0e
S_ENVCNT        equ     $0f             ; envelope counter (8 bit)
S_HOLD          equ     $10
S_STATE         equ     $11
S_NEXT          equ     $12
S_PIPE          equ     $13
S_ATTACK        equ     $14
S_DECAY         equ     $15
S_SUSTAIN       equ     $16
S_RELEASE       equ     $17
S_GATE          equ     $18
S_N             equ     $19             ; cycles in this frame
S_TMPDT         equ     $1a
S_TMPSTEP       equ     $1b
S_TMPA          equ     $1c
S_TMPB          equ     $1d
S_SHADOW        equ     $60             ; 32-word register shadow

        org     p:$0000
        jmp     start

        org     p:$0080                 ; P:$0040-$007f belongs to the stage-two loader
start:
        movep   #0,x:m_bcr              ; reset leaves external memory at 15 wait states
        movep   #1,x:m_pbc              ; enable the Falcon host port
        jsr     reset_state

main_loop:
        jclr    #0,x:m_hsr,main_loop    ; HRDF: a command word arrived
        movep   x:m_hrx,a
        move    #>DSP_CMD_FRAME,x0
        cmp     x0,a
        jeq     cmd_frame
        move    #>DSP_CMD_WRITE_REG,x0
        cmp     x0,a
        jeq     cmd_write
        move    #>DSP_CMD_LOAD_X,x0
        cmp     x0,a
        jeq     cmd_load
        move    #>DSP_CMD_CONFIG,x0
        cmp     x0,a
        jeq     cmd_config
        move    #>DSP_CMD_PING,x0
        cmp     x0,a
        jeq     cmd_ping
        move    #>DSP_CMD_READ_REG,x0
        cmp     x0,a
        jeq     cmd_read
        move    #>DSP_CMD_RESET,x0
        cmp     x0,a
        jeq     cmd_reset
reply_error:
        move    #>DSP_REPLY_ERROR,a
        jmp     reply
cmd_ping:
        move    #>DSP_REPLY_HELLO,a
        jmp     reply
cmd_reset:
        jsr     reset_state
reply_ok:
        clr     a
reply:                                  ; a1 = reply word
        jclr    #1,x:m_hsr,*            ; HTDE: host consumed the last reply
        movep   a1,x:m_htx
        jmp     main_loop

; ---------------------------------------------------------------- host side

cmd_load:                               ; address, count, words
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        move    x1,r0
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        do      x1,load_done
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x:(r0)+
load_done:
        jmp     reply_ok

cmd_config:                             ; wave zero level, floating TTL start
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x0
        move    x0,x:<S_ZERO
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x0
        move    x0,x:<S_TTLSTART
        jmp     reply_ok

cmd_read:                               ; reg -> shadow value
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        move    x1,a
        move    #>31,x0
        cmp     x0,a
        jgt     reply_error
        move    x1,n0
        move    #>S_SHADOW,r0
        nop
        move    x:(r0+n0),a
        jmp     reply

cmd_write:                              ; reg, value
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,y1
        move    x1,a
        move    #>31,x0
        cmp     x0,a
        jgt     reply_ok                ; not a SID register
        move    x1,n0
        move    #>S_SHADOW,r0
        nop
        move    y1,x:(r0+n0)            ; shadow for READ_REG
        move    x1,a
        tst     a
        jeq     wr_freq_lo
        move    #>1,x0
        cmp     x0,a
        jeq     wr_freq_hi
        move    #>2,x0
        cmp     x0,a
        jeq     wr_pw_lo
        move    #>3,x0
        cmp     x0,a
        jeq     wr_pw_hi
        move    #>4,x0
        cmp     x0,a
        jeq     wr_control
        move    #>5,x0
        cmp     x0,a
        jeq     wr_ad
        move    #>6,x0
        cmp     x0,a
        jeq     wr_sr
        jmp     reply_ok                ; voices 2 and 3, filter: later milestones

wr_freq_lo:
        move    x:<S_FREQ,a
        move    #>$ff00,x0
        and     x0,a
        move    y1,x0
        or      x0,a
        move    a1,x:<S_FREQ
        jmp     reply_ok

wr_freq_hi:
        move    x:<S_FREQ,a
        move    #>$ff,x0
        and     x0,a
        move    y1,b
        rep     #8
        asl     b
        move    b1,x0
        or      x0,a
        move    a1,x:<S_FREQ
        jmp     reply_ok

wr_pw_lo:
        move    x:<S_PW,a
        move    #>$f00,x0
        and     x0,a
        move    y1,x0
        or      x0,a
        move    a1,x:<S_PW
        jsr     calc_pulse_out
        jmp     reply_ok

wr_pw_hi:
        move    x:<S_PW,a
        move    #>$ff,x0
        and     x0,a
        move    y1,b
        rep     #8
        asl     b
        move    #>$f00,x0
        and     x0,b
        move    b1,x0
        or      x0,a
        move    a1,x:<S_PW
        jsr     calc_pulse_out
        jmp     reply_ok

wr_ad:
        move    y1,a
        rep     #4
        lsr     a
        move    a1,x:<S_ATTACK
        move    y1,a
        move    #>$f,x0
        and     x0,a
        move    a1,x:<S_DECAY
        move    x:<S_STATE,a
        tst     a
        jne     wad_notatk
        move    x:<S_ATTACK,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
        jmp     reply_ok
wad_notatk:
        move    #>ST_DECSUS,x0
        cmp     x0,a
        jne     reply_ok
        move    x:<S_DECAY,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
        jmp     reply_ok

wr_sr:
        move    y1,a
        rep     #4
        lsr     a
        move    a1,x:<S_SUSTAIN
        move    y1,a
        move    #>$f,x0
        and     x0,a
        move    a1,x:<S_RELEASE
        move    x:<S_STATE,a
        move    #>ST_RELEASE,x0
        cmp     x0,a
        jne     reply_ok
        move    x:<S_RELEASE,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
        jmp     reply_ok

wr_control:
        move    x:<S_WAVEFORM,a
        move    a1,x:<S_TMPA            ; waveform_prev
        move    x:<S_TEST,a
        move    a1,x:<S_TMPB            ; test_prev
        move    y1,a
        rep     #4
        lsr     a
        move    a1,x:<S_WAVEFORM
        move    y1,a
        move    #>8,x0
        and     x0,a
        move    a1,x:<S_TEST
        move    x:<S_TMPB,a
        tst     a
        jne     wc_after_test           ; falling edge only touches the noise register
        move    x:<S_TEST,a
        tst     a
        jeq     wc_after_test
        clr     a                       ; test rising: phase to 0, pulse high
        move    a1,x:<S_ACC
        move    #>$fff,x0
        move    x0,x:<S_PULSE
wc_after_test:
        move    x:<S_WAVEFORM,a
        tst     a
        jeq     wc_nowave
        jsr     calc_wave_code
        jsr     calc_pulse_out
        jmp     wc_env
wc_nowave:
        move    x:<S_TMPA,a             ; waveform dropped to none: output floats
        tst     a
        jeq     wc_env
        move    x:<S_TTLSTART,x0
        move    x0,x:<S_TTL
wc_env:
        move    y1,a                    ; envelope gate
        move    #>1,x0
        and     x0,a
        move    a1,x:<S_TMPA            ; gate_next
        move    x:<S_GATE,x0
        cmp     x0,a
        jeq     reply_ok
        tst     a
        jeq     wc_release
        move    #>ST_ATTACK,x0
        move    x0,x:<S_NEXT
        move    #>ST_DECSUS,x0
        move    x0,x:<S_STATE
        move    x:<S_DECAY,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
        jmp     wc_pipe
wc_release:
        move    #>ST_RELEASE,x0
        move    x0,x:<S_NEXT
wc_pipe:
        move    #>2,x0
        move    x0,x:<S_PIPE
        move    x:<S_TMPA,a
        move    a1,x:<S_GATE
        jmp     reply_ok

; ------------------------------------------------------------------- helpers

rate_lookup:                            ; a1 = nibble -> a = rate counter period
        move    a1,n1
        move    #>DSP_X_RATE_TAB,r1
        nop
        move    x:(r1+n1),a
        rts

; pulse_output = ((acc >> 12) >= pw) ? $fff : 0
calc_pulse_out:
        clr     a
        move    x:<S_ACC,a1
        rep     #12
        lsr     a
        move    x:<S_PW,x0
        cmp     x0,a
        jlt     cpo_low
        move    #>$fff,x0
        move    x0,x:<S_PULSE
        rts
cpo_low:
        clr     a
        move    a1,x:<S_PULSE
        rts

; waveform_output for waveform 1 (triangle), 2 (saw) or 4 (pulse), from the
; phase at the frame's integer cycle. Combined waveforms and noise: later.
calc_wave_code:
        clr     a
        move    x:<S_ACC,a1
        rep     #12
        lsr     a                       ; a1 = ix
        move    x:<S_WAVEFORM,b
        move    #>2,y0
        cmp     y0,b
        jeq     cw_store                ; saw: the code is ix
        move    #>4,y0
        cmp     y0,b
        jeq     cw_pulse
        move    a1,x0                   ; triangle: ((ix ^ (msb ? $7ff : 0)) & $7ff) << 1
        move    #>$7ff,y0
        jclr    #11,x0,cw_nofold
        eor     y0,a
cw_nofold:
        and     y0,a
        lsl     a
        jmp     cw_store
cw_pulse:
        move    x:<S_PULSE,a
cw_store:
        move    a1,x:<S_WAVEOUT
        rts

reset_state:                            ; the model's power-on state
        clr     a
        move    #0,r0
        rep     #$20
        move    a,x:(r0)+
        move    #>S_SHADOW,r0
        rep     #32
        move    a,x:(r0)+
        move    #>$555555,x0
        move    x0,x:<S_ACC
        move    #>$fff,x0
        move    x0,x:<S_PULSE
        move    #>$aa,x0
        move    x0,x:<S_ENVCNT
        move    #>8,x0
        move    x0,x:<S_RATEPER
        move    #>1,x0
        move    x0,x:<S_EXPPER
        move    #>ST_RELEASE,x0
        move    x0,x:<S_STATE
        move    x0,x:<S_NEXT
        rts

; ---------------------------------------------------------------- one frame

cmd_frame:
        clr     a                       ; n = 20 + carry of the Q24 fraction
        move    x:<S_EPS,a0
        move    #0,x1
        move    #>EPS_INC,x0
        add     x,a                     ; 48-bit add: a1 = carry, a0 = new fraction
        move    a0,x:<S_EPS
        move    a1,x0
        move    #>20,a
        add     x0,a
        move    a1,x:<S_N
        move    a1,x:<S_TMPDT
        jsr     env_clock

        move    x:<S_TEST,a             ; oscillator
        tst     a
        jne     fr_test
        move    x:<S_FREQ,x0            ; delta = freq * n
        move    x:<S_N,y0
        mpy     x0,y0,a
        asr     a
        move    a0,x0
        clr     a                       ; acc = (acc + delta) & $ffffff
        move    x:<S_ACC,a0
        move    #0,x1
        add     x,a
        move    a0,x:<S_ACC
        jsr     calc_pulse_out
        jmp     fr_wave
fr_test:
        move    #>$fff,x0
        move    x0,x:<S_PULSE

fr_wave:
        move    x:<S_WAVEFORM,a
        tst     a
        jeq     fr_floating
        jsr     calc_wave_code
        jmp     fr_output
fr_floating:
        move    x:<S_TTL,a
        tst     a
        jeq     fr_output
        move    x:<S_N,x0
        sub     x0,a
        jgt     fr_ttl_keep
        clr     a
        move    a1,x:<S_WAVEOUT
fr_ttl_keep:
        move    a1,x:<S_TTL

fr_output:                              ; (wave DAC - zero) * envelope DAC
        move    x:<S_WAVEOUT,n1
        move    #>DSP_X_WAVE_DAC,r1
        nop
        move    x:(r1+n1),a
        move    x:<S_ZERO,x0
        sub     x0,a
        move    a1,x0
        move    x:<S_ENVCNT,n1
        move    #>DSP_X_ENV_DAC,r1
        nop
        move    x:(r1+n1),y0
        mpy     x0,y0,a
        asr     a
        jclr    #1,x:m_hsr,*
        movep   a0,x:m_htx
        jmp     main_loop

; ---------------------------------------------------------------- envelope

; EnvelopeGenerator::clock(dt), dt = S_TMPDT
env_clock:
        move    x:<S_PIPE,a
        tst     a
        jeq     ec_nopipe
        move    x:<S_NEXT,a
        tst     a
        jne     ec_p_rel
        clr     a                       ; next state ATTACK
        move    a1,x:<S_STATE
        move    a1,x:<S_HOLD
        move    x:<S_ATTACK,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
        jmp     ec_p_done
ec_p_rel:
        move    #>ST_RELEASE,x0
        cmp     x0,a
        jne     ec_p_done
        move    x0,x:<S_STATE
        move    x:<S_RELEASE,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
ec_p_done:
        clr     a
        move    a1,x:<S_PIPE
ec_nopipe:
        move    x:<S_RATEPER,a          ; rate_step = period - counter, +$7fff if <= 0
        move    x:<S_RATECNT,x0
        sub     x0,a
        jgt     ec_step_ok
        move    #>$7fff,x0
        add     x0,a
ec_step_ok:
        move    a1,x:<S_TMPSTEP
ec_loop:
        move    x:<S_TMPDT,a
        tst     a
        jeq     ec_done
        move    x:<S_TMPSTEP,x0
        cmp     x0,a
        jge     ec_step
        move    x:<S_RATECNT,b          ; dt < rate_step: advance the counter and stop
        add     a,b
        jclr    #15,b1,ec_store
        move    #>1,x0
        add     x0,b
        move    #>$7fff,x0
        and     x0,b
ec_store:
        move    b1,x:<S_RATECNT
ec_done:
        rts
ec_step:
        clr     b                       ; rate_counter = 0, dt -= rate_step
        move    b1,x:<S_RATECNT
        sub     x0,a
        move    a1,x:<S_TMPDT
        move    x:<S_STATE,a
        tst     a
        jeq     ec_do_step              ; attack steps every period
        move    x:<S_EXPCNT,a
        move    #>1,x0
        add     x0,a
        move    a1,x:<S_EXPCNT
        move    x:<S_EXPPER,x0
        cmp     x0,a
        jne     ec_next
ec_do_step:
        clr     a
        move    a1,x:<S_EXPCNT
        move    x:<S_HOLD,a
        tst     a
        jne     ec_next                 ; frozen at zero
        move    x:<S_STATE,a
        tst     a
        jeq     ec_attack
        move    #>ST_DECSUS,x0
        cmp     x0,a
        jeq     ec_decsus
ec_dec:                                 ; release: env = (env - 1) & $ff
        move    x:<S_ENVCNT,a
        move    #>1,x0
        sub     x0,a
        move    #>$ff,x0
        and     x0,a
        move    a1,x:<S_ENVCNT
        jmp     ec_setexp
ec_decsus:                              ; decrement unless at the sustain level
        move    x:<S_SUSTAIN,a
        move    a1,n1
        move    #>DSP_X_SUST_TAB,r1
        nop
        move    x:(r1+n1),x0
        move    x:<S_ENVCNT,a
        cmp     x0,a
        jeq     ec_setexp
        jmp     ec_dec
ec_attack:
        move    x:<S_ENVCNT,a
        move    #>1,x0
        add     x0,a
        move    #>$ff,x0
        and     x0,a
        move    a1,x:<S_ENVCNT
        cmp     x0,a
        jne     ec_setexp
        move    #>ST_DECSUS,x0          ; reached $ff: decay
        move    x0,x:<S_STATE
        move    x:<S_DECAY,a
        jsr     rate_lookup
        move    a1,x:<S_RATEPER
ec_setexp:                              ; exponential counter period by envelope value
        move    x:<S_ENVCNT,a
        move    #>$ff,x0
        cmp     x0,a
        jeq     ec_e_1
        move    #>$5d,x0
        cmp     x0,a
        jeq     ec_e_2
        move    #>$36,x0
        cmp     x0,a
        jeq     ec_e_4
        move    #>$1a,x0
        cmp     x0,a
        jeq     ec_e_8
        move    #>$0e,x0
        cmp     x0,a
        jeq     ec_e_16
        move    #>$06,x0
        cmp     x0,a
        jeq     ec_e_30
        tst     a
        jne     ec_next
        move    #>1,x0                  ; zero: hold
        move    x0,x:<S_HOLD
        jmp     ec_e_store
ec_e_1:
        move    #>1,x0
        jmp     ec_e_store
ec_e_2:
        move    #>2,x0
        jmp     ec_e_store
ec_e_4:
        move    #>4,x0
        jmp     ec_e_store
ec_e_8:
        move    #>8,x0
        jmp     ec_e_store
ec_e_16:
        move    #>16,x0
        jmp     ec_e_store
ec_e_30:
        move    #>30,x0
ec_e_store:
        move    x0,x:<S_EXPPER
ec_next:
        move    x:<S_RATEPER,a
        move    a1,x:<S_TMPSTEP
        jmp     ec_loop

        end
