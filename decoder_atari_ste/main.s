;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

lo_var_base	EQU	$800
vbl_idx		EQU	lo_var_base-4
vbl_done	EQU	vbl_idx-4
io_ptr		EQU	vbl_done-4
lo_var_main_end	EQU	io_ptr

lo_buf_base	EQU	$7a00
lo_buf_main_end	EQU	lo_buf_base

proc_lives	EQU	$380
_v_bas_ad	EQU	$44e
_memtop		EQU	$436

screen_width_b	EQU	160
screen_height	EQU	200	
screen_size_b	EQU	screen_width_b*screen_height

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	macro	debug
		bsr.w debug_call
		illegal
	endm

	macro	wait_frames
		lea	vbl_idx.w,a0
		move.l	(a0),d1
		addi.l	#\1,d1
	_lp\@:
		cmp.l	(a0),d1
		bne.s	_lp\@
	endm
	
	macro	set_screen_addr
		movem.l	d0/d7,-(sp)
		move.l	\1,d0
		move.b	d0,d7
		lsr.w	#8,d0
		move.b	d0,$ffff8203.w
		swap.w	d0
		move.b	d0,$ffff8201.w
		move.b	d7,$ffff820d.w
		movem.l	(sp)+,d0/d7
	endm	
	
	
	macro	dbgb
	.tx_not_empty\@:
		btst.b	#1,$fffffc04.w
		beq.s .tx_not_empty\@

		move.b	\1,$fffffc06.w
	endm

	macro	dbgw
		rol.w	#8,\1

	.tx_not_empty\@:
		btst.b	#1,$fffffc04.w
		beq.s .tx_not_empty\@

		move.b	\1,$fffffc06.w
		
		rol.w	#8,\1
		
	.tx_not_empty_2\@:
		btst.b	#1,$fffffc04.w
		beq.s .tx_not_empty_2\@

		move.b	\1,$fffffc06.w
	endm
	
	macro	dbgl
		swap.w	\1
		dbgw	\1
		swap.w	\1
		dbgw	\1
	endm

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  STARTUP  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT

	; System call to execute a function in Supervisor mode.
	; If we don't run our code in supervisor mode, we
	; cannot write to the registers to set up screen pointer
	; and palette.

