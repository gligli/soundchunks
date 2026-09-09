;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

lo_var_base	EQU	$800
ssp_save	EQU	lo_var_base-4
screen_res_save	EQU	ssp_save-2
palette_save	EQU	screen_res_save-6
mfp_int_save	EQU	palette_save-4
vbl_int_save	EQU	mfp_int_save-4
trap_storage	EQU	vbl_int_save-24
vbl_idx		EQU	trap_storage-4
vbl_done	EQU	vbl_idx-4
gsc_file_size	EQU	vbl_done-4
gsc_file_ptr	EQU	gsc_file_size-4
gsc_file_pos	EQU	gsc_file_ptr-4
gsc_file_handle	EQU	gsc_file_pos-4
lo_var_main_end	EQU	gsc_file_handle

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
	lea	12(sp),sp			; correct stack pointer
		
	; super
	clr.l	-(sp)
	move.w	#$20,-(sp)
	trap	#1
	addq.l	#6,sp
	
	move.l	d0,ssp_save.w
	
	bra.w	main

vbl:
	bset.b	#0,vbl_done.w
	addq.l	#1,vbl_idx.w
	rte
	
dummy_vector:
	rte

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  INCLUDES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	include	"gsc.s"	

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; trap_gemdos
trap_gemdos:
	movem.l	a0-a2/d1-d2,trap_storage+4.w	; store regs that can be overwritten by trap
	move.l	(sp)+,trap_storage.w		; store return address (also makes stack ready for trap)
	trap	#1
	move.l	trap_storage.w,-(sp)
	movem.l	trap_storage+4.w,a0-a2/d1-d2
	rts		

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; trap_bios
trap_bios:
	movem.l	a0-a2/d1-d2,trap_storage+4.w	; store regs that can be overwritten by trap
	move.l	(sp)+,trap_storage.w		; store return address (also makes stack ready for trap)
	trap	#13
	move.l	trap_storage.w,-(sp)
	movem.l	trap_storage+4.w,a0-a2/d1-d2
	rts		

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; trap_xbios
trap_xbios:
	movem.l	a0-a2/d1-d2,trap_storage+4.w	; store regs that can be overwritten by trap
	move.l	(sp)+,trap_storage.w		; store return address (also makes stack ready for trap)
	trap	#14
	move.l	trap_storage.w,-(sp)
	movem.l	trap_storage+4.w,a0-a2/d1-d2
	rts		

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
	; init_ints
init_ints:

	; disable irqs
	move    #$2700,SR

	; init vbl counter
	clr.l	vbl_idx.w

	; set Level 6 Int Autovector (MFP)
	move.l	$78.w,mfp_int_save.w
	move.l	#dummy_vector,$78.w
	
	; set Level 4 Int Autovector (VBL)
	move.l	$70.w,vbl_int_save.w
	move.l	#vbl,$70.w

	; enable irqs
	move    #$2300,SR

	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; finish_ints
finish_ints:

	; disable irqs
	move    #$2700,SR

	; reset Level 4 Int Autovector (VBL)
	move.l	vbl_int_save.w,$70.w

	; reset Level 6 Int Autovector (MFP)
	move.l	mfp_int_save.w,$78.w
	
	; enable irqs
	move    #$2300,SR
	
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; print_value (d0: word value)
print_value:
	movem.l	a0-a1/d0-d3,-(sp)
	
	lea	print_data,a1
	
	moveq	#4,d3
	.space_lp:
		move.b	#' ',(a1)+
		dbeq.w	d3,.space_lp
	move.b	#0,(a1)	
		
	moveq	#4,d3
	.decimal_lp:
		andi.l	#$0000ffff,d0
		divu.w	#10,d0
		move.l	d0,d2
		swap.w	d2
		add.w	#'0',d2
		
		move.b	d2,-(a1)

		tst.w	d0
		dbeq.w	d3,.decimal_lp
	
	move.l	#print_data,-(sp)
	move.w	#$09,-(sp)
	bsr.w	trap_gemdos
	addq.l	#6,sp	

	movem.l	(sp)+,a0-a1/d0-d3
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; print_text (a0: string) 
print_text:
	movem.l	a0/d0,-(sp)

	move.l	a0,-(sp)
	move.w	#$09,-(sp)
	bsr.w	trap_gemdos
	addq.l	#6,sp

	movem.l	(sp)+,a0/d0
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; read_text (returns: a0: string)
read_text:
	move.l	d0,-(sp)

	lea	(print_data),a0
	move.w	#$4000,(a0)

	move.l	a0,-(sp)
	move.w	#$0a,-(sp)
	bsr.w	trap_gemdos
	addq.l	#6,sp	
	
	moveq	#0,d0
	move.b	1(a0),d0
	addq.l	#2,a0
	clr.b	0(a0,d0.w)

	move.l	(sp)+,d0
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; alloc_read_file_beginning (a0: file name; returns: d0: file size, d7: file handle, a0: pointer on allocated data, a1: pointer on end of red data)	
alloc_read_file_beginning:
	movem.l	a6/d6,-(sp)

	; open
	move.w	0,-(sp)		; read only
	move.l	a0,-(sp)
	move.w	#$3d,-(sp)
	bsr.w	trap_gemdos
	addq.l	#8,sp
	tst.l	d0
	bpl.s	.file_found

	move.l	a0,a6

.no_str_end:
	tst.b	(a6)+
	bne.s 	.no_str_end
	
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
	bsr.w	trap_gemdos
	addq.l	#8,sp
	tst.l	d0
	bmi.w	.error_no_open
		
.file_found:
	move.l	d0,d7		; store handle

	; lseek
	move.w	#2,-(sp)	; from end of file
	move.w	d7,-(sp)
	move.l	#0,-(sp)
	move.w	#$42,-(sp)
	bsr.w	trap_gemdos
	lea	10(sp),sp
	tst.l	d0
	bmi.s	.error	

	move.l	d0,d6		; store file size

	; lseek
	move.w	#0,-(sp)	; back to start of file
	move.w	d7,-(sp)
	move.l	#0,-(sp)
	move.w	#$42,-(sp)
	bsr.w	trap_gemdos
	lea	10(sp),sp
	tst.l	d0
	bmi.s	.error	
	
	; malloc
	move.l	d6,-(sp)
	move.w	#$48,-(sp)
	bsr.w	trap_gemdos
	addq.l	#6,sp
	tst.l	d0
	bmi.s	.error	

	move.l	d0,a6		; allocated mem ptr
	
	lea	(file_read_message),a0
	bsr.w	print_text

	; read
	move.l	a6,-(sp)
	move.l	#$2000,-(sp)
	move.w	d7,-(sp)
	move.w	#$3f,-(sp)
	bsr.w	trap_gemdos
	lea	12(sp),sp
	tst.l	d0
	bmi.s	.error
	
	move.l	a6,a0
	
	move.l	a6,a1
	adda.l	d0,a1

	move.l	d6,d0
	
.end:
	movem.l	(sp)+,a6/d6
	rts
	
.error:
	bsr.w	close_file

.error_no_open:

	lea	(file_error_message),a0
	bsr.w	print_text
	
	moveq	#0,d0
	move.l	d0,a0
	move.l	d0,a1
	
	bra.s	.end

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; continue_read_file (d7: file handle, a1: pointer on end of red data; returns: a1: pointer on end of red data)	
continue_read_file:
	move.l	d0,-(sp)

	; read
	move.l	a1,-(sp)
	move.l	#$800,-(sp)
	move.w	d7,-(sp)
	move.w	#$3f,-(sp)
	bsr.w	trap_gemdos
	lea	12(sp),sp
	tst.l	d0
	bmi.s	.error
	
	adda.l	d0,a1

	move.l	(sp)+,d0
	rts

.error:
	lea	(file_error_message),a0
	bsr.w	print_text
	
.halt   bra.s   .halt

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; close_file (d7: file handle)	
close_file:
	move.l	d0,-(sp)

	; close
	move.w	d7,-(sp)
	move.w	#$3e,-(sp)
	bsr.w	trap_gemdos
	addq.l	#4,sp

	move.l	(sp)+,d0
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_show_welcome_message
gsc_show_welcome_message:
	move.l	a0,-(sp)

	; save palette
	move.w  $ffff8240.w,palette_save+0.w
	move.w  $ffff8246.w,palette_save+2.w
	move.w  $ffff825e.w,palette_save+4.w

	; white on blue
	move.w  #$0812,$ffff8240.w
	move.w  #$03cd,$ffff8246.w
	move.w  #$03cd,$ffff825e.w

	lea	(gsc_welcome_message),a0
	bsr.w	print_text
	
	move.l	(sp)+,a0
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_load_track
gsc_load_track:
	movem.l	a0/a1/d0/d7,-(sp)

	.load_valid_track_lp:
		lea	(gsc_track_message),a0
		bsr.w	print_text
		
		bsr.w	read_text
		tst.b	(a0)		; empty string?
		beq.s	.load_valid_track_lp	
		cmpi.b	#$1b,(a0)	; esc key?
		beq.s	.quit	
		
		bsr.w	alloc_read_file_beginning
		tst.l	d0
		beq.s	.load_valid_track_lp
	
	move.l	a0,gsc_file_ptr.w
	move.l	a1,gsc_file_pos.w
	move.l	d0,gsc_file_size.w
	move.l	d7,gsc_file_handle.w

	movem.l	(sp)+,a0/a1/d0/d7
	rts	
	
.quit:
	; restore resolution
	move.w	screen_res_save.w,-(sp)
	move.l	#-1,-(sp)
	move.l	#-1,-(sp)
	move.w	#5,-(sp)
	bsr.w	trap_xbios
	lea	12(sp),sp

	; restore palette
	move.w	palette_save+0.w,$ffff8240.w
	move.w	palette_save+2.w,$ffff8246.w
	move.w	palette_save+4.w,$ffff825e.w

	; restore mouse
	pea	(ikbd_enable_mouse)
	move.w	#0,-(sp)
	move.w	#25,-(sp)
	bsr.w	trap_xbios
	addq.l	#8,sp

	; wait vbl
	move.w	#37,-(sp)
	bsr.w	trap_xbios
	addq.l	#2,sp

	; super (back to user)
	move.l	ssp_save.w,-(sp)
	move.w	#$20,-(sp)
	trap	#1		; not trap_gemdos to avoid accessing low mem
	addq.l	#6,sp

	; terminate program
	move.w	#0,-(sp)
	move.w	#$4c,-(sp)
	trap	#1		; not trap_gemdos to avoid accessing low mem

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_continue_load_track
gsc_continue_load_track:
	movem.l	a0/a1/d0/d7,-(sp)

	move.l	gsc_file_size.w,d0
	move.l	gsc_file_ptr.w,a0
	adda.l	d0,a0

	move.l	gsc_file_pos.w,a1

	cmp.l	a0,a1
	bhs.s	.finished_loading
	
	.no_finished_loading:
		move.l	gsc_file_handle.w,d7
		bsr.w	continue_read_file
		move.l	a1,gsc_file_pos.w

		movem.l	(sp)+,a0/a1/d0/d7
		rts

	.finished_loading:
		tst.l	gsc_file_handle.w
		beq.s	.no_close_file
		
		.close_file:
		
			bsr.w	gsc_close_track

			lea	(file_loading_done_message),a0
			bsr.w	print_text
		
		.no_close_file:

		movem.l	(sp)+,a0/a1/d0/d7
		rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_close_track
gsc_close_track:
	move.l	d7,-(sp)

	move.l	gsc_file_handle.w,d7
	beq.s	.no_close_file
	
	.close_file:
	
		bsr.w	close_file
		clr.l	gsc_file_handle.w
	
	.no_close_file:
	
	move.l	(sp)+,d7
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_free_track
gsc_free_track:
	move.l	d0,-(sp)
	
	; mfree
	move.l	gsc_file_ptr.w,-(sp)
	move.w	#$49,-(sp)
	bsr.w	trap_gemdos
	addq.l	#6,sp

	movem.l	(sp)+,d0
	rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MAIN  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

main:
	; disable mouse
	pea	(ikbd_disable_mouse)
	move.w	#0,-(sp)
	move.w	#25,-(sp)
	bsr.w	trap_xbios
	addq.l	#8,sp

	; get resolution
	move.w	#4,-(sp)
	bsr.w	trap_xbios
	addq.l	#2,sp

	move.w	d0,screen_res_save.w

	; setup resolution (med res)
	move.w	#1,-(sp)
	move.l	#-1,-(sp)
	move.l	#-1,-(sp)
	move.w	#5,-(sp)
	bsr.w	trap_xbios
	lea	12(sp),sp
		
	; clear screen
	bsr.w	clear_screen

	; welcome message
	bsr.w	gsc_show_welcome_message

