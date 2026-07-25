program encoder;

{$mode objfpc}{$H+}

uses
  windows, Classes, sysutils, strutils, Types, fgl, math,
  extern, ap, conv, correlation, orthogonal_kmeans, mtpool;

const
  CStreamVersion = 2;
  CVariableCodingHeaderSize = 2;
  CVariableCodingBlockSize = 3;
  CMaxAttenuation = 15;
  CMaxChunksPerFrame = 4096;
  CAttenuationLawNumerator = 1;

type
  TEncoder = class;
  TFrame = class;
  TChunk = class;

  { TChunk }

  TChunkList = specialize TFPGObjectList<TChunk>;

  TChunk = class
  public
    frame: TFrame;
    reducedChunk: TChunk;

    channel, index, bandIndex, useCount: Integer;
    dstNegative: Boolean;
    dstReversed: Boolean;
    dstAttenuation: Integer;

    srcData: TDoubleDynArray;
    dstData: TSmallIntDynArray;

    constructor Create(frm: TFrame; idx, bandIdx: Integer; srcDta: PDouble);

    function ComputeDCT: TDoubleDynArray;
    procedure ComputeDstAttributes;
    procedure MakeDstData;
  end;

  { TFrame }

  TFrame = class
  private
    function GetAttenuationLaw: Double;
    function FindQuietest(Dataset: TDoubleDynArray2): Integer;
  public
    encoder: TEncoder;

    index: Integer;
    ChunkCount: Integer;
    StartSample: Integer;
    SampleCount: Integer;
    FrameSize: Integer;
    Gain: Integer;

    chunkRefs, reducedChunks, finalChunks: TChunkList;

    srcFirstSample: TDoubleDynArray;

    srcData: TDoubleDynArray2;
    dstData: TDoubleDynArray2;

    constructor Create(enc: TEncoder; idx, startSmp, endSmp: Integer);
    destructor Destroy; override;

    procedure FindGain;
    procedure MakeChunks;
    procedure Reduce;
    procedure KNNFit;
    procedure SaveStream(AStream: TStream);
    procedure MakeDstData;

    property AttenuationLaw: Double read GetAttenuationLaw;
  end;

  TFrameList = specialize TFPGObjectList<TFrame>;

  { TEncoder }

  TEncoder = class
  type
    TOutputSample = record
      AsInteger: Integer;
      AsDouble: Double;
    end;
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
    VariableFrameSizeRatio: Double;
    TrebleBoost: Boolean;
    ChunkBlend: Integer;
    FrameLength: Double;
    PythonReduce: Boolean;
    DebugMode: Boolean;
    ThreadsPerFrame: Cardinal;

    ChannelCount: Integer;
    SampleRate: Integer;
    SampleCount: Integer;
    BlockSampleCount: Integer;
    ProjectedByteSize, FrameCount: Integer;
    Verbose: Boolean;

    srcHeader: array[$00..$2b] of Byte;
    srcData: TSmallIntDynArray2;
    filteredData: TDoubleDynArray2;
    dstData: TSmallIntDynArray2;

    frames: TFrameList;

    class function simpleRound(smp: Double): Integer;
    class function make16BitSample(smp: Double): SmallInt;
    class function makeOutputSample(smp: Double; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double): TOutputSample;
    class function makeFloatSample(smp: SmallInt): Double;
    class function makeFloatSample(smp: SmallInt; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double): Double;
    class function ComputeAttenuation(chunkSz: Integer; const samples: TDoubleDynArray; Law: Double): Integer;
    class function ComputeDCT(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
    class function ComputeInvDCT(chunkSz: Integer; const dct: TDoubleDynArray): TDoubleDynArray;
    class function ComputeDCT4(chunkSz: Integer; const samples: TDoubleDynArray): TDoubleDynArray;
    class function CompareEuclidean(const dctA, dctB: TANNFloatDynArray): TANNFloat; overload;
    class function CompareEuclidean(const dctA, dctB: TDoubleDynArray): Double; overload;
    class function CompareEuclidean(const dctA, dctB: TSmallIntDynArray): Double; overload;
    class function ComputePsyADelta(const smpRef, smpTst: TSmallIntDynArray2): Double;
    class procedure createWAV(channels: word; resolution: word; rate: longint; fn: string; const data: TSmallIntDynArray);

    constructor Create(InFN, OutFN: String);
    destructor Destroy; override;

    procedure Load;
    procedure SaveWAV;
    function SaveGSC: Double;
    procedure SaveStream(AStream: TStream);

    procedure MakeFilteredData;

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

{ TChunk }

constructor TChunk.Create(frm: TFrame; idx, bandIdx: Integer; srcDta: PDouble);
begin
  index := idx;
  bandIndex := bandIdx;
  frame := frm;
  reducedChunk := Self;
  channel := -1;

  SetLength(srcData, frame.encoder.ChunkSize);
  if Assigned(srcDta) then
    Move(srcDta[idx * (frame.encoder.ChunkSize - frame.encoder.ChunkBlend)], srcData[0], frame.encoder.ChunkSize * SizeOf(Double));
end;

function TChunk.ComputeDCT: TDoubleDynArray;
var
  iSample: Integer;
  data: TDoubleDynArray;
begin
  SetLength(data, Length(srcData));
  for iSample := 0 to High(data) do
    data[iSample] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, High(data) - iSample, iSample)], 2, 0, dstNegative, frame.AttenuationLaw).AsDouble;
  Result := TEncoder.ComputeDCT(Length(data), data);
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
  for i := Length(srcData) - Length(srcData) div 2 to High(srcData) do
    p2 += Abs(srcData[i]);

  dstReversed := p1 > p2;
end;

procedure TChunk.MakeDstData;
var
  i: Integer;
begin
  SetLength(dstData, length(srcData));
  for i := 0 to High(dstData) do
    dstData[i] := TEncoder.makeOutputSample(srcData[IfThen(dstReversed, High(dstData) - i, i)], frame.encoder.ChunkBitDepth, dstAttenuation, dstNegative, frame.AttenuationLaw).AsInteger;
end;

constructor TFrame.Create(enc: TEncoder; idx, startSmp, endSmp: Integer);
var
  iChannel, iSample: Integer;
  prevSmp, smp: Double;
begin
  encoder := enc;
  index := idx;
  StartSample := startSmp;
  SampleCount := endSmp - startSmp + 1;
  Gain := 6;

  chunkRefs := TChunkList.Create(False);
  reducedChunks := TChunkList.Create;
  finalChunks := TChunkList.Create;

  SetLength(srcFirstSample, encoder.ChannelCount);
  SetLength(srcData, encoder.ChannelCount, endSmp - startSmp + 1);
  for iChannel := 0 to High(srcData) do
  begin
    srcFirstSample[iChannel] := encoder.filteredData[iChannel, startSmp + 0];

    prevSmp := srcFirstSample[iChannel];
    for iSample := 0 to endSmp - startSmp + 1 - 1 do
    begin
      smp := encoder.filteredData[iChannel, startSmp + iSample];
      srcData[iChannel, iSample] := smp - prevSmp;
      prevSmp := smp;
    end;
  end;

  ChunkCount := (endSmp - startSmp + 1 - 1) div (encoder.ChunkSize - encoder.ChunkBlend) + 1;

  if encoder.Verbose then
    WriteLn('Frame #', index, #9, ChunkCount);
end;

destructor TFrame.Destroy;
begin
  chunkRefs.Free;
  reducedChunks.Free;
  finalChunks.Free;

  inherited Destroy;
end;

function TFrame.GetAttenuationLaw: Double;
begin
  Result := CAttenuationLawNumerator / Gain;
end;

procedure TFrame.FindGain;
var
  iGain, iChannel, iChunk, iSample, bestMul, atten, pos: Integer;
  best, v, fs, law: Double;
  os: SmallInt;
  tmp: TDoubleDynArray;
begin
  SetLength(tmp, encoder.ChunkSize);
  bestMul := 1;
  best := MaxSingle;
  for iGain := CAttenuationLawNumerator to CAttenuationLawNumerator * 64 do
  begin
    law := CAttenuationLawNumerator / iGain;

    v := 0;
    for iChannel := 0 to encoder.ChannelCount - 1 do
      for iChunk := 0 to SampleCount div encoder.ChunkSize - 1 do
      begin
        pos := iChunk * encoder.ChunkSize;

        for iSample := 0 to encoder.ChunkSize - 1 do
          tmp[iSample] := srcData[iChannel, pos + iSample];

        atten := TEncoder.ComputeAttenuation(encoder.ChunkSize, tmp, law);

        for iSample := 0 to encoder.ChunkSize - 1 do
        begin
          os := TEncoder.makeOutputSample(tmp[iSample], encoder.ChunkBitDepth, atten, False, law).AsInteger;
          fs := TEncoder.makeFloatSample(os, encoder.ChunkBitDepth, atten, False, law);
          v += sqr(tmp[iSample] - fs);
        end;
      end;

    if v < best then
    begin
      best := v;
      bestMul := iGain;
    end;
  end;

  Gain := bestMul;
end;

procedure TFrame.MakeChunks;
var
  iChannel, iChunk: Integer;
  chunk: TChunk;
begin
  finalChunks.Clear;
  finalChunks.Capacity := ChunkCount * encoder.ChannelCount;

  for iChunk := 0 to ChunkCount - 1 do
    for iChannel := 0 to encoder.ChannelCount - 1 do
    begin
      chunk := TChunk.Create(Self, iChunk, index, @srcData[iChannel, 0]);
      chunk.channel := iChannel;
      chunk.ComputeDstAttributes;
      chunk.MakeDstData;
      chunk.ComputeDCT;
      finalChunks.Add(chunk);
      chunkRefs.Add(chunk);
    end;
end;

function TFrame.FindQuietest(Dataset: TDoubleDynArray2): Integer;
var
  i, j: Integer;
  v, best: Double;
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
  i, j, iSample, prec, colCount, clusterCount: Integer;
  chunk: TChunk;
  centroid: TDoubleDynArray;
  Clusters: TIntegerDynArray;
  Dataset: TKFloatArray2;
  Centroids: TKFloatArray2;
  Yakmo: TOrthogonalKmeans;
  CIList: TCountIndexList;
  CIInv: TIntegerDynArray;
begin
  prec := encoder.Precision;

  colCount := encoder.ChunkSize;
  clusterCount := encoder.ChunksPerFrame;

  SetLength(Dataset, chunkRefs.Count);

  for i := 0 to chunkRefs.Count - 1 do
    Dataset[i] := chunkRefs[i].ComputeDCT;

  if (prec > 0) and (chunkRefs.Count > clusterCount) then
  begin
    // usual chunk reduction

    if encoder.Verbose then
      WriteLn('Reduce Frame = ', index, ', Gain = ', Gain, ', N = ', chunkRefs.Count, ', K = ', clusterCount);

    SetLength(Clusters, chunkRefs.Count);
    SetLength(Centroids, clusterCount, colCount);
    SetLength(centroid, colCount);

    if not encoder.PythonReduce then
    begin
      if clusterCount > 1 then
      begin
        Yakmo := TOrthogonalKmeans.Create(clusterCount, -1, kiKMeansPP, encoder.ThreadsPerFrame, False);
        try
          Yakmo.load_train_data(chunkRefs.Count, colCount, PPKFloat(@Dataset[0]));
          Yakmo.train_on_data(@Clusters[0]);
          Yakmo.get_centroids(PPKFloat(@Centroids[0]));
        finally
          Yakmo.Free;
        end;
      end;
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

        for iSample := 0 to encoder.ChunkSize - 1 do
          centroid[iSample] := 0;

        for j := 0 to High(Clusters) do
          if Clusters[j] = i then
          begin
            chunk := chunkRefs[j];

            for iSample := 0 to encoder.ChunkSize - 1 do
              centroid[iSample] += TEncoder.makeOutputSample(chunk.srcData[IfThen(chunk.dstReversed, High(centroid) - iSample, iSample)], 2, 0, chunk.dstNegative, AttenuationLaw).AsDouble;

            Inc(CIList[i].Count);
          end;

        for iSample := 0 to encoder.ChunkSize - 1 do
          Centroids[i, iSample] := DivDef(centroid[iSample], CIList[i].Count, 0.0);
      end;
      CIList.Sort(@CompareCountIndexInv);
      SetLength(CIInv, clusterCount);

      reducedChunks.Clear;
      reducedChunks.Capacity := clusterCount;
      for i := 0 to clusterCount - 1 do
      begin
        chunk := TChunk.Create(Self, i, -1, nil);
        reducedChunks.Add(chunk);

        for iSample := 0 to encoder.chunkSize - 1 do
          chunk.srcData[iSample] := Centroids[CIList[i].Index, iSample];

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
      chunk := TChunk.Create(Self, i, -1, nil);

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
var
  iChunk, iSample, iSampleCribble, iChannel, dsIdx, bestIdx, iteration: Integer;
  err: TANNFloat;
  corr, curTruthAcc, curLossyAcc, bestErr, skew: Double;
  truthAcc, lossyAcc: TDoubleDynArray;
  DCTDataset, PlainDataset: TANNFloatDynArray2;
  query: TANNFloatDynArray;
  KDT: PANNkdtree;
  chunk: TChunk;
begin
  SetLength(PlainDataset, reducedChunks.Count * 2 {Negative} * 2 {Reversed}, encoder.chunkSize);
  SetLength(DCTDataset, reducedChunks.Count * 2 {Negative} * 2 {Reversed});
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
      PlainDataset[dsIdx + 0, iSample] := TEncoder.makeFloatSample(chunk.dstData[iSample], encoder.ChunkBitDepth, chunk.dstAttenuation, False, AttenuationLaw);
      PlainDataset[dsIdx + 1, iSample] := TEncoder.makeFloatSample(chunk.dstData[iSample], encoder.ChunkBitDepth, chunk.dstAttenuation, True, AttenuationLaw);
      PlainDataset[dsIdx + 2, iSample] := TEncoder.makeFloatSample(chunk.dstData[encoder.ChunkSize - 1 - iSample], encoder.ChunkBitDepth, chunk.dstAttenuation, False, AttenuationLaw);
      PlainDataset[dsIdx + 3, iSample] := TEncoder.makeFloatSample(chunk.dstData[encoder.ChunkSize - 1 - iSample], encoder.ChunkBitDepth, chunk.dstAttenuation, True, AttenuationLaw);
    end;

    DCTDataset[dsIdx + 0] := TEncoder.ComputeDCT(encoder.ChunkSize, PlainDataset[dsIdx + 0]);
    DCTDataset[dsIdx + 1] := TEncoder.ComputeDCT(encoder.ChunkSize, PlainDataset[dsIdx + 1]);
    DCTDataset[dsIdx + 2] := TEncoder.ComputeDCT(encoder.ChunkSize, PlainDataset[dsIdx + 2]);
    DCTDataset[dsIdx + 3] := TEncoder.ComputeDCT(encoder.ChunkSize, PlainDataset[dsIdx + 3]);
    Inc(dsIdx, 4);
  end;

  KDT := ann_kdtree_create(PPANNFloat(@DCTDataset[0]), Length(DCTDataset), encoder.ChunkSize, 1, ANN_KD_STD);
  try
    for iChunk := 0 to chunkRefs.Count - 1 do
    begin
      chunk := chunkRefs[iChunk];

      corr := 1.0;
      curTruthAcc := truthAcc[chunk.channel];
      curLossyAcc := lossyAcc[chunk.channel];

      iteration := 0;
      repeat

        bestIdx := -1;
        bestErr := Infinity;
        for iSampleCribble := 0 to encoder.ChunkSize - 1 do
        begin
          // cumulate
          for iSample := 0 to encoder.ChunkSize - 1 do
          begin
            query[iSample] := chunk.srcData[iSample];

            if iSample = 0 then
              query[iSample] += curTruthAcc
            else
              query[iSample] += query[iSample - 1];

            // also apply skew removal
            if iSample = iSampleCribble then
              query[iSampleCribble] -= curLossyAcc - curTruthAcc;
          end;

          // clamp
          for iSample := 0 to encoder.ChunkSize - 1 do
            query[iSample] := EnsureRange(query[iSample], -corr, corr);

          // decumulate
          for iSample := encoder.ChunkSize - 1 downto 1 do
            query[iSample] -= query[iSample - 1];
          query[0] -= curTruthAcc;

          // DCT
          query := TEncoder.ComputeDCT(encoder.ChunkSize, query);

          // query
          dsIdx := ann_kdtree_search(KDT, @query[0], 0.0, @err);

          if err < bestErr then
          begin
            bestIdx := dsIdx;
            bestErr := err;
          end;
        end;

        chunk.dstNegative := bestIdx and 1 <> 0;
        chunk.dstReversed := bestIdx and 2 <> 0;
        chunk.reducedChunk := reducedChunks[bestIdx shr 2];

        skew := (iteration shr 1) / (1 shl encoder.ChunkBitDepth) * (1.0 - 2.0 * (iteration and 1));
        corr := 1.0;
        curTruthAcc := truthAcc[chunk.channel];
        curLossyAcc := lossyAcc[chunk.channel];
        for iSample := 0 to encoder.ChunkSize - 1 do
        begin
          curTruthAcc += chunk.srcData[iSample];
          curLossyAcc += PlainDataset[bestIdx, iSample];

          if Abs(curLossyAcc) >= 1.0 then
            corr := min(corr, 2.0 - Abs(curLossyAcc) - skew);
        end;

        //if iteration >= 0 then
        //  WriteLn(index:8,iChunk:8,bestIdx:8,iteration:8,corrLo:12:6,corrHi:12:6);

        Inc(iteration);

      until corr = 1.0;

      Inc(chunk.reducedChunk.useCount);

      truthAcc[chunk.channel] := curTruthAcc;
      lossyAcc[chunk.channel] := curLossyAcc;
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
  iChunk, iSample, iChannel, s1, s2, vcbsCnt, prevVcbsCnt, codeSize, bitCnt: Integer;
  code, w, bits: UInt64;
  cl: TChunkList;
begin
  Assert(reducedChunks.Count <= CMaxChunksPerFrame);

  w := (encoder.ChannelCount shl 8) or CStreamVersion;
  AStream.WriteWord(w and $ffff);
  w := reducedChunks.Count;
  AStream.WriteWord(w and $ffff);
  w := (encoder.ChunkSize shl 8) or encoder.ChunkBitDepth;
  AStream.WriteWord(w and $ffff);
  w := (encoder.ChunkBlend shl 24) or encoder.SampleRate;
  AStream.WriteDWord(w and $ffffffff);
  w := Gain;
  AStream.WriteWord(w and $ffff);

  cl := reducedChunks;

  for iChunk := 0 to cl.Count div 2 - 1 do
  begin
    s1 := cl[iChunk * 2 + 0].dstAttenuation;
    s2 := cl[iChunk * 2 + 1].dstAttenuation;
    AStream.WriteByte((s1 shl 4) or s2);
  end;

  if Odd(cl.Count) then
    AStream.WriteByte(cl[cl.Count - 1].dstAttenuation shl 4);


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

  cl := finalChunks;

  AStream.WriteDWord(cl.Count div encoder.ChannelCount);

  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    w := TEncoder.make16BitSample(srcFirstSample[iChannel]);
    AStream.WriteWord(w and $ffff);
  end;

  bitCnt := 0;
  bits := 0;
  for iChunk := 0 to cl.Count - 1 do
  begin
    vcbsCnt := IfThen(cl[iChunk].reducedChunk.index = 0, 0, BsrWord(cl[iChunk].reducedChunk.index) div CVariableCodingBlockSize);

    //writeln(cl[iChunk].reducedChunk.index:5,vcbsCnt:3);

    prevVcbsCnt := -1;
    if iChunk >= 1 then
      prevVcbsCnt := IfThen(cl[iChunk - 1].reducedChunk.index = 0, 0, BsrWord(cl[iChunk - 1].reducedChunk.index) div CVariableCodingBlockSize);

    code := 0;
    codeSize := 0;

    code := code or (Ord(cl[iChunk].dstNegative) shl codeSize);
    codeSize += 1;

    code := code or (Ord(cl[iChunk].dstReversed) shl codeSize);
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

    for iSample := vcbsCnt downto 0 do
    begin
      code := code or (((cl[iChunk].reducedChunk.index shr (iSample * CVariableCodingBlockSize)) and ((1 shl CVariableCodingBlockSize) - 1)) shl codeSize);
      codeSize += CVariableCodingBlockSize;
    end;

    bits := bits or (code shl bitCnt);
    bitCnt += codeSize;
    while bitCnt >= 16 do
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

procedure TFrame.MakeDstData;
var
  iChannel, iChunk, iSample: Integer;
  chunk: TChunk;
  delta: Double;
  pos: TIntegerDynArray;
  smp: TDoubleDynArray;
begin
  //WriteLn('MakeDstData #', index);

  SetLength(pos, encoder.ChannelCount);
  SetLength(smp, encoder.ChannelCount);
  SetLength(dstData, encoder.ChannelCount, SampleCount);
  for iChannel := 0 to encoder.ChannelCount - 1 do
  begin
    FillQWord(dstData[iChannel, 0], SampleCount, 0);
    pos[iChannel] := 0;
    smp[iChannel] := srcFirstSample[iChannel];
  end;

  for iChunk := 0 to finalChunks.Count - 1 do
  begin
    chunk := finalChunks[iChunk];

    for iSample := 0 to encoder.ChunkSize - 1 do
    begin
      delta := TEncoder.makeFloatSample(chunk.reducedChunk.dstData[IfThen(chunk.dstReversed, encoder.ChunkSize - 1 - iSample, iSample)], encoder.ChunkBitDepth, chunk.reducedChunk.dstAttenuation, chunk.dstNegative, AttenuationLaw);
      smp[chunk.channel] += delta;

      if InRange(pos[chunk.channel], 0, High(dstData[chunk.channel])) then
        dstData[chunk.channel, pos[chunk.channel]] += smp[chunk.channel];
      Inc(pos[chunk.channel]);
    end;

    Dec(pos[chunk.channel], encoder.ChunkBlend);
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

procedure TEncoder.MakeFilteredData;
var
  i, j: Integer;
begin
  SetLength(filteredData, ChannelCount, SampleCount);
  for i := 0 to ChannelCount - 1 do
    for j := 0 to SampleCount - 1 do
      filteredData[i, j] := makeFloatSample(srcData[i, j]);

  // band pass the samples
  for i := 0 to ChannelCount - 1 do
    filteredData[i] := DoBPFilter(LowCut / SampleRate, HighCut / SampleRate, BandTransFactor, filteredData[i]);
end;

procedure TEncoder.PrepareFrames;
const
  CVariableCodingRatio = 0.71;
var
  j, i, k, nextStart, psc, tentativeByteSize: Integer;
  frm: TFrame;
  fixedCost, chunksCost, indexingCost: Double;
  avgPower, totalPower, perFramePower, curPower, smp: Int64;
begin
  // pass 1

  BlockSampleCount := ChunkSize - ChunkBlend;

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

    indexingCost := (SampleCount * ChannelCount * (Log2(ChunksPerFrame) + (1 + CVariableCodingHeaderSize) + 1 {dstNegative} + 1 {dstReversed})) / (8 {bytes -> bits} * (ChunkSize - ChunkBlend));

    chunksCost := (ChunksPerFrame * ChunkSize) * ChunkBitDepth / 8 + ChunksPerFrame * 4 / 8 + (4 * SizeOf(Word) + SizeOf(Cardinal) + SizeOf(Cardinal)) {frame header};

    tentativeByteSize := Round(fixedCost + indexingCost * CVariableCodingRatio + FrameCount * chunksCost);

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

  MakeFilteredData;

  // pass 2

  avgPower := 0;
  for j := 0 to ChannelCount - 1 do
    for i := 0 to SampleCount - 1 do
      avgPower += Abs(srcData[j, i]);
  avgPower := avgPower div (SampleCount * ChannelCount);

  totalPower := 0;
  for i := 0 to SampleCount - 1 do
  begin
    smp := 0;
    for j := 0 to ChannelCount - 1 do
      smp += Sqr(Abs(srcData[j, i]) - avgPower);
    smp := Round(Sqrt(smp / ChannelCount));

    totalPower += Round(lerp(avgPower, smp, VariableFrameSizeRatio));
  end;

  perFramePower := totalPower div FrameCount;

  if Verbose then
  begin
    writeln('TotalPower = ', Round(totalPower / High(SmallInt)));
    writeln('PerFramePower = ', Round(perFramePower / High(SmallInt)));
  end;

  k := 0;
  nextStart := 0;
  curPower := 0;
  for i := 0 to SampleCount - 1 do
  begin
    smp := 0;
    for j := 0 to ChannelCount - 1 do
      smp += Sqr(Abs(srcData[j, i]) - avgPower);
    smp := Round(Sqrt(smp / ChannelCount));

    curPower += Round(lerp(avgPower, smp, VariableFrameSizeRatio));

    if (i mod BlockSampleCount = 0) and (curPower >= perFramePower) then
    begin
      frm := TFrame.Create(Self, k, nextStart, i - 1);
      frames.Add(frm);

      curPower := 0;
      nextStart := i;
      Inc(k);
    end;
  end;

  frm := TFrame.Create(Self, k, nextStart, SampleCount - 1);
  frames.Add(frm);

  FrameCount := frames.Count;

  ThreadsPerFrame := max(1, ThreadsPerFrame div FrameCount);
end;

procedure TEncoder.MakeFrames;

  procedure DoFrame(Index: PtrInt; Data: Pointer);
  var
    frm: TFrame;
  begin
    frm := frames[Index];

    frm.FindGain;
    frm.MakeChunks;
    frm.Reduce;
    frm.KNNFit;
    frm.MakeDstData;
    Write('.');
  end;

begin
  TMTPool.DoStandaloneLocalProc(@DoFrame, 0, FrameCount - 1, NumberOfProcessors);
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
  HighCut := 18000.0;
  ChunkBitDepth := 8;
  ChunkSize := 4;
  TrebleBoost := False;
  VariableFrameSizeRatio := 1.0;
  ChunkBlend := 0;
  FrameLength := 4000; // in ms
  PythonReduce := False;
  Precision := 3;
  ThreadsPerFrame := NumberOfProcessors;

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
  iSample, iFrame, iChannel, pos: Integer;
begin
  WriteLn('MakeDstData');

  SetLength(dstData, ChannelCount, SampleCount);

  for iChannel := 0 to ChannelCount - 1 do
  begin
    pos := 0;
    for iFrame := 0 to frames.Count - 1 do
      for iSample := 0 to frames[iFrame].SampleCount - 1 do
      begin
        dstData[iChannel, pos] := make16BitSample(frames[iFrame].dstData[iChannel, iSample]);
        Inc(pos);
      end;
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

class function TEncoder.simpleRound(smp: Double): Integer;
begin
  Result := Trunc(smp + 0.5);
end;

class function TEncoder.make16BitSample(smp: Double): SmallInt;
begin
  Result := EnsureRange(simpleRound(smp * High(SmallInt)), Low(SmallInt), High(SmallInt));
end;

class function TEncoder.makeFloatSample(smp: SmallInt): Double;
begin
  Result := smp / High(SmallInt);
end;

class function TEncoder.makeOutputSample(smp: Double; OutBitDepth, Attenuation: Integer; Negative: Boolean; Law: Double): TOutputSample;
var
  i, obd: Integer;
  smp16, coeff: Double;
begin
  coeff := 1.0;
  for i := 0 to Attenuation do
    coeff += i * Law;

  obd := (1 shl (OutBitDepth - 1)) - 1;
  smp16 := smp * obd * coeff;
  if Negative then smp16 := -smp16;
  Result.AsInteger := EnsureRange(simpleRound(smp16), -obd, obd);
  Result.AsDouble := EnsureRange(smp16, -obd, obd);
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
    o := TEncoder.makeOutputSample(f, obd, bs, sgn, 1 / 6).AsInteger;
    so := TEncoder.makeOutputSample(sf, obd, bs, sgn, 1 / 6).AsInteger;
    writeln(smp,#9,o,#9,so,#9,bs,#9,sgn,#9,FloatToStr(f));
    assert(smp = o);
    assert(smp = so);
  end;

  halt;
end;

var
  enc: TEncoder;
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
        WriteLn('ChunkBitDepth = ', enc.ChunkBitDepth);
        WriteLn('Precision = ', enc.Precision);
        WriteLn('ChunkBlend = ', enc.ChunkBlend);
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

      WriteLn('PsyADelta = ', FormatFloat('0.0000000000', enc.ComputePsyADelta(enc.srcData, enc.dstData)));

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

