program decoder;

uses Types, SysUtils, Classes, Math, extern;

const
  CDecodedStreamVersion = 7;
  CMaxAttenuationBits = 6;
  CAttenuationLawDecibels = 0.75;

  CAttrShift = 16;
  CAttrMul: array[Boolean{12 bits?}] of Integer = ((1 shl (CAttrShift + (16 - 8))) - 1, (1 shl (CAttrShift + (16 - 12))) - 1);
  CMaxAttenuation = (1 shl CMaxAttenuationBits) - 1;

var
  GAttenuationLookup : array[Boolean{12 bits?}, 0 .. CMaxAttenuation] of Integer;

  function CreateWAVHeader(channels: word; resolution: word; rate, size: longint): TWavHeader;
  var
    wh : TWavHeader;
  begin
    wh.rId             := $46464952; { 'RIFF' }
    wh.rLen            := 36 + size; { length of sample + format }
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
    wh.wSampleLength   := size; { sample size }

    Result := wh;
  end;

  procedure PrepareAttenuationLookup;
  const
    CInvLaw = Exp(-CAttenuationLawDecibels / 20.0 * Ln(10.0));
  var
    iAttenuation: Integer;
    isChunkBitDepth12: Boolean;
    lawAcc: Double;
  begin
    lawAcc := 1.0;
    for isChunkBitDepth12 := False to True do
      for iAttenuation := 0 to CMaxAttenuation do
      begin
        GAttenuationLookup[isChunkBitDepth12, iAttenuation] := round(CAttrMul[isChunkBitDepth12] * lawAcc);
        lawAcc *= CInvLaw;
      end;
  end;

  procedure GSCUnpack(ASourceStream, ADestStream: TStream);
  var
    StreamVersion, ChannelCount, ChunkBitDepth, ChunkSize, ChunkCount: Integer;
    FrameLength, SampleRate, ChunksPerAttenuation: Integer;
    iChunk, iCPABlock, iSample, iChannel, iVariableCoding: Integer;
    bitCount, variableCodingHeader, chunksAttenuation, finalSample, clippingErrors, bit: Integer;
    delta, b, s1, s2: Integer;
    channelSample: TIntegerDynArray;
    chunkIndex: TIntegerDynArray;
    chunkNegative, chunkReversed: TBooleanDynArray;
    Chunks: TSmallIntDynArray2;
    piggyCodings: array of record
      BitSize: Byte;
      CumulatedStart: Integer;
    end;
    memStream: TMemoryStream;
    bits: Word;

    function GetBit: Integer;
    begin
      Dec(bitCount);
      if bitCount <= 0 then
      begin
        bits := ASourceStream.ReadWord;
        bitCount := BitSizeOf(bits);
      end;
      bits := RolWord(bits);
      Result := bits and 1;
    end;

    function GetBits(ABitCount: Integer): Integer;
    var
      iBit: Integer;
    begin
      Result := 0;
      for iBit := 0 to ABitCount - 1 do
      begin
        Result := Result shl 1;
        Result := Result or GetBit;
      end;
    end;

    function Attenuate(ASample, AAttenuation: Integer): Integer;
    begin
      Result := SarLongint(ASample * GAttenuationLookup[ChunkBitDepth = 12, AAttenuation] + (1 shl (CAttrShift - 1)), CAttrShift);
    end;

  begin
    clippingErrors := 0;

    memStream := TMemoryStream.Create;
    try
      while ASourceStream.Position <> ASourceStream.Size do
      begin
        // parse header

        StreamVersion := ASourceStream.ReadByte;
        ChannelCount := ASourceStream.ReadByte;
        ChunkCount := ASourceStream.ReadWord;
        ChunkBitDepth := ASourceStream.ReadByte;
        ChunkSize := ASourceStream.ReadByte;
        SampleRate := ASourceStream.ReadDWord;
        ChunksPerAttenuation := ASourceStream.ReadByte;
        ASourceStream.ReadByte;

        if memStream.Position = 0 then
        begin
          writeln('StreamVersion = ', StreamVersion);
          writeln('SampleRate = ', SampleRate);
          writeln('ChannelCount = ', ChannelCount);
          writeln('ChunkBitDepth = ', ChunkBitDepth);
          writeln('ChunkSize = ', ChunkSize);
        end;

        Assert(StreamVersion = CDecodedStreamVersion, 'StreamVersion not supported');

        SetLength(Chunks, ChunkCount, ChunkSize);

        // depack Chunks

        case ChunkBitDepth of
          8:
            for iChunk := 0 to ChunkCount - 1 do
              for iSample := 0 to ChunkSize - 1 do
              begin
                b := ASourceStream.ReadByte;
                Chunks[iChunk, iSample] := b + Low(ShortInt);
              end;
          12:
            for iChunk := 0 to ChunkCount - 1 do
            begin
              for iSample := 0 to ChunkSize div 2 - 1 do
              begin
                b := ASourceStream.ReadByte;
                s1 := Integer(ASourceStream.ReadByte) or ((b and $f0) shl 4);
                s2 := Integer(ASourceStream.ReadByte) or ((b and $0f) shl 8);

                Chunks[iChunk, iSample * 2 + 0] := s1 - 2048;
                Chunks[iChunk, iSample * 2 + 1] := s2 - 2048;
              end;

              if Odd(ChunkSize) then
              begin
                b := ASourceStream.ReadByte;
                s1 := Integer(ASourceStream.ReadByte) or ((b and $f0) shl 4);

                Chunks[iChunk, ChunkSize - 1] := s1 - 2048;
              end;
            end;
          else
            Assert(False, 'ChunkBitDepth not supported');
        end;

        // depack Frames

        SetLength(chunkIndex, ChannelCount);
        SetLength(chunkNegative, ChannelCount);
        SetLength(chunkReversed, ChannelCount);
        SetLength(channelSample, ChannelCount);

        FrameLength := ASourceStream.ReadDWord;

        Assert((FrameLength mod ChunksPerAttenuation) = 0, 'Frame should contain an integer number of ChunksPerAttenuation');

        // frame start samples
        for iChannel := 0 to ChannelCount - 1 do
          channelSample[iChannel] := SmallInt(ASourceStream.ReadWord);

        // frame piggy coder data
        SetLength(piggyCodings, ASourceStream.ReadByte);
        for iVariableCoding := 0 to High(piggyCodings) do
          piggyCodings[iVariableCoding].BitSize := ASourceStream.ReadByte;

        piggyCodings[0].CumulatedStart := 0;
        for iVariableCoding := 1 to High(piggyCodings) do
        begin
          piggyCodings[iVariableCoding].CumulatedStart := piggyCodings[iVariableCoding - 1].CumulatedStart;
          piggyCodings[iVariableCoding].CumulatedStart += 1 shl piggyCodings[iVariableCoding - 1].BitSize;
        end;

        bits := 0;
        bitCount := 0;
        variableCodingHeader := -1;
        chunksAttenuation := 0;

        for iCPABlock := 0 to FrameLength div ChunksPerAttenuation - 1 do
        begin
          chunksAttenuation := GetBits(CMaxAttenuationBits);

          for iChunk := 0 to ChunksPerAttenuation - 1 do
          begin
            for iChannel := 0 to ChannelCount - 1 do
            begin
              chunkNegative[iChannel] := GetBits(1) <> 0;
              chunkReversed[iChannel] := GetBits(1) <> 0;

              variableCodingHeader := 0;
              repeat
                bit := GetBits(1);
                variableCodingHeader += bit;
              until (bit = 0) or (variableCodingHeader >= High(piggyCodings));

              chunkIndex[iChannel] := piggyCodings[variableCodingHeader].CumulatedStart;
              chunkIndex[iChannel] += GetBits(piggyCodings[variableCodingHeader].BitSize);
            end;

            for iSample := 0 to ChunkSize - 1 do
              for iChannel := 0 to ChannelCount - 1 do
              begin
                delta := Chunks[chunkIndex[iChannel], IfThen(chunkReversed[iChannel], ChunkSize - 1 - iSample, iSample)];
                delta := Attenuate(delta, chunksAttenuation);
                if chunkNegative[iChannel] then
                  delta := -delta;

                channelSample[iChannel] := channelSample[iChannel] - SarLongint(channelSample[iChannel], 2) + delta;

                finalSample := channelSample[iChannel];
                if not InRange(finalSample, Low(SmallInt), High(SmallInt)) then
                begin
                  Inc(clippingErrors);
                  finalSample := EnsureRange(finalSample, Low(SmallInt), High(SmallInt));
                end;

                memStream.WriteWord(Word(finalSample));
              end;
          end;
        end;
      end;

      memStream.Seek(0, soFromBeginning);
      ADestStream.Write(CreateWAVHeader(ChannelCount, 16, SampleRate, memStream.Size), SizeOf(TWavHeader));
      ADestStream.CopyFrom(memStream, memStream.Size);

      if clippingErrors > 0 then
      begin
        WriteLn;
        WriteLn('/!\ ', clippingErrors, ' clipping errors.');
      end;

    finally
      memStream.Free;
    end;
  end;


var
  gscFN, wavFN: String;
  inFS, outFS: TFileStream;
  ms: TMemoryStream;
begin
  if ParamCount = 0 then
  begin
    WriteLn('Usage: ', ExtractFileName(ParamStr(0)) + ' <source GSC file> [dest WAV file]');
    WriteLn;
    Exit;
  end;

  PrepareAttenuationLookup;

  gscFN := ParamStr(1);
  if ParamCount > 1 then
    wavFN := ParamStr(2)
  else
    wavFN := ChangeFileExt(gscFN, '.wav');

  inFS := TFileStream.Create(gscFN, fmOpenRead or fmShareDenyNone);
  outFS := TFileStream.Create(wavFN, fmCreate or fmShareDenyWrite);
  ms := TMemoryStream.Create;
  try
    ms.CopyFrom(inFS, inFS.Size); // to buffer inFS
    ms.Position := 0;
    GSCUnpack(ms, outFS);
  finally
    ms.Free;
    outFS.Free;
    inFS.Free;
  end;
end.

