program encoder;

{$mode objfpc}{$H+}

uses windows, Classes, sysutils, strutils, Types, fgl, MTProcs, math, extern, ap, conv, correlation;

const
  CBandCount = 1;
  C1Freq = 32.703125;

  CStreamVersion = 1;
  CVariableCodingHeaderSize = 2;
  CVariableCodingBlockSize = 3;
  CMaxAttenuation = 15;
  CMaxChunksPerFrame = 4096;
  CAttenuationLawNumerator = 1;

type
  TEncoder = class;
  TFrame = class;
  TBand = class;
  TChunk = class;

  TBandGlobalData = record
    fcl, fch: Double;
    underSample: Integer;
    filteredData: TDoubleDynArray2;
    dstData: TSmallIntDynArray2;
  end;

  PBandGlobalData = ^TBandGlobalData;

  { TChunk }

  TChunkList = specialize TFPGObjectList<TChunk>;

  TChunk = class
  public
    frame: TFrame;
    reducedChunk: TChunk;

    channel, index, bandIndex, useCount: Integer;
    underSample: Integer;
    dstNegative: Boolean;
    dstReversed: Boolean;
    dstAttenuation: Integer;

    origSrcData: PDouble;
    srcData: TDoubleDynArray;
    dct: TDoubleDynArray;
    dstData: TSmallIntDynArray;

    constructor Create(frm: TFrame; idx, bandIdx: Integer; underSmp: Integer; srcDta: PDouble);
    destructor Destroy; override;

    procedure ComputeDCT;
    procedure ComputeDstAttributes;
    procedure MakeSrcData(origData: PDouble);
    procedure MakeDstData;
  end;

  { TBand }

  TBand = class
  public
    frame: TFrame;

    index: Integer;
    ChunkCount: Integer;

    srcData: array of PDouble;
    dstData: TDoubleDynArray2;

    finalChunks: TChunkList;

    globalData: PBandGlobalData;

    constructor Create(frm: TFrame; idx: Integer; startSample, endSample: Integer);
    destructor Destroy; override;

    procedure MakeChunks;
    procedure MakeDstData;
  end;

  { TFrame }

  TFrame = class
  private
    function GetAttenuationLaw: Double;
    function FindQuietest(Dataset: TFloatDynArray2): Integer;
    function InitFarthestFirst(Dataset: TFloatDynArray2; InitPoint: Integer): TFloatDynArray2;
    procedure KNNScanReduce(Dataset: TFloatDynArray2; var Centroids: TFloatDynArray2; var Clusters: TIntegerDynArray);
  public
    encoder: TEncoder;

    index: Integer;
    SampleCount: Integer;
    FrameSize: Integer;
    AttenuationDivider: Integer;

    chunkRefs, reducedChunks: TChunkList;

    bands: array[0..CBandCount - 1] of TBand;

    constructor Create(enc: TEncoder; idx, startSample, endSample: Integer);
    destructor Destroy; override;

    procedure FindAttenuationDivider;
    procedure MakeChunks;
    procedure Reduce;
    procedure KNNFit;
    procedure SaveStream(AStream: TStream);

    property AttenuationLaw: Double read GetAttenuationLaw;
  end;

  TFrameList = specialize TFPGObjectList<TFrame>;

  { TEncoder }

  TEncoder = class
  public
    inputFN, outputFN: String;

    BitRate: Integer;
    Precision: Integer;
    BandTransFactor: Double;
    LowCut: Double;
    HighCut: Double;
    ChunkBitDepth: Integer; // 8 or 12 Bits
    ChunkSize: Integer;
    ChunksPerFrame: Integer;
    ReduceBassBand: Boolean;
    VariableFrameSizeRatio: Double;
    TrebleBoost: Boolean;
    ChunkBlend: Integer;
    FrameLength: Double;
    PythonReduce: Boolean;
    DebugMode: Boolean;

    ChannelCount: Integer;
    SampleRate: Integer;
    SampleCount: Integer;
    BlockSampleCount: Integer;
    ProjectedByteSize, FrameCount: Integer;
    Verbose: Boolean;

    srcHeader: array[$00..$2b] of Byte;
    srcData: TSmallIntDynArray2;
    dstData: TSmallIntDynArray2;

    frames: TFrameList;

    bandData: array[0 .. CBandCount - 1] of TBandGlobalData;

    class function make16BitSample(smp: Double): SmallInt;
    class function makeOutputSample(smp: Double; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double
      ): SmallInt;
    class function makeFloatSample(smp: SmallInt): Double; overload;
    class function makeFloatSample(smp: SmallInt; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double
      ): Double; overload;
    class function ComputeAttenuation(chunkSz: Integer; const samples: TDoubleDynArray; Law: Double): Integer;
    class function ComputeDCT(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
    class function ComputeInvDCT(chunkSz: Integer; const dct: TDoubleDynArray): TDoubleDynArray;
    class function ComputeDCT4(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
    class function ComputeModifiedDCT(samplesSize: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
    class function ComputeInvModifiedDCT(dctSize: Integer; const dct: TDoubleDynArray): TDoubleDynArray;
    class function CompareEuclidean(const dctA, dctB: TANNFloatDynArray): TANNFloat; overload;
    class function CompareEuclidean(const dctA, dctB: TDoubleDynArray): Double; overload;
    class function CompareEuclidean(const dctA, dctB: TSmallIntDynArray): Double; overload;
    class function CheckJoinPenalty(x, y, z, a, b, c: Double; TestRange: Boolean): Boolean; inline;
    class function ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): Double;
    class procedure createWAV(channels: word; resolution: word; rate: longint; fn: string; const data: TSmallIntDynArray);

    constructor Create(InFN, OutFN: String);
    destructor Destroy; override;

    procedure Load;
    procedure SaveWAV;
    function SaveGSC: Double;
    procedure SaveStream(AStream: TStream);
    procedure SaveBandWAV(index: Integer; fn: String);

    procedure MakeBandGlobalData;
    procedure MakeBandSrcData(AIndex: Integer);

    procedure PrepareFrames;
    procedure MakeFrames;
    procedure MakeDstData;

    function DoFilterCoeffs(fc, transFactor: Double; HighPass, Windowed: Boolean): TDoubleDynArray;
    function DoFilter(const samples, coeffs: TDoubleDynArray): TDoubleDynArray;
    function DoBPFilter(fcl, fch, transFactor: Double; const samples: TDoubleDynArray): TDoubleDynArray;

    function ComputeEAQUAL(chunkSz: Integer; UseDIX, Verbz: Boolean; const smpRef, smpTst: TSmallIntDynArray): Double;
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

function lerp(x, y, alpha: Double): Double; inline;
begin
  Result := x + (y - x) * alpha;
end;

function ilerp(x, y, alpha, maxAlpha: Integer): Integer; inline;
begin
  Result := x + ((y - x) * alpha) div maxAlpha;
end;

function revlerp(x, y, alpha: Double): Double; inline;
begin
  Result := (alpha - x) / (y - x);
end;

function nan0(x: Double): Double; inline;
begin
  Result := 0;
  if not IsNan(x) then
    Result := x;
end;

function div0(x, y: Double): Double; inline;
begin
  Result := 0;
  if not IsZero(y) then
    Result := x / y;
end;

procedure DFT(frequencies, wave: PDouble; N: Integer);
var
  real, imag: Double;
  k, i: Integer;
begin
  real := 0;
  imag := 0;

  for k := 0 to N - 1 do
  begin
    for i := 0 to N - 1 do
    begin
      real += wave[i] * cos(-2 * PI * k * i / N);
      imag += wave[i] * sin(-2 * PI * k * i / N);
    end;

    frequencies[k] := real * real + imag * imag;
    real := 0;
    imag := 0;
  end;
end;

procedure iDFT(frequencies, wave: PDouble; N: Integer);
var
  real, imag: Double;
  k, i: Integer;
begin
  real := 0;
  imag := 0;

  for k := 0 to N - 1 do
  begin
    for i := 0 to N - 1 do
    begin
      real += wave[i] * cos(2 * PI * k * i / N);
      imag += wave[i] * sin(2 * PI * k * i / N);

    end;
    real /= N;
    imag /= N;
    frequencies[k] := sqrt(real * real + imag * imag);
    real := 0;
    imag := 0;
  end;
end;

// from https://github.com/ke2li/Arduino-Music-Tuner/blob/master/cepstrum/cepstrum.ino
procedure cepstrum(wave: PDouble; N: Integer);
var
  temp: TDoubleDynArray;
  i: Integer;
begin
  SetLength(temp, N);

  //step 1 of cepstrum
  DFT(@temp[0], wave, N);

  //step 2 of cepstrum
  for i := 0 to N - 1 do
    if not IsZero(temp[i]) then
      temp[i] := Log10(temp[i]);

  //step 3 of cepstrum
  iDFT(wave, @temp[0], N);
end;

{ TChunk }

constructor TChunk.Create(frm: TFrame; idx, bandIdx: Integer; underSmp: Integer; srcDta: PDouble);
begin
  index := idx;
  bandIndex := bandIdx;
  underSample := underSmp;
  frame := frm;
  reducedChunk := Self;
  channel := -1;

  SetLength(srcData, frame.encoder.chunkSize);

  if Assigned(srcDta) then
  begin
    origSrcData := @srcDta[idx * (frame.encoder.chunkSize - frame.encoder.ChunkBlend) * underSample];
    MakeSrcData(origSrcData);
  end;
end;

destructor TChunk.Destroy;
begin
  inherited Destroy;
end;

procedure TChunk.ComputeDCT;
var
  i: Integer;
  data: TDoubleDynArray;
begin
  SetLength(data, Length(srcData));
  for i := 0 to High(data) do
    data[i] := srcData[IfThen(dstReversed, High(data) - i, i)] * IfThen(dstNegative, -1, 1);
  dct := TEncoder.ComputeDCT(Length(data), data);

  SetLength(dct, Length(srcData) * 2);
  cepstrum(@data[0], Length(srcData));
  for i := 0 to High(srcData) do
    dct[i + Length(srcData)] := data[i] * 0.00001;
end;

procedure TChunk.ComputeDstAttributes;
var
  i: Integer;
  p1, p2: Double;
begin
  dstAttenuation := TEncoder.ComputeAttenuation(Length(srcData), srcData, frame.AttenuationLaw);

  // compute overall sign (up <-> down mirror)

  p1 := 0.0;
  for i := 0 to High(srcData) do
    if srcData[i] < 0 then
      p1 -= srcData[i];

  p2 := 0.0;
  for i := 0 to High(srcData) do
    if srcData[i] > 0 then
      p2 += srcData[i];

  dstNegative := p1 > p2;

  // compute overall reversed (left <-> right mirror)

  p1 := 0.0;
  for i := 0 to Length(srcData) div 2 - 1 do
    p1 += Abs(srcData[i]);

  p2 := 0.0;
  for i := Length(srcData) div 2 to High(srcData) do
    p2 += Abs(srcData[i]);

  dstReversed := p1 > p2;
end;

procedure TChunk.MakeSrcData(origData: PDouble);
var
  i, j, pos, n: Integer;
  f, acc: Double;
begin
  for i := 0 to High(srcData) do
  begin
    pos := i * underSample;

    acc := 0.0;
    n := 0;
    for j := 0 to underSample - 1 do
    begin
      if pos + j >= frame.SampleCount then
        Break;
      acc += origData[pos + j];
      Inc(n);
    end;

    if n = 0 then
      srcData[i] := 0
    else
      srcData[i] := acc / n;
  end;

  for i := 0 to frame.encoder.ChunkBlend - 1 do
  begin
    f := (i + 1) / (frame.encoder.ChunkBlend + 1);
    srcData[i] *= f;
    srcData[frame.encoder.ChunkSize - 1 - i] *= f;
  end;
end;

procedure TChunk.MakeDstData;
var
  i: Integer;
begin
  SetLength(dstData, length(srcData));
  for i := 0 to High(dstData) do
    dstData[i] := TEncoder.makeOutputSample(srcData[i], frame.encoder.ChunkBitDepth, dstAttenuation, dstNegative, frame.AttenuationLaw);
end;

{ TBand }

constructor TBand.Create(frm: TFrame; idx: Integer; startSample, endSample: Integer);
var
  i: Integer;
begin
  frame := frm;
  index := idx;
  globalData := @frame.encoder.bandData[index];

  SetLength(srcData, frame.encoder.ChannelCount);
  for i := 0 to High(srcData) do
    srcData[i] := @globalData^.filteredData[i, startSample];

  ChunkCount := (endSample - startSample + 1 - 1) div ((frame.encoder.ChunkSize - frame.encoder.ChunkBlend) * globalData^.underSample) + 1;

  finalChunks := TChunkList.Create;
end;

destructor TBand.Destroy;
begin
  finalChunks.Free;

  inherited Destroy;
end;

procedure TBand.MakeChunks;
var
  j, i: Integer;
  chunk: TChunk;
begin
  finalChunks.Clear;
  finalChunks.Capacity := ChunkCount * frame.encoder.ChannelCount;

  for i := 0 to ChunkCount - 1 do
    for j := 0 to frame.encoder.ChannelCount - 1 do
    begin
      chunk := TChunk.Create(frame, i, index, globalData^.underSample, srcData[j]);
      chunk.channel := j;
      chunk.ComputeDstAttributes;
      chunk.MakeDstData;
      chunk.ComputeDCT;
      finalChunks.Add(chunk);
    end;
end;

procedure TBand.MakeDstData;
var
  i, j, k: Integer;
  chunk: TChunk;
  smp: Double;
  pos: TIntegerDynArray;
begin
  //WriteLn('MakeDstData #', index);

  SetLength(pos, frame.encoder.ChannelCount);
  SetLength(dstData, frame.encoder.ChannelCount, frame.SampleCount);
  for i := 0 to frame.encoder.ChannelCount - 1 do
  begin
    FillQWord(dstData[i, 0], frame.SampleCount, 0);
    pos[i] := 0;
  end;

  for i := 0 to finalChunks.Count - 1 do
  begin
    chunk := finalChunks[i];

    for j := 0 to frame.encoder.chunkSize - 1 do
    begin
      smp := TEncoder.makeFloatSample(chunk.reducedChunk.dstData[IfThen(chunk.dstReversed, frame.encoder.chunkSize - 1 - j, j)], frame.encoder.ChunkBitDepth, chunk.reducedChunk.dstAttenuation, chunk.dstNegative, frame.AttenuationLaw);

      for k := 0 to globalData^.underSample - 1 do
      begin
        if InRange(pos[chunk.channel], 0, High(dstData[chunk.channel])) then
          dstData[chunk.channel, pos[chunk.channel]] += smp;
        Inc(pos[chunk.channel]);
      end;
    end;

    Dec(pos[chunk.channel], frame.encoder.ChunkBlend);
  end;
end;

constructor TFrame.Create(enc: TEncoder; idx, startSample, endSample: Integer);
var
  i: Integer;
begin
  encoder := enc;
  index := idx;
  SampleCount := endSample - startSample + 1;
  AttenuationDivider := 6;

  for i := 0 to CBandCount - 1 do
    bands[i] := TBand.Create(Self, i, startSample, endSample);

  if encoder.Verbose then
  begin
    Write('Frame #', index);
    for i := 0 to CBandCount - 1 do
      Write(#9, bands[i].ChunkCount);
    WriteLn;
  end;

  chunkRefs := TChunkList.Create(False);
  reducedChunks := TChunkList.Create;
end;

destructor TFrame.Destroy;
var
  i: Integer;
begin
  reducedChunks.Free;
  chunkRefs.Free;

  for i := 0 to CBandCount - 1 do
    bands[i].Free;

  inherited Destroy;
end;

function TFrame.GetAttenuationLaw: Double;
begin
  Result := CAttenuationLawNumerator / AttenuationDivider;
end;

procedure TFrame.FindAttenuationDivider;
var
  i, j, k, l, bestDiv, atten, pos: Integer;
  best, v, fs: Double;
  os: SmallInt;
  tmp: TDoubleDynArray;
begin
  SetLength(tmp, encoder.ChunkSize);
  bestDiv := 1;
  best := MaxSingle;
  for i := CAttenuationLawNumerator to CAttenuationLawNumerator * 64 do
  begin
    v := 0;
    for j := 0 to encoder.ChannelCount - 1 do
      for k := 0 to SampleCount div encoder.ChunkSize - 1 do
      begin
        pos := k * encoder.ChunkSize;

        for l := 0 to encoder.ChunkSize - 1 do
          tmp[l] := bands[0].srcData[j, pos + l];

        atten := TEncoder.ComputeAttenuation(encoder.ChunkSize, tmp, CAttenuationLawNumerator / i);

        for l := 0 to encoder.ChunkSize - 1 do
        begin
          os := TEncoder.makeOutputSample(tmp[l], encoder.ChunkBitDepth, atten, False, CAttenuationLawNumerator / i);
          fs := TEncoder.makeFloatSample(os, encoder.ChunkBitDepth, atten, False, CAttenuationLawNumerator / i);
          v += sqr(tmp[l] - fs);
        end;
      end;

    if v < best then
    begin
      best := v;
      bestDiv := i;
    end;
  end;

  AttenuationDivider := bestDiv;
end;

procedure TFrame.MakeChunks;
var
  i, j, k: Integer;
begin
  chunkRefs.Clear;
  for i := Ord(not encoder.ReduceBassBand) to CBandCount - 1 do
  begin
    bands[i].MakeChunks;
    for j := 0 to bands[i].finalChunks.Count - 1 do
      //for k := 1 to round(Power(bands[i].globalData^.underSample, sqrt(2.0))) do
        chunkRefs.Add(bands[i].finalChunks[j]);
  end;
end;

function TFrame.FindQuietest(Dataset: TFloatDynArray2): Integer;
var
  i, j: Integer;
  v, best: TFloat;
begin
  best := MaxSingle;
  Result := -1;
  for i := 0 to High(Dataset) do
  begin
    v := 0;
    for j := 0 to encoder.ChunkSize - 1 do
      v += Abs(Dataset[i, j]);
    if v < best then
    begin
      best := v;
      Result := i;
    end;
  end;
end;

function TFrame.InitFarthestFirst(Dataset: TFloatDynArray2; InitPoint: Integer): TFloatDynArray2;
var
  icentroid, ifarthest, i, colCount: Integer;
  max: TFloat;
  used: TBooleanDynArray;
  mindistance: TFloatDynArray;
  floatDummyDist: TFloat;
  dummyDist: Integer absolute floatDummyDist;

  procedure UpdateMinDistance(icenter: Integer); inline;
  var
    i: Integer;
    dis: TFloat;
  begin
    for i := 0 to high(Dataset) do
      if not used[i] then
      begin
        dis := TEncoder.CompareEuclidean(Dataset[icenter], Dataset[i]);
        if dis < mindistance[i] then
          mindistance[i] := dis;
      end;
  end;

begin
  colCount := Length(Dataset[0]);
  floatDummyDist := MaxSingle;
  SetLength(Result, encoder.ChunksPerFrame, colCount);
  SetLength(used, Length(Dataset));
  SetLength(mindistance, Length(Dataset));

  for icentroid := 0 to encoder.ChunksPerFrame - 1 do
    FillDWord(Result[icentroid, 0], colCount, dummyDist);
  FillChar(used[0], Length(Dataset), False);
  FillDWord(mindistance[0], Length(Dataset), dummyDist);

  icentroid := 0;
  ifarthest := InitPoint;
  Move(Dataset[ifarthest, 0], Result[icentroid, 0], colCount * SizeOf(TFloat));
  used[ifarthest] := True;
  UpdateMinDistance(ifarthest);

  for icentroid := 1 to encoder.ChunksPerFrame - 1 do
  begin
    max := 0;
    ifarthest := -1;
    for i := 0 to Length(Dataset) - 1 do
      if (MinDistance[i] >= max) and not Used[i] then
      begin
        max := MinDistance[i];
        ifarthest := i;
      end;

    Move(Dataset[ifarthest, 0], Result[icentroid, 0], colCount * SizeOf(TFloat));
    used[ifarthest] := True;
    UpdateMinDistance(ifarthest);
  end;
end;

procedure TFrame.KNNScanReduce(Dataset: TFloatDynArray2; var Centroids: TFloatDynArray2; var Clusters: TIntegerDynArray
  );
const
  CCntStart = 1;
  CMaxIterations = 100;
var
  i, j, k, iter, bestIdx, colCount, clusterCount: Integer;
  err, prevErr: Double;
  v, best, rate: TANNFloat;
  cnts: array[Boolean] of TIntegerDynArray;
  KDT: PANNkdtree;
begin
  colCount := Length(Dataset[0]);
  clusterCount := Length(Centroids);

  SetLength(cnts[False], clusterCount);
  SetLength(cnts[True], clusterCount);

  for j := 0 to clusterCount - 1 do
  begin
    cnts[False, j] := CCntStart;
    cnts[True, j] := CCntStart;
  end;

  iter := 0;
  err := MaxSingle;
  repeat
    prevErr := err;
    err := 0;

    KDT := ann_kdtree_create(@Centroids[0], clusterCount, colCount, 1, ANN_KD_STD);

    for i := 0 to chunkRefs.Count - 1 do
    begin
      bestIdx := ann_kdtree_search(KDT, @Dataset[i, 0], 0.0, @best);

      rate := 1 / sqrt(cnts[not Odd(iter), bestIdx]);
      for k := 0 to colCount - 1 do
      begin
        v := Dataset[i, k] - Centroids[bestIdx, k];
        Centroids[bestIdx, k] += v * rate;
      end;

      Clusters[i] := bestIdx;
      err += sqrt(best / colCount);
      cnts[Odd(iter), bestIdx] += 1;
    end;

    if encoder.Verbose then
    begin
{$if false}
      WriteLn(index:7, iter:7, err:10:3);
{$ifend}
    end;

    for j := 0 to clusterCount - 1 do
      cnts[not Odd(iter), j] := CCntStart;

    Inc(iter);

    ann_kdtree_destroy(KDT);

  until SameValue(err, prevErr, IntPower(10.0, -encoder.Precision)) or (iter >= CMaxIterations);

  if encoder.Verbose then
    WriteLn('Frame index: ', index:3, ' Iteration: ', iter:3, ' Residual error: ', err:10:3);
end;

type
  TCountIndex = class
    Index, Count: Integer;
    Value: Double;
  end;

  TCountIndexList = specialize TFPGObjectList<TCountIndex>;

function CompareCountIndexInv(const Item1, Item2: TCountIndex): Integer;
begin
  Result := CompareValue(Item2.Count, Item1.Count);
end;

function CompareChunkUseCountInv(const Item1, Item2: TChunk): Integer;
begin
  Result := CompareValue(Item2.useCount, Item1.useCount);
end;

procedure TFrame.Reduce;
var
  i, j, k, prec, colCount, clusterCount: Integer;
  chunk: TChunk;
  centroid: TDoubleDynArray;
  Clusters: TIntegerDynArray;
  Dataset: TFloatDynArray2;
  Centroids: TFloatDynArray2;
  Yakmo: PYakmo;
  CIList: TCountIndexList;
  CIInv: TIntegerDynArray;
begin
  prec := encoder.Precision;

  colCount := Length(chunkRefs[0].dct);
  clusterCount := encoder.ChunksPerFrame;

  SetLength(Dataset, chunkRefs.Count, colCount);

  for i := 0 to chunkRefs.Count - 1 do
    for j := 0 to colCount - 1 do
      Dataset[i, j] := chunkRefs[i].dct[j];

  if (prec > 0) and (chunkRefs.Count > clusterCount) then
  begin
    // usual chunk reduction

    if encoder.Verbose then
      WriteLn('Reduce Frame = ', index, ', N = ', chunkRefs.Count, ', K = ', clusterCount);

    SetLength(Clusters, chunkRefs.Count);
    SetLength(Centroids, clusterCount, colCount);
    SetLength(centroid, colCount);

    if not encoder.PythonReduce then
    begin
      if True then
      begin
        // using Yakmo KMeans++ init
        Yakmo := yakmo_create(clusterCount, 1, 0, 1, 0, 0, IfThen(encoder.Verbose, 1));
        yakmo_load_train_data(Yakmo, chunkRefs.Count, colCount, @Dataset[0]);
        yakmo_train_on_data(Yakmo, @Clusters[0]);
        yakmo_get_centroids(Yakmo, @Centroids[0]);
        yakmo_destroy(Yakmo);
      end
      else
      begin
        Centroids := InitFarthestFirst(Dataset, FindQuietest(Dataset));
      end;

      KNNScanReduce(Dataset, Centroids, Clusters);
    end
    else
    begin
      DoExternalSKLearn(Dataset, clusterCount, prec, False, encoder.Verbose, Clusters, Centroids);
      SetLength(Centroids, clusterCount, colCount);
    end;

    CIList := TCountIndexList.Create;
    try
      for i := 0 to clusterCount - 1 do
      begin
        CIList.Add(TCountIndex.Create);
        CIList[i].Index := i;

        for k := 0 to encoder.ChunkSize - 1 do
          centroid[k] := 0;

        for j := 0 to High(Clusters) do
          if Clusters[j] = i then
          begin
            for k := 0 to encoder.ChunkSize - 1 do
              centroid[k] += chunkRefs[j].srcData[IfThen(chunkRefs[j].dstReversed, encoder.ChunkSize - 1 - k, k)] * IfThen(chunkRefs[j].dstNegative, -1, 1);

            Inc(CIList[i].Count);
          end;

        for k := 0 to encoder.ChunkSize - 1 do
          Centroids[i, k] := div0(centroid[k], CIList[i].Count);
      end;
      CIList.Sort(@CompareCountIndexInv);
      SetLength(CIInv, clusterCount);

      reducedChunks.Clear;
      reducedChunks.Capacity := clusterCount;
      for i := 0 to clusterCount - 1 do
      begin
        chunk := TChunk.Create(Self, i, -1, 1, nil);
        reducedChunks.Add(chunk);

        for j := 0 to encoder.chunkSize - 1 do
          chunk.srcData[j] := nan0(Centroids[CIList[i].Index][j]);

        CIInv[CIList[i].Index] := i;

        chunk.ComputeDstAttributes;
        chunk.MakeDstData;
  	  end;

      for i := 0 to chunkRefs.Count - 1 do
        chunkRefs[i].reducedChunk := reducedChunks[CIInv[Clusters[i]]];

    finally
      CIList.Free;
    end;
  end
  else
  begin
    // passthrough mode

    reducedChunks.Clear;
    reducedChunks.Capacity := chunkRefs.Count;
    for i := 0 to reducedChunks.Capacity - 1 do
    begin
      chunk := TChunk.Create(Self, i, -1, 1, nil);

      reducedChunks.Add(chunk);

      chunk.srcData := Copy(chunkRefs[i].srcData);
      chunk.ComputeDstAttributes;
      chunk.MakeDstData;
    end;

    Centroids := Dataset;

    for i := 0 to chunkRefs.Count - 1 do
      chunkRefs[i].reducedChunk := reducedChunks[i];
  end;
end;

procedure TFrame.KNNFit;
const
  CBucketSize = 64;
var
  i, j: Integer;
  maxAttenuationLaw, epsilon: TANNFloat;
  bestIdx: Integer;
  Dataset: TANNFloatDynArray2;
  chunk: TANNFloatDynArray;
  KDT: PANNkdtree;
  idxs: array[0 .. CBucketSize - 1] of Integer;
  errs: array[0 .. CBucketSize - 1] of TANNFloat;
begin
  SetLength(Dataset, reducedChunks.Count * 2 {Negative} * 2 {Reversed}, encoder.chunkSize);
  SetLength(chunk, encoder.chunkSize);
  for i := 0 to reducedChunks.Count * 2 - 1 do
    for j := 0 to encoder.ChunkSize - 1 do
      Dataset[i * 2 + 0, j] := TEncoder.makeFloatSample(reducedChunks[i shr 1].dstData[j],
        encoder.ChunkBitDepth, reducedChunks[i shr 1].dstAttenuation, i and 1 <> 0, AttenuationLaw);

  for i := 0 to reducedChunks.Count * 2 - 1 do
    for j := 0 to encoder.ChunkSize - 1 do
      Dataset[i * 2 + 1, j] := TEncoder.makeFloatSample(reducedChunks[i shr 1].dstData[encoder.ChunkSize - 1 - j],
        encoder.ChunkBitDepth, reducedChunks[i shr 1].dstAttenuation, i and 1 <> 0, AttenuationLaw);

  maxAttenuationLaw := 1.0;
  for j := 0 to CMaxAttenuation do
    maxAttenuationLaw += j * AttenuationLaw;
  epsilon := max(1.0 / ((1 shl encoder.ChunkBitDepth) * maxAttenuationLaw), 1.0 / high(SmallInt));

  KDT := ann_kdtree_create(@Dataset[0], Length(Dataset), encoder.ChunkSize, 1, ANN_KD_STD);
  try
    for i := 0 to chunkRefs.Count - 1 do
    begin
      for j := 0 to encoder.ChunkSize - 1 do
        chunk[j] := chunkRefs[i].srcData[j];

      ann_kdtree_pri_search_multi(KDT, @idxs[0], @errs[0], CBucketSize, @chunk[0], 0.0);

      bestIdx := idxs[0];
      for j := 0 to CBucketSize - 1 do
        if InRange(idxs[j], 0, bestIdx - 1) and
            SameValue(sqrt(errs[0] / encoder.ChunkSize), sqrt(errs[j] / encoder.ChunkSize), epsilon) then
          bestIdx := idxs[j];

      chunkRefs[i].dstNegative := bestIdx and 2 <> 0;
      chunkRefs[i].dstReversed := bestIdx and 1 <> 0;
      chunkRefs[i].reducedChunk := reducedChunks[bestIdx shr 2];

      Inc(chunkRefs[i].reducedChunk.useCount);
    end;
  finally
    ann_kdtree_destroy(KDT);
  end;

  for i := reducedChunks.Count - 1 downto 0 do
    if reducedChunks[i].useCount = 0 then
       reducedChunks.Delete(i);

  reducedChunks.Sort(@CompareChunkUseCountInv);

  for i := 0 to reducedChunks.Count - 1 do
    reducedChunks[i].index := i;
end;

procedure TFrame.SaveStream(AStream: TStream);
var
  i, j, k, s1, s2, vcbsCnt, prevVcbsCnt, codeSize, bitCnt: Integer;
  code, w, bits: Cardinal;
  cl: TChunkList;
begin
  Assert(reducedChunks.Count <= CMaxChunksPerFrame);

  w := (encoder.ChannelCount shl 8) or CStreamVersion;
  AStream.WriteWord(w and $ffff);
  w := reducedChunks.Count or ((CBandCount - 1) shl 13);
  AStream.WriteWord(w and $ffff);
  w := (encoder.ChunkSize shl 8) or encoder.ChunkBitDepth;
  AStream.WriteWord(w and $ffff);
  w := (encoder.ChunkBlend shl 24) or encoder.SampleRate;
  AStream.WriteDWord(w and $ffffffff);
  w := AttenuationDivider;
  AStream.WriteWord(w and $ffff);

  cl := reducedChunks;
  if cl.Count = 0 then
    cl := chunkRefs;

  for j := 0 to cl.Count div 2 - 1 do
  begin
    s1 := cl[j * 2 + 0].dstAttenuation;
    s2 := cl[j * 2 + 1].dstAttenuation;
    AStream.WriteByte((s1 shl 4) or s2);
  end;

  if Odd(cl.Count) then
    AStream.WriteByte(cl[cl.Count - 1].dstAttenuation shl 4);


  case encoder.ChunkBitDepth of
    8:
      for j := 0 to cl.Count - 1 do
        for k := 0 to encoder.ChunkSize - 1 do
          AStream.WriteByte((cl[j].dstData[k] - Low(ShortInt)) and $ff);
    12:
      for j := 0 to cl.Count - 1 do
      begin
        for k := 0 to encoder.ChunkSize div 2 - 1 do
        begin
          s1 := cl[j].dstData[k * 2 + 0] + 2048;
          s2 := cl[j].dstData[k * 2 + 1] + 2048;

          AStream.WriteByte(((s1 shr 4) and $f0) or ((s2 shr 8) and $0f));
          AStream.WriteByte(s1 and $ff);
          AStream.WriteByte(s2 and $ff);
        end;

        if Odd(encoder.ChunkSize) then
        begin
          s1 := cl[j].dstData[encoder.ChunkSize - 1] + 2048;

          AStream.WriteByte((s1 shr 4) and $f0);
          AStream.WriteByte(s1 and $ff);
        end;
      end
    else
      Assert(False, 'ChunkBitDepth not supported');
  end;

  for i := 0 to CBandCount - 1 do
  begin
    cl := bands[i].finalChunks;

    AStream.WriteDWord(cl.Count div encoder.ChannelCount);

    bitCnt := 0;
    bits := 0;
    for j := 0 to cl.Count - 1 do
    begin
      vcbsCnt := IfThen(cl[j].reducedChunk.index = 0, 0, BsrWord(cl[j].reducedChunk.index) div CVariableCodingBlockSize);

      //writeln(cl[j].reducedChunk.index:5,vcbsCnt:3);

      prevVcbsCnt := -1;
      if j >= 1 then
        prevVcbsCnt := IfThen(cl[j - 1].reducedChunk.index = 0, 0, BsrWord(cl[j - 1].reducedChunk.index) div CVariableCodingBlockSize);

      code := 0;
      codeSize := 0;

      code := code or (Ord(cl[j].dstNegative) shl codeSize);
      codeSize += 1;

      code := code or (Ord(cl[j].dstReversed) shl codeSize);
      codeSize += 1;

      if vcbsCnt = prevVcbsCnt then
      begin
        code := code or (0 shl codeSize);
        codeSize += 1;
      end
      else
      begin
        code := code or (1 shl codeSize);
        codeSize += 1;
        code := code or (vcbsCnt shl codeSize);
        codeSize += CVariableCodingHeaderSize;
      end;

      for k := vcbsCnt downto 0 do
      begin
        code := code or (((cl[j].reducedChunk.index shr (k * CVariableCodingBlockSize)) and ((1 shl CVariableCodingBlockSize) - 1)) shl codeSize);
        codeSize += CVariableCodingBlockSize;
      end;

      bits := bits or (code shl bitCnt);
      bitCnt += codeSize;
      if bitCnt >= 16 then
      begin
        bitCnt -= 16;
        AStream.WriteWord(bits and $ffff);
        bits := bits shr 16;
      end;
    end;

    if bitCnt > 0 then
    begin
      Assert(bitCnt <= 16);
      AStream.WriteWord(bits and $ffff);
      bits := bits shr 16;
    end;
  end;
end;

{ TEncoder }

procedure TEncoder.Load;
var
  wavFN: String;
  fs: TFileStream;
  i, j: Integer;
  data: TSmallIntDynArray;
begin
  if LowerCase(ExtractFileExt(inputFN)) <> '.wav' then
  begin
    WriteLn('Convert ', inputFN);
    wavFN := GetTempFileName + '.wav';
    DoExternalSOX(inputFN, wavFN);
  end
  else
  begin
    wavFN := inputFN;
  end;

  WriteLn('Load ', wavFN);

  fs := TFileStream.Create(wavFN, fmOpenRead or fmShareDenyNone);
  try
    fs.ReadBuffer(srcHeader[0], SizeOf(srcHeader));
    SampleRate := PInteger(@srcHeader[$18])^;
    ChannelCount := PWORD(@srcHeader[$16])^;

    SampleCount := (fs.Size - fs.Position) div (SizeOf(SmallInt) * ChannelCount);
    SetLength(srcData, ChannelCount, SampleCount);

    SetLength(data, SampleCount * ChannelCount);
    fs.ReadBuffer(data[0], SampleCount * ChannelCount * 2);

    for i := 0 to SampleCount - 1 do
      for j := 0 to ChannelCount - 1 do
        srcData[j, i] := data[i * ChannelCount + j];
  finally
    fs.Free;

    if wavFN <> inputFN then
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
  wavFN := ChangeFileExt(outputFN, '.wav');

  WriteLn('Save ', wavFN);

  fs := TFileStream.Create(wavFN, fmCreate or fmShareDenyWrite);
  try
    fs.WriteBuffer(srcHeader[0], SizeOf(srcHeader));

    SetLength(data, SampleCount * ChannelCount);

    for i := 0 to SampleCount - 1 do
      for j := 0 to ChannelCount - 1 do
        data[i * ChannelCount + j] := dstData[j, i];

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
begin
  fs := nil;
  fn := ChangeFileExt(outputFN, '.gsc');
  cur := TMemoryStream.Create;
  fs := TFileStream.Create(fn, fmCreate or fmShareDenyWrite);
  try
    WriteLn('Save ', fn);

    SaveStream(cur);
    cur.Position := 0;

    fs.CopyFrom(cur, cur.Size);

    Result := cur.size * (8 / 1024) / (SampleCount / SampleRate); // returns bitrate

    writeln('FinalByteSize = ', cur.Size);
    writeln('FinalBitRate = ', round(Result));
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
    frames[i].SaveStream(AStream);
end;

procedure TEncoder.SaveBandWAV(index: Integer; fn: String);
var
  i, j: Integer;
  fs: TFileStream;
  data: TSmallIntDynArray;
begin
  //WriteLn('SaveBandWAV #', index, ' ', fn);

  fs := TFileStream.Create(fn, fmCreate or fmShareDenyWrite);
  try
    fs.WriteBuffer(srcHeader[0], SizeOf(srcHeader));

    SetLength(data, SampleCount * ChannelCount);

    for i := 0 to SampleCount - 1 do
      for j := 0 to ChannelCount - 1 do
        data[i * ChannelCount + j] := bandData[index].dstData[j, i];

    fs.WriteBuffer(data[0], SampleCount * ChannelCount * 2);
  finally
    fs.Free;
  end;
end;

procedure TEncoder.MakeBandGlobalData;
var
  i: Integer;
  ratio, hc: Double;
  bnd: TBandGlobalData;
begin
  for i := 0 to CBandCount - 1 do
  begin
    bnd.dstData := nil;
    FillChar(bnd, SizeOf(bnd), 0);

    // determing low and high bandpass frequencies

    hc := min(HighCut, SampleRate / 2);
    ratio := (log2(hc) - log2(max(C1Freq, LowCut))) / CBandCount;

    if i = 0 then
      bnd.fcl := LowCut / SampleRate
    else
      bnd.fcl := 0.5 * power(2.0, -floor((CBandCount - i) * ratio));

    if i = CBandCount - 1 then
      bnd.fch := hc / SampleRate
    else
      bnd.fch := 0.5 * power(2.0, -floor((CBandCount - 1 - i) * ratio));

    // undersample if the band high freq is a lot lower than nyquist

    bnd.underSample := Max(1, round(0.25 / bnd.fch));

    bandData[i] := bnd;
  end;
end;

procedure TEncoder.MakeBandSrcData(AIndex: Integer);
var
  i, j: Integer;
  bnd: TBandGlobalData;
begin
  bnd := bandData[AIndex];

  SetLength(bnd.filteredData, ChannelCount, SampleCount);
  for i := 0 to ChannelCount - 1 do
    for j := 0 to SampleCount - 1 do
      bnd.filteredData[i, j] := makeFloatSample(srcData[i, j]);

  // band pass the samples
  for i := 0 to ChannelCount - 1 do
    bnd.filteredData[i] := DoBPFilter(bnd.fcl, bnd.fch, BandTransFactor, bnd.filteredData[i]);

  bandData[AIndex] := bnd;
end;

procedure TEncoder.PrepareFrames;

  procedure DoBand(AIndex: PtrInt; AData: Pointer; AItem: TMultiThreadProcItem);
  begin
    MakeBandSrcData(AIndex);
  end;

const
  CVariableCodingRatio = 0.8;
var
  j, i, k, nextStart, psc, tentativeByteSize: Integer;
  frm: TFrame;
  fixedCost, frameCost, bandCost, avgPower, totalPower, perFramePower, curPower, smp: Double;
begin
  MakeBandGlobalData;

  // pass 1

  BlockSampleCount := 0;
  for i := 0 to CBandCount - 1 do
    if bandData[i].underSample * (ChunkSize - ChunkBlend) > BlockSampleCount then
      BlockSampleCount := bandData[i].underSample * (ChunkSize - ChunkBlend);

  // ensure srcData ends on a full block
  psc := SampleCount;
  SampleCount := ((SampleCount - 1) div BlockSampleCount + 1) * BlockSampleCount;
  SetLength(srcData, ChannelCount, SampleCount);
  for j := 0 to ChannelCount - 1 do
    for i := psc to SampleCount - 1 do
      srcData[j, i] := 0;

  if BitRate > 0 then
    ProjectedByteSize := ceil((SampleCount / SampleRate) * (BitRate * 1024 / 8))
  else
    ProjectedByteSize := MaxInt;

  if Verbose then
  begin
    writeln('ProjectedByteSize = ', ProjectedByteSize);
  end;

  FrameCount := ceil(SampleCount / (SampleRate * (FrameLength / 1000)));

  Inc(ChunksPerFrame);
  repeat
    Dec(ChunksPerFrame);

    fixedCost := 0 {no header besides frame};

    bandCost := 0;
    for i := 0 to CBandCount - 1 do
      bandCost += (SampleCount * ChannelCount * (Log2(ChunksPerFrame) + (1 + CVariableCodingHeaderSize) + 1 {dstNegative} + 1 {dstReversed})) / (8 {bytes -> bits} * (ChunkSize - ChunkBlend) * bandData[i].underSample);

    frameCost := (ChunksPerFrame * ChunkSize) * ChunkBitDepth / 8 + ChunksPerFrame * 4 / 8 + (4 * SizeOf(Word) + SizeOf(Cardinal) + CBandCount * SizeOf(Cardinal)) {frame header};

    tentativeByteSize := Round(fixedCost + bandCost * CVariableCodingRatio + FrameCount * frameCost);

  until (tentativeByteSize <= ProjectedByteSize) or (ChunksPerFrame <= 1);

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

  ProcThreadPool.DoParallelLocalProc(@DoBand, 0, CBandCount - 1, nil);

  // pass 2

  avgPower := 0.0;
  for j := 0 to ChannelCount - 1 do
    for i := 0 to SampleCount - 1 do
      avgPower += Sqr(makeFloatSample(srcData[j, i]));
  avgPower := Sqrt(avgPower / (SampleCount * ChannelCount));

  totalPower := 0.0;
  for i := 0 to SampleCount - 1 do
  begin
    smp := 0.0;
    for j := 0 to ChannelCount - 1 do
      smp += Sqr(makeFloatSample(srcData[j, i]));
    smp := Sqrt(smp / ChannelCount);

    totalPower += 1.0 - lerp(avgPower, smp, VariableFrameSizeRatio);
  end;

  perFramePower := totalPower / FrameCount;

  if Verbose then
  begin
    writeln('TotalPower = ', FormatFloat('0.00', totalPower));
    writeln('PerFramePower = ', FormatFloat('0.00', perFramePower));
  end;

  k := 0;
  nextStart := 0;
  curPower := 0.0;
  for i := 0 to SampleCount - 1 do
  begin
    smp := 0.0;
    for j := 0 to ChannelCount - 1 do
      smp += Sqr(makeFloatSample(srcData[j, i]));
    smp := Sqrt(smp / ChannelCount);

    curPower += 1.0 - lerp(avgPower, smp, VariableFrameSizeRatio);

    if (i mod BlockSampleCount = 0) and (curPower >= perFramePower) then
    begin
      frm := TFrame.Create(Self, k, nextStart, i - 1);
      frames.Add(frm);

      curPower := 0.0;
      nextStart := i;
      Inc(k);
    end;
  end;

  frm := TFrame.Create(Self, k, nextStart, SampleCount - 1);
  frames.Add(frm);

  FrameCount := frames.Count;

  for i := 0 to CBandCount - 1 do
     WriteLn('Band #', i, ' (', round(bandData[i].fcl * SampleRate), ' Hz .. ', round(bandData[i].fch * SampleRate), ' Hz); ', bandData[i].underSample);
end;

procedure TEncoder.MakeFrames;

  procedure DoFrame(AIndex: PtrInt; AData: Pointer; AItem: TMultiThreadProcItem);
  var
    i: Integer;
    frm: TFrame;
  begin
    frm := frames[AIndex];

    frm.FindAttenuationDivider;
    frm.MakeChunks;
    frm.Reduce;
    frm.KNNFit;
    for i := 0 to CBandCount - 1 do
      frm.bands[i].MakeDstData;
    Write('.');
  end;
begin
  ProcThreadPool.DoParallelLocalProc(@DoFrame, 0, FrameCount - 1, nil);
  WriteLn;
end;

function TEncoder.DoFilter(const samples, coeffs: TDoubleDynArray): TDoubleDynArray;
var
  i: Integer;
begin
  Result := nil;
  ConvR1D(samples, Length(samples), coeffs, Length(coeffs), Result);

  for i := 0 to High(samples) do
    Result[i] := Result[i + High(coeffs) div 2];

  SetLength(Result, Length(samples));
end;

function TEncoder.DoBPFilter(fcl, fch, transFactor: Double; const samples: TDoubleDynArray
  ): TDoubleDynArray;
var
  coeffs: TDoubleDynArray;
begin
  Result := samples;

  if fcl > 0.0 then
  begin
    coeffs := DoFilterCoeffs(fcl, transFactor * fcl, True, True);
    Result := DoFilter(Result, coeffs);
  end;

  if fch < 0.5 then
  begin
    coeffs := DoFilterCoeffs(fch, transFactor * fch, False, True);
    Result := DoFilter(Result, coeffs);
  end;
end;

constructor TEncoder.Create(InFN, OutFN: String);
begin
  inputFN := InFN;
  outputFN := OutFN;

  BitRate := -1;
  Precision := 1;
  LowCut := 0.0;
  HighCut := 24000.0;
  ChunkBitDepth := 8;
  ChunkSize := 4;
  ReduceBassBand := True;
  TrebleBoost := False;
  VariableFrameSizeRatio := 1.0;
  ChunkBlend := 0;
  FrameLength := 4000; // in ms
  PythonReduce := False;
  Precision := 3;

  ChunksPerFrame := CMaxChunksPerFrame;
  BandTransFactor := 1 / 256;

  frames := TFrameList.Create;
end;

destructor TEncoder.Destroy;
begin
  frames.Free;

  inherited Destroy;
end;

procedure TEncoder.MakeDstData;
var
  i, j, k, l, pos: Integer;
  smp: Double;
  bnd: TBandGlobalData;
  resamp: array[0 .. CBandCount - 1] of TDoubleDynArray;
  floatDst: TDoubleDynArray;
begin
  WriteLn('MakeDstData');

  SetLength(dstData, ChannelCount, SampleCount);
  for l := 0 to ChannelCount - 1 do
    FillWord(dstData[l, 0], Length(dstData), 0);

  SetLength(floatDst, SampleCount);

  for i := 0 to CBandCount - 1 do
  begin
    bnd := bandData[i];

    SetLength(bnd.dstData, ChannelCount, SampleCount);
    for l := 0 to ChannelCount - 1 do
      FillWord(bnd.dstData[l, 0], SampleCount, 0);

    bandData[i] := bnd;
  end;

  for l := 0 to ChannelCount - 1 do
  begin
    FillQWord(floatDst[0], Length(floatDst), 0);

    pos := 0;
    for k := 0 to frames.Count - 1 do
    begin
      for j := 0 to CBandCount - 1 do
      begin
        bnd := bandData[j];
{$if true}
        resamp[j] := frames[k].bands[j].dstData[l];
{$else}
        resamp[j] := DoBPFilter(bnd.fcl, bnd.fch, BandTransFactor, frames[k].bands[j].dstData[l]);
{$endif}
      end;

      for i := 0 to frames[k].SampleCount - 1 do
      begin
        for j := 0 to CBandCount - 1 do
        begin
          smp := resamp[j][i];

          if InRange(pos, 0, High(dstData[l])) then
          begin
            bandData[j].dstData[l, pos] := make16BitSample(smp);
            floatDst[pos] := floatDst[pos] + smp;
          end;
        end;

        Inc(pos);
      end;
    end;

    for i := 0 to High(floatDst) do
      dstData[l, i] := make16BitSample(floatDst[i]);
  end;
end;

function TEncoder.DoFilterCoeffs(fc, transFactor: Double; HighPass, Windowed: Boolean): TDoubleDynArray;
var
  sinc, win, sum: Double;
  i, N: Integer;
begin
  N := ceil(4.6 / transFactor);
  if (N mod 2) = 0 then N += 1;

  //writeln('DoFilterCoeffs ', ifthen(HighPass, 'HP', 'LP'), ' ', FloatToStr(SampleRate * fc), ' ', N);

  SetLength(Result, N);
  sum := 0;
  for i := 0 to N - 1 do
  begin
    sinc := 2.0 * fc * (i - (N - 1) / 2.0) * pi;
    if sinc = 0 then
      sinc := 1.0
    else
      sinc := sin(sinc) / sinc;

    win := 1.0;
    if Windowed then
    begin
{$if true}
      // blackman window
      win := 7938/18608 - 9240/18608 * cos(2 * pi * i / (N - 1)) + 1430/18608 * cos(4 * pi * i / (N - 1));
{$else}
      // sinc window
      win := (2 * i / (N - 1) - 1) * pi;
      if win = 0 then
        win := 1.0
      else
        win := sin(win) / win;
{$endif}
    end;

    Result[i] := sinc * win;
    sum += Result[i];
  end;

  if HighPass then
  begin
    for i := 0 to N - 1 do
      Result[i] := -Result[i] / sum;

    Result[(N - 1) div 2] += 1.0;
  end
  else
  begin
    for i := 0 to N - 1 do
      Result[i] := Result[i] / sum;
  end;
end;

class function TEncoder.make16BitSample(smp: Double): SmallInt;
begin
  Result := EnsureRange(round(smp * High(SmallInt)), Low(SmallInt), High(SmallInt));
end;

class function TEncoder.makeFloatSample(smp: SmallInt): Double;
begin
  Result := smp / High(SmallInt);
end;

class function TEncoder.makeOutputSample(smp: Double; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double): SmallInt;
var
  i, obd: Integer;
  smp16: SmallInt;
  coeff: Double;
begin
  coeff := 1.0;
  for i := 0 to Attenuation do
    coeff += i * Law;

  obd := (1 shl (OutBitDepth - 1)) - 1;
  smp16 := round(smp * obd * coeff);
  if Negative then smp16 := -smp16;
  smp16 := EnsureRange(smp16, -obd + 1, obd - 1);
  Result := smp16;
end;

class function TEncoder.makeFloatSample(smp: SmallInt; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double): Double;
var
  i: Integer;
  smp16: SmallInt;
  obd, coeff: Double;
begin
  coeff := 1.0;
  for i := 0 to Attenuation do
    coeff += i * Law;

  obd := (1 shl (OutBitDepth - 1)) - 1;
  smp16 := smp;
  if Negative then smp16 := -smp16;
  Result := smp16 / (obd * coeff);
  Result := EnsureRange(Result, -1.0, 1.0);
end;

class function TEncoder.ComputeAttenuation(chunkSz: Integer; const samples: TDoubleDynArray; Law: Double): Integer;
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
    coeff += Result * Law;
  until (hiSmp * coeff > High(SmallInt)) or (Result > CMaxAttenuation);
  Dec(Result);
end;

class function TEncoder.ComputeDCT(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
var
  k, n: Integer;
  sum, s: Double;
begin
  SetLength(Result, length(samples));
  for k := 0 to chunkSz - 1 do
  begin
    s := ifthen(k = 0, sqrt(0.5), 1.0);

    sum := 0;
    for n := 0 to chunkSz - 1 do
      sum += s * samples[n] * cos(pi / chunkSz * (n + 0.5) * k);

    Result[k] := sum * sqrt (2.0 / chunkSz);
  end;
end;

class function TEncoder.ComputeInvDCT(chunkSz: Integer; const dct: TDoubleDynArray): TDoubleDynArray;
var
  k, n: Integer;
  sum: Double;
begin
  SetLength(Result, length(dct));
  for k := 0 to chunkSz - 1 do
  begin
    sum := sqrt(0.5) * dct[0];
    for n := 1 to chunkSz - 1 do
      sum += dct[n] * cos (pi / chunkSz * (k + 0.5) * n);

    Result[k] := sum * sqrt (2.0 / chunkSz);
  end;
end;

class function TEncoder.ComputeDCT4(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
var
  k, n: Integer;
  sum: Double;
begin
  SetLength(Result, length(samples));
  for k := 0 to chunkSz - 1 do
  begin
    sum := 0;
    for n := 0 to chunkSz - 1 do
      sum += samples[n] * cos(pi / chunkSz * (n + 0.5) * (k + 0.5));

    Result[k] := sum * sqrt (2.0 / chunkSz);
  end;
end;

// MDCT cannot be used (would need overlapped add in decoder)
class function TEncoder.ComputeModifiedDCT(samplesSize: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
var
  k, n: Integer;
  sum: Double;
begin
  SetLength(Result, length(samples) div 2);
  for k := 0 to samplesSize div 2 - 1 do
  begin
    sum := 0;
    for n := 0 to samplesSize - 1 do
      sum += samples[n] * cos(pi / (samplesSize div 2) * (n + 0.5 + (samplesSize div 2) * 0.5) * (k + 0.5));

    Result[k] := sum;
  end;
end;

// IMDCT cannot be used (would need overlapped add in decoder)
class function TEncoder.ComputeInvModifiedDCT(dctSize: Integer; const dct: TDoubleDynArray): TDoubleDynArray;
var
  k, n, i: Integer;
  sum: Double;
begin
  SetLength(Result, length(dct));
  for n := 0 to dctSize - 1 do
  begin
    sum := 0;
    for k := 0 to dctSize div 2 - 1 do
      sum += dct[k] * cos (pi / (dctSize div 2) * (n + 0.5 + (dctSize div 2) * 0.5) * (k + 0.5));

    Result[n] := sum / (dctSize div 2);
  end;

  for i := 0 to dctSize div 2 - 1 do
  begin
    Result[i] += Result[i + dctSize div 2];
    Result[i + dctSize div 2] := 0.0;
  end;
end;

class function TEncoder.CompareEuclidean(const dctA, dctB: TANNFloatDynArray): TANNFloat;
var
  i: Integer;
begin
  Assert(Length(dctA) = Length(dctB));
  Result := 0.0;

  for i := 0 to High(dctA) do
    Result += sqr(dctA[i] - dctB[i]);

  Result := sqrt(Result / Length(dctA));
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

class function TEncoder.CompareEuclidean(const dctA, dctB: TSmallIntDynArray): Double;
var
  i: Integer;
begin
  Assert(Length(dctA) = Length(dctB));
  Result := 0.0;

  for i := 0 to High(dctA) do
    Result += sqr((dctA[i] - dctB[i]) / High(SmallInt));

  Result := sqrt(Result / Length(dctA));
end;

class function TEncoder.CheckJoinPenalty(x, y, z, a, b, c: Double; TestRange: Boolean): Boolean;
var
  dStart, dEnd: Double;
begin
  dStart := -1.5 * x + 2.0 * y - 0.5 * z;
  dEnd := -1.5 * a + 2.0 * b - 0.5 * c;

  Result := Sign(dStart) * Sign(dEnd) <> -1;
  if TestRange and Result then
    Result := InRange(y, a, c) or InRange(y, c, a);
end;

function TEncoder.ComputeEAQUAL(chunkSz: Integer; UseDIX, Verbz: Boolean; const smpRef, smpTst: TSmallIntDynArray): Double;
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

class function TEncoder.ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): Double;
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
      rr[j * Length(smpRef[0]) + i] := smpRef[j, i];
      rt[j * Length(smpRef[0]) + i] := smpTst[j, i];
    end;

  Result := CompareEuclidean(rr, rt);
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


procedure test_makeSample;
var
  i: Integer;
  smp, o, so: SmallInt;
  obd, bs: SmallInt;
  sgn: Boolean;
  f, sf: Double;
begin
  for i := 0 to 65535 do
  begin
    bs := RandomRange(0, 7);
    sgn := Random >= 0.5;
    obd := 12;//RandomRange(1, 8);

    smp := (i mod (1 shl obd)) - (1 shl (obd - 1));
    sf := smp / (1 shl (obd - 1)) / (1 * (1 + bs)) * IfThen(sgn, -1, 1);

    f := TEncoder.makeFloatSample(smp, obd, bs, sgn, 1 / 6);
    o := TEncoder.makeOutputSample(f, obd, bs, sgn, 1 / 6);
    so := TEncoder.makeOutputSample(sf, obd, bs, sgn, 1 / 6);
    writeln(smp,#9,o,#9,so,#9,bs,#9,sgn,#9,FloatToStr(f));
    assert(smp = o);
    assert(smp = so);
  end;

  halt;
end;

var
  enc: TEncoder;
  i: Integer;
  br, psy: double;
  s: String;
begin
  try
    FormatSettings.DecimalSeparator := '.';

{$ifdef DEBUG}
    //ProcThreadPool.MaxThreadCount := 1;
{$else}
    SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
{$endif}

    //test_makeSample;


    if ParamCount < 2 then
    begin
      WriteLn('Usage: ', ExtractFileName(ParamStr(0)) + ' <source file> <dest file> [options]');
      Writeln('Main options:');
      WriteLn(#9'-br'#9'encoder bit rate in kilobits/second; example: "-br250"');
      WriteLn(#9'-lc'#9'bass cutoff frequency');
      WriteLn(#9'-hc'#9'treble cutoff frequency');
      WriteLn(#9'-vfr'#9'RMS power based variable frame size ratio (0.0-1.0); default: "-vfr1.0"');
      WriteLn(#9'-fl'#9'(Average) frame length in milliseconds; default: "-fl4000"');
      WriteLn(#9'-v'#9'verbose mode');
      Writeln('Development options:');
      WriteLn(#9'-d'#9'debug mode (outputs decoded WAVs)');
      WriteLn(#9'-cs'#9'chunk size');
      WriteLn(#9'-cpf'#9'max. chunks per frame (256-4096)');
      WriteLn(#9'-pbb'#9'disable lossy compression on bass band');
      WriteLn(#9'-cbd'#9'chunk bit depth (8,12)');
      WriteLn(#9'-pr'#9'K-means precision; 0: "lossless" mode');
      WriteLn(#9'-cb'#9'chunk blend');
      WriteLn(#9'-py'#9'python cluster.py reducer');

      WriteLn;
      Writeln('(source file must be 16bit WAV or anything SOX can convert)');
      WriteLn;
      Exit;
    end;

    enc := TEncoder.Create(ParamStr(1), ParamStr(2));
    try
      enc.BitRate := round(ParamValue('-br', enc.BitRate));
      enc.Precision := round(ParamValue('-pr', enc.Precision));
      enc.LowCut := ParamValue('-lc', enc.LowCut);
      enc.HighCut := ParamValue('-hc', enc.HighCut);
      enc.VariableFrameSizeRatio :=  EnsureRange(ParamValue('-vfr', enc.VariableFrameSizeRatio), 0.0, 1.0);
      enc.FrameLength := Max(ParamValue('-fl', enc.FrameLength), 1.0);
      enc.ChunkBitDepth := EnsureRange(round(ParamValue('-cbd', enc.ChunkBitDepth)), 1, 16);
      enc.ChunkSize := round(ParamValue('-cs', enc.ChunkSize));
      enc.ChunksPerFrame := EnsureRange(round(ParamValue('-cpf', enc.ChunksPerFrame)), 256, CMaxChunksPerFrame);
      enc.Verbose := HasParam('-v');
      enc.ReduceBassBand := not HasParam('-pbb');
      enc.ChunkBlend := EnsureRange(round(ParamValue('-cb', enc.ChunkBlend)), 0, enc.ChunkSize div 2);
      enc.PythonReduce := HasParam('-py');
      enc.DebugMode := HasParam('-d');

      WriteLn('BitRate = ', FloatToStr(enc.BitRate));
      WriteLn('LowCut = ', FloatToStr(enc.LowCut));
      WriteLn('HighCut = ', FloatToStr(enc.HighCut));
      WriteLn('VariableFrameSizeRatio = ', FloatToStr(enc.VariableFrameSizeRatio));
      WriteLn('FrameLength = ', enc.FrameLength:0:0);
      if enc.Verbose then
      begin
        WriteLn('ChunkSize = ', enc.ChunkSize);
        WriteLn('MaxChunksPerFrame = ', enc.ChunksPerFrame);
        WriteLn('ReduceBassBand = ', BoolToStr(enc.ReduceBassBand, True));
        WriteLn('ChunkBitDepth = ', enc.ChunkBitDepth);
        WriteLn('Precision = ', enc.Precision);
        WriteLn('ChunkBlend = ', enc.ChunkBlend);
      end;
      WriteLn;

      enc.Load;

      enc.PrepareFrames;
      enc.MakeFrames;
      enc.MakeDstData;

      br := 0;
      if enc.Precision > 0 then
        br := enc.SaveGSC;

      psy := enc.ComputePsyADelta(enc.srcData, enc.dstData);
      WriteLn('PsyADelta = ', FormatFloat(',0.0000000000', psy));

      if enc.DebugMode then
      begin
        enc.SaveWAV;
        if CBandCount > 1 then
          for i := 0 to CBandCount - 1 do
            enc.SaveBandWAV(i, ChangeFileExt(enc.outputFN, '-' + IntToStr(i) + '.wav'));

        s := IntToStr(round(br)) + ' ' + FormatFloat(',0.00000', psy) + ' ';
        for i := 0 to ParamCount do s := s + ParamStr(i) + ' ';
        ShellExecute(0, 'open', 'cmd.exe', PChar('/c echo ' + s + ' >> ..\log.txt'), '', 0);
      end;

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

