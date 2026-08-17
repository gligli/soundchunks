
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

gsc_audio_buf_size	EQU	gsc_chunks_per_att*gsc_chunk_size
gsc_audio_dblbuf_size	EQU	gsc_audio_buf_size*2

gsc_timer_data_num	EQU	mfp_clock_rate/(gsc_sample_rate/gsc_chunk_size/gsc_chunks_per_att)
gsc_timer_data		EQU	gsc_timer_data_num/gsc_mfp_prescaler_value-1

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gsc_dmasnd_phase	EQU	lo_var_main_end-2
gsc_lmc_next_att	EQU	gsc_dmasnd_phase-2
lo_var_gsc_end		EQU	gsc_lmc_next_att
			
lo_buf_gsc_end		EQU	lo_buf_main_end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	macro	mac				;
	endm

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_init_int
gsc_timer_a_init_int:
	move.l	a0,-(sp)

	; set ST-MFP-13 Vector (Timer A)
	lea	(gsc_timer_a_update_int),a0
	move.l	a0,$134.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  

	; start DMA Sound System
	move.b	#$3,$ffff8901.w
	
	move.l	(sp)+,a0
	rte
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_update_int
gsc_timer_a_update_int:
	movem.l	a0-a2/d0-d1,-(sp)

	tst.w	gsc_dmasnd_phase.w
	beq.s	.skew_end
	.second_buffer_playing:

		moveq.l	#0,d0
		move.l	d0,a2
		lea	(gsc_audio_buf+gsc_audio_buf_size+gsc_lmc_sample_skew),a1

		movep.w	$ffff890b(a2),d1
		cmp.w	a1,d1
		bhs.s	.skew_end
		
		move.b	d0,$fffffa19.w

		.skew_fix_lp1:
			movep.w	$ffff890b(a2),d1
			cmp.w	a1,d1
			bne.s	.skew_fix_lp1

		move.b	#gsc_mfp_prescaler_code,$fffffa19.w
		
	.skew_end:

	move.w	gsc_lmc_next_att.w,$ffff8922.w

	lea	(gsc_audio_buf),a1
	lea	(sintmp),a0
	
	move.w	#$4c0+40,d1
	move.w	#gsc_audio_buf_size,d0
	sub.w	gsc_dmasnd_phase.w,d0
	adda.w	d0,a1
	adda.w	d0,a0
	move.w	d0,gsc_dmasnd_phase.w	
	bne.s	.nrm_lmc
		subi.w	#6,d1	; -12dB
	.nrm_lmc:
	move.w	d1,gsc_lmc_next_att.w

	move.w	#gsc_audio_buf_size/gsc_chunk_size-1,d0
	.lp:
		rept	gsc_chunk_size
			move.b	(a0)+,(a1)+
		endr
		dbra.w	d0,.lp

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  		

	movem.l	(sp)+,a0-a2/d0-d1
	rte


	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_init
gsc_init:
	move.w	#gsc_audio_buf_size,gsc_dmasnd_phase.w

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

	; 200Hz MFP Timer A
	bset.b	#5,$fffffa07.w
	bclr.b	#5,$fffffa0b.w
	bclr.b	#5,$fffffa0f.w
	bset.b	#5,$fffffa13.w
	move.b	#$10+gsc_mfp_prescaler_code,$fffffa19.w
	move.b	#gsc_timer_data,$fffffa1f.w

	; set ST-MFP-13 Vector (Timer A)
	lea	(gsc_timer_a_init_int),a0
	move.l	a0,$134.w

	; start Timer A
	bclr.b	#4,$fffffa19.w

	rts

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_finish
gsc_finish:
	rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

gsc_audio_buf:
	ds.b	gsc_audio_dblbuf_size

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA
	
sintmp:
	dc.b 127,127,127,127,126,126,125,125,124,123,123,122,121,120,119,117,116,115,113,112,110,108,107,105,103,101,99,97,94,92,90,87,85,82,80,77,75,72,69,66,64,61,58,55,52,49,46,42,39,36,33,30,26,23,20,17,13,10,7,3,0,-3,-7,-10,-13,-17,-20,-23,-26,-30,-33,-36,-39,-42,-46,-49,-52,-55,-58,-61,-64,-66,-69,-72,-75,-77,-80,-82,-85,-87,-90,-92,-94,-97,-99,-101,-103,-105,-107,-108,-110,-112,-113,-115,-116,-117,-119,-120,-121,-122,-123,-123,-124,-125,-125,-126,-126,-127,-127,-127,-127,-127,-127,-127,-126,-126,-125,-125,-124,-123,-123,-122,-121,-120,-119,-117,-116,-115,-113,-112,-110,-108,-107,-105,-103,-101,-99,-97,-94,-92,-90,-87,-85,-82,-80,-77,-75,-72,-69,-66,-64,-61,-58,-55,-52,-49,-46,-42,-39,-36,-33,-30,-26,-23,-20,-17,-13,-10,-7,-3,0,3,7,10,13,17,20,23,26,30,33,36,39,42,46,49,52,55,58,61,64,66,69,72,75,77,80,82,85,87,90,92,94,97,99,101,103,105,107,108,110,112,113,115,116,117,119,120,121,122,123,123,124,125,125,126,126,127,127,127,32,32,32,32,32,32,31,31,31,31,31,31,30,30,30,29,29,29,28,28,28,27,27,26,26,25,25,24,24,23,23,22,21,21,20,19,19,18,17,17,16,15,15,14,13,12,12,11,10,9,8,8,7,6,5,4,3,3,2,1,0,-1,-2,-3,-3,-4,-5,-6,-7,-8,-8,-9,-10,-11,-12,-12,-13,-14,-15,-15,-16,-17,-17,-18,-19,-19,-20,-21,-21,-22,-23,-23,-24,-24,-25,-25,-26,-26,-27,-27,-28,-28,-28,-29,-29,-29,-30,-30,-30,-31,-31,-31,-31,-31,-31,-32,-32,-32,-32,-32,-32,-32,-32,-32,-32,-32,-31,-31,-31,-31,-31,-31,-30,-30,-30,-29,-29,-29,-28,-28,-28,-27,-27,-26,-26,-25,-25,-24,-24,-23,-23,-22,-21,-21,-20,-19,-19,-18,-17,-17,-16,-15,-15,-14,-13,-12,-12,-11,-10,-9,-8,-8,-7,-6,-5,-4,-3,-3,-2,-1,0,1,2,3,3,4,5,6,7,8,8,9,10,11,12,12,13,14,15,15,16,17,17,18,19,19,20,21,21,22,23,23,24,24,25,25,26,26,27,27,28,28,28,29,29,29,30,30,30,31,31,31,31,31,31,32,32,32,32,32
	
	even