program encoder;

{$mode objfpc}{$H+}

uses
  windows, Classes, sysutils, strutils, Types, fgl, math,
  extern, mtpool;

const
  CStreamVersion = 5;

{$ifdef ATARI_STE}
  CMaxAttenuationBits = 4;
  CAttenuationLawDecibels = 2.0;
  CMinChunksPerFrame = 8;
  CMaxChunksPerFrame = 256;
{$else}
  CMaxAttenuationBits = 6;
  CAttenuationLawDecibels = 0.75;
  CMinChunksPerFrame = 8;
  CMaxChunksPerFrame = 65536;
{$endif}

  CMaxAttenuation = (1 shl CMaxAttenuationBits) - 1;

type
  TEncoder = class;
  TFrame = class;
  TChunk = class;

  { TEmphasisFilter }

  TEmphasisFilter = class
  protected
    sampleRate: Integer;
  public
    constructor Create(ASampleRate: Integer); virtual;
    procedure Init; virtual; abstract;
    function PreFilter(s: Double): Double; virtual; abstract;
    function DeFilter(s: Double): Double; virtual; abstract;
  end;

  { TDeltaFilter }

  TDeltaFilter = class(TEmphasisFilter)
  private
    prevSample: Double;
    accSample: Double;
  public
    procedure Init; override;
    function PreFilter(s: Double): Double; override;
    function DeFilter(s: Double): Double; override;
  end;

  { TLMC1992Filter }

  // code ported from https://framagit.org/hatari/hatari/-/blob/main/src/dmaSnd.c?ref_type=heads
  // updated with code from https://docs.rs/ym2149-sndh-replayer/latest/src/ym2149_sndh_replayer/lmc1992.rs.html
  TLMC1992Filter = class(TEmphasisFilter)
  const
    TONE_STEPS = 13;
    NEUTRAL_TONE = 6;
  type
    TFirstOrder = record
      a1, b0, b1: Double;
    end;
  private
    bass_table: array[0 .. TONE_STEPS - 1] of TFirstOrder;
    treb_table: array[0 .. TONE_STEPS - 1] of TFirstOrder;

    coef: array[Boolean{DeFilter?}, Boolean{treble?}] of TFirstOrder;

    data: array[Boolean{DeFilter?}, Boolean{treble?}] of record
      x1, y1: Double;
    end;

    function Bass_Shelf(g, fc, Fs: Double): TFirstOrder;
    function Treble_Shelf(g, fc, Fs: Double): TFirstOrder;

    function BiQuad(input: Double; ADefilter, ATreble: Boolean): Double;
  public
    bass_level, treb_level: Byte;

    constructor Create(ASampleRate: Integer); override;
    procedure Init; override;
    function PreFilter(s: Double): Double; override;
    function DeFilter(s: Double): Double; override;

    procedure Set_Tone_Level(set_bass, set_treb: Byte);
  end;

  { TPiggyCoder }

  TPiggyCoder = class
  type
    TCode = record
      Code: Cardinal;
      ExtraBits: Cardinal;
      ExtraBitCount: Byte;
    end;
    TCodeArray = array of TCode;
    TCodingBlock = record
      BitSize: Byte;
      Value: Cardinal;
    end;
  private
    codingBlocks: array[0 .. High(Byte)] of TCodingBlock;
    highestCode: Cardinal;
    codes: TCodeArray;
    codesBitCount: Byte;

    solveByValue: Boolean;
    codingBlocksBits: Byte;
    codingBlocksCount: Cardinal;

    function TestCodingBlocks(const ACodingBlocks: array of TCodingBlock): UInt64;
    function SolveCodingBlocks_ByBit: UInt64;
    function SolveCodingBlocks_ByValue: UInt64;
  public
    constructor Create(ACodes: TCodeArray; ACodingBlocksBits: Byte; ASolveByValue: Boolean; AHighestCode: Integer);

    function SolveCodingBlocks: UInt64;
    procedure Render(AStream: TStream);
  end;

  { TChunk }

  TChunkList = specialize TFPGObjectList<TChunk>;

  TChunk = class
  public
    frame: TFrame;
    reducedChunk: TChunk;

    channel, index, useCount: Integer;
    dstNegative: Boolean;
    dstReversed: Boolean;
    dstAttenuation: Byte;

    srcData: PDouble;
    dstData: TSmallIntDynArray;

    constructor Create(frm: TFrame; idx: Integer; srcDta: PDouble);

    function ComputeFeatures: TDoubleDynArray;
    procedure ComputeFromFeatures(AFeatures: PDouble);
    procedure ComputeDstAttributes;
    procedure MakeDstData;
  end;

  { TFrame }

  TFrame = class
  public
    encoder: TEncoder;

    index: Integer;
    ChunkCount: Integer;
    StartSample: Integer;
    SampleCount: Integer;
    FrameSize: Integer;

    plainChunks, reducedChunks: TChunkList;

    srcFirstSample: TDoubleDynArray;

    dstPiggyCoder: TPiggyCoder;

    srcData: TDoubleDynArray2;
    dstData: TDoubleDynArray2;

    filter: array of TEmphasisFilter;

    constructor Create(enc: TEncoder; idx, startSmp, endSmp: Integer);
    destructor Destroy; override;

    procedure MakeChunks;
    procedure ComputeAttenuations;
    procedure Reduce;
    procedure Reconstruct;
    procedure MakeDstData;
    procedure SaveStream(AStream: TStream);

    procedure MakeFrame(AVerbose: Boolean = True);
    procedure SolveCompandingFilterSettings;
  end;

  { TEncoder }

  TEncoder = class
  type
    TOutputSample = record
      AsInt: SmallInt;
      AsDouble: Double;
    end;
    TPsyADelta = record
      Linear, MuLaw: Double;
    end;
  private
    function GetThreadsPerFrame: Cardinal;
  public
    InputFN, OutputFN: String;

    ArtistTag, TitleTag: String;
    BitRate: Double;
    Precision: Integer;
    ChunkBitDepth: Integer; // 8 or 12 Bits
    ChunkSize: Integer;
    ChunksPerFrame: Integer;
    PiggyCodingBlocksBits: Byte;
    PiggyCodingSolveByValue: Boolean;
    VariableFrameSizeRatio: Double;
    AttenuationChunkRatioMul: Double;
    FrameLength: Double;
    PythonReduce: Boolean;
    NoSolveFilterSettings: Boolean;
    DebugMode: Boolean;
    Verbose: Boolean;

    ChannelCount: Integer;
    SampleRate: Integer;
    SampleCount: Integer;
    BlockSampleCount: Integer;
    ProjectedByteSize: Integer;
    ChunksPerAttenuation: Integer;
    FrameCount: Integer;

    GainFactor: Double;
    FramesLeft: Integer;

    SrcHeader: array[$00..$2b] of Byte;
    SrcData: TSmallIntDynArray2;
    DstData: TSmallIntDynArray2;

    Frames: array of TFrame;

    function CreateEmphasisFilter: TEmphasisFilter;

    class function make16BitSample(smp: Double): SmallInt;
    class function makeOutputSample(smp: Double; OutBitDepth, Attenuation: Byte; Negative: Boolean; gain: Double): TOutputSample;
    class function makeFloatSample(smp: SmallInt): Double;
    class function makeFloatSample(smp: Integer; OutBitDepth, Attenuation: Byte; Negative: Boolean; gain: Double): Double;
    class function SolveAttenuation(chunkSz: Integer; samples: PDouble): Byte;
    class function ComputeAttenuation(Attenuation: Integer): Double;
    class procedure ComputeDCT(chunkSz: Integer; samples, dct: PDouble);
    class procedure ComputeInvDCT(chunkSz: Integer; dct, samples: PDouble);
    class function CompareEuclidean(const dctA, dctB: TDoubleDynArray): Double; overload;
    class function CompareMuLawManhattan(const dctA, dctB: TDoubleDynArray): TPsyADelta;
    class function ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): TPsyADelta;
    class procedure createWAV(channels: word; resolution: word; rate: longint; fn: string; const data: TSmallIntDynArray);

    constructor Create(InFN, OutFN: String);
    destructor Destroy; override;

    procedure Load;
    procedure SaveWAV;
    function SaveGSC: Double;
    procedure SaveStream(AStream: TStream);

    procedure PrepareFrames;
    procedure MakeFrames;
    procedure MakeDstData;

    function ComputeEAQUAL(UseDIX, Verbz: Boolean; const smpRef, smpTst: TSmallIntDynArray): Double;

    property ThreadsPerFrame: Cardinal read GetThreadsPerFrame;
  end;


function IsDebuggerPresent(): LongBool stdcall; external 'kernel32.dll';

function HasParam(p: String): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 3 to ParamCount do
    if SameText(p, ParamStr(i)) then
      Exit(True);
end;

function ParamStart(p: String): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 3 to ParamCount do
    if AnsiStartsStr(p, ParamStr(i)) then
      Exit(i);
end;

function ParamValue(p: String; def: Double): Double;
var
  idx: Integer;
begin
  idx := ParamStart(p);
  if idx < 0 then
    Exit(def);
  Result := StrToFloatDef(copy(ParamStr(idx), Length(p) + 1), def);
end;

constructor TEmphasisFilter.Create(ASampleRate: Integer);
begin
  sampleRate := ASampleRate;
