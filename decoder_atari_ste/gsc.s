; GliGli's SoundChunks decoder
;
; Author: GliGli
; License: GNU GPL3

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  CONSTANTS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; tweakable

gsc_volume_compensation	EQU	0	; eg. 6 = 12dB

gsc_chunk_size		EQU	6
gsc_chunks_per_att	EQU	36

gsc_mfp_prescaler_value	EQU	100	; /!\ keep both gsc_mfp_prescaler_* synced!
gsc_mfp_prescaler_code	EQU	6

gsc_timer_data		EQU	212

gsc_timer_skew		EQU	3
gsc_lmc_sample_skew	EQU	20

; shouldn't be tweaked

gsc_header_size		EQU	80

gsc_audio_buf_size	EQU	gsc_chunks_per_att*gsc_chunk_size
gsc_audio_dblbuf_size	EQU	gsc_audio_buf_size*2

gsc_timer_skewed_data	EQU	gsc_timer_data-gsc_timer_skew

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
gsc_coding_blocks_bits	EQU	gsc_bits_cnt-2
gsc_coding_blocks_val	EQU	gsc_coding_blocks_bits-2
gsc_coding_blocks_dummy	EQU	gsc_coding_blocks_val-2
lo_var_gsc_end		EQU	gsc_coding_blocks_dummy
			
lo_buf_gsc_end		EQU	lo_buf_main_end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_init_int: bokeh isr to cleanly start the DMA Sound System
gsc_timer_a_init_int:
	; disable irqs while decoding
	move    #$2700,SR

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
	; disable irqs while decoding
	move    #$2700,SR

	movem.l	a0-a4/d0-d7,-(sp)

	; sync timer on buffer start

	moveq.l	#0,d0
	move.l	d0,a0
	
	lea	(gsc_audio_buf+gsc_lmc_sample_skew),a1
	add.w	gsc_dmasnd_phase.w,a1

	; wait any change on "Frame address counter", so that just after, nothing can change and we can read the entire value
	move.b	$ffff890d.w,d1
	.wait_change_lp:
		move.b	d1,d0	
		move.b	$ffff890d.w,d1
		cmp.b	d1,d0
		beq.s	.wait_change_lp

	; get relative sample position
	movep.l	$ffff8907(a0),d1
	andi.l	#$00ffffff,d1
	sub.l	a1,d1
	
	; negative feedback loop on timer data from sample position
	asr.b	#2,d1
	move.b	#gsc_timer_skewed_data,d0
	sub.b	d1,d0
	move.b	d0,$fffffa1f.w

	; send attenuation to LMC1992 thru Microwire (when this command takes effect in the LMC, we are synced with the buffer start)
	
	move.w	gsc_lmc_next_att.w,d0
	bsr.w	gsc_microwire_write_wait
	
	; actual decoding

	move.w	#gsc_audio_buf_size,d0
	sub.w	gsc_dmasnd_phase.w,d0
	move.w	d0,gsc_dmasnd_phase.w	
	
	lea	(gsc_audio_buf),a1
	adda.w	d0,a1

	cmpi.w	#-1,gsc_cur_indexes_left.w
	bne.s	.begin_decode

.next_frame:
	
	move.l	gsc_cur_indexes_ptr.w,a0
	bsr.w	gsc_next_frame

.begin_decode:
	
	; restore decoding state
	move.l	gsc_cur_indexes_ptr.w,a2
	lea	gsc_coding_blocks_val.w,a3
	move.l	gsc_cur_chunks_ptr.w,a4
	move.w	gsc_bits_val.w,d5
	move.w	gsc_bits_cnt.w,d6
	
	; decode attenuation
	moveq	#0,d0
	get_bits d0,4
	neg.w	d0
	add.w	#%10011000000+40-gsc_volume_compensation,d0
	move.w	d0,gsc_lmc_next_att.w
	
	; decode mirrors & chunk index & upload chunk data to dmasnd buffer
	move.w	#gsc_chunks_per_att-1,d7
	.chunk_per_att_lp:

		; decode mirrors
		moveq	#0,d0
		get_bit d0	; negative?
		moveq	#0,d4
		get_bit d4	; reversed?
		
		; decode chunk index
		moveq	#0,d2
		get_bit d2
		moveq	#0,d3
		move.b	2(a3,d2.w),d3
		moveq	#0,d1
		.idx_bit_lp:
			get_bit	d1
			dbra.w	d3,.idx_bit_lp
		add.b	-1(a3,d2.w),d1

		ifeq	gsc_chunk_size-6
			add.w	d1,d1
			move.w	d1,d2
			add.w	d2,d2
			add.w	d2,d1
		else
			mulu.w	#gsc_chunk_size,d1
		endif
		
		move.l	a4,a0
		adda.l	d1,a0

		; upload chunk data to dmasnd buffer
		tst.b	d0
		bne.s	.negative_any_chunk

		.positive_any_chunk:
			tst.b	d4
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
				bra.s	.chunk_per_att_end
	
		.negative_any_chunk:
			tst.b	d4
			bne.s	.negative_reversed_chunk
			
			.negative_forward_chunk:
				rept	gsc_chunk_size
					move.b	(a0)+,d0
					neg.b	d0
					move.b	d0,(a1)+
				endr
				dbra.w	d7,.chunk_per_att_lp
				bra.s	.chunk_per_att_end
			
			.negative_reversed_chunk:
				addq.l	#gsc_chunk_size,a0
				
				rept	gsc_chunk_size
					move.b	-(a0),d0
					neg.b	d0
					move.b	d0,(a1)+
				endr
				dbra.w	d7,.chunk_per_att_lp
				
	.chunk_per_att_end:	

	; we uploaded gsc_chunks_per_att to dmasnd
	subi.w	#gsc_chunks_per_att,gsc_cur_indexes_left.w

	; save decoding state
	move.l	a2,gsc_cur_indexes_ptr.w
	move.w	d5,gsc_bits_val.w
	move.w	d6,gsc_bits_cnt.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  		

	movem.l	(sp)+,a0-a4/d0-d7
	rte

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_microwire_write_wait: (d0: command)
gsc_microwire_write_wait:
	movem.l	a0/d1,-(sp)

	lea	$ffff8922.w,a0

	move.w	(a0),d1
	
	; do it
	
	move.w	d0,(a0)
	.wait:
		cmp.w	(a0),d1
		bne.s	.wait

	; ... then wait the same amount of time

	rept	7
		ori.b	#0,ccr
	endr

	; ... then do it again

	move.w	d0,(a0)
	.wait2:
		cmp.w	(a0),d1
		bne.s	.wait2

	; ... profit! (it then works reliably on real hw =)

	movem.l	(sp)+,a0/d1
	rts
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_next_frame: handle changing frame (a0: pointer on frame start)
gsc_next_frame:
	movem.l	a0/d0/d1/d2,-(sp)
	
	; test	end-of-data and loop
	cmpa.l	gsc_end_ptr.w,a0
	blo.s	.no_eof
	.eof:
		move.l	gsc_start_ptr.w,a0
	.no_eof:
	
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

	; store chunk ptr
	move.l	a0,gsc_cur_chunks_ptr.w
	
	; skip chunks
	adda.l	d2,a0

	; read indexes count
	move.w	(a0)+,gsc_cur_indexes_left.w
	
	; read coding blocks
	move.w	(a0)+,gsc_coding_blocks_val.w
	
	; store indexes ptr
	move.l	a0,gsc_cur_indexes_ptr.w
	
	; convert coding block values to coding bits
	
	move.b	gsc_coding_blocks_val+0.w,d1
	subq.b	#1,d1
	moveq	#-1,d2
	.lo_cb_val_lp:
		addq.b	#1,d2
		lsr.b	#1,d1
		bne.s	.lo_cb_val_lp
	move.b	d2,gsc_coding_blocks_bits+0.w
	
	move.b	gsc_coding_blocks_val+1.w,d1
	subq.b	#1,d1
	moveq	#-1,d2
	.hi_cb_val_lp:
		addq.b	#1,d2
		lsr.b	#1,d1
		bne.s	.hi_cb_val_lp
	move.b	d2,gsc_coding_blocks_bits+1.w
		
	; initial bit packing state
	move.w	#0,gsc_bits_val.w
	move.w	#0,gsc_bits_cnt.w
	
	movem.l	(sp)+,a0/d0/d1/d2
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_init (a0: pointer on GSC data, d0: GSC data size)
gsc_init:
	movem.l	a0/a1/d0,-(sp)

	; initial state
	move.w	#gsc_audio_buf_size,gsc_dmasnd_phase.w
	move.w	#0,gsc_coding_blocks_dummy.w

	; prepare decoding
	
	lea	gsc_header_size(a0),a1
	sub.l	#gsc_header_size,d0
	move.l	a1,gsc_start_ptr.w
	adda.l	d0,a1
	move.l	a1,gsc_end_ptr.w
	
	move.l	gsc_start_ptr.w,gsc_cur_indexes_ptr.w
	add.w	#%10011000000+40,gsc_lmc_next_att.w
	move.w	#-1,gsc_cur_indexes_left.w

	; set Microwire mask register
	move.w	#$7ff,$ffff8924.w

	; init LMC1992 thru Microwire
	move.w	#%10011000000+40-gsc_volume_compensation,d0	; master volume
	bsr.w	gsc_microwire_write_wait
	move.w	#%10010000000+0,d0				; treble
	bsr.w	gsc_microwire_write_wait
	move.w	#%10001000000+12,d0				; bass
	bsr.w	gsc_microwire_write_wait
	move.w	#%10000000010,d0 				; mixer
	bsr.w	gsc_microwire_write_wait

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
	move.b	#gsc_timer_skewed_data,$fffffa1f.w

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
	move.w	#%10000000001,d0 		; mixer
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