start:
	; InitBasepage (for working malloc, from https://github.com/georgjz/atari-st-project-template/blob/master/src/init.s)		      
	move.l	4(sp),a0			; get pointer to basepage
	lea	(system_stack_end),sp		; set user stack pointer 
	move.l	#$100,d0			; length of basepage 
	add.l	$0c(a0),d0			; add length of code section 
	add.l	$14(a0),d0			; add length of data section 
	add.l	$1c(a0),d0			; add length of bss section for total program length 
	move.l	d0,-(sp)			; pass total length 
	move.l	a0,-(sp)			; pass pointer to basepage 
	clr.w	-(sp)				; clear word 
	move.w	#$4a,-(sp)			; Mskrink opcode 
	trap	#1				; call GEMDOS 
	lea	$0c(sp),sp			; correct stack pointer
		
	pea	main				; Push address pointer to stack 
	move.w	#$26,-(sp)			; XBIOS call to Supexec.
	trap	#14				; Software interript #14 -> XBIOS

dummy_vector:
	rte

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  INCLUDES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; debug_call
debug_call:
	set_screen_addr _v_bas_ad.w
	move.w  #$0500,$ffff8240.w
	move.w  #$00f0,$ffff825e.w
	rts		

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; clear screen
clear_screen:
	movem.l	a0-a6/d0-d7,-(sp)
	move.l  _v_bas_ad.w,a5
	moveq	#0,d0
	move.l	d0,a4
	move.l	d0,a3
	move.l	d0,a2
	move.l	d0,a1
	move.l	d0,a0
	move.l	d0,d6
	move.l	d0,d5
	move.l	d0,d2
	move.l	d0,d1
	adda.l	#screen_size_b,a5
	move.w	#screen_height-1,d7
clear_screen_lp:
		movem.l	a0-a4/d0-d2/d5-d6,-(a5)
		movem.l	a0-a4/d0-d2/d5-d6,-(a5)
		movem.l	a0-a4/d0-d2/d5-d6,-(a5)
		movem.l	a0-a4/d0-d2/d5-d6,-(a5)
		dbra 	d7,clear_screen_lp
	movem.l	(sp)+,a0-a6/d0-d7
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; print_buffer (a0: word data, d7: number of words)
print_buffer:
	movem.l	a0-a1/d0-d3,-(sp)
	subq.w	#1,d7
	lea	print_data,a1
	
print_buffer_word_lp:	
	move.w	(a0)+,d2

	moveq	#3,d3
		
	print_buffer_nibble_lp:
		rol.w	#4,d2
		move.w	d2,d0
		and.w	#$000f,d0
		add.w	#'0',d0
		cmp.w	#'9',d0
		ble.s		.zn
			add.w	#'a'-'9'-1,d0
		.zn:

		move.b	d0,(a1)+
		
		dbra	d3,print_buffer_nibble_lp
	
	move.b	#' ',(a1)+

	dbra	d7,print_buffer_word_lp

	move.b	#13,(a1)+
	move.b	#0,(a1)+
	
	move.l	#print_data,-(sp)
	move.w	#$09,-(sp)
	trap	#1
	addq.l	#6,sp	

	movem.l	(sp)+,a0-a1/d0-d3
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; print_text (a0: string)
print_text:
	movem.l	a0/d0,-(sp)

	move.l	a0,-(sp)
	move.w	#$09,-(sp)
	trap	#1
	addq.l	#6,sp	

	movem.l	(sp)+,a0/d0
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; read_text (returns: a0: string)
read_text:
	movem.l	d0,-(sp)

	lea	(print_data),a0
	move.w	#$4000,(a0)

	move.l	a0,-(sp)
	move.w	#$0a,-(sp)
	trap	#1
	addq.l	#6,sp	
	
	moveq	#0,d0
	move.b	1(a0),d0
	addq.l	#2,a0
	clr.b	0(a0,d0.w)

	movem.l	(sp)+,d0
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; alloc_read_file (a0: file name; returns: d0: file size, a0: pointer on allocated data)	
alloc_read_file:
	movem.l	a5/a6/d6/d7,-(sp)

	; open
	move.w	0,-(sp)		; read only
	move.l	a0,-(sp)
	move.w	#$3d,-(sp)
	trap	#1
	addq.l	#8,sp
	tst.l	d0
	bpl.s	.file_found

	move.l	a0,a6

.go_str_end:
	tst.b	(a6)+
	bne.s 	.go_str_end
	
	move.b	#'.',-(a6)
	addq.l	#1,a6
	move.b	#'g',(a6)+
	move.b	#'s',(a6)+
	move.b	#'c',(a6)+
	clr.b	(a6)

	bsr.w	print_text
	
	; open
	move.w	0,-(sp)		; read only
	move.l	a0,-(sp)
	move.w	#$3d,-(sp)
	trap	#1
	addq.l	#8,sp
	tst.l	d0
	bmi.w	.error
		
.file_found:
	move.l	d0,d7		; store handle

	; lseek
	move.w	#2,-(sp)	; from end of file
	move.w	d7,-(sp)
	move.l	#0,-(sp)
	move.w	#$42,-(sp)
	trap	#1
	adda.l	#10,sp
	tst.l	d0
	bmi.s	.error	

	move.l	d0,d6		; store file size

	; lseek
	move.w	#0,-(sp)	; back to start of file
	move.w	d7,-(sp)
	move.l	#0,-(sp)
	move.w	#$42,-(sp)
	trap	#1
	adda.l	#10,sp
	tst.l	d0
	bmi.s	.error	
	
	; malloc
	move.l	d6,-(sp)
	move.w	#$48,-(sp)
	trap	#1
	addq.l	#6,sp
	tst.l	d0
	bmi.s	.error	

	move.l	d0,a6		; allocated mem ptr
	
	lea	(file_read),a0
	bsr.w	print_text

	move.l	a6,a5
	.read_loop:
		; read
		move.l	a5,-(sp)
		move.l	#$200,-(sp)
		move.w	d7,-(sp)
		move.w	#$3f,-(sp)
		trap	#1
		adda.l	#12,sp

		adda.l	d0,a5

		tst.l	d0
		bmi.s	.error
		bne.s	.read_loop
	
	; close
	move.w	d7,-(sp)
	move.w	#$3e,-(sp)
	trap	#1
	addq.l	#4,sp
	
	move.l	d6,d0
	move.l	a6,a0
	
.end:
	movem.l	(sp)+,a5/a6/d6/d7
	rts
	
.error:
	lea	(file_error),a0
	bsr.w	print_text
	
	moveq	#0,d0
	move.l	d0,a0
	
	bra.s	.end

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_show_welcome_message
gsc_show_welcome_message:
	; white on blue
	move.w  #$0812,$ffff8240.w
	move.w  #$03cd,$ffff8246.w
	move.w  #$03cd,$ffff825e.w

	lea	(gsc_welcome_message),a0
	bsr.w	print_text
	
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_load_track
gsc_load_track:
	lea	(gsc_track_message),a0
	bsr.w	print_text
	
	bsr.w	read_text
	bsr.w	alloc_read_file
	tst.l	d0
	beq.s	gsc_load_track
	
	lea	(gsc_play_message),a0
	bsr.w	print_text
	
	rts	

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; debugl
debugl:
	dbgl d0
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; debugw
debugw:
	dbgw d0
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; debugb
debugb:
	dbgb d0
	rts
	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MAIN  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

main:
	; clear screen
	bsr.w	clear_screen

	; welcome message
	jsr	gsc_show_welcome_message

	; load ROM
	jsr	gsc_load_track	

	; disable irqs
	move    #$2700,SR

	; no MFP TimerA & TimerB interrupts
	clr.b 	$fffffa07.w
	clr.b 	$fffffa09.w  

	; init vbl counter
	clr.l	vbl_idx.w

	; set Level 6 Int Autovector (MFP)
	lea	(dummy_vector),a0
	move.l	a0,$78.w
	
	; set Level 4 Int Autovector (VBL)
	lea	(dummy_vector),a0
	move.l	a0,$70.w

	; enable irqs
	move    #$2300,SR


	; main loop
main_loop:

	; debug bar
	; move.w  #$070,$ffff8240.w
	
	; wait vsync
	lea		vbl_done.w,a0
	bclr.b	#0,(a0)
.wait_sync:
	btst.b	#0,(a0)
	beq.s 	.wait_sync 
	
	; restore bg
	; move.w  #$000,$ffff8240.w
	
	bra.w	main_loop	
	
.halt   bra.s   .halt

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

; screen:
	; ds.b	screen_size_b

mpb:
	ds.b	12

system_stack:
	ds.b	4096			; stack space (/!\ below z80_code_ptrs)
system_stack_end:

print_data:
	ds.b	256

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA

gsc_welcome_message:
	dc.b	13,10,"STeGSC, Atari STe SoundChunks replayer",13,10,"By GliGli, version 0.00a",13,10,13,10,0

gsc_track_message:
	dc.b	"Please input GSC name:",13,10,0

gsc_play_message:
	dc.b	"Playing...",13,10,0

file_read:
	dc.b	13,10,"Reading file...",13,10,0	

file_error:
	dc.b	13,10,"Error reading file!",13,10,0	