.retry:

	; load ROM
	bsr.w	gsc_load_track	

	; init interrupts
	bsr.w	init_ints
	
	; init SoundChunks replayer
	move.l	gsc_file_ptr.l,a0
	move.l	gsc_file_size.l,d0
	bsr.w	gsc_init
	tst.l	d0
	bne.w	.fail

	; show some nice infos

	move.l	a0,a1

	lea	(gsc_artist_message),a0
	bsr.w	print_text

	lea.l	16(a1),a0
	bsr.w	print_text

	lea 	(gsc_title_message),a0
	bsr.w	print_text
	
	lea.l	48(a1),a0
	bsr.w	print_text

	lea	(gsc_length_message),a0
	bsr.w	print_text
	
	move.l	12(a1),d0
	add.l	#500,d0
	divu.w	#1000,d0
	move.w	d0,d1
	bsr.w	print_value	

	lea	(gsc_bitrate_message),a0
	bsr.w	print_text
	
	move.l	gsc_file_size.l,d0
	lsr.l	#7,d0
	moveq	#0,d2
	move.w	d1,d2
	lsr.w	#1,d2
	add.l	d2,d0
	divu.w	d1,d0
	bsr.w	print_value	

	lea	(gsc_play_message),a0
	bsr.w	print_text
	
	; main loop
.main_loop:

	; continue loading GSC
	bsr.w	gsc_continue_load_track
	
.test_key_pressed:
	; a key was pressed?
	move.w	#2,-(sp)
	move.w	#1,-(sp)
	bsr.w	trap_bios
	addq.l	#4,sp

	tst.w	d0
	beq.s	.main_loop

	; read keyboard
	move.w	#2,-(sp)
	move.w	#2,-(sp)
	bsr.w	trap_bios
	addq.l	#4,sp

	; if esc is pressed, stop playing
	cmpi.b	#$1b,d0
	beq.s	.finish

	cmpi.b	#'+',d0
	bne.s	.no_up_volume
.up_volume:
		bsr.w	gsc_get_volume
		addq.w	#1,d0
		bsr.w	gsc_set_volume
		bra.s	.test_key_pressed
.no_up_volume:

	cmpi.b	#'-',d0
	bne.s	.test_key_pressed
.dn_volume:
		bsr.w	gsc_get_volume
		subq.w	#1,d0
		bsr.w	gsc_set_volume
		bra.s	.test_key_pressed
	
.finish:
	; finish
	bsr.w	gsc_finish
	bsr.w	gsc_close_track
	bsr.w	gsc_free_track

	; reset interrupts
	bsr.w	finish_ints
	
	bra.w	.retry

.fail:
	lea	(file_not_a_gsc_message),a0
	bsr.w	print_text
	bra.s	.finish

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

system_stack:
	ds.b	4096			; stack space
system_stack_end:

print_data:
	ds.b	256

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA

ikbd_disable_mouse:
	dc.b	$12,$00

ikbd_enable_mouse:
	dc.b	$08,$00

gsc_welcome_message:
	dc.b	13,10,"STeGSC, Atari STe SoundChunks replayer",13,10,"By GliGli, version 0.02b",13,10,13,10,0

gsc_track_message:
	dc.b	"Please input GSC file name: (Esc,Return: Quit)",13,10,0

file_read_message:
	dc.b	13,10,"Reading file...",13,10,0	

file_loading_done_message:
	dc.b	"File loading done!",13,10,0	

file_error_message:
	dc.b	13,10,"Error reading file!",13,10,0	

file_not_a_gsc_message:
	dc.b	13,10,"File is not a valid SoundChunks stream! (bad stream version?)",13,10,13,10,0	

gsc_artist_message:
	dc.b	"Artist: ",0	
gsc_title_message:
	dc.b	13,10,"Title:  ",0	
gsc_length_message:
	dc.b	13,10,"Length: ",0	
gsc_bitrate_message:
	dc.b	" seconds",13,10,"Rate:   ",0	
gsc_play_message:
	dc.b	" Kb/sec",13,10,"Playing (Esc: Stop, -/+: Volume)...",13,10,0

	even