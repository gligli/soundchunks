; GliGli's SoundChunks decoder
;
; Author: GliGli
; License: GNU GPL3

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  CONSTANTS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; tweakable

gsc_default_volume	EQU	40-3	; -3 = -6dB

gsc_chunk_size		EQU	6
gsc_chunks_per_att	EQU	36

gsc_mfp_prescaler_value	EQU	100	; /!\ keep both gsc_mfp_prescaler_* synced!
gsc_mfp_prescaler_code	EQU	6

gsc_timer_data		EQU	212

gsc_timer_skew		EQU	3
gsc_lmc_sample_skew	EQU	20

; shouldn't be tweaked

gsc_stream_version	EQU	7
gsc_header_size		EQU	80

gsc_audio_buf_size	EQU	gsc_chunks_per_att*gsc_chunk_size
gsc_audio_dblbuf_size	EQU	gsc_audio_buf_size*2

gsc_timer_skewed_data	EQU	gsc_timer_data-gsc_timer_skew

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gsc_timer_a_int_save	EQU	lo_var_main_end-4
gsc_start_ptr		EQU	gsc_timer_a_int_save-4
gsc_end_ptr		EQU	gsc_start_ptr-4
gsc_volume		EQU	gsc_end_ptr-2
gsc_channel_count	EQU	gsc_volume-2
gsc_frame_chunks_size	EQU	gsc_channel_count-4
gsc_coding_block_m2	EQU	gsc_frame_chunks_size-2
gsc_cur_chunks_ptr	EQU	gsc_coding_block_m2-4
gsc_cur_indexes_ptr	EQU	gsc_cur_chunks_ptr-4
gsc_cur_att_left	EQU	gsc_cur_indexes_ptr-2
gsc_dmasnd_phase	EQU	gsc_cur_att_left-2
gsc_lmc_next_bass_treb	EQU	gsc_dmasnd_phase-4
gsc_lmc_next_att	EQU	gsc_lmc_next_bass_treb-2
gsc_bits_val		EQU	gsc_lmc_next_att-2
gsc_bits_cnt		EQU	gsc_bits_val-2
gsc_coding_blocks_bits	EQU	gsc_bits_cnt-32
gsc_coding_blocks_cmls	EQU	gsc_coding_blocks_bits-32
lo_var_gsc_end		EQU	gsc_coding_blocks_cmls
			
lo_buf_gsc_end		EQU	lo_buf_main_end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_init_int: bokeh isr to cleanly start the DMA Sound System
gsc_timer_a_init_int:
	; start DMA Sound System
	move.b	#$3,$ffff8901.w
	
	; disable irqs while decoding
	move    #$2700,SR

	; set ST-MFP-13 Vector (Timer A)
	move.l	#gsc_timer_a_update_int,$134.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  

	rte
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_update_int: everything happens here (decoding SoundChunks)
	
	macro	get_bit	; \1: dest reg, \2: carry output only?
			subq.b	#1,d6
			bpl.s	.no_underflow\@
				move.w	(a2)+,d5
				moveq	#16-1,d6
		.no_underflow\@:
			add.w	d5,d5
			
			ifeq	\2
				addx.w	\1,\1
			endif			
	endm

	macro	get_bits	; \1: dest reg, \2: bit count
		rept \2
			get_bit \1,0
		endr
	endm
	
gsc_timer_a_update_int:
	; disable irqs while decoding
	move    #$2700,SR

	movem.l	a0-a5/d0-d7,-(sp)

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
	
	; send new bass/treble levels to LMC1992 (after a new frame)
	
	move.l	gsc_lmc_next_bass_treb.w,d0
	beq.s	.no_new_lmc_bt

.new_lmc_bt:
	
	bsr.w	gsc_microwire_write_wait
	swap.w	d0
	bsr.w	gsc_microwire_write_wait
	clr.l	gsc_lmc_next_bass_treb.w
	
.no_new_lmc_bt:
	
	; actual decoding

	move.w	#gsc_audio_buf_size,d0
	sub.w	gsc_dmasnd_phase.w,d0
	move.w	d0,gsc_dmasnd_phase.w	
	
	lea	(gsc_audio_buf),a1
	adda.w	d0,a1

	tst.w	gsc_cur_att_left.w
	bne.s	.begin_decode

.next_frame:
	
	move.l	gsc_cur_indexes_ptr.w,a0
	bsr.w	gsc_next_frame

.begin_decode:
	
	; restore decoding state
	move.l	gsc_cur_indexes_ptr.w,a2
	lea	gsc_coding_blocks_bits.w,a3
	move.l	gsc_cur_chunks_ptr.w,a4
	move.w	gsc_coding_block_m2.w,a5
	move.w	gsc_bits_val.w,d5
	move.w	gsc_bits_cnt.w,d6
	
	; decode attenuation
	moveq	#0,d0
	get_bits d0,4
	neg.w	d0
	add.w	#%10011000000,d0
	add.w	gsc_volume.w,d0
	move.w	d0,gsc_lmc_next_att.w
	
	; decode mirrors & chunk index & upload chunk data to dmasnd buffer
	move.w	#gsc_chunks_per_att-1,d7
	.chunk_per_att_lp:

		; decode mirrors
		
			; negative?
		moveq	#0,d0
		get_bit d0,0	
			
			; reversed?
		moveq	#0,d4
		get_bit d4,0	
		
		; decode chunk index
		
			; decode coding block index
		move.w	a5,d2
		bmi.s	.no_coding_bits

		.has_coding_bits:
		
			.coding_bits_lp:
				get_bit	carry,1
				dbcc.w	d2,.coding_bits_lp
		
			add.w	d2,d2
			
		.no_coding_bits:
		
			; decode actual chunk index
		moveq	#0,d1
		move.w	0(a3,d2.w),d3
		bmi.s	.no_index_bits
		
		.has_index_bits:
		
			.index_bits_lp:
				get_bit	d1,0
				dbra.w	d3,.index_bits_lp
		
		.no_index_bits:
		
		add.w	-32(a3,d2.w),d1

		; convert to chunk ptr

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

	; we uploaded one attenuation to dmasnd
	subq.w	#1,gsc_cur_att_left.w

	; save decoding state
	move.l	a2,gsc_cur_indexes_ptr.w
	move.w	d5,gsc_bits_val.w
	move.w	d6,gsc_bits_cnt.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  		

	movem.l	(sp)+,a0-a5/d0-d7
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
	movem.l	a0/a1/d0/d1/d2/d3/d4,-(sp)
	
	; test	end-of-data and loop
	cmpa.l	gsc_end_ptr.w,a0
	blo.s	.no_eof
	.eof:
		move.l	gsc_start_ptr.w,a0
	.no_eof:
	
	; read attenuation count
	move.w	(a0)+,d0
	addq.w	#1,d0
	move.w	d0,gsc_cur_att_left.w
	
	; read bass/treble
	moveq	#0,d1
	move.b	(a0)+,d1
	
	; get treble LMC command
	move.w	d1,d0
	andi.w	#$000f,d0
	ori.w	#%10010000000,d0		; treble
	
	swap.w	d0
	
	; get bass LMC command
	move.w	d1,d0
	lsr.w	#4,d0
	ori.w	#%10001000000,d0		; bass

	move.l	d0,gsc_lmc_next_bass_treb.w

	; read coding block count
	moveq	#0,d2
	move.b	(a0)+,d2
	subq.w	#2,d2
	move.w	d2,gsc_coding_block_m2.w

	; store chunk ptr
	move.l	a0,gsc_cur_chunks_ptr.w
	
	; skip chunks
	adda.l	gsc_frame_chunks_size.w,a0

	; read coding blocks
	move.w	d2,d1
	addq.w	#1,d1
	lsr.w	#2,d1
	moveq	#$f,d4
	lea	gsc_coding_blocks_bits+2.w,a1
	adda.w	d2,a1
	adda.w	d2,a1
	.cb_read_denibble_lp:
		move.w	(a0)+,d0
		
		rept	4
			rol.w	#4,d0
			move.w	d0,d3
			and.w	d4,d3
			subq.w	#1,d3
			move.w	d3,-(a1)
		endr
		
		dbra.w	d1,.cb_read_denibble_lp
	
	; store indexes ptr
	move.l	a0,gsc_cur_indexes_ptr.w
	
	; convert coding block to (cumulated) coding values
	tst.w	d2
	bmi.s	.no_cumulation
	
	.cumulation:	

		lea	gsc_coding_blocks_bits+2.w,a1
		adda.w	d2,a1
		adda.w	d2,a1
		lea	-32-2(a1),a0
		clr.w	(a0)
		.cb_cumulate_lp:
			move.w	-(a1),d0
			addq.w	#1,d0
			moveq	#1,d1
			lsl.w	d0,d1
			add.w	(a0),d1
			move.w	d1,-(a0)
			dbra.w	d2,.cb_cumulate_lp

	.no_cumulation:	

	; initial bit packing state
	move.w	#0,gsc_bits_val.w
	move.w	#0,gsc_bits_cnt.w
	
	movem.l	(sp)+,a0/a1/d0/d1/d2/d3/d4
	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_init (a0: pointer on GSC data, d0: GSC data size; retusns: d0: 0 on success)
gsc_init:
	movem.l	a0/a1/d1,-(sp)

	; initial state
	move.w	#gsc_audio_buf_size,gsc_dmasnd_phase.w
	move.w	#gsc_default_volume,gsc_volume.w
	
	; clear audio buffer
	lea	(gsc_audio_buf),a1
	moveq	#gsc_audio_dblbuf_size/4-1,d1
	.clr_audio_buf_lp:
		clr.l	(a1)+
		dbra.w	d1,.clr_audio_buf_lp

	; prepare decoding

	cmpi.l	#$47534361,(a0)			; 'GSCa' header
	bne.w	.fail
	
	cmpi.b	#gsc_stream_version,4(a0)	; 'CStreamVersion'
	bne.w	.fail						
	
	cmpi.b	#gsc_chunk_size,6(a0)		; 'ChunkSize'
	bne.w	.fail						

	move.b	5(a0),gsc_channel_count.w	; 'ChannelCount'

	move.w	10(a0),d1			; 'ChunksPerFrame - 1'
	addq.w	#1,d1
	mulu.w	#gsc_chunk_size,d1
	move.l	d1,gsc_frame_chunks_size.w
	
	lea	gsc_header_size(a0),a1
	sub.l	#gsc_header_size,d0
	move.l	a1,gsc_start_ptr.w
	adda.l	d0,a1
	move.l	a1,gsc_end_ptr.w
	
	move.l	gsc_start_ptr.w,gsc_cur_indexes_ptr.w
	move.w	#%10011000000,d0
	add.w	gsc_volume.w,d0
	move.w	d0,gsc_lmc_next_att.w
	clr.w	gsc_cur_att_left.w
	clr.l	gsc_lmc_next_bass_treb.w

	; set Microwire mask register
	move.w	#$7ff,$ffff8924.w

	; init LMC1992 thru Microwire
	move.w	#%10011000000,d0		; master volume
	add.w	gsc_volume.w,d0
	bsr.w	gsc_microwire_write_wait
	move.w	#%10010000000+0,d0		; treble
	bsr.w	gsc_microwire_write_wait
	move.w	#%10001000000+12,d0		; bass
	bsr.w	gsc_microwire_write_wait
	move.w	#%10000000001,d0 		; mixer
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
	move.l	#gsc_timer_a_init_int,$134.w

	; start Timer A
	bclr.b	#4,$fffffa19.w

	; success!
	moveq.l	#0,d0

.end:
	movem.l	(sp)+,a0/a1/d1
	rts

.fail:
	; failure...
	moveq.l	#-1,d0
	bra.s	.end

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

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_set_volume (d0: 0-40 volume; returns: d0: valid volume)
gsc_set_volume:
	tst.w	d0
	bpl.s	.no_too_lo_volume
.too_lo_volume:
		clr.w	d0
.no_too_lo_volume:

	cmp.w	#40,d0
	blo.s	.no_too_hi_volume
.too_hi_volume:
		move.w	#40,d0
.no_too_hi_volume:

	move.w	d0,gsc_volume.w

	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_get_volume (returns d0: 0-40 volume)
gsc_get_volume:
	move.w	gsc_volume.w,d0
	
	rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

gsc_audio_buf:
	ds.b	gsc_audio_dblbuf_size

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA
