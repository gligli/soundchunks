;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  CONSTANTS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gsc_audio_buf_size	EQU	1000

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  VARIABLES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

lo_var_gsc_end		EQU	lo_var_main_end
			
lo_buf_gsc_end		EQU	lo_buf_main_end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  MACROS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	macro	mac				;
	endm

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  ROUTINES  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	SECTION TEXT

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_init_int
gsc_timer_a_init_int:
	movem.l	a0/d0,-(sp)

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
	lea	gsc_audio_buf_size(a0),a0
	move.l	a0,d0
	swap.w	d0
	move.b	d0,$ffff890f.w
	rol.l	#8,d0
	move.b	d0,$ffff8911.w
	rol.l	#8,d0
	move.b	d0,$ffff8913.w

	; start DMA Sound System
	move.b	#$3,$ffff8901.w

	; set ST-MFP-13 Vector (Timer A)
	lea	(gsc_timer_a_update_int),a0
	move.l	a0,$134.w

	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  

	movem.l	(sp)+,a0/d0
	rte
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_timer_a_update_int
gsc_timer_a_update_int:
	movem.l	a0-a1/d0,-(sp)
	
	lea	(gsc_audio_buf),a1

	macro	sn
		lea	(sintmp),a0
		move.w	#gsc_audio_buf_size/4/5-1,d0
		.lp\@:
			move.b	(a0)+,(a1)+
			move.b	(a0)+,(a1)+
			move.b	(a0)+,(a1)+
			move.b	(a0)+,(a1)+
			move.b	(a0)+,(a1)+
			dbra.w	d0,.lp\@
	endm

	rept 	gsc_audio_buf_size/250
		sn
	endr
	
	; interrupt not "in service" anymore
	bclr.b	#5,$fffffa0f.w  

	movem.l	(sp)+,a0-a1/d0
	rte
	
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	; gsc_init
gsc_init:
	moveq.l	#0,d1

	; 200Hz MFP Timer A
	bset.b	#5,$fffffa07.w
	bclr.b	#5,$fffffa0b.w
	bclr.b	#5,$fffffa0f.w
	bset.b	#5,$fffffa13.w
	move.b	#$15,$fffffa19.w
	move.b	#192,$fffffa1f.w

	; set ST-MFP-13 Vector (Timer A)
	lea	(gsc_timer_a_init_int),a0
	move.l	a0,$134.w

	; start Timer A
	bclr.b	#4,$fffffa19.w

	rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  BSS  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION	BSS

gsc_audio_buf:
	ds.b	gsc_audio_buf_size

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  DATA  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	SECTION DATA
	
sintmp:
	dc.b 127,127,127,127,126,126,126,125,124,124,123,122,121,120,119,118,117,116,114,113,111,110,108,106,105,103,101,99,97,95,93,90,88,86,83,81,78,76,73,71,68,65,63,60,57,54,51,48,45,42,39,36,33,30,27,24,21,17,14,11,8,5,2,-2,-5,-8,-11,-14,-17,-21,-24,-27,-30,-33,-36,-39,-42,-45,-48,-51,-54,-57,-60,-63,-65,-68,-71,-73,-76,-78,-81,-83,-86,-88,-90,-93,-95,-97,-99,-101,-103,-105,-106,-108,-110,-111,-113,-114,-116,-117,-118,-119,-120,-121,-122,-123,-124,-124,-125,-126,-126,-126,-127,-127,-127,-127,-127,-127,-127,-126,-126,-126,-125,-124,-124,-123,-122,-121,-120,-119,-118,-117,-116,-114,-113,-111,-110,-108,-106,-105,-103,-101,-99,-97,-95,-93,-90,-88,-86,-83,-81,-78,-76,-73,-71,-68,-65,-63,-60,-57,-54,-51,-48,-45,-42,-39,-36,-33,-30,-27,-24,-21,-17,-14,-11,-8,-5,-2,2,5,8,11,14,17,21,24,27,30,33,36,39,42,45,48,51,54,57,60,63,65,68,71,73,76,78,81,83,86,88,90,93,95,97,99,101,103,105,106,108,110,111,113,114,116,117,118,119,120,121,122,123,124,124,125,126,126,126,127,127,127
	
	even