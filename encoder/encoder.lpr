program encoder;

{$mode objfpc}{$H+}

uses
  tbbmalloc,
  windows, Classes, sysutils, strutils, Types, fgl, math,
  extern, mtpool;

const
{$ifdef ATARI_STE}
  CStreamVersion = 7;

  CMaxAttenuationBits = 4;
  CAttenuationLawDecibels = 2.0;
{$else}
  CStreamVersion = 7;

  CMaxAttenuationBits = 6;
  CAttenuationLawDecibels = 0.75;
{$endif}

  CMinChunksPerFrame = 8;
  CMaxChunksPerFrame = 65536;
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
  const
    CFactor = 0.75;
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
    TCodingTableItem = record
      Bits: UInt64;
      BitCount: Byte;
    end;
    TCodingTable = record
      LUT: array of TCodingTableItem;
      codingBlocksCount: Byte;
      codingBlocks: array[0 .. High(Byte)] of Byte;
    end;
  private
    FCodingBlocks: array[0 .. High(Byte)] of Byte;
    FHighestCode: Cardinal;
    FCodes: TCodeArray;
    FCodesBitCount: Byte;

    FCodingBlocksCount: Byte;
    FBestCodingSize: UInt64;

    FFrequencies: TCardinalDynArray;

    function GREvalCodingSize(const AX: TDoubleDynArray; AData: Pointer): Double;

    function BuildCodingTable(ACodingBlocksCount: Byte; const ACodingBlocks: array of Byte; var ACodingTable: TCodingTable): Boolean;
    function TestCoding(const ACodingTable: TCodingTable): UInt64;

    procedure SolveCodingBlocks_BruteForce;
    procedure SolveCodingBlocks_GridReduce;
  public
    constructor Create(ACodes: TCodeArray; AHighestCode: Integer);

    procedure SolveCodingBlocks;
    procedure Render(AStream: TStream);

    property CodingBlocksCount: Byte read FCodingBlocksCount;
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

    function GetDstFloatSample(AIndex: Integer): Double;
    function GetDstFloatSample(AIndex: Integer; ANegative, AReversed: Boolean; AAttenuation: Integer): Double;
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

    srcFirstSample: TSmallIntDynArray;

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
    procedure MakeCoding;
    procedure SaveStream(AStream: TStream);

    procedure SolveCompandingFilterSettings;
    procedure MakeFrame(AMakeCoding: Boolean = True);
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
  public
    InputFN, OutputFN: String;

    ArtistTag, TitleTag: String;
    BitRate: Double;
    Precision: Integer;
    ChunkBitDepth: Integer; // 8 or 12 Bits
    ChunkSize: Integer;
    ChunksPerFrame: Integer;
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

    SrcData: TSmallIntDynArray2;
    DstData: TSmallIntDynArray2;
    DCTLut: TDoubleDynArray;
    InvDCTLut: TDoubleDynArray;

    Frames: array of TFrame;

    function CreateEmphasisFilter: TEmphasisFilter;

    class function make16BitSample(ASample: Double): SmallInt;
    class function makeOutputSample(ASample: Double; AOutBitDepth, AAttenuation: Byte; ANegative: Boolean): TOutputSample;
    class function makeFloatSample(ASample: SmallInt): Double;
    class function makeFloatSample(ASample: Integer; AOutBitDepth, AAttenuation: Byte; ANegative: Boolean): Double;
    class function SolveAttenuation(chunkSz: Integer; samples: PDouble): Byte;
    class function ComputeAttenuation(Attenuation: Integer): Double;
    class procedure ComputeDCTLut(chunkSz: Integer; lut: PDouble);
    class procedure ComputeInvDCTLut(chunkSz: Integer; lut: PDouble);
    class function CompareEuclidean(const dctA, dctB: TDoubleDynArray): Double; overload;
    class function CompareMuLawManhattan(const dctA, dctB: TDoubleDynArray): TPsyADelta;
    class function ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): TPsyADelta;
    class procedure createWAV(channels: word; resolution: word; rate: longint; fn: string; const data: TSmallIntDynArray);

    class procedure ConvolveDCT(chunkSz: Integer; input, output, lut: PDouble);

    constructor Create(InFN, OutFN: String);
    destructor Destroy; override;

    procedure Load;
    procedure SaveWAV;
    function SaveGSC: Double;
    procedure SaveStream(AStream: TStream);

    procedure PrepareFrames;
    procedure MakeFrames;
    procedure MakeDstData;

    function ComputeEAQUAL(UseDIX, Verbz: Boolean): Double;
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
  prevSample := s * CFactor;
end;

function TDeltaFilter.DeFilter(s: Double): Double;
begin
  accSample := accSample * CFactor + s;
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

constructor TPiggyCoder.Create(ACodes: TCodeArray; AHighestCode: Integer);
var
  iCode: Integer;
begin
  FCodes := ACodes;
  FHighestCode := AHighestCode;
  FCodesBitCount := Ceil(Log2(FHighestCode + 1));

  FBestCodingSize := High(UInt64);

  SetLength(FFrequencies, FHighestCode + 1);
  for iCode := 0 to High(FCodes) do
    Inc(FFrequencies[FCodes[iCode].Code]);

  // dumb default (need to call SolveCodingBlocks)
  FCodingBlocksCount := 1;
  FCodingBlocks[0] := FCodesBitCount;
end;

procedure TPiggyCoder.SolveCodingBlocks;
begin
  if FHighestCode < 256 then
    SolveCodingBlocks_BruteForce;

  SolveCodingBlocks_GridReduce;
end;

procedure TPiggyCoder.SolveCodingBlocks_BruteForce;
const
  CLoCBC = 1;
  CHiCBC = 6;
var
  locCodingBlocks: array[0 .. High(Byte)] of Byte;
  codingTable: TCodingTable;
  iCBC, iCB: ShortInt;
  curSize: UInt64;
begin
  SetLength(codingTable.LUT, FHighestCode + 1);

  for iCBC := CLoCBC to CHiCBC do
  begin
    FillChar(locCodingBlocks, SizeOf(locCodingBlocks), 0);

    repeat

      Inc(locCodingBlocks[0]);
      for iCB := 0 to iCBC - 2 do
      begin
        if locCodingBlocks[iCB] >= FCodesBitCount then
        begin
          locCodingBlocks[iCB] := 0;
          Inc(locCodingBlocks[iCB + 1]);
        end
        else
        begin
          Break;
        end;
      end;

      if BuildCodingTable(iCBC, locCodingBlocks, codingTable) then
      begin
        curSize := TestCoding(codingTable);

        if curSize < FBestCodingSize then
        begin
          FBestCodingSize := curSize;
          FCodingBlocksCount := iCBC;
          for iCB := 0 to iCBC - 1 do
            FCodingBlocks[iCB] := locCodingBlocks[iCB];
        end;
      end;

    until locCodingBlocks[iCBC - 1] >= FCodesBitCount;
  end;
end;

procedure TPiggyCoder.SolveCodingBlocks_GridReduce;
const
  CLoCBC = 1;
  CHiCBC = 16;
var
  iCBC, iCB: ShortInt;
  curSize: UInt64;
  X, GridExtents: TDoubleDynArray;
  GridSize: TIntegerDynArray;
begin
  for iCBC := CLoCBC to CHiCBC do
  begin
    SetLength(X, iCBC);
    SetLength(GridExtents, iCBC);
    SetLength(GridSize, iCBC);

    if iCBC = 1 then
    begin
      X[0] := FCodesBitCount;
      GridExtents[0] := FCodesBitCount * 0.25;
      GridSize[0] := 10;
    end
    else
    begin
      X[iCBC - 1] := X[iCBC - 2];
      GridExtents[iCBC - 1] := GridExtents[iCBC - 2];
      GridSize[iCBC - 1] := GridSize[iCBC - 2];
    end;

    curSize := Round(GridReduceMinimize(@GREvalCodingSize, X, GridSize, GridExtents, 0.025));

    if (curSize < High(Integer)) and (curSize < FBestCodingSize) then
    begin
      FBestCodingSize := curSize;
      FCodingBlocksCount := iCBC;
      for iCB := 0 to iCBC - 1 do
        FCodingBlocks[iCB] := EnsureRange(Trunc(X[iCB]), 0, FCodesBitCount);
    end;
  end;
end;

function TPiggyCoder.TestCoding(const ACodingTable: TCodingTable): UInt64;
var
  iCode: Integer;
begin
  // !\ keep synced with TPiggyCoder.Render

{$ifdef ATARI_STE}
  Result := (((ACodingTable.codingBlocksCount * 4 - 1) shr 4) + 1) shl 4;
{$else}
  Result := (ACodingTable.codingBlocksCount + 1) * BitSizeOf(Byte);
{$endif}

  for iCode := 0 to FHighestCode do
    Result += FFrequencies[iCode] * ACodingTable.LUT[iCode].BitCount;
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

  procedure DoByte(AByte: UInt64);
  begin
    AStream.WriteByte(AByte and $ff);
  end;

var
  built: Boolean;
  iCode, iCodingBlocks, itemBitCnt, overallBitCnt, codeValue: Integer;
  itemBits, overallBits: UInt64;
  w: Word;
  codingTable: TCodingTable;
  locCB: array[0 .. High(Byte)] of Byte;
begin
  // !\ keep synced with TPiggyCoder.TestCoding

  SetLength(codingTable.LUT, FHighestCode + 1);
  built := BuildCodingTable(FCodingBlocksCount, FCodingBlocks, codingTable);
  Assert(built);

{$ifdef ATARI_STE}
  w := 0;
  FillChar(locCB, SizeOf(locCB), 0);
  Move(codingTable.codingBlocks, locCB, codingTable.codingBlocksCount);
  for iCodingBlocks := 0 to ((codingTable.codingBlocksCount - 1) div 4 + 1) * 4 - 1 do
  begin
    w := locCB[iCodingBlocks] or (w shl 4);
    if iCodingBlocks and 3 = 3 then
    begin
      DoWord(w);
      w := 0;
    end;
  end;
{$else}
  DoByte(codingTable.codingBlocksCount);
  for iCodingBlocks := 0 to codingTable.codingBlocksCount - 1 do
    DoByte(codingTable.codingBlocks[iCodingBlocks]);
{$endif}

  overallBits := 0;
  overallBitCnt := 0;

  for iCode := 0 to High(FCodes) do
  begin
    itemBits := 0;
    itemBitCnt := 0;

    if FCodes[iCode].ExtraBitCount > 0 then
    begin
      itemBits := FCodes[iCode].ExtraBits or (itemBits shl FCodes[iCode].ExtraBitCount);
      itemBitCnt += FCodes[iCode].ExtraBitCount;
    end;

    codeValue := FCodes[iCode].Code;
    itemBits := codingTable.LUT[codeValue].Bits or (itemBits shl codingTable.LUT[codeValue].BitCount);
    itemBitCnt += codingTable.LUT[codeValue].BitCount;

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

function TPiggyCoder.GREvalCodingSize(const AX: TDoubleDynArray; AData: Pointer): Double;
var
  iCB: Integer;
  locCodingBlocks: array[0 .. High(Byte)] of Byte;
  codingTable: TCodingTable;
begin
  Result := High(Cardinal);

  for iCB := 0 to High(AX) do
    locCodingBlocks[iCB] := EnsureRange(Trunc(AX[iCB]), 0, FCodesBitCount);

  SetLength(codingTable.LUT, FHighestCode + 1);

  if BuildCodingTable(Length(AX), locCodingBlocks, codingTable) then
    Result := TestCoding(codingTable);
end;

function TPiggyCoder.BuildCodingTable(ACodingBlocksCount: Byte; const ACodingBlocks: array of Byte;
  var ACodingTable: TCodingTable): Boolean;
var
  iCode, iCodingBlocks, itemBitCnt, codeValue, codeBlockLimit, codingBlock: Integer;
  itemBits: UInt64;
  cbSum: Byte;
begin
  Result := True;

  cbSum := 0;
  for iCodingBlocks := 0 to ACodingBlocksCount - 1 do
    cbSum += ACodingBlocks[iCodingBlocks];
  if cbSum < FCodesBitCount then
    Exit(False);

  ACodingTable.codingBlocksCount := ACodingBlocksCount;
  Move(ACodingBlocks, ACodingTable.codingBlocks, ACodingBlocksCount);

  for iCode := 0 to FHighestCode do
  begin
    itemBits := 0;
    itemBitCnt := 0;

    codeValue := iCode;

    codingBlock := -1;
    for iCodingBlocks := 0 to ACodingBlocksCount - 1 do
    begin
      codeBlockLimit := 1 shl ACodingBlocks[iCodingBlocks];

      if codeValue < codeBlockLimit then
      begin
        if iCodingBlocks < ACodingBlocksCount - 1 then
        begin
	        itemBits := 0 or (itemBits shl 1);
	        itemBitCnt += 1;
        end;

        codingBlock := iCodingBlocks;
        Break;
      end;

      itemBits := 1 or (itemBits shl 1);
      itemBitCnt += 1;

      codeValue -= codeBlockLimit;
    end;

    if codingBlock < 0 then
      Exit(False);

    itemBits := codeValue or (itemBits shl ACodingBlocks[codingBlock]);
    itemBitCnt += ACodingBlocks[codingBlock];

    ACodingTable.LUT[iCode].Bits := itemBits;
    ACodingTable.LUT[iCode].BitCount := itemBitCnt;
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
  data: TDoubleDynArray;
begin
  SetLength(data, frame.encoder.ChunkSize);
  for iSample := 0 to High(data) do
    data[iSample] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, frame.encoder.ChunkSize - 1 - iSample, iSample)], 2, dstAttenuation, dstNegative).AsDouble;

  SetLength(Result, frame.encoder.ChunkSize);
  TEncoder.ConvolveDCT(Length(data), @data[0], @Result[0], @frame.encoder.DCTLut[0]);
end;

procedure TChunk.ComputeFromFeatures(AFeatures: PDouble);
var
  iSample: Integer;
  data: TDoubleDynArray;
begin
  SetLength(data, frame.encoder.ChunkSize);
  TEncoder.ConvolveDCT(frame.encoder.ChunkSize, AFeatures, @data[0], @frame.encoder.InvDCTLut[0]);

  SetLength(dstData, frame.encoder.ChunkSize);
  for iSample := 0 to High(data) do
    dstData[iSample] := TEncoder.makeOutputSample(data[iSample], frame.encoder.ChunkBitDepth, 0, False).AsInt;
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
    dstData[i] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, High(dstData) - i, i)], frame.encoder.ChunkBitDepth, dstAttenuation, dstNegative).AsInt;
end;

function TChunk.GetDstFloatSample(AIndex: Integer): Double;
begin
  Result := GetDstFloatSample(AIndex, dstNegative, dstReversed, dstAttenuation);
end;

function TChunk.GetDstFloatSample(AIndex: Integer; ANegative, AReversed: Boolean; AAttenuation: Integer): Double;
begin
  Result := TEncoder.makeFloatSample(reducedChunk.dstData[IfThen(AReversed, frame.encoder.ChunkSize - 1 - AIndex, AIndex)], frame.encoder.ChunkBitDepth, AAttenuation, ANegative);
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
    srcFirstSample[iChannel] := 0;
    if StartSample > 0 then
      srcFirstSample[iChannel] := encoder.SrcData[iChannel, StartSample - 1];
    filter[iChannel].Init;
    filter[iChannel].PreFilter(TEncoder.makeFloatSample(srcFirstSample[iChannel]));
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

  SetLength(Dataset, plainChunks.Count);

  for iChunk := 0 to plainChunks.Count - 1 do
    Dataset[iChunk] := plainChunks[iChunk].ComputeFeatures;

  colCount := Length(Dataset[0]);
  clusterCount := encoder.ChunksPerFrame;

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
          yakmo_load_train_data(Yakmo, Length(Dataset), colCount, PPDouble(@Dataset[0]));
          yakmo_train_on_data(Yakmo, @Clusters[0]);
          yakmo_get_centroids(Yakmo, PPDouble(@Centroids[0]));
        finally
          yakmo_destroy(Yakmo);
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
  iChunk, iSample, dsIdx, bestIdx, colCount: Integer;
  iNegative, iReversed: Boolean;
  bestErr, attCoeff: Double;
  Dataset: TANNFloatDynArray2;
  query: TANNFloatDynArray;
  KDT: PANNkdtree;
  chunk: TChunk;
begin
  colCount := encoder.chunkSize;

  SetLength(query, colCount + encoder.chunkSize);
  SetLength(Dataset, reducedChunks.Count * 2 {Negative} * 2 {Reversed}, Length(query));

  dsIdx := 0;
  for iChunk := 0 to reducedChunks.Count - 1 do
  begin
    chunk := reducedChunks[iChunk];

    // also reset chunk useCount
    chunk.useCount := 0;

    for iReversed := False to True do
      for iNegative := False to True do
      begin
        for iSample := 0 to encoder.ChunkSize - 1 do
          Dataset[dsIdx, colCount + iSample] := chunk.GetDstFloatSample(iSample, iNegative, iReversed, 0);
        TEncoder.ConvolveDCT(encoder.ChunkSize, @Dataset[dsIdx, colCount], @Dataset[dsIdx, 0], @encoder.DCTLut[0]);
        Inc(dsIdx);
      end;
  end;

  KDT := ann_kdtree_create(PPANNFloat(@Dataset[0]), Length(Dataset), colCount, 1, ANN_KD_STD);
  try
    for iChunk := 0 to plainChunks.Count - 1 do
    begin
      chunk := plainChunks[iChunk];

      attCoeff := encoder.ComputeAttenuation(chunk.dstAttenuation);

      for iSample := 0 to encoder.ChunkSize - 1 do
        query[colCount + iSample] := chunk.srcData[iSample] * attCoeff;

      TEncoder.ConvolveDCT(encoder.ChunkSize, @query[colCount], @query[0], @encoder.DCTLut[0]);

      bestIdx := ann_kdtree_search(KDT, @query[0], 0.0, @bestErr);

      chunk.dstNegative := bestIdx and 1 <> 0;
      chunk.dstReversed := bestIdx and 2 <> 0;
      chunk.reducedChunk := reducedChunks[bestIdx shr 2];

      Inc(chunk.reducedChunk.useCount);
    end;
  finally
    ann_kdtree_destroy(KDT);
  end;

{$ifndef ATARI_STE}
  for iChunk := reducedChunks.Count - 1 downto 0 do
    if reducedChunks[iChunk].useCount = 0 then
       reducedChunks.Delete(iChunk);
{$endif}

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
  Assert(plainChunks.Count div (encoder.ChannelCount * encoder.ChunksPerAttenuation) - 1 <= High(Word));
  AStream.WriteWord(NtoBE(WORD(plainChunks.Count div (encoder.ChannelCount * encoder.ChunksPerAttenuation) - 1)));

  AStream.WriteByte((TLMC1992Filter(filter[0]).bass_level shl 4) or TLMC1992Filter(filter[0]).treb_level);
  AStream.WriteByte(dstPiggyCoder.CodingBlocksCount);

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
  w := encoder.SampleRate;
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
  AStream.WriteDWord(plainChunks.Count div encoder.ChannelCount);

  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    w := srcFirstSample[iChannel];
    AStream.WriteWord(w and $ffff);
  end;
{$endif}

  dstPiggyCoder.Render(AStream);
end;

procedure TFrame.MakeFrame(AMakeCoding: Boolean);
var
  pass: Integer;
begin
  MakeChunks;
  ComputeAttenuations;

  for pass := 1 to 2 do
  begin
    Reduce;
    Reconstruct;
  end;

  MakeDstData;
  if AMakeCoding then
    MakeCoding;
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

  MakeFrame(True);
  //WriteLn(index:4, bestTreb:4, best * High(SmallInt) / (SampleCount * encoder.ChannelCount):12:3);
{$endif}
end;

procedure TFrame.MakeDstData;
var
  iChannel, iChunk, iSample: Integer;
  smp: Double;
  chunk: TChunk;
  pos: TIntegerDynArray;
begin
  SetLength(pos, encoder.ChannelCount);
  SetLength(dstData, encoder.ChannelCount, SampleCount);
  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    FillQWord(dstData[iChannel, 0], SampleCount, 0);
    pos[iChannel] := 0;
    filter[iChannel].Init;
    filter[iChannel].DeFilter(TEncoder.makeFloatSample(srcFirstSample[iChannel]));
  end;

  for iChunk := 0 to plainChunks.Count - 1 do
  begin
    chunk := plainChunks[iChunk];

    for iSample := 0 to encoder.ChunkSize - 1 do
    begin
      smp := chunk.GetDstFloatSample(iSample);

      if InRange(pos[chunk.channel], 0, High(dstData[chunk.channel])) then
        dstData[chunk.channel, pos[chunk.channel]] := filter[chunk.channel].DeFilter(smp);

      Inc(pos[chunk.channel]);
    end;
  end;
end;

procedure TFrame.MakeCoding;
var
  iChunk: Integer;
  chunk: TChunk;
  pCode: ^TPiggyCoder.TCode;
  piggyCodes: TPiggyCoder.TCodeArray;
begin
  SetLength(piggyCodes, plainChunks.Count);
  for iChunk := 0 to plainChunks.Count - 1 do
  begin
    chunk := plainChunks[iChunk];
    pCode := @piggyCodes[iChunk];

    pCode^.Code := chunk.reducedChunk.index;

    if iChunk mod (encoder.ChunksPerAttenuation * encoder.ChannelCount) = 0 then
    begin
      pCode^.ExtraBits := chunk.dstAttenuation;
      pCode^.ExtraBitCount := CMaxAttenuationBits;
    end;

    pCode^.ExtraBits := Ord(chunk.dstNegative) or (pCode^.ExtraBits shl 1);
    pCode^.ExtraBitCount += 1;

    pCode^.ExtraBits := Ord(chunk.dstReversed) or (pCode^.ExtraBits shl 1);
    pCode^.ExtraBitCount += 1;
  end;

  dstPiggyCoder.Free;
  dstPiggyCoder := TPiggyCoder.Create(piggyCodes, reducedChunks.Count - 1);
  dstPiggyCoder.SolveCodingBlocks;
end;

{ TEncoder }

procedure TEncoder.Load;
var
  wavFN: String;
  fs: TFileStream;
  iSample, iChannel: Integer;
  data: TSmallIntDynArray;
  srcHeader: TWavHeader;
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
    fs.ReadBuffer(srcHeader, SizeOf(srcHeader));
    SampleRate := srcHeader.nSamplesPerSec;
    ChannelCount := srcHeader.nChannels;
    SampleCount := srcHeader.wSampleLength div (ChannelCount * SizeOf(SmallInt));

    Assert(srcHeader.wBitsPerSample = 16, 'can only read 16-bit WAVs');

    SetLength(SrcData, ChannelCount, SampleCount);

    SetLength(data, SampleCount * ChannelCount);
    fs.ReadBuffer(data[0], SampleCount * ChannelCount * SizeOf(SmallInt));

    for iSample := 0 to SampleCount - 1 do
      for iChannel := 0 to ChannelCount - 1 do
        SrcData[iChannel, iSample] := data[iSample * ChannelCount + iChannel];
  finally
    fs.Free;

    if wavFN <> InputFN then
      DeleteFile(wavFN);
  end;
end;

procedure TEncoder.SaveWAV;
var
  iSample, iChannel: Integer;
  wavFN: String;
  data: TSmallIntDynArray;
begin
  wavFN := ChangeFileExt(OutputFN, '.wav');

  WriteLn('[SaveWAV] ', wavFN);

  SetLength(data, SampleCount * ChannelCount);
  for iSample := 0 to SampleCount - 1 do
    for iChannel := 0 to ChannelCount - 1 do
      data[iSample * ChannelCount + iChannel] := DstData[iChannel, iSample];

  createWAV(ChannelCount, 16, SampleRate, wavFN, data);
end;

function TEncoder.SaveGSC: Double;
var
  fs: TFileStream;
  cur: TMemoryStream;
  fn: String;
begin
  fs := nil;
  fn := ChangeFileExt(OutputFN, '.gsc');
  cur := TMemoryStream.Create;
  fs := TFileStream.Create(fn, fmCreate or fmShareDenyWrite);
  try
    WriteLn('[SaveGSC] ', fn);

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
  tag: array[0 .. 31] of AnsiChar;
begin
{$ifdef ATARI_STE}
  tag := 'GSCa';
  AStream.Write(tag, 4);
  AStream.WriteByte(CStreamVersion);
  AStream.WriteByte(ChannelCount);
  AStream.WriteByte(ChunkSize);
  AStream.WriteByte(ChunksPerAttenuation);
  AStream.WriteWord(NtoBE(Word(SampleRate)));
  AStream.WriteWord(NtoBE(Word(ChunksPerFrame - 1)));

  // dummy stuff to fill 16 bytes :o)
  AStream.WriteWord(NtoBE(Word($611)));
  AStream.WriteWord(NtoBE(Word($611)));

  Assert(AStream.Position = 16);

  tag := ArtistTag;
  AStream.Write(tag, SizeOf(tag));

  tag := TitleTag;
  AStream.Write(tag, SizeOf(tag));
{$endif}

  for i := 0 to FrameCount - 1 do
    Frames[i].SaveStream(AStream);
end;

procedure TEncoder.PrepareFrames;
const
  CAttenuationMilliseconds = 2.0;
  CVFRTransitionFreq = 250.0;
var
  iChannel, iSample, iCPA, frmIdx, nextStart, psc, tentativeByteSize, offset, vfrDctSz: Integer;
  frm: TFrame;
  headerCost, chunksCost, indexingCost: Double;
  totalPower, perFramePower, curPower, smp, acc: Double;

  vfr, vfrSigmoid, vfrBuf, vfrDCT, vfrDCTLUT: TDoubleDynArray;
begin
  WriteLn('[PrepareFrames]');

  // pass 1

  SetLength(DCTLut, Sqr(ChunkSize));
  SetLength(InvDCTLut, Sqr(ChunkSize));
  ComputeDCTLut(ChunkSize, @DCTLut[0]);
  ComputeInvDCTLut(ChunkSize, @InvDCTLut[0]);

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

  Inc(ChunksPerFrame);
  repeat
    Dec(ChunksPerFrame);

    indexingCost :=
      (SampleCount * ChannelCount * (
        Log2(ChunksPerFrame) +
        1 {dstNegative} + 1 {dstReversed} +
        CMaxAttenuationBits / (ChunksPerAttenuation * ChannelCount)
      )) / (8 {bytes -> bits} * ChunkSize);

    chunksCost :=
      (ChunksPerFrame * ChunkSize) * ChunkBitDepth * FrameCount / 8;

{$ifdef ATARI_STE}
    headerCost := SizeOf(Word) + SizeOf(Byte) + 5 * 0.5 {estimated mean codingBlocksCount} * SizeOf(Byte);
{$else}
    headerCost :=
      4 * SizeOf(Word) + SizeOf(Cardinal) + SizeOf(Cardinal) +
      ChannelCount * SizeOf(Word) +
       SizeOf(Byte) + 9 {estimated mean codingBlocksCount} * SizeOf(Byte);
{$endif}

    tentativeByteSize := Round(headerCost + indexingCost + chunksCost);

  until (tentativeByteSize <= ProjectedByteSize) or (ChunksPerFrame <= CMinChunksPerFrame);

  ProjectedByteSize := tentativeByteSize;

  Assert(ChunksPerFrame > 0, 'Null ChunksPerFrame! (BitRate too low)');

  if Verbose then
  begin
    writeln('FrameSize = ', ProjectedByteSize div FrameCount);
    writeln('ProjectedByteSize = ', ProjectedByteSize);
  end;

  // pass 2

  vfrDctSz := min(Round((SampleRate * 0.5 / CVFRTransitionFreq) + 1), BlockSampleCount);

  SetLength(vfrDCTLUT, Sqr(BlockSampleCount));
  ComputeDCTLut(BlockSampleCount, @vfrDCTLUT[0]);

  SetLength(vfrSigmoid, BlockSampleCount);
  for iSample := 0 to BlockSampleCount - 1 do
    vfrSigmoid[iSample] := TanH((iSample - (BlockSampleCount - 1 - vfrDctSz)) * 2.0 * pi / BlockSampleCount) * 0.5 + 0.5;

  SetLength(vfrBuf, BlockSampleCount);
  SetLength(vfrDCT, BlockSampleCount);
  SetLength(vfr, SampleCount div BlockSampleCount);

  totalPower := 0;
  for iCPA := 0 to SampleCount div BlockSampleCount - 1 do
  begin
    offset := iCPA * BlockSampleCount;

    for iSample := 0 to BlockSampleCount - 1 do
    begin
      acc := 0.0;
      for iChannel := 0 to ChannelCount - 1 do
        acc += SrcData[iChannel, offset + iSample];
      vfrBuf[iSample] := acc / ChannelCount;
    end;

    ConvolveDCT(BlockSampleCount, @vfrBuf[0], @vfrDCT[0], @vfrDCTLUT[0]);

    acc := 0.0;
    smp := 0.0;
    for iSample := 0 to BlockSampleCount - 1 do
    begin
      acc += vfrSigmoid[iSample];
      smp += Sqr(vfrDCT[iSample]) * vfrSigmoid[iSample];
    end;
    smp := Sqrt(smp / acc);

    vfr[iCPA] := lerp(1.0, smp, VariableFrameSizeRatio);

    totalPower += vfr[iCPA];
  end;

  perFramePower := totalPower / FrameCount;

  if Verbose then
  begin
    writeln('TotalPower = ', Round(totalPower / High(SmallInt)));
    writeln('PerFramePower = ', Round(perFramePower / High(SmallInt)));
  end;

  frmIdx := 0;
  nextStart := 0;
  curPower := 0;
  SetLength(Frames, FrameCount);
  for iCPA := 0 to SampleCount div BlockSampleCount - 1 do
  begin
    offset := iCPA * BlockSampleCount;

    curPower += vfr[iCPA];

    if curPower >= perFramePower then
    begin
      if frmIdx >= Length(Frames) then
        SetLength(Frames, frmIdx + 1);

      frm := TFrame.Create(Self, frmIdx, nextStart, offset - 1);
      Frames[frmIdx] := frm;
      Inc(frmIdx);

      curPower := 0;
      nextStart := offset;
    end;
  end;

  if frmIdx >= Length(Frames) then
    SetLength(Frames, frmIdx + 1);

  frm := TFrame.Create(Self, frmIdx, nextStart, SampleCount - 1);
  Frames[frmIdx] := frm;
  Inc(frmIdx);

  SetLength(Frames, frmIdx);
  FrameCount := frmIdx;

  // set yakmo threading
  yakmo_set_num_threads(EnsureRange(NumberOfProcessors div FrameCount, 1, HalfNumberOfProcessors));

  WriteLn('SampleCount = ', SampleCount);
  writeln('ChannelCount = ', ChannelCount);
  writeln('SampleRate = ', SampleRate);
  writeln('FrameCount = ', FrameCount);
  writeln('ChunksPerFrame = ', ChunksPerFrame);
end;

procedure TEncoder.MakeFrames;
var
  framesDone: Integer;

  procedure DoFrame(Index: PtrInt; Data: Pointer);
  begin
    if NoSolveFilterSettings then
      Frames[Index].MakeFrame
    else
      Frames[Index].SolveCompandingFilterSettings;

    Write(InterLockedIncrement(framesDone):4, ' / ', FrameCount:4, #13);
  end;

begin
  WriteLn('[MakeFrames]');

  framesDone := 0;
  TMTPool.DoStandaloneLocalProc(@DoFrame, 0, FrameCount - 1, Min(NumberOfProcessors, FrameCount));
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
  ChunksPerAttenuation := 36;
  FrameLength := 500; // in ms
  VariableFrameSizeRatio := 1.0;
  NoSolveFilterSettings := False;
{$else}
  ChunkSize := 4;
  ChunksPerAttenuation := 16;
  FrameLength := 4000; // in ms
  VariableFrameSizeRatio := 1.0;
  ChunksPerFrame := 8192;
  NoSolveFilterSettings := True;
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

function TEncoder.CreateEmphasisFilter: TEmphasisFilter;
begin
{$ifdef ATARI_STE}
  Result := TLMC1992Filter.Create(SampleRate);
  // +4dB bass is the max the STe can take before staturating in a LMC1992 intermediate stage
  TLMC1992Filter(Result).Set_Tone_Level(TLMC1992Filter.NEUTRAL_TONE + 2, TLMC1992Filter.NEUTRAL_TONE - 3);
{$else}
  Result := TDeltaFilter.Create(SampleRate);
{$endif}
end;

class function TEncoder.make16BitSample(ASample: Double): SmallInt;
begin
  Result := EnsureRange(Round(ASample * High(SmallInt)), Low(SmallInt), High(SmallInt));
end;

class function TEncoder.makeFloatSample(ASample: SmallInt): Double;
begin
  Result := ASample / High(SmallInt);
end;

class function TEncoder.makeOutputSample(ASample: Double; AOutBitDepth, AAttenuation: Byte; ANegative: Boolean): TOutputSample;
var
  obd: Integer;
  smp, coeff: Double;
begin
  coeff := ComputeAttenuation(AAttenuation);

  obd := (1 shl (AOutBitDepth - 1)) - 1;
  smp := ASample * coeff * obd;
  Result.AsInt := EnsureRange(Round(smp), -obd, obd);
  Result.AsDouble := EnsureRange(smp, -obd, obd);
  if ANegative then
  begin
    Result.AsInt := -Result.AsInt;
    Result.AsDouble := -Result.AsDouble;
  end;
end;

class function TEncoder.makeFloatSample(ASample: Integer; AOutBitDepth, AAttenuation: Byte; ANegative: Boolean): Double;
var
  obd: Integer;
  coeff: Double;
begin
  coeff := ComputeAttenuation(-AAttenuation);

  obd := (1 shl (AOutBitDepth - 1)) - 1;
  if ANegative then ASample := -ASample;
  Result := ASample * coeff / obd;
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
const
  CLaw = Exp(CAttenuationLawDecibels / 20.0 * Ln(10.0));
  CInvLaw = Exp(-CAttenuationLawDecibels / 20.0 * Ln(10.0));
var
  iAtt: Integer;
begin
  Result := 1.0;
  if Attenuation > 0 then
  begin
    for iAtt := 1 to Attenuation do
      Result *= CLaw;
  end
  else if Attenuation < 0 then
  begin
    for iAtt := 1 to -Attenuation do
      Result *= CInvLaw;
  end
end;

class procedure TEncoder.ComputeDCTLut(chunkSz: Integer; lut: PDouble);
var
  k, n: Integer;
begin
  for k := 0 to chunkSz - 1 do
  begin
    for n := 0 to chunkSz - 1 do
    begin
      lut^ := cos(pi / chunkSz * (n + 0.5) * k) * sqrt (2.0 / chunkSz);
      Inc(lut);
    end;
  end;
end;

class procedure TEncoder.ComputeInvDCTLut(chunkSz: Integer; lut: PDouble);
var
  k, n: Integer;
begin
  for k := 0 to chunkSz - 1 do
  begin
    lut^ := 0.5 * sqrt(2.0 / chunkSz);
    Inc(lut);
    for n := 1 to chunkSz - 1 do
    begin
      lut^ := cos(pi / chunkSz * (k + 0.5) * n) * sqrt(2.0 / chunkSz);
      Inc(lut);
    end;
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

function TEncoder.ComputeEAQUAL(UseDIX, Verbz: Boolean): Double;
var
  i, j: Integer;
  FNTmp, FNRef, FNTst: String;
  ref, tst: TSmallIntDynArray;
begin
  FNTmp := GetTempFileName('', 'tmp-'+IntToStr(GetCurrentThreadId))+'.wav';
  FNRef := GetTempFileName('', 'ref-'+IntToStr(GetCurrentThreadId))+'.wav';
  FNTst := GetTempFileName('', 'tst-'+IntToStr(GetCurrentThreadId))+'.wav';

  SetLength(ref, SampleCount * ChannelCount);
  SetLength(tst, SampleCount * ChannelCount);

  for i := 0 to SampleCount - 1 do
    for j := 0 to ChannelCount - 1 do
    begin
      ref[i * ChannelCount + j] := SrcData[j, i];
      tst[i * ChannelCount + j] := DstData[j, i];
    end;

  createWAV(ChannelCount, 16, SampleRate, FNTmp, ref);
  DoExternalSOX(FNTmp, FNRef, IfThen(SampleRate <= 44100, 44100, 48000));

  createWAV(ChannelCount, 16, SampleRate, FNTmp, tst);
  DoExternalSOX(FNTmp, FNTst, IfThen(SampleRate <= 44100, 44100, 48000));

  Result := DoExternalEAQUAL(FNRef, FNTst, Verbz, UseDIX, -1);

  DeleteFile(FNTmp);
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

class procedure TEncoder.ConvolveDCT(chunkSz: Integer; input, output, lut: PDouble);
var
  k, n, p: Integer;
  acc: Double;
begin
  p := 0;
  for k := 0 to chunkSz - 1 do
  begin
    acc := 0.0;
    for n := 0 to chunkSz - 1 do
    begin
      acc += input[n] * lut[p];
      Inc(p);
    end;
    output[k] := acc;
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
  lut: array[0 .. Sqr(CLen) - 1] of Double;
  ilut: array[0 .. Sqr(CLen) - 1] of Double;
begin
  RandSeed := $42381337;

  TEncoder.ComputeDCTLut(CLen, @lut[0]);
  TEncoder.ComputeInvDCTLut(CLen, @ilut[0]);

  for iIter := 0 to CIter - 1 do
  begin
    for iDCT := 0 to CLen - 1 do
      test[iDCT] := Random * 2.0 - 1.0;
    TEncoder.ConvolveDCT(CLen, @test[0], @dct[0], @lut[0]);
    TEncoder.ConvolveDCT(CLen, @dct[0], @invdct[0], @ilut[0]);
    for iDCT := 0 to CLen - 1 do
      Assert(SameValue(test[iDCT], invdct[iDCT], 1e-6), 'test_dct_idct failed!');
  end;
end;

procedure test_osmp_fsmp;
const
  CLen = 100;
var
  iBit, iAtt, iSample: Integer;
  iNegative: Boolean;
  osmp, tsmp: SmallInt;
  fsmp: Double;
begin
  RandSeed := $42381337;

  for iBit := 2 to 12 do
    for iAtt := 0 to (1 shl CMaxAttenuationBits) - 1 do
      for iNegative := False to True do
        for iSample := 0 to CLen - 1 do
        begin
          osmp := Random((1 shl iBit) - 1) - (1 shl (iBit - 1)) + 1;
          fsmp := TEncoder.makeFloatSample(osmp, iBit, iAtt, iNegative);
          tsmp := TEncoder.makeOutputSample(fsmp, iBit, iAtt, iNegative).AsInt;
          Assert(tsmp = osmp, 'test_osmp_fsmp failed!');
        end;
end;

var
  enc: TEncoder;
  psyA: TEncoder.TPsyADelta;
  s: String;
begin
  try
    FormatSettings.DecimalSeparator := '.';

{$ifndef DEBUG}
    SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
{$endif}

    test_dct_idct;
    test_osmp_fsmp;

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
      Writeln(#9'-eaqual'#9'use EAQUAL to evaluate audio quality');
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
      enc.ChunkBitDepth := EnsureRange(round(ParamValue('-cbd', enc.ChunkBitDepth)), 2, 16);
      enc.AttenuationChunkRatioMul := EnsureRange(ParamValue('-att', enc.AttenuationChunkRatioMul), 0.1, 10.0);
{$endif}

      WriteLn('BitRate = ', FloatToStr(enc.BitRate));
      WriteLn('VariableFrameSizeRatio = ', FloatToStr(enc.VariableFrameSizeRatio));
      WriteLn('FrameLength = ', enc.FrameLength:0:3);
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

      if HasParam('-eaqual') then
        WriteLn('[EAQUAL] ODG:',enc.ComputeEAQUAL(False, False):7:3);

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
      if IsDebuggerPresent then
        ReadLn;
    end;
  end;
end.

