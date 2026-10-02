; Host/DSP protocol. Keep in sync with src/dsp/protocol.inc.
;
; Every exchange is a burst of 24-bit host words followed by exactly one
; reply word. Commands are listed with their trailing argument words.

DSP_PROTOCOL_VERSION equ     2

DSP_CMD_PING        equ     $010000     ; -> DSP_REPLY_HELLO
DSP_CMD_WRITE_REG   equ     $020000     ; reg, value -> OK
DSP_CMD_READ_REG    equ     $030000     ; reg -> shadow value / ERROR
DSP_CMD_RESET       equ     $040000     ; -> OK (power-on state; tables are kept)
DSP_CMD_LOAD_X      equ     $0a0000     ; address, count, count words -> OK
DSP_CMD_CONFIG      equ     $0b0000     ; wave zero level, floating-output TTL -> OK
DSP_CMD_FRAME       equ     $0c0000     ; -> voice 0 output of the next codec frame

; The SID register file: 25 write-only registers plus the 4 read-only ones,
; mirrored in a 32-word X-memory shadow indexed by the SID address.
DSP_SID_REG_COUNT   equ     32

DSP_REPLY_HELLO     equ     $534944     ; "SID"
DSP_REPLY_OK        equ     $000000
DSP_REPLY_ERROR     equ     $ffffff

; Table placement the host loads with DSP_CMD_LOAD_X.
DSP_X_RATE_TAB      equ     $0040       ; 16 words: rate counter period by AD/R nibble
DSP_X_SUST_TAB      equ     $0050       ; 16 words: sustain level by nibble
DSP_X_ENV_DAC       equ     $0200       ; 256 words: envelope DAC
DSP_X_WAVE_DAC      equ     $0400       ; 4096 words: waveform DAC
