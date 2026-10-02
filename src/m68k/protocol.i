; Host/DSP protocol. Keep in sync with src/dsp/protocol.inc.
;
; Every exchange is a burst of 24-bit host words followed by exactly one
; reply word. Commands are listed with their trailing argument words.

DSP_PROTOCOL_VERSION equ     4

DSP_CMD_PING        equ     $010000     ; -> DSP_REPLY_HELLO
DSP_CMD_WRITE_REG   equ     $020000     ; reg, value -> OK
DSP_CMD_READ_REG    equ     $030000     ; reg -> shadow value / ERROR
DSP_CMD_RESET       equ     $040000     ; -> OK (power-on state; tables are kept)
DSP_CMD_LOAD_X      equ     $0a0000     ; address, count, count words -> OK
DSP_CMD_CONFIG      equ     $0b0000     ; wave zero, floating TTL, model (0 = 6581), shift reset start -> OK
DSP_CMD_FRAME       equ     $0c0000     ; -> three words: the voice 1, 2 and 3 outputs of the next codec frame
DSP_CMD_LOAD_Y      equ     $0d0000     ; address, count, count words (Y memory) -> OK

; The SID register file: 25 write-only registers plus the 4 read-only ones,
; mirrored in a 32-word X-memory shadow indexed by the SID address.
DSP_SID_REG_COUNT   equ     32

DSP_REPLY_HELLO     equ     $534944     ; "SID"
DSP_REPLY_OK        equ     $000000
DSP_REPLY_ERROR     equ     $ffffff

; Table placement the host loads with DSP_CMD_LOAD_X.
DSP_X_RATE_TAB      equ     $0088       ; 16 words: rate counter period by AD/R nibble
DSP_X_SUST_TAB      equ     $0098       ; 16 words: sustain level by nibble
DSP_X_ENV_DAC       equ     $0200       ; 256 words: envelope DAC
DSP_X_WAVE_DAC      equ     $0400       ; 4096 words: waveform DAC
; Combined-waveform tables (waveform & 7 = 3, 5, 6, 7), 4096 words each. Above
; P:$1400 so that external P (which aliases external Y) holds only the kernel.
DSP_Y_WAVE3         equ     $1400
DSP_Y_WAVE5         equ     $2400
DSP_X_WAVE6         equ     $1400
DSP_X_WAVE7         equ     $2400
