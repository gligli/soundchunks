
OUT = STeGSC.prg

SRC = main.s

AS = ./vasm/vasmm68k_mot
AS_FLAGS = -unnamed-sections -m68000 -devpac -align -Ftos -L main.lst

all: $(OUT)

$(OUT): $(SRC)
	$(AS) $(AS_FLAGS) -o $(OUT) $(SRC)
	cp $(OUT) ../../stdev/disk/AUTO/$(OUT)

clean:
	rm -f $(OUT)
