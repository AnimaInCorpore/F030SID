; F030SID tune menu (SIDMENU.TOS): pick one of up to nine tunes with the keys
; 1 to 9 and play it with F030SID.TTP from the same folder.
;
; MENU.INF beside the program lists the tunes, one per line:
;
;     command tail for F030SID.TTP;title shown in the menu
;
; for example "ROBOCOP3.SID;RoboCop 3" or "TUNE.SID 2 -m 8580;Tune, song 2".
; A line without ';' shows its command tail. Empty lines are skipped; lines
; after the ninth are ignored.
;
; The player stops on any key and returns that key as its exit code, so 1 to 9
; pressed while a tune plays starts that tune at once. Any other key returns
; to the menu; Esc or Q there leaves.

        include "xbios.i"

INF_MAX         equ     2048
TAIL_MAX        equ     124
STACK_SIZE      equ     4096

        text

start:  move.l  4(sp),a5                ; basepage: keep only what the program needs,
        move.l  $c(a5),d0               ; the rest of the memory is the player's
        add.l   $14(a5),d0
        add.l   $1c(a5),d0
        add.l   #$100,d0
        lea     stack_top,sp
        move.l  d0,-(sp)
        move.l  a5,-(sp)
        clr.w   -(sp)
        move.w  #$4a,-(sp)              ; Mshrink
        trap    #1
        lea     12(sp),sp

        Fopen   inf_name,#0
        tst.l   d0
        bmi     noinf
        move.w  d0,handle
        Fread   handle,#INF_MAX,inf
        move.l  d0,d7
        Fclose  handle
        tst.l   d7
        ble     noinf
        lea     inf,a0
        clr.b   (a0,d7.l)

; split the text: per line the command tail, and the title after ';'
        lea     tails,a2
        lea     titles,a3
        moveq   #0,d6                   ; tunes found
.line:  move.b  (a0),d0
        beq.s   .parsed
        cmp.b   #13,d0
        beq.s   .skip
        cmp.b   #10,d0
        beq.s   .skip
        cmp.w   #9,d6
        bcc.s   .parsed
        move.l  a0,(a2)+
        move.l  a0,a1                   ; the title, unless a ';' follows
.scan:  move.b  (a0),d0
        beq.s   .eol
        cmp.b   #13,d0
        beq.s   .eol
        cmp.b   #10,d0
        beq.s   .eol
        addq.l  #1,a0
        cmp.b   #';',d0
        bne.s   .scan
        cmp.l   -4(a2),a1               ; (the first ';' only)
        bne.s   .scan
        clr.b   -1(a0)
        move.l  a0,a1
        bra.s   .scan
.eol:   move.l  a1,(a3)+
        addq.w  #1,d6
        tst.b   d0
        beq.s   .parsed
        clr.b   (a0)+
        bra.s   .line
.skip:  addq.l  #1,a0
        bra.s   .line
.parsed:
        move.w  d6,count
        beq     noinf

menu:   Cconws  txt_head
        lea     titles,a3
        moveq   #0,d5
.item:  move.b  d5,d0
        add.b   #'1',d0
        move.b  d0,txt_item+2
        Cconws  txt_item
        move.l  (a3)+,a0
        bsr     puts
        Cconws  txt_nl
        addq.w  #1,d5
        cmp.w   count,d5
        bne.s   .item
        Cconws  txt_foot

.key:   move.w  #7,-(sp)                ; Crawcin
        trap    #1
        addq.l  #2,sp
        cmp.b   #27,d0
        beq     bye
        cmp.b   #'q',d0
        beq     bye
        cmp.b   #'Q',d0
        beq     bye
        moveq   #0,d5
        move.b  d0,d5
        sub.w   #'1',d5
        bcs.s   .key
        cmp.w   count,d5
        bcc.s   .key

; play tune d5: the command tail as GEMDOS wants it, a length byte and the text
.play:  lea     tails,a2
        move.l  (a2,d5.w*4),a0
        lea     tail+1,a1
        moveq   #0,d1
.copy:  move.b  (a0)+,d0
        beq.s   .copied
        cmp.w   #TAIL_MAX,d1
        bcc.s   .copied
        move.b  d0,(a1)+
        addq.w  #1,d1
        bra.s   .copy
.copied:
        clr.b   (a1)
        move.b  d1,tail
        Cconws  txt_cls
        clr.l   -(sp)                   ; Pexec(0, player, tail, the parent's environment)
        pea     tail
        pea     prg_name
        clr.w   -(sp)
        move.w  #$4b,-(sp)
        trap    #1
        lea     16(sp),sp
        tst.l   d0
        bmi.s   .failed
        moveq   #0,d5                   ; the key that stopped it: another tune?
        move.b  d0,d5
        sub.w   #'1',d5
        bcs     menu
        cmp.w   count,d5
        bcs.s   .play
        bra     menu
.failed:
        Cconws  txt_noprg
        Cconin
        bra     menu

bye:    Cconws  txt_cls
        Pterm0

noinf:  Cconws  txt_noinf
        Cconin
        Pterm0

puts:   move.l  a0,-(sp)                ; Cconws with the string in a0
        move.w  #9,-(sp)
        trap    #1
        addq.l  #6,sp
        rts

        data

inf_name:       dc.b    'MENU.INF',0
prg_name:       dc.b    'F030SID.TTP',0
txt_cls:        dc.b    27,'E',0
txt_head:       dc.b    27,'E',13,10,' F030SID',13,10,13,10,0
txt_item:       dc.b    '  1  ',0
txt_nl:         dc.b    13,10,0
txt_foot:       dc.b    13,10,' 1-9 plays (also while a tune plays), any other key stops,',13,10
                dc.b    ' Esc or Q leaves.',13,10,0
txt_noinf:      dc.b    13,10,'MENU.INF is missing or empty: one tune per line,',13,10
                dc.b    '"command tail for F030SID.TTP;title". Press a key.',13,10,0
txt_noprg:      dc.b    13,10,'cannot run F030SID.TTP (it must be in this folder). Press a key.',13,10,0
        even

        bss

count:          ds.w    1
handle:         ds.w    1
tails:          ds.l    9
titles:         ds.l    9
tail:           ds.b    TAIL_MAX+4
inf:            ds.b    INF_MAX+2
        even
                ds.b    STACK_SIZE
stack_top:
