; GliGli's SoundChunks decoder
;
; Author: GliGli
; License: GNU GPL3

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  CONSTANTS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; tweakable

gsc_chunk_size		EQU	6
gsc_chunks_per_att	EQU	40
gsc_lmc_sample_skew	EQU	10

gsc_mfp_prescaler_value	EQU	200	; /!\ keep both gsc_mfp_prescaler_* synced!
gsc_mfp_prescaler_code	EQU	7

; shouldn't be tweaked

mfp_clock_rate		EQU	2457600
gsc_sample_rate		EQU	25033

gsc_header_size		EQU	80

gsc_audio_buf_size	EQU	gsc_chunks_per_att*gsc_chunk_size
gsc_audio_dblbuf_size	EQU	gsc_audio_buf_size*2

gsc_timer_data_num	EQU	mfp_clock_rate/(gsc_sample_rate/gsc_chunk_size/gsc_chunks_per_att)
gsc_timer_data		EQU	gsc_timer_data_num/gsc_mfp_prescaler_value-1

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gsc_timer_a_int_save	EQU	lo_var_main_end-4
gsc_start_ptr		EQU	gsc_timer_a_int_save-4
gsc_end_ptr		EQU	gsc_start_ptr-4
gsc_cur_chunks_ptr	EQU	gsc_end_ptr-4
gsc_cur_indexes_ptr	EQU	gsc_cur_chunks_ptr-4
gsc_cur_indexes_left	EQU	gsc_cur_indexes_ptr-2
gsc_dmasnd_phase	EQU	gsc_cur_indexes_left-2
gsc_lmc_next_att	EQU	gsc_dmasnd_phase-2
gsc_bits_val		EQU	gsc_lmc_next_att-2
gsc_bits_cnt		EQU	gsc_bits_val-2
gsc_coding_blocks	EQU	gsc_bits_cnt-2
lo_var_gsc_end		EQU	gsc_coding_blocks
			
lo_buf_gsc_end		EQU	lo_buf_main_end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_init_int: bokeh isr to cleanly start the DMA Sound System
gsc_timer_a_init_int:
	move.l	a0,-(sp)

	; set ST-MFP-13 Vector (Timer A)
	lea	(gsc_timer_a_update_int),a0
	move.l	a0,$134.w

	; start DMA Sound System
	move.b	#$3,$ffff8901.w
	
	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  

	move.l	(sp)+,a0
	rte
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_update_int: everything happens here (decoding SoundChunks)
	
	macro	get_bit	; \1: dest reg
			subq.b	#1,d6
			bpl.s	.no_underflow\@
				move.w	(a2)+,d5
				moveq	#16-1,d6
		.no_underflow\@:
			add.w	d5,d5
			addx.w	\1,\1
	endm

	macro	get_bits	; \1: dest reg, \2: bit count
		rept \2
			get_bit \1
		endr
	endm
	
gsc_timer_a_update_int:
	movem.l	a0/a1/a2/a3/a4/d0/d1/d2/d5/d6/d7,-(sp)

	; sync only on second buffer (ie. half the time, good enough)
	tst.w	gsc_dmasnd_phase.w
	beq.s	.skew_end
	.second_buffer_playing:

		moveq.l	#0,d0
		move.l	d0,a0
		
		lea	(gsc_audio_buf+gsc_audio_buf_size+gsc_lmc_sample_skew),a1

		; already synced?
		movep.w	$ffff890b(a0),d1
		cmp.w	a1,d1
		bhs.s	.skew_end
		
		; stop Timer A
		move.b	d0,$fffffa19.w

		; loop until we are synced on the sample we want
		.skew_fix_lp:
			movep.w	$ffff890b(a0),d1
			cmp.w	a1,d1
			bne.s	.skew_fix_lp

		; continue Timer A
		move.b	#gsc_mfp_prescaler_code,$fffffa19.w
		
	.skew_end:

	; send attenuation to LMC1992 thru Microwire (when this command takes effect in the LMC, we are synced with the buffer start)
	move.w	gsc_lmc_next_att.w,$ffff8922.w
	
	; actual decoding

	move.w	#gsc_audio_buf_size,d0
	sub.w	gsc_dmasnd_phase.w,d0
	move.w	d0,gsc_dmasnd_phase.w	
	
	lea	(gsc_audio_buf),a1
	adda.w	d0,a1

	bra.s	.begin_decode

.next_frame:
	
	move.l	a2,a0
	bsr.w	gsc_next_frame

.begin_decode:
	
	; restore decoding state
	move.l	gsc_cur_indexes_ptr.w,a2
	lea	gsc_coding_blocks.w,a3
	move.l	gsc_cur_chunks_ptr.w,a4
	move.w	gsc_bits_val.w,d5
	move.w	gsc_bits_cnt.w,d6
	
	; decode attenuation
	moveq	#0,d0
	get_bits d0,4
	neg.w	d0
	add.w	#%10011000000+40,d0
	move.w	d0,gsc_lmc_next_att.w
		
	move.w	#gsc_chunks_per_att-1,d7
	.chunk_per_att_lp:
		subq.w	#1,gsc_cur_indexes_left.w
		bmi.s	.next_frame
			
		moveq	#0,d0
		get_bits d0,2
		
		moveq	#0,d1
		get_bit d1
		move.b	0(a3,d1.w),d1

		moveq	#0,d2
		.idx_bit_lp:
			get_bit	d2
			lsr.b	#1,d1
			bne.s	.idx_bit_lp
		mulu.w	#gsc_chunk_size,d2
		move.l	a4,a0
		adda.l	d2,a0	
		
		btst	#1,d0
		bne.s	.positive_reversed_chunk
		
		.positive_forward_chunk:
			rept	gsc_chunk_size
				move.b	(a0)+,(a1)+
			endr
			dbra.w	d7,.chunk_per_att_lp
			bra.s	.chunk_per_att_end
		
		.positive_reversed_chunk:
			addq.l	#gsc_chunk_size,a0
			
			rept	gsc_chunk_size
				move.b	-(a0),(a1)+
			endr
			dbra.w	d7,.chunk_per_att_lp
	
	.chunk_per_att_end:	

	; save decoding state
	move.l	a2,gsc_cur_indexes_ptr.w
	move.w	d5,gsc_bits_val.w
	move.w	d6,gsc_bits_cnt.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  		

	movem.l	(sp)+,a0/a1/a2/a3/a4/d0/d1/d2/d5/d6/d7
	rte

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_microwire_write_wait: (d0: command)
gsc_microwire_write_wait:
	move.l	d1,-(sp)

	move.w	$ffff8922.w,d1
	move.w	d0,$ffff8922.w
	.wait:
		cmp.w	$ffff8922.w,d1
		bne.s	.wait

	move.l	(sp)+,d1
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_next_frame: handle changing frame (a0: pointer on frame start)
gsc_next_frame:
	movem.l	a0/d0/d1/d2,-(sp)
	
	; read chunk count
	moveq	#0,d2
	move.b	(a0)+,d2
	addq.w	#1,d2
	mulu.w	#gsc_chunk_size,d2
		
	; read bass/treble
	moveq	#0,d1
	move.b	(a0)+,d1
	
	; apply treble
	move.w	d1,d0
	andi.w	#$000f,d0
	ori.w	#%10010000000,d0		; treble
	bsr.w	gsc_microwire_write_wait
	
	; apply bass
	move.w	d1,d0
	lsr.w	#4,d0
	ori.w	#%10001000000,d0		; bass
	bsr.w	gsc_microwire_write_wait
	
	move.l	a0,gsc_cur_chunks_ptr.w
	
	; skip chunks
	adda.l	d2,a0

	; read indexes count
	move.w	(a0)+,gsc_cur_indexes_left.w
	
	; read coding blocks
	move.w	(a0)+,gsc_coding_blocks.w
	
	move.l	a0,gsc_cur_indexes_ptr.w
	
	; initial bit packing state
	move.w	#0,gsc_bits_val.w
	move.w	#0,gsc_bits_cnt.w
	
	lea.l	gsc_cur_indexes_left.w,a0
	moveq	#8,d7
	bsr.w	print_buffer

	movem.l	(sp)+,a0/d0/d1/d2
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_init (a0: pointer on GSC data, d0: GSC data size)
gsc_init:
	movem.l	a0/a1/d0,-(sp)

	; initial state
	move.w	#gsc_audio_buf_size,gsc_dmasnd_phase.w

	; prepare decoding
	lea	gsc_header_size(a0),a1
	move.l	a1,gsc_start_ptr.w
	adda.l	d0,a1
	move.l	a1,gsc_end_ptr.w
	
	move.l	gsc_start_ptr.w,a0
	bsr.w	gsc_next_frame

	; set Microwire mask register
	move.w	#$7ff,$ffff8924.w

	; 25033Hz Mono Looping DMA Sound System
	clr.b	$ffff8901.w
	move.b	#$82,$ffff8921.w
	lea	(gsc_audio_buf),a0
	move.l	a0,d0
	swap.w	d0
	move.b	d0,$ffff8903.w
	rol.l	#8,d0
	move.b	d0,$ffff8905.w
	rol.l	#8,d0
	move.b	d0,$ffff8907.w
	lea	gsc_audio_dblbuf_size(a0),a0
	move.l	a0,d0
	swap.w	d0
	move.b	d0,$ffff890f.w
	rol.l	#8,d0
	move.b	d0,$ffff8911.w
	rol.l	#8,d0
	move.b	d0,$ffff8913.w

	; setup MFP Timer A (slightly faster than buffer length)
	bset.b	#5,$fffffa07.w
	bclr.b	#5,$fffffa0b.w
	bclr.b	#5,$fffffa0f.w
	bset.b	#5,$fffffa13.w
	move.b	#$10+gsc_mfp_prescaler_code,$fffffa19.w
	move.b	#gsc_timer_data,$fffffa1f.w

	; set ST-MFP-13 Vector (Timer A)
	move.l	$134.w,gsc_timer_a_int_save.w
	lea	(gsc_timer_a_init_int),a0
	move.l	a0,$134.w

	; start Timer A
	bclr.b	#4,$fffffa19.w

	movem.l	(sp)+,a0/a1/d0
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_finish
gsc_finish:
	; stop Timer A
	bset.b	#4,$fffffa19.w
	bclr.b	#5,$fffffa07.w
	
	; stop DMA Sound System
	clr.b	$ffff8901.w
	
	; reset LMC1992 thru Microwire
	move.w	#%10011000000+40,d0		; master volume
	bsr.w	gsc_microwire_write_wait
	move.w	#%10010000000+6,d0		; treble
	bsr.w	gsc_microwire_write_wait
	move.w	#%10001000000+6,d0		; bass
	bsr.w	gsc_microwire_write_wait

	; restore ST-MFP-13 Vector (Timer A)
	move.l	gsc_timer_a_int_save.w,$134.w
	
	rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

gsc_audio_buf:
	ds.b	gsc_audio_dblbuf_size

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA
