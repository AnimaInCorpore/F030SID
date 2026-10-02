; Host/DSP protocol. Keep in sync with src/dsp/protocol.inc.
;
; Every exchange is a burst of 24-bit host words followed by exactly one
; reply word. Commands are listed with their trailing argument words.

DSP_PROTOCOL_VERSION equ     1

DSP_CMD_PING        equ     $010000     ; -> DSP_REPLY_HELLO
DSP_CMD_WRITE_REG   equ     $020000     ; reg, value -> OK / ERROR
DSP_CMD_READ_REG    equ     $030000     ; reg -> shadow value / ERROR
DSP_CMD_RESET       equ     $040000     ; -> OK (clears every register)

; The SID register file: 25 write-only registers plus the 4 read-only ones,
; mirrored in a 32-word X-memory shadow indexed by the SID address.
DSP_SID_REG_COUNT   equ     32

DSP_REPLY_HELLO     equ     $534944     ; "SID"
DSP_REPLY_OK        equ     $000000
DSP_REPLY_ERROR     equ     $ffffff
