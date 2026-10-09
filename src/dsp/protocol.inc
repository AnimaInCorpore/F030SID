; Host/DSP protocol. Keep in sync with src/m68k/protocol.i.
;
; Every exchange is a burst of 24-bit host words followed by exactly one
; reply word. Commands are listed with their trailing argument words.

DSP_PROTOCOL_VERSION equ     12

DSP_CMD_PING        equ     $010000     ; -> DSP_REPLY_HELLO
DSP_CMD_WRITE_REG   equ     $020000     ; reg, value -> OK
DSP_CMD_READ_REG    equ     $030000     ; reg -> shadow value / ERROR
DSP_CMD_RESET       equ     $040000     ; -> OK (power-on state; tables are kept)
DSP_CMD_LOAD_X      equ     $0a0000     ; address, count, count words -> OK
DSP_CMD_CONFIG      equ     $0b0000     ; wave zero, floating TTL, model (0 = 6581), shift reset start,
                                        ; a reserved word, mixer scale, filter gain -> OK
                                        ; (after the tables: it latches the envelope DAC words)
DSP_CMD_FRAME       equ     $0c0000     ; -> four words: the voice 1, 2 and 3 outputs and the chip output of the next codec frame
DSP_CMD_LOAD_Y      equ     $0d0000     ; address, count, count words (Y memory) -> OK
DSP_CMD_LOAD_X_HI   equ     $0f0000     ; address, count, count words -> OK: each word becomes the upper twelve
                                        ; bits of the X word there (the lower twelve stay): combined-waveform table 7
DSP_CMD_FILTER      equ     $0e0000     ; a1, a2, a3, k4, wl, wb, wh, wleak (Q23 words, host-derived: the filter's
                                        ; coefficients, the three outputs' gains / 2, the low-pass share in the
                                        ; high-pass output) -> OK
DSP_FILTER_WORDS    equ     8
; The SSI stream (docs/dsp-kernel.md): the DSP renders ahead into a ring the SSI
; transmitter plays. Writes are stamped with their SID cycle (mod 2^24), sent in
; order; the horizon is the cycle below which frames may start, and every write
; below horizon + 21 must have been sent by then. Register numbers 32-39 in a
; queued write carry the filter's eight coefficient words.
DSP_CMD_STREAM_START equ    $100000     ; -> OK (clock 0, queue empty, transmitter on)
DSP_CMD_STREAM_PUSH equ     $110000     ; count, count * (cycle, register, value), horizon -> queue entries free
DSP_CMD_STREAM_READ equ     $120000     ; index -> status word: 0 started, 1 checksum, 2 least ring
                                        ; fill (frames), 3 queue entries, 4 render clock, 5 overtakes, 6 SSI underrun flag,
                                        ; 7 ring fill now (frames)
DSP_CMD_STREAM_STOP equ     $130000     ; -> OK
DSP_CMD_STREAM_PLAIN equ    $140000     ; -> OK (after START: render without the checksum, which costs
                                        ; ten cycles a frame and only the gates read)
DSP_STREAM_QUEUE    equ     1024        ; write queue entries

; The SID register file: 25 write-only registers plus the 4 read-only ones,
; mirrored in a 32-word X-memory shadow indexed by the SID address.
DSP_SID_REG_COUNT   equ     32

DSP_REPLY_HELLO     equ     $534944     ; "SID"
DSP_REPLY_OK        equ     $000000
DSP_REPLY_ERROR     equ     $ffffff

; Table placement the host loads with DSP_CMD_LOAD_X.
DSP_X_RATE_TAB      equ     $0088       ; 16 words: rate counter period by AD/R nibble
DSP_X_SUST_TAB      equ     $0098       ; 16 words: sustain level by nibble
; The DAC tables come scaled so that one multiply of the two is the voice output:
; envelope DAC << 13, (waveform DAC - wave zero) << 10.
DSP_X_ENV_TAB       equ     $0200       ; 512 words, a pair per envelope value: envelope DAC << 13, and the
                                        ; exponential counter period that starts at this value (0 = no
                                        ; change, -1 at value 0: hold). Must be $0200.
DSP_X_WAVE_DAC      equ     $0400       ; 4096 words: (waveform DAC - wave zero) << 10
; Combined-waveform tables (waveform & 7 = 3, 5, 6, 7), 4096 words each. Above
; P:$1c00 so that external P (which aliases external Y) holds only the kernel.
DSP_Y_WAVE3         equ     $1c00
DSP_Y_WAVE5         equ     $2c00
DSP_Y_BLEP          equ     $007f       ; 129 words (internal Y): the polyBLEP step residual, Q23
                                        ; (S(i/64) - 1 for i = 0..128, see src/ref/sid_ref.c)
DSP_X_WAVE6         equ     $1400       ; tables 6 and 7 share their words: 6 in the lower twelve bits (LOAD_X, first),
DSP_X_WAVE7         equ     $1400       ; 7 in the upper twelve (LOAD_X_HI). That leaves X:$3000-$3fff to the stream's ring.