end;

{ TDeltaFilter }

procedure TDeltaFilter.Init;
begin
  prevSample := 0.0;
  accSample := 0.0;
end;

function TDeltaFilter.PreFilter(s: Double): Double;
begin
  Result := s - prevSample;
  prevSample := s;
end;

function TDeltaFilter.DeFilter(s: Double): Double;
begin
  accSample += s;
  Result := accSample;
end;

{ TLMC1992Filter }

function TLMC1992Filter.Bass_Shelf(g, fc, Fs: Double): TFirstOrder;
var
  sqrt_g, k, k_sqrt_g, k_over_sqrt_g, denom: Double;
begin
  // Linear gain and its square root
  sqrt_g := Sqrt(g);

  // Bilinear transform: K = tan(π × fc / fs)
  k := Tan(Pi*fc/Fs);

  // Coefficients for H(s) = (s + ω₀×√G) / (s + ω₀/√G)
  // After bilinear transform:
  k_sqrt_g := k * sqrt_g;
  k_over_sqrt_g := k / sqrt_g;
  denom := 1.0 + k_over_sqrt_g;

  Result.b0 := (1.0 + k_sqrt_g) / denom;
  Result.b1 := (k_sqrt_g - 1.0) / denom;
  Result.a1 := (k_over_sqrt_g - 1.0) / denom;
end;

function TLMC1992Filter.Treble_Shelf(g, fc, Fs: Double): TFirstOrder;
var
  sqrt_g, k, k_sqrt_g, denom: Double;
begin
  // Linear gain and its square root
  sqrt_g :=  Sqrt(g);

  // Bilinear transform: K = tan(π × fc / fs)
  k := Tan(Pi*fc/Fs);

  // First-order high shelf via bilinear transform:
  // H(s) = (s×√G + ω₀) / (s/√G + ω₀)
  // After transform with pre-warping:
  // b0 = √G × (√G + k) / (1 + k×√G)
  // b1 = √G × (k - √G) / (1 + k×√G)
  // a1 = (k×√G - 1) / (1 + k×√G)
  k_sqrt_g := k * sqrt_g;
  denom := 1.0 + k_sqrt_g;

  Result.b0 := sqrt_g * (sqrt_g + k) / denom;
  Result.b1 := sqrt_g * (k - sqrt_g) / denom;
  Result.a1 := (k_sqrt_g - 1.0) / denom;
end;

function TLMC1992Filter.BiQuad(input: Double; ADefilter, ATreble: Boolean): Double;

  function mul_add(x, a, b: Double): Double;
  begin
    Result := x * a + b;
  end;

var
	output: Double;
begin
  output := mul_add(coef[ADefilter, ATreble].b0, input, mul_add(coef[ADefilter, ATreble].b1, data[ADefilter, ATreble].x1, -coef[ADefilter, ATreble].a1 * data[ADefilter, ATreble].y1));
  data[ADefilter, ATreble].x1 := input;
  data[ADefilter, ATreble].y1 := output;

  Result := output;
end;

constructor TLMC1992Filter.Create(ASampleRate: Integer);
var
	dB_adjusted, dB, g, fc_bt, fc_tt, Fs: Double;
	n: Integer;
	bass, treb: TFirstOrder;
begin
  inherited Create(ASampleRate);

  fc_bt := 118.2763 * Pi; //TODO: Gli: why Pi there to get something close to the hw?
  fc_tt := 8438.756 * Sqrt(2.0) / 2.0; //TODO: Gli: why Sqrt(2.0) / 2.0 there to get something close to the hw?
  Fs := sampleRate;

  if fc_tt > 0.5*Fs then
  begin
    fc_tt := 0.5*Fs;
    dB_adjusted := 2.0 * 0.5*Fs/fc_tt;
  end
  else
  begin
    dB_adjusted := 2.0;
  end;

  dB := dB_adjusted*(TONE_STEPS-1)/2;
  for n := TONE_STEPS - 1 downto 0 do
  begin
    g := Power(10.0, dB/20.0);	// 12dB to -12dB

    treb := Treble_Shelf(g, fc_tt, Fs);

    treb_table[n].a1 := treb.a1;
    treb_table[n].b0 := treb.b0;
    treb_table[n].b1 := treb.b1;

    dB -= dB_adjusted;
  end;

  dB := 12.0;
  for n := TONE_STEPS - 1 downto 0 do
  begin
  	g := Power(10.0, dB/20.0);	// 12dB to -12dB

  	bass := Bass_Shelf(g, fc_bt, Fs);

  	bass_table[n].a1 := bass.a1;
  	bass_table[n].b0 := bass.b0;
  	bass_table[n].b1 := bass.b1;

    dB -= 2.0;
  end;

  Set_Tone_Level(NEUTRAL_TONE, NEUTRAL_TONE); // no bass / treble boost
end;

procedure TLMC1992Filter.Init;
var
  de, tr: Boolean;
begin
  for de := False to True do
    for tr := False to True do
    begin
      data[de, tr].x1 := 0.0;
      data[de, tr].y1 := 0.0;
    end;
end;

function TLMC1992Filter.PreFilter(s: Double): Double;
var
  tr: Boolean;
begin
  Result := s;
  for tr := False to True do
    Result := BiQuad(Result, False, tr);
end;

function TLMC1992Filter.DeFilter(s: Double): Double;
var
  tr: Boolean;
begin
  Result := s;
  for tr := False to True do
    Result := BiQuad(Result, True, tr);
end;

procedure TLMC1992Filter.Set_Tone_Level(set_bass, set_treb: Byte);
var
  de: Boolean;
begin
  bass_level := set_bass;
  treb_level := set_treb;

  for de := True downto False do
  begin
    // 13 levels; 0 through 12 correspond with -12dB to 12dB in 2dB steps
    coef[de, False] := bass_table[set_bass];
    coef[de, True] := treb_table[set_treb];

    set_bass := TONE_STEPS - 1 - set_bass;
    set_treb := TONE_STEPS - 1 - set_treb;
  end;
end;

{ TPiggyCoder }

constructor TPiggyCoder.Create(ACodes: TCodeArray; ACodingBlocksBits: Byte; ASolveByValue: Boolean; AHighestCode:
  Integer);
var
  iCodingBits: Integer;
  bitBlock, valuesCoded: Integer;
begin
  codes := ACodes;
  highestCode := AHighestCode;
  codesBitCount := Ceil(Log2(highestCode + 1));
  solveByValue := ASolveByValue;
  codingBlocksBits := ACodingBlocksBits;
  codingBlocksCount := 1 shl codingBlocksBits;

  bitBlock := codesBitCount div codingBlocksCount;
  valuesCoded := 0;
  for iCodingBits := 0 to codingBlocksCount - 1 do
  begin
    valuesCoded += 1 shl (bitBlock * (iCodingBits + 1));
    codingBlocks[iCodingBits].BitSize := Ceil(Log2(valuesCoded));
    codingBlocks[iCodingBits].Value := 1 shl codingBlocks[iCodingBits].BitSize;
  end;
end;

function TPiggyCoder.SolveCodingBlocks: UInt64;
begin
  if solveByValue then
    Result := SolveCodingBlocks_ByValue
  else
    Result := SolveCodingBlocks_ByBit;
end;

function TPiggyCoder.SolveCodingBlocks_ByBit: UInt64;
var
  locCodingBlocks: array[0 .. High(Byte)] of TCodingBlock;

  procedure DoTest;
  var
    iCodingBlocks: Integer;
    curSize: UInt64;
  begin
    for iCodingBlocks := 0 to codingBlocksCount - 1 do
      locCodingBlocks[iCodingBlocks].Value := 1 shl locCodingBlocks[iCodingBlocks].BitSize;

    curSize := TestCodingBlocks(locCodingBlocks);

    if curSize < Result then
    begin
      Result := curSize;
      for iCodingBlocks := 0 to codingBlocksCount - 1 do
        codingBlocks[iCodingBlocks] := locCodingBlocks[iCodingBlocks];
    end;
  end;

var
  iCB0, iCB1, iCB2, iCB3, iCB4, iCB5, iCB6, iCB7: Byte;
begin
  Result := High(UInt64);

  if codingBlocksBits = 3 then
  begin
    for iCB0 := 1 to codesBitCount do
      for iCB1 := iCB0 to codesBitCount do
        for iCB2 := iCB1 to codesBitCount do
          for iCB3 := iCB2 to codesBitCount do
            for iCB4 := iCB3 to codesBitCount do
              for iCB5 := iCB4 to codesBitCount do
                for iCB6 := iCB5 to codesBitCount do
                  for iCB7 := iCB6 to codesBitCount do
                  begin
                    locCodingBlocks[0].BitSize := iCB0; locCodingBlocks[1].BitSize := iCB1;
                    locCodingBlocks[2].BitSize := iCB2; locCodingBlocks[3].BitSize := iCB3;
                    locCodingBlocks[4].BitSize := iCB4; locCodingBlocks[5].BitSize := iCB5;
                    locCodingBlocks[6].BitSize := iCB6; locCodingBlocks[7].BitSize := iCB7;

                    DoTest;
                  end;
  end
  else if codingBlocksBits = 2 then
  begin
    for iCB0 := 1 to codesBitCount do
      for iCB1 := iCB0 to codesBitCount do
        for iCB2 := iCB1 to codesBitCount do
          for iCB3 := iCB2 to codesBitCount do
          begin
            locCodingBlocks[0].BitSize := iCB0; locCodingBlocks[1].BitSize := iCB1;
            locCodingBlocks[2].BitSize := iCB2; locCodingBlocks[3].BitSize := iCB3;

            DoTest;
          end;
  end
  else if codingBlocksBits = 1 then
  begin
    for iCB0 := 1 to codesBitCount do
      for iCB1 := iCB0 to codesBitCount do
      begin
        locCodingBlocks[0].BitSize := iCB0; locCodingBlocks[1].BitSize := iCB1;

        DoTest;
      end;
  end
  else
  begin
    Assert(False);
  end;
end;

function TPiggyCoder.SolveCodingBlocks_ByValue: UInt64;
var
  locCodingBlocks: array[0 .. High(Byte)] of TCodingBlock;

  procedure DoTest;
  var
    iCodingBlocks: Integer;
    curSize: UInt64;
  begin
    for iCodingBlocks := 0 to codingBlocksCount - 1 do
      locCodingBlocks[iCodingBlocks].BitSize := Ceil(Log2(locCodingBlocks[iCodingBlocks].Value));

    curSize := TestCodingBlocks(locCodingBlocks);

    if curSize < Result then
    begin
      Result := curSize;
      for iCodingBlocks := 0 to codingBlocksCount - 1 do
        codingBlocks[iCodingBlocks] := locCodingBlocks[iCodingBlocks];
    end;
  end;

var
  iCB0, iCB1, iCB2, iCB3: Cardinal;

begin
  Result := High(UInt64);

  if codingBlocksBits = 2 then
  begin
    for iCB0 := 2 to highestCode + 1 do
      for iCB1 := iCB0 to highestCode + 1 do
        for iCB2 := iCB1 to highestCode + 1 do
          for iCB3 := iCB2 to highestCode + 1 do
          begin
            locCodingBlocks[0].Value := iCB0; locCodingBlocks[1].Value := iCB1;
            locCodingBlocks[2].Value := iCB2; locCodingBlocks[3].Value := iCB3;

            DoTest;
          end;
  end
  else if codingBlocksBits = 1 then
  begin
    for iCB0 := 2 to highestCode + 1 do
      for iCB1 := iCB0 to highestCode + 1 do
      begin
        locCodingBlocks[0].Value := iCB0; locCodingBlocks[1].Value := iCB1;

        DoTest;
      end;
  end
  else
  begin
    Assert(False);
  end;
end;

function TPiggyCoder.TestCodingBlocks(const ACodingBlocks: array of TCodingBlock): UInt64;
var
  iCode, iCodingBlocks, codeValue, codeBlockLimit, prevCodingBlocks: Integer;
  coded: Boolean;
begin
  // /!\ should be kept synced with TPiggyCoder.Render

  Result := 0;
  prevCodingBlocks := -1;
  for iCode := 0 to High(codes) do
  begin
    Result += codes[iCode].ExtraBitCount;

    coded := False;
    codeValue := codes[iCode].Code;
    iCodingBlocks := 0;
    repeat
      codeBlockLimit := ACodingBlocks[iCodingBlocks].Value;
      if codeValue < codeBlockLimit then
      begin
        coded := True;
        Break;
      end;
      codeValue -= codeBlockLimit;
      Inc(iCodingBlocks);
    until iCodingBlocks >= codingBlocksCount;

    if not coded then
      Exit(High(UInt64));

    if codingBlocksBits > 1 then
      Result += IfThen(iCodingBlocks = prevCodingBlocks, 1, 1 + codingBlocksBits)
    else
      Result += codingBlocksBits;

    Result += ACodingBlocks[iCodingBlocks].BitSize;

    prevCodingBlocks := iCodingBlocks;
  end;

  if Result and 15 <> 0 then
    Result += 16 - (Result and 15);
end;

procedure TPiggyCoder.Render(AStream: TStream);

  procedure DoWord(AWord: UInt64);
  begin
{$ifdef ATARI_STE}
    AStream.WriteWord(NtoBE(Word(AWord and $ffff)));
{$else}
    AStream.WriteWord(AWord and $ffff);
{$endif}
  end;

var
  iCode, iCodingBlocks, itemBitCnt, overallBitCnt, codeValue, codeBlockLimit, prevCodingBlocks: Integer;
  itemBits, overallBits: UInt64;
  coded: Boolean;
begin
  // /!\ should be kept synced with TPiggyCoder.TestCodingBlocks

  for iCodingBlocks := 0 to codingBlocksCount - 1 do
    if solveByValue then
      AStream.WriteByte(codingBlocks[iCodingBlocks].Value)
    else
      AStream.WriteByte(codingBlocks[iCodingBlocks].BitSize);

  overallBits := 0;
  overallBitCnt := 0;

  prevCodingBlocks := -1;
  for iCode := 0 to High(codes) do
  begin
    itemBits := 0;
    itemBitCnt := 0;

    if codes[iCode].ExtraBitCount > 0 then
    begin
      itemBits := codes[iCode].ExtraBits or (itemBits shl codes[iCode].ExtraBitCount);
      itemBitCnt += codes[iCode].ExtraBitCount;
    end;

    coded := False;
    codeValue := codes[iCode].Code;
    for iCodingBlocks := 0 to codingBlocksCount - 1 do
    begin
      codeBlockLimit := codingBlocks[iCodingBlocks].Value;

      if codeValue < codeBlockLimit then
      begin
        if codingBlocksBits > 1 then
        begin
          if iCodingBlocks = prevCodingBlocks then
          begin
            itemBits := 0 or (itemBits shl 1);
            itemBitCnt += 1;
          end
          else
          begin
            itemBits := 1 or (itemBits shl 1);
            itemBitCnt += 1;

            itemBits := iCodingBlocks or (itemBits shl codingBlocksBits);
            itemBitCnt += codingBlocksBits;

            prevCodingBlocks := iCodingBlocks;
          end;
        end
        else
        begin
          itemBits := iCodingBlocks or (itemBits shl codingBlocksBits);
          itemBitCnt += codingBlocksBits;
        end;

        itemBits := codeValue or (itemBits shl codingBlocks[iCodingBlocks].BitSize);
        itemBitCnt += codingBlocks[iCodingBlocks].BitSize;

        coded := True;
        Break;
      end;

      codeValue -= codeBlockLimit;
    end;
    Assert(coded);

    overallBits := itemBits or (overallBits shl itemBitCnt);
    overallBitCnt += itemBitCnt;
    while overallBitCnt >= 16 do
    begin
      overallBitCnt -= 16;
      DoWord(overallBits shr overallBitCnt);
      overallBits := overallBits and ((1 shl overallBitCnt) - 1);
    end;
  end;

  if overallBitCnt > 0 then
  begin
    Assert(overallBitCnt <= 16);
    DoWord(overallBits shl (16 - overallBitCnt));
  end;
end;

{ TChunk }

constructor TChunk.Create(frm: TFrame; idx: Integer; srcDta: PDouble);
begin
  index := idx;
  frame := frm;
  reducedChunk := Self;
  channel := -1;
  srcData := srcDta;
end;

function TChunk.ComputeFeatures: TDoubleDynArray;
var
  iSample: Integer;
begin
  SetLength(Result, frame.encoder.ChunkSize);
  for iSample := 0 to High(Result) do
    Result[iSample] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, frame.encoder.ChunkSize - 1 - iSample, iSample)], 2, dstAttenuation, dstNegative, 1.0).AsDouble;
end;

procedure TChunk.ComputeFromFeatures(AFeatures: PDouble);
var
  iSample: Integer;
begin
  SetLength(dstData, frame.encoder.ChunkSize);
  for iSample := 0 to High(dstData) do
    dstData[iSample] := TEncoder.makeOutputSample(AFeatures[iSample], frame.encoder.ChunkBitDepth, 0, False, frame.encoder.GainFactor).AsInt;
end;

procedure TChunk.ComputeDstAttributes;
var
  i: Integer;
  p1, p2: Double;
begin
  // compute overall sign (up <-> down mirror)

  p1 := 0.0;
  for i := 0 to frame.encoder.ChunkSize - 1 do
    if srcData[i] < 0 then
      p1 -= srcData[i];

  p2 := 0.0;
  for i := 0 to frame.encoder.ChunkSize - 1 do
    if srcData[i] > 0 then
      p2 += srcData[i];

  dstNegative := p1 > p2;

  // compute overall reversed (left <-> right mirror)

  p1 := 0.0;
  for i := 0 to frame.encoder.ChunkSize div 2 - 1 do
    p1 += Abs(srcData[i]);

  p2 := 0.0;
  for i := frame.encoder.ChunkSize - frame.encoder.ChunkSize div 2 to frame.encoder.ChunkSize - 1 do
    p2 += Abs(srcData[i]);

  dstReversed := p1 > p2;
end;

procedure TChunk.MakeDstData;
var
  i: Integer;
begin
  SetLength(dstData, frame.encoder.ChunkSize);
  for i := 0 to High(dstData) do
    dstData[i] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, High(dstData) - i, i)], frame.encoder.ChunkBitDepth, dstAttenuation, dstNegative, frame.encoder.GainFactor).AsInt;
end;

constructor TFrame.Create(enc: TEncoder; idx, startSmp, endSmp: Integer);
var
  iChannel: Integer;
begin
  encoder := enc;
  index := idx;
  StartSample := startSmp;
  SampleCount := endSmp - startSmp + 1;
  ChunkCount := (SampleCount - 1) div encoder.ChunkSize + 1;

  reducedChunks := TChunkList.Create;
  plainChunks := TChunkList.Create;

  SetLength(filter, encoder.ChannelCount);
  for iChannel := 0 to encoder.ChannelCount - 1 do
    filter[iChannel] := encoder.CreateEmphasisFilter;

  if encoder.Verbose then
    WriteLn('Frame #', index, #9, ChunkCount);
end;

destructor TFrame.Destroy;
var
  iChannel: Integer;
begin
  for iChannel := 0 to encoder.ChannelCount - 1 do
    filter[iChannel].Free;

  reducedChunks.Free;
  plainChunks.Free;
  dstPiggyCoder.Free;

  inherited Destroy;
end;

procedure TFrame.MakeChunks;
var
  iSample, iChannel, iChunk: Integer;
  smp: Double;
  chunk: TChunk;
begin
  SetLength(srcFirstSample, encoder.ChannelCount);
  SetLength(srcData, encoder.ChannelCount, SampleCount);

  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    srcFirstSample[iChannel] := 0.0;
    if StartSample > 0 then
      srcFirstSample[iChannel] := TEncoder.makeFloatSample(encoder.SrcData[iChannel, StartSample - 1]);
    filter[iChannel].Init;
    filter[iChannel].PreFilter(srcFirstSample[iChannel]);
    for iSample := 0 to SampleCount - 1 do
    begin
      smp := TEncoder.makeFloatSample(encoder.SrcData[iChannel, StartSample + iSample]);
      srcData[iChannel, iSample] := filter[iChannel].PreFilter(smp);
    end;
  end;

  reducedChunks.Clear;

  plainChunks.Clear;
  plainChunks.Capacity := ChunkCount * encoder.ChannelCount;

  for iChunk := 0 to ChunkCount - 1 do
    for iChannel := 0 to encoder.ChannelCount - 1 do
    begin
      chunk := TChunk.Create(Self, iChunk, @srcData[iChannel, iChunk * encoder.ChunkSize]);
      chunk.channel := iChannel;
      chunk.ComputeDstAttributes;
      plainChunks.Add(chunk);
    end;
end;

procedure TFrame.ComputeAttenuations;
var
  iChannel, iChunk, iSample, iAtt, attCnt, pos, loIdx, hiIdx: Integer;
  att: Byte;
  chunkBuffer: TDoubleDynArray;
  chunk: TChunk;
begin
  SetLength(chunkBuffer, encoder.ChunksPerAttenuation * encoder.ChunkSize * encoder.ChannelCount);

  attCnt := (ChunkCount - 1) div encoder.ChunksPerAttenuation + 1;
  for iAtt := 0 to attCnt - 1 do
  begin
    pos := 0;
    loIdx := iAtt * encoder.ChunksPerAttenuation;
    hiIdx := Min((iAtt + 1) * encoder.ChunksPerAttenuation, ChunkCount) - 1;

    for iChunk := loIdx to hiIdx do
      for iChannel := 0 to encoder.ChannelCount - 1 do
      begin
        chunk := plainChunks[iChunk * encoder.ChannelCount + iChannel];

        for iSample := 0 to encoder.ChunkSize - 1 do
        begin
          chunkBuffer[pos] := chunk.srcData[iSample];
          Inc(pos);
        end;
      end;

    att := TEncoder.SolveAttenuation(pos, @chunkBuffer[0]);

    for iChunk := loIdx to hiIdx do
      for iChannel := 0 to encoder.ChannelCount - 1 do
        plainChunks[iChunk * encoder.ChannelCount + iChannel].dstAttenuation := att;
  end;
end;

function CompareChunkUseCountInv(const Item1, Item2: TChunk): Integer;
begin
  Result := CompareValue(Item2.useCount, Item1.useCount);
  if Result = 0 then
    Result := CompareValue(Item1.index, Item2.index);
end;

procedure TFrame.Reduce;
var
  iChunk, iSample, prec, colCount, clusterCount: Integer;
  chunk: TChunk;
  Clusters: TIntegerDynArray;
  Dataset: TDoubleDynArray2;
  Centroids: TDoubleDynArray2;
  Yakmo: PYakmo;
begin
  prec := encoder.Precision;

  colCount := encoder.ChunkSize;
  clusterCount := encoder.ChunksPerFrame;

  SetLength(Dataset, plainChunks.Count);

  for iChunk := 0 to plainChunks.Count - 1 do
    Dataset[iChunk] := plainChunks[iChunk].ComputeFeatures;

  if (prec > 0) and (plainChunks.Count > clusterCount) then
  begin
    // usual chunk reduction

    if encoder.Verbose then
      WriteLn('[Reduce] Frame = ', index:4, ', N = ', Length(Dataset):8, ', K = ', clusterCount:6);

    SetLength(Clusters, Length(Dataset));
    SetLength(Centroids, clusterCount, colCount);

    if not encoder.PythonReduce then
    begin
      if clusterCount > 1 then
      begin
        Yakmo := yakmo_create(clusterCount, 1, -1, 1, 0, 0, Ord(encoder.Verbose));
        try
          yakmo_set_num_threads(encoder.ThreadsPerFrame);
          yakmo_load_train_data(Yakmo, Length(Dataset), colCount, PPDouble(@Dataset[0]));
          yakmo_train_on_data(Yakmo, @Clusters[0]);
          yakmo_get_centroids(Yakmo, PPDouble(@Centroids[0]));
        finally
          yakmo_destroy(Yakmo);

          InterLockedDecrement(encoder.FramesLeft);
          yakmo_set_num_threads(encoder.ThreadsPerFrame);
        end;
      end;
    end
    else
    begin
      DoExternalSKLearn(Dataset, clusterCount, prec, False, encoder.Verbose, Clusters, Centroids);
      SetLength(Centroids, clusterCount, colCount);
    end;

    reducedChunks.Clear;
    reducedChunks.Capacity := clusterCount;
    for iChunk := 0 to clusterCount - 1 do
    begin
      chunk := TChunk.Create(Self, iChunk, nil);
      reducedChunks.Add(chunk);

      for iSample := 0 to colCount - 1 do
        if IsNan(Centroids[iChunk, iSample]) or IsInfinite(Centroids[iChunk, iSample]) then
          Centroids[iChunk, iSample] := 0.0;

      chunk.ComputeFromFeatures(@Centroids[iChunk, 0]);
  	end;

    for iChunk := 0 to plainChunks.Count - 1 do
    begin
      plainChunks[iChunk].reducedChunk := reducedChunks[Clusters[iChunk]];
      Inc(plainChunks[iChunk].reducedChunk.useCount);
    end;
  end
  else
  begin
    // passthrough mode

    reducedChunks.Clear;
    reducedChunks.Capacity := plainChunks.Count;
    for iChunk := 0 to reducedChunks.Capacity - 1 do
    begin
      chunk := TChunk.Create(Self, iChunk, nil);
      reducedChunks.Add(chunk);

      plainChunks[iChunk].MakeDstData;
      chunk.srcData := plainChunks[iChunk].srcData;
      chunk.dstData := Copy(plainChunks[iChunk].dstData);
    end;

    for iChunk := 0 to plainChunks.Count - 1 do
    begin
      plainChunks[iChunk].reducedChunk := reducedChunks[iChunk];
      Inc(plainChunks[iChunk].reducedChunk.useCount);
    end;
  end;

  reducedChunks.Sort(@CompareChunkUseCountInv);
end;

procedure TFrame.Reconstruct;
var
  iChunk, iSample, iChannel, dsIdx, bestIdx: Integer;
  bestErr, attCoeff, skew: Double;
  truthAcc, lossyAcc: TDoubleDynArray;
  Dataset: TANNFloatDynArray2;
  query: TANNFloatDynArray;
  KDT: PANNkdtree;
  chunk: TChunk;
begin
  SetLength(Dataset, reducedChunks.Count * 2 {Negative} * 2 {Reversed}, encoder.chunkSize);

  SetLength(query, encoder.chunkSize);
  SetLength(truthAcc, encoder.ChannelCount);
  SetLength(lossyAcc, encoder.ChannelCount);
  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    truthAcc[iChannel] := srcFirstSample[iChannel];
    lossyAcc[iChannel] := truthAcc[iChannel];
  end;

  dsIdx := 0;
  for iChunk := 0 to reducedChunks.Count - 1 do
  begin
    chunk := reducedChunks[iChunk];

    for iSample := 0 to encoder.ChunkSize - 1 do
    begin
      Dataset[dsIdx + 0, iSample] := TEncoder.makeFloatSample(chunk.dstData[iSample], encoder.ChunkBitDepth, 0, False, encoder.GainFactor);
      Dataset[dsIdx + 1, iSample] := TEncoder.makeFloatSample(chunk.dstData[iSample], encoder.ChunkBitDepth, 0, True, encoder.GainFactor);
      Dataset[dsIdx + 2, iSample] := TEncoder.makeFloatSample(chunk.dstData[encoder.ChunkSize - 1 - iSample], encoder.ChunkBitDepth, 0, False, encoder.GainFactor);
      Dataset[dsIdx + 3, iSample] := TEncoder.makeFloatSample(chunk.dstData[encoder.ChunkSize - 1 - iSample], encoder.ChunkBitDepth, 0, True, encoder.GainFactor);
    end;

    Inc(dsIdx, 4);
  end;

  KDT := ann_kdtree_create(PPANNFloat(@Dataset[0]), Length(Dataset), encoder.ChunkSize, 1, ANN_KD_STD);
  try
    for iChunk := 0 to plainChunks.Count - 1 do
    begin
      chunk := plainChunks[iChunk];

      attCoeff := encoder.ComputeAttenuation(chunk.dstAttenuation);

      skew := (lossyAcc[chunk.channel] - truthAcc[chunk.channel]) / encoder.ChunkSize;
      for iSample := 0 to encoder.ChunkSize - 1 do
        query[iSample] := (chunk.srcData[iSample] - skew) * attCoeff;

      bestIdx := ann_kdtree_search(KDT, @query[0], 0.0, @bestErr);

      chunk.dstNegative := bestIdx and 1 <> 0;
      chunk.dstReversed := bestIdx and 2 <> 0;
      chunk.reducedChunk := reducedChunks[bestIdx shr 2];

      Inc(chunk.reducedChunk.useCount);

      for iSample := 0 to encoder.ChunkSize - 1 do
      begin
        truthAcc[chunk.channel] += chunk.srcData[iSample];
        lossyAcc[chunk.channel] += Dataset[bestIdx, iSample] / attCoeff;
      end;
    end;
  finally
    ann_kdtree_destroy(KDT);
  end;

  for iChunk := reducedChunks.Count - 1 downto 0 do
    if reducedChunks[iChunk].useCount = 0 then
       reducedChunks.Delete(iChunk);

  reducedChunks.Sort(@CompareChunkUseCountInv);

  for iChunk := 0 to reducedChunks.Count - 1 do
    reducedChunks[iChunk].index := iChunk;
end;

procedure TFrame.SaveStream(AStream: TStream);
var
  iChunk, iSample, iChannel, s1, s2: Integer;
  sb: ShortInt;
  w: UInt64;
  cl: TChunkList;
begin
  Assert(reducedChunks.Count <= CMaxChunksPerFrame);

{$ifdef ATARI_STE}
  Assert(reducedChunks.Count - 1 <= High(Byte));
  AStream.WriteByte(reducedChunks.Count - 1);
  AStream.WriteByte((TLMC1992Filter(filter[0]).bass_level shl 4) or TLMC1992Filter(filter[0]).treb_level);

  Assert(encoder.ChunkBitDepth = 8, 'ChunkBitDepth not supported');
  cl := reducedChunks;
  for iChunk := 0 to cl.Count - 1 do
    for iSample := 0 to encoder.ChunkSize - 1 do
    begin
      sb := cl[iChunk].dstData[iSample];
      AStream.Write(sb,1);
    end;
{$else}
  w := (encoder.ChannelCount shl 8) or CStreamVersion;
  AStream.WriteWord(w and $ffff);
  w := reducedChunks.Count;
  AStream.WriteWord(w and $ffff);
  w := (encoder.ChunkSize shl 8) or encoder.ChunkBitDepth;
  AStream.WriteWord(w and $ffff);
  w := (encoder.PiggyCodingBlocksBits shl 24) or encoder.SampleRate;
  AStream.WriteDWord(w and $ffffffff);
  w := encoder.ChunksPerAttenuation;
  AStream.WriteWord(w and $ffff);

  cl := reducedChunks;
  case encoder.ChunkBitDepth of
    8:
      for iChunk := 0 to cl.Count - 1 do
        for iSample := 0 to encoder.ChunkSize - 1 do
          AStream.WriteByte((cl[iChunk].dstData[iSample] - Low(ShortInt)) and $ff);
    12:
      for iChunk := 0 to cl.Count - 1 do
      begin
        for iSample := 0 to encoder.ChunkSize div 2 - 1 do
        begin
          s1 := cl[iChunk].dstData[iSample * 2 + 0] + 2048;
          s2 := cl[iChunk].dstData[iSample * 2 + 1] + 2048;

          AStream.WriteByte(((s1 shr 4) and $f0) or ((s2 shr 8) and $0f));
          AStream.WriteByte(s1 and $ff);
          AStream.WriteByte(s2 and $ff);
        end;

        if Odd(encoder.ChunkSize) then
        begin
          s1 := cl[iChunk].dstData[encoder.ChunkSize - 1] + 2048;

          AStream.WriteByte((s1 shr 4) and $f0);
          AStream.WriteByte(s1 and $ff);
        end;
      end
    else
      Assert(False, 'ChunkBitDepth not supported');
  end;
{$endif}


{$ifdef ATARI_STE}
  Assert(plainChunks.Count div encoder.ChannelCount - 1 <= High(Word));
  AStream.WriteWord(NtoBE(WORD(plainChunks.Count div encoder.ChannelCount - 1)));
{$else}
  AStream.WriteDWord(plainChunks.Count div encoder.ChannelCount);

  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    w := Word(TEncoder.make16BitSample(srcFirstSample[iChannel]));
    AStream.WriteWord(w and $ffff);
  end;
{$endif}

  dstPiggyCoder.Render(AStream);
end;

procedure TFrame.MakeFrame(AVerbose: Boolean);
begin
  Inc(encoder.FramesLeft);

  MakeChunks;
  ComputeAttenuations;
  if AVerbose then Write('.');
  Reduce;
  Reconstruct;
  if AVerbose then Write('.');
  Reduce;
  Reconstruct;
  if AVerbose then Write('.');
  MakeDstData;
  if AVerbose then Write('.');
end;

procedure TFrame.SolveCompandingFilterSettings;
var
  iChannel, iSample, iTreb, bestTreb: Integer;
  bass_level: Byte;
  v, best: Double;
  ref: TDoubleDynArray2;
begin
{$ifdef ATARI_STE}
  bass_level := TLMC1992Filter(filter[0]).bass_level;

  SetLength(ref, encoder.ChannelCount, SampleCount);

  for iChannel := 0 to encoder.ChannelCount - 1 do
    for iSample := 0 to SampleCount - 1 do
      ref[iChannel, iSample] := TEncoder.makeFloatSample(encoder.SrcData[iChannel, StartSample + iSample]);

  bestTreb := -1;
  best := Infinity;

  for iTreb := 0 to TLMC1992Filter.TONE_STEPS - 1 do
  begin
    for iChannel := 0 to encoder.ChannelCount - 1 do
      TLMC1992Filter(filter[iChannel]).Set_Tone_Level(bass_level, iTreb);

    MakeFrame(False);

    v := 0.0;
		for iChannel := 0 to encoder.ChannelCount - 1 do
		  for iSample := 0 to SampleCount - 1 do
    		v += Abs(ref[iChannel, iSample] - dstData[iChannel, iSample]);

    if v < best then
    begin
      best := v;
      bestTreb := iTreb;
    end;
  end;

  for iChannel := 0 to encoder.ChannelCount - 1 do
    TLMC1992Filter(filter[iChannel]).Set_Tone_Level(bass_level, bestTreb);

  MakeFrame;
  //WriteLn(index:4, bestTreb:4, best * High(SmallInt) / (SampleCount * encoder.ChannelCount):12:3);
{$endif}
end;

procedure TFrame.MakeDstData;
var
  iChannel, iChunk, iSample: Integer;
  chunk: TChunk;
  smp: Double;
  pos: TIntegerDynArray;
  piggyCodes: TPiggyCoder.TCodeArray;
begin
  SetLength(pos, encoder.ChannelCount);
  SetLength(dstData, encoder.ChannelCount, SampleCount);
  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    FillQWord(dstData[iChannel, 0], SampleCount, 0);
    pos[iChannel] := 0;
    filter[iChannel].Init;
    filter[iChannel].DeFilter(srcFirstSample[iChannel]);
  end;

  for iChunk := 0 to plainChunks.Count - 1 do
  begin
    chunk := plainChunks[iChunk];

    for iSample := 0 to encoder.ChunkSize - 1 do
    begin
      smp := TEncoder.makeFloatSample(chunk.reducedChunk.dstData[IfThen(chunk.dstReversed, encoder.ChunkSize - 1 - iSample, iSample)], encoder.ChunkBitDepth, chunk.dstAttenuation, chunk.dstNegative, encoder.GainFactor);

      if InRange(pos[chunk.channel], 0, High(dstData[chunk.channel])) then
        dstData[chunk.channel, pos[chunk.channel]] := filter[chunk.channel].DeFilter(smp);

      Inc(pos[chunk.channel]);
    end;
  end;

  SetLength(piggyCodes, plainChunks.Count);
  for iChunk := 0 to plainChunks.Count - 1 do
  begin
    piggyCodes[iChunk].Code := plainChunks[iChunk].reducedChunk.index;

    if iChunk mod (encoder.ChunksPerAttenuation * encoder.ChannelCount) = 0 then
    begin
      piggyCodes[iChunk].ExtraBits := plainChunks[iChunk].dstAttenuation;
      piggyCodes[iChunk].ExtraBitCount := CMaxAttenuationBits;
    end;

    piggyCodes[iChunk].ExtraBits := Ord(plainChunks[iChunk].dstNegative) or (piggyCodes[iChunk].ExtraBits shl 1);
    piggyCodes[iChunk].ExtraBitCount += 1;

    piggyCodes[iChunk].ExtraBits := Ord(plainChunks[iChunk].dstReversed) or (piggyCodes[iChunk].ExtraBits shl 1);
    piggyCodes[iChunk].ExtraBitCount += 1;
  end;

  dstPiggyCoder.Free;
  dstPiggyCoder := TPiggyCoder.Create(piggyCodes, encoder.PiggyCodingBlocksBits, encoder.PiggyCodingSolveByValue, reducedChunks.Count - 1);
  dstPiggyCoder.SolveCodingBlocks;
end;

{ TEncoder }

procedure TEncoder.Load;
var
  wavFN: String;
  fs: TFileStream;
  i, j: Integer;
  data: TSmallIntDynArray;
begin
  if LowerCase(ExtractFileExt(InputFN)) <> '.wav' then
  begin
    WriteLn('[Convert] ', InputFN);
    wavFN := GetTempFileName + '.wav';
{$ifdef ATARI_STE}
    DoExternalSOX(InputFN, wavFN, 25033, True, True);
{$else}
    DoExternalSOX(inputFN, wavFN);
{$endif}
  end
  else
  begin
    wavFN := InputFN;
  end;

  WriteLn('[Load] ', wavFN);

  fs := TFileStream.Create(wavFN, fmOpenRead or fmShareDenyNone);
  try
    fs.ReadBuffer(SrcHeader[0], SizeOf(SrcHeader));
    SampleRate := PInteger(@SrcHeader[$18])^;
    ChannelCount := PWORD(@SrcHeader[$16])^;

    SampleCount := (fs.Size - fs.Position) div (SizeOf(SmallInt) * ChannelCount);
    SetLength(SrcData, ChannelCount, SampleCount);

    SetLength(data, SampleCount * ChannelCount);
    fs.ReadBuffer(data[0], SampleCount * ChannelCount * 2);

    for i := 0 to SampleCount - 1 do
      for j := 0 to ChannelCount - 1 do
        SrcData[j, i] := data[i * ChannelCount + j];
  finally
    fs.Free;

    if wavFN <> InputFN then
      DeleteFile(wavFN);
  end;
end;

procedure TEncoder.SaveWAV;
var
  i, j: Integer;
  fs: TFileStream;
  wavFN: String;
  data: TSmallIntDynArray;
begin
  wavFN := ChangeFileExt(OutputFN, '.wav');

  WriteLn('[SaveWAV] ', wavFN);

  fs := TFileStream.Create(wavFN, fmCreate or fmShareDenyWrite);
  try
    fs.WriteBuffer(SrcHeader[0], SizeOf(SrcHeader));

    SetLength(data, SampleCount * ChannelCount);

    for i := 0 to SampleCount - 1 do
      for j := 0 to ChannelCount - 1 do
        data[i * ChannelCount + j] := DstData[j, i];

    fs.WriteBuffer(data[0], SampleCount * ChannelCount * 2);
  finally
    fs.Free;
  end;
end;

function TEncoder.SaveGSC: Double;
var
  fs: TFileStream;
  cur: TMemoryStream;
  fn: String;
  tag: array[0 .. 31] of AnsiChar;
begin
  fs := nil;
  fn := ChangeFileExt(OutputFN, '.gsc');
  cur := TMemoryStream.Create;
  fs := TFileStream.Create(fn, fmCreate or fmShareDenyWrite);
  try
    WriteLn('[SaveGSC] ', fn);

{$ifdef ATARI_STE}
    tag := 'GSCa';
    cur.Write(tag, 4);
    cur.WriteByte(CStreamVersion);
    cur.WriteByte(ChannelCount);
    cur.WriteByte(ChunkSize);
    cur.WriteByte(ChunksPerAttenuation);
    cur.WriteWord(NtoBE(Word(SampleRate)));

    // dummy stuff to fill 16 bytes :o)
    cur.WriteWord(NtoBE(Word($c0de)));
    cur.WriteWord(NtoBE(Word($611)));
    cur.WriteWord(NtoBE(Word($611)));

    Assert(cur.Position = 16);

    tag := ArtistTag;
    cur.Write(tag, SizeOf(tag));

    tag := TitleTag;
    cur.Write(tag, SizeOf(tag));
{$endif}

    SaveStream(cur);
    cur.Position := 0;

    fs.CopyFrom(cur, cur.Size);

    Result := cur.size * (8 / 1024) / (SampleCount / SampleRate); // returns bitrate

    writeln('FinalByteSize = ', cur.Size);
    writeln('FinalBitRate = ', Result:5:2);
  finally
    fs.Free;
    cur.Free;
  end;
end;

procedure TEncoder.SaveStream(AStream: TStream);
var
  i: Integer;
begin
  for i := 0 to FrameCount - 1 do
    Frames[i].SaveStream(AStream);
end;

procedure TEncoder.PrepareFrames;
const
  CAttenuationMilliseconds = 2.0;
  CVariableCodingRatio = 0.7;
var
  iChannel, iSample, frmIdx, nextStart, psc, tentativeByteSize: Integer;
  frm: TFrame;
  headerCost, chunksCost, indexingCost: Double;
  totalPower, perFramePower, curPower, smp: Double;
  flt: array of TEmphasisFilter;
begin
  WriteLn('[PrepareFrames]');

  // pass 1

{$ifdef ATARI_STE}
  ChunksPerAttenuation := Max(1, Round(ChunksPerAttenuation / AttenuationChunkRatioMul));
{$else}
  ChunksPerAttenuation := Max(1, Round(SampleRate * CAttenuationMilliseconds / (1000.0 * ChunkSize * AttenuationChunkRatioMul)));
{$endif}

  BlockSampleCount := ChunkSize * ChunksPerAttenuation;

  // ensure SrcData ends on a full block
  psc := SampleCount;
  SampleCount := ((SampleCount - 1) div BlockSampleCount + 1) * BlockSampleCount;
  SetLength(SrcData, ChannelCount, SampleCount);
  for iChannel := 0 to ChannelCount - 1 do
    for iSample := psc to SampleCount - 1 do
      SrcData[iChannel, iSample] := 0;

  if not IsInfinite(BitRate) then
    ProjectedByteSize := ceil((SampleCount / SampleRate) * (BitRate * 1024 / 8))
  else
    ProjectedByteSize := MaxInt;

  if Verbose then
  begin
    writeln('ChunksPerAttenuation = ', ChunksPerAttenuation);
    writeln('ProjectedByteSize = ', ProjectedByteSize);
  end;

  FrameCount := Max(1, ceil(SampleCount / (SampleRate * (FrameLength / 1000))));

{$ifdef ATARI_STE}
  ChunksPerFrame := ChunksPerFrame and (High(Word) - 1);
  Inc(ChunksPerFrame, 2);
  repeat
    Dec(ChunksPerFrame, 2);
{$else}
  Inc(ChunksPerFrame);
  repeat
    Dec(ChunksPerFrame);
{$endif}

    indexingCost :=
      (SampleCount * ChannelCount * (
        (Log2(ChunksPerFrame) + PiggyCodingBlocksBits + Ord(PiggyCodingBlocksBits > 1)) * CVariableCodingRatio +
        1 {dstNegative} + 1 {dstReversed} +
        CMaxAttenuationBits / (ChunksPerAttenuation * ChannelCount)
      )) / (8 {bytes -> bits} * ChunkSize);

    chunksCost :=
      (ChunksPerFrame * ChunkSize) * ChunkBitDepth * FrameCount / 8;

{$ifdef ATARI_STE}
    headerCost := SizeOf(Word) * (1 shl PiggyCodingBlocksBits) * SizeOf(Byte);
{$else}
    headerCost :=
      4 * SizeOf(Word) + SizeOf(Cardinal) + SizeOf(Cardinal) +
      ChannelCount * SizeOf(Word) +
      (1 shl PiggyCodingBlocksBits) * SizeOf(Byte);
{$endif}

    tentativeByteSize := Round(headerCost + indexingCost + chunksCost);

  until (tentativeByteSize <= ProjectedByteSize) or (ChunksPerFrame <= CMinChunksPerFrame);

  ProjectedByteSize := tentativeByteSize;

  writeln('ChannelCount = ', ChannelCount);
  writeln('SampleRate = ', SampleRate);
  writeln('FrameCount = ', FrameCount);
  writeln('ChunksPerFrame = ', ChunksPerFrame);

  Assert(ChunksPerFrame > 0, 'Null ChunksPerFrame! (BitRate too low)');

  if Verbose then
  begin
    WriteLn('SampleCount = ', SampleCount);
    writeln('FrameSize = ', ProjectedByteSize div FrameCount);
    writeln('ProjectedByteSize = ', ProjectedByteSize);
    writeln('ChunkSize = ', ChunkSize);
  end;

  // pass 2

  SetLength(flt, ChannelCount);
  for iChannel := 0 to ChannelCount - 1 do
    flt[iChannel] := CreateEmphasisFilter;
  try
    totalPower := 0;
    for iSample := 0 to SampleCount - 1 do
    begin
      smp := 0;
      for iChannel := 0 to ChannelCount - 1 do
        smp += Sqr(flt[iChannel].PreFilter(SrcData[iChannel, iSample]));
      smp := Round(Sqrt(smp / ChannelCount));

      totalPower += Round(lerp(1.0, smp, VariableFrameSizeRatio));
    end;

    perFramePower := totalPower / FrameCount;

    if Verbose then
    begin
      writeln('TotalPower = ', Round(totalPower / High(SmallInt)));
      writeln('PerFramePower = ', Round(perFramePower / High(SmallInt)));
    end;

    for iChannel := 0 to ChannelCount - 1 do
      flt[iChannel].Init;

    frmIdx := 0;
    nextStart := 0;
    curPower := 0;
    SetLength(Frames, FrameCount);
    for iSample := 0 to SampleCount - 1 do
    begin
      smp := 0;
      for iChannel := 0 to ChannelCount - 1 do
        smp += Sqr(flt[iChannel].PreFilter(SrcData[iChannel, iSample]));
      smp := Round(Sqrt(smp / ChannelCount));

      curPower += Round(lerp(1.0, smp, VariableFrameSizeRatio));

      if (iSample mod BlockSampleCount = 0) and (curPower >= perFramePower) then
      begin
        if frmIdx >= Length(Frames) then
          SetLength(Frames, frmIdx + 1);

        frm := TFrame.Create(Self, frmIdx, nextStart, iSample - 1);
        Frames[frmIdx] := frm;
        Inc(frmIdx);

        curPower := 0;
        nextStart := iSample;
      end;
    end;

    if frmIdx >= Length(Frames) then
      SetLength(Frames, frmIdx + 1);

    frm := TFrame.Create(Self, frmIdx, nextStart, SampleCount - 1);
    Frames[frmIdx] := frm;
    Inc(frmIdx);

    SetLength(Frames, frmIdx);
    FrameCount := frmIdx;
  finally
    for iChannel := 0 to ChannelCount - 1 do
      flt[iChannel].Free;
  end;
end;

procedure TEncoder.MakeFrames;

  procedure DoFrame(Index: PtrInt; Data: Pointer);
  begin
    if NoSolveFilterSettings then
      Frames[Index].MakeFrame
    else
      Frames[Index].SolveCompandingFilterSettings;
  end;

begin
  WriteLn('[MakeFrames]');

  TMTPool.DoStandaloneLocalProc(@DoFrame, 0, FrameCount - 1, NumberOfProcessors);
  WriteLn;
end;

constructor TEncoder.Create(InFN, OutFN: String);
begin
  InputFN := InFN;
  OutputFN := OutFN;

  BitRate := Infinity;
  ChunkBitDepth := 8;
  AttenuationChunkRatioMul := 1.0;
  PythonReduce := False;
  Precision := 3;

{$ifdef ATARI_STE}
  ChunkSize := 6;
  ChunksPerFrame := 256;
  ChunksPerAttenuation := 40;
  FrameLength := 1000.0 / 3; // in ms
  VariableFrameSizeRatio := 1.0;
  PiggyCodingBlocksBits := 1;
  PiggyCodingSolveByValue := True;
  NoSolveFilterSettings := False;
  GainFactor := 0.5;
{$else}
  ChunkSize := 4;
  ChunksPerAttenuation := 16;
  FrameLength := 10000; // in ms
  VariableFrameSizeRatio := 1.0;
  ChunksPerFrame := 8192;
  PiggyCodingBlocksBits := 2;
  PiggyCodingSolveByValue := False;
  NoSolveFilterSettings := True;
  GainFactor := 1.0;
{$endif}

end;

destructor TEncoder.Destroy;
begin
  inherited Destroy;
end;

procedure TEncoder.MakeDstData;
var
  iSample, iFrame, iChannel, pos: Integer;
begin
  WriteLn('[MakeDstData]');

  SetLength(DstData, ChannelCount, SampleCount);

  for iChannel := 0 to ChannelCount - 1 do
  begin
    pos := 0;
    for iFrame := 0 to FrameCount - 1 do
      for iSample := 0 to Frames[iFrame].SampleCount - 1 do
      begin
        DstData[iChannel, pos] := make16BitSample(Frames[iFrame].dstData[iChannel, iSample]);
        Inc(pos);
      end;
  end;
end;

function TEncoder.GetThreadsPerFrame: Cardinal;
begin
  Result := Max(1, iDivDef(NumberOfProcessors, FramesLeft, NumberOfProcessors));
end;

function TEncoder.CreateEmphasisFilter: TEmphasisFilter;
begin
{$ifdef ATARI_STE}
  Result := TLMC1992Filter.Create(SampleRate);
  TLMC1992Filter(Result).Set_Tone_Level(TLMC1992Filter.NEUTRAL_TONE + 3, TLMC1992Filter.NEUTRAL_TONE - 6);
{$else}
  Result := TDeltaFilter.Create(SampleRate);
{$endif}
end;

class function TEncoder.make16BitSample(smp: Double): SmallInt;
begin
  Result := EnsureRange(Round(smp * High(SmallInt)), Low(SmallInt), High(SmallInt));
end;

class function TEncoder.makeFloatSample(smp: SmallInt): Double;
begin
  Result := smp / High(SmallInt);
end;

class function TEncoder.makeOutputSample(smp: Double; OutBitDepth, Attenuation: Byte; Negative: Boolean; gain: Double): TOutputSample;
var
  obd, loBnd, upBnd: Integer;
  smp16, coeff: Double;
begin
  coeff := ComputeAttenuation(Attenuation);

  obd := (1 shl (OutBitDepth - 1)) - 1;
  smp16 := smp * obd * coeff * gain;
  if Negative then smp16 := -smp16;
  loBnd := Floor(-obd * coeff);
  upBnd := Ceil(obd * coeff);
  Result.AsInt := EnsureRange(Round(smp16), loBnd, upBnd);
  Result.AsDouble := EnsureRange(smp16, loBnd, upBnd);
end;

class function TEncoder.makeFloatSample(smp: Integer; OutBitDepth, Attenuation: Byte; Negative: Boolean; gain: Double): Double;
var
  obd, coeff: Double;
begin
  coeff := ComputeAttenuation(Attenuation);

  obd := (1 shl (OutBitDepth - 1)) - 1;
  if Negative then smp := -smp;
  Result := smp / (obd * coeff * gain);
  Result := EnsureRange(Result, -1.0, 1.0);
end;

class function TEncoder.SolveAttenuation(chunkSz: Integer; samples: PDouble): Byte;
var
  i, hiSmp: Integer;
  coeff: Double;
begin
  hiSmp := 0;
  for i := 0 to chunkSz - 1 do
    hiSmp := max(hiSmp, ceil(abs(samples[i] * High(SmallInt))));

  Result := 0;
  coeff := 1.0;
  repeat
    Inc(Result);
    coeff := ComputeAttenuation(Result);
  until (hiSmp * coeff > High(SmallInt)) or (Result > CMaxAttenuation);
  Dec(Result);
end;

class function TEncoder.ComputeAttenuation(Attenuation: Integer): Double;
begin
  Result := Power(10.0, Attenuation * CAttenuationLawDecibels / 20.0);
end;

class procedure TEncoder.ComputeDCT(chunkSz: Integer; samples, dct: PDouble);
var
  k, n: Integer;
  sum: Double;
begin
  for k := 0 to chunkSz - 1 do
  begin
    sum := 0;
    for n := 0 to chunkSz - 1 do
      sum += samples[n] * cos(pi / chunkSz * (n + 0.5) * k);

    dct^ := sum * sqrt (2.0 / chunkSz);
    Inc(dct);
  end;
end;

class procedure TEncoder.ComputeInvDCT(chunkSz: Integer; dct, samples: PDouble);
var
  k, n: Integer;
  sum: Double;
begin
  for k := 0 to chunkSz - 1 do
  begin
    sum := 0.5 * dct[0];
    for n := 1 to chunkSz - 1 do
      sum += dct[n] * cos (pi / chunkSz * (k + 0.5) * n);

    samples^ := sum * sqrt(2.0 / chunkSz);
    Inc(samples);
  end;
end;

class function TEncoder.CompareEuclidean(const dctA, dctB: TDoubleDynArray): Double;
var
  i: Integer;
begin
  Assert(Length(dctA) = Length(dctB));
  Result := 0.0;

  for i := 0 to High(dctA) do
    Result += sqr(dctA[i] - dctB[i]);

  Result := sqrt(Result / Length(dctA));
end;

class function TEncoder.CompareMuLawManhattan(const dctA, dctB: TDoubleDynArray): TPsyADelta;
var
  i: Integer;
begin
  Assert(Length(dctA) = Length(dctB));

  Result.Linear := 0.0;
  Result.MuLaw := 0.0;
  for i := 0 to High(dctA) do
  begin
    Result.Linear += Abs(dctA[i] - dctB[i]);
    Result.MuLaw += Abs(muLaw(dctA[i]) - muLaw(dctB[i]));
  end;

  Result.Linear := Result.Linear / Length(dctA);
  Result.MuLaw := Result.MuLaw / Length(dctA);
end;

function TEncoder.ComputeEAQUAL(UseDIX, Verbz: Boolean; const smpRef, smpTst: TSmallIntDynArray): Double;
var
  FNTmp, FNRef, FNTst: String;
begin
  FNTmp := GetTempFileName('', 'tmp-'+IntToStr(GetCurrentThreadId))+'.wav';
  FNRef := GetTempFileName('', 'ref-'+IntToStr(GetCurrentThreadId))+'.wav';
  FNTst := GetTempFileName('', 'tst-'+IntToStr(GetCurrentThreadId))+'.wav';

  createWAV(ChannelCount, 16, SampleRate, FNTmp, smpRef);
  DoExternalSOX(FNTmp, FNRef, 48000);

  createWAV(ChannelCount, 16, SampleRate, FNTmp, smpTst);
  DoExternalSOX(FNTmp, FNTst, 48000);

  Result := DoExternalEAQUAL(FNRef, FNTst, Verbz, UseDIX, -1);

  DeleteFile(FNTst);
  DeleteFile(FNRef);
  DeleteFile(FNTst);
end;

class function TEncoder.ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): TPsyADelta;
var
  i, j, len: Integer;
  rr, rt: TDoubleDynArray;
begin
  len := length(smpRef) * length(smpRef[0]);
  Assert(len = length(smpTst) * length(smpTst[0]), 'ComputePsyADelta length mismatch!');
  SetLength(rr, len);
  SetLength(rt, len);

  for j := 0 to High(smpRef) do
    for i := 0 to High(smpRef[0]) do
    begin
      rr[j * Length(smpRef[0]) + i] := makeFloatSample(smpRef[j, i]);
      rt[j * Length(smpRef[0]) + i] := makeFloatSample(smpTst[j, i]);
    end;

  Result := CompareMuLawManhattan(rr, rt);

  Result.Linear *= High(SmallInt);
  Result.MuLaw *= High(SmallInt);
end;

class procedure TEncoder.createWAV(channels: word; resolution: word; rate: longint; fn: string; const data: TSmallIntDynArray);
var
  wf : TFileStream;
  wh : TWavHeader;
begin
  wh.rId             := $46464952; { 'RIFF' }
  wh.rLen            := 36 + Length(data) * SizeOf(data[0]); { length of sample + format }
  wh.wId             := $45564157; { 'WAVE' }
  wh.fId             := $20746d66; { 'fmt ' }
  wh.fLen            := 16; { length of format chunk }
  wh.wFormatTag      := 1; { PCM data }
  wh.nChannels       := channels; { mono/stereo }
  wh.nSamplesPerSec  := rate; { sample rate }
  wh.nAvgBytesPerSec := channels*rate*(resolution div 8);
  wh.nBlockAlign     := channels*(resolution div 8);
  wh.wBitsPerSample  := resolution;{ resolution 8/16 }
  wh.dId             := $61746164; { 'data' }
  wh.wSampleLength   := Length(data) * SizeOf(data[0]); { sample size }

  wf := TFileStream.Create(fn, fmCreate or fmShareDenyNone);
  try
    wf.WriteBuffer(wh, SizeOf(wh));
    wf.WriteBuffer(data[0], Length(data) * SizeOf(data[0]));
  finally
    wf.Free;
  end;
end;

procedure test_dct_idct;
const
  CIter = 1000;
  CLen = 16;
var
  iIter, iDCT: Integer;
  test: array[0 .. CLen - 1] of Double;
  dct: array[0 .. CLen - 1] of Double;
  invdct: array[0 .. CLen - 1] of Double;
begin
  RandSeed := $42381337;
  for iIter := 0 to CIter - 1 do
  begin
    for iDCT := 0 to CLen - 1 do
      test[iDCT] := Random * 2.0 - 1.0;
    TEncoder.ComputeDCT(CLen, @test[0], @dct[0]);
    TEncoder.ComputeInvDCT(CLen, @dct[0], @invdct[0]);
    for iDCT := 0 to CLen - 1 do
      Assert(SameValue(test[iDCT], invdct[iDCT], 1e-6));
  end;
end;

var
  enc: TEncoder;
  psyA: TEncoder.TPsyADelta;
  s: String;
begin
  try
    FormatSettings.DecimalSeparator := '.';

{$ifdef DEBUG}
    //ProcThreadPool.MaxThreadCount := 1;
{$else}
    SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
{$endif}

    test_dct_idct;

    if ParamCount < 2 then
    begin
      WriteLn('Usage: ', ExtractFileName(ParamStr(0)) + ' <source file> <dest file> [options]');
      Writeln('Main options:');
      WriteLn(#9'-br'#9'encoder bit rate in kilobits/second; example: "-br250"');
      WriteLn(#9'-vfr'#9'RMS power based variable frame size ratio (0.0-1.0); default: "-vfr1.0"');
      WriteLn(#9'-fl'#9'(Average) frame length in milliseconds; default: "-fl10000"');
{$ifdef ATARI_STE}
      WriteLn(#9'-artist'#9'artist name tag (max. 31 chars); example: -artist"GliGli"');
      WriteLn(#9'-title'#9'song title tag (max. 31 chars); example: -title"SoundChunks Demo"');
{$endif}
      WriteLn(#9'-v'#9'verbose mode');
      Writeln('Development options:');
      WriteLn(#9'-d'#9'debug mode (outputs decoded WAVs)');
{$ifdef ATARI_STE}
      WriteLn(#9'-nsfs'#9'Don''t solve filter settings (faster!)');
{$else}
      WriteLn(#9'-cs'#9'chunk size');
      WriteLn(#9'-cbd'#9'chunk bit depth (8,12)');
      WriteLn(#9'-att'#9'attenuation to chunk ratio multiplier (0.1-10.0)');
{$endif}
      WriteLn(#9'-cpf'#9'max. chunks per frame (', CMinChunksPerFrame, '-', CMaxChunksPerFrame, ')');
      WriteLn(#9'-pr'#9'K-means precision; 0: "lossless" mode');
      WriteLn(#9'-py'#9'python cluster.py reducer');

      WriteLn;
      Writeln('(source file must be 16bit WAV or anything SOX can convert)');
      WriteLn;
      Exit;
    end;

    enc := TEncoder.Create(ParamStr(1), ParamStr(2));
    try
      enc.BitRate := ParamValue('-br', enc.BitRate);
      enc.Precision := round(ParamValue('-pr', enc.Precision));
      enc.VariableFrameSizeRatio := EnsureRange(ParamValue('-vfr', enc.VariableFrameSizeRatio), 0.0, 1.0);
      enc.FrameLength := Max(ParamValue('-fl', enc.FrameLength), 1.0);
      enc.ChunksPerFrame := EnsureRange(round(ParamValue('-cpf', enc.ChunksPerFrame)), CMinChunksPerFrame, CMaxChunksPerFrame);
      enc.Verbose := HasParam('-v');
      enc.PythonReduce := HasParam('-py');
      enc.DebugMode := HasParam('-d');
{$ifdef ATARI_STE}
      enc.NoSolveFilterSettings := HasParam('-nsfs');
      s := '-artist';
      if ParamStart(s) >= 0 then
      begin
        s := ParamStr(ParamStart(s));
        enc.ArtistTag := Copy(s, 8, 31);
      end;

      s := '-title';
      if ParamStart(s) >= 0 then
      begin
        s := ParamStr(ParamStart(s));
        enc.TitleTag := Copy(s, 7, 31);
      end;
{$else}
      enc.ChunkSize := round(ParamValue('-cs', enc.ChunkSize));
      enc.ChunkBitDepth := EnsureRange(round(ParamValue('-cbd', enc.ChunkBitDepth)), 1, 16);
      enc.AttenuationChunkRatioMul := EnsureRange(ParamValue('-att', enc.AttenuationChunkRatioMul), 0.1, 10.0);
{$endif}

      WriteLn('BitRate = ', FloatToStr(enc.BitRate));
      WriteLn('VariableFrameSizeRatio = ', FloatToStr(enc.VariableFrameSizeRatio));
      WriteLn('FrameLength = ', enc.FrameLength:0:0);
      if enc.Verbose then
      begin
        WriteLn('ChunkSize = ', enc.ChunkSize);
        WriteLn('MaxChunksPerFrame = ', enc.ChunksPerFrame);
        WriteLn('ChunkBitDepth = ', enc.ChunkBitDepth);
        WriteLn('AttenuationChunkRatioMul = ', FloatToStr(enc.AttenuationChunkRatioMul));
        WriteLn('Precision = ', enc.Precision);
      end;
      WriteLn;

      enc.Load;

      enc.PrepareFrames;
      enc.MakeFrames;
      enc.MakeDstData;

      if enc.DebugMode then
        enc.SaveWAV;

      if enc.Precision > 0 then
        enc.SaveGSC;

      psyA :=  enc.ComputePsyADelta(enc.SrcData, enc.DstData);
      WriteLn('[PsyADelta] Linear:', psyA.Linear:12:6, ', mu-Law:', psyA.MuLaw:12:6);

    finally
      enc.Free;
    end;

    WriteLn('Done.');
    if IsDebuggerPresent then
      ReadLn;

  except
    on e: Exception do
    begin
      WriteLn('Exception: ', e.Message, ' (', e.ClassName, ')');
      ReadLn;
    end;
  end;
end.

