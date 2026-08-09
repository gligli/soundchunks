program decoder;

uses Types, SysUtils, Classes, Math, extern;

const
  CDecodedStreamVersion = 4;

  CAttrShift = 16;
  CAttrMul: array[Boolean{12 bits?}] of Integer = ((1 shl (CAttrShift + (16 - 8))) - 1, (1 shl (CAttrShift + (16 - 12))) - 1);

  CAttenuationLawNumerator = 1;
  CPiggyCodingBits = 2;
  CPiggyCodingCount = 1 shl CPiggyCodingBits;
  CMaxAttenuationBits = 5;
  CMaxAttenuation = (1 shl CMaxAttenuationBits) - 1;
  CMaxAttenuationLawDiviverBits = 7;

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

  procedure GSCUnpack(ASourceStream, ADestStream: TStream);
  var
    iChunk, iAttenuation, iSample, iChannel, iVariableCoding, cpaCounter, apalCounter: Integer;
    bitCount, variableCodingHeader, chunkAttenuation, attenuationLawDivider, finalSample, clippingErrors: Integer;
    delta, b, s1, s2: Integer;
    w: Word;
    channelSample: TIntegerDynArray;
    chunkIndex: TIntegerDynArray;
    chunkNegative, chunkReversed: TBooleanDynArray;
    StreamVersion, ChannelCount, ChunkBitDepth, ChunkSize, ChunkCount: Integer;
    FrameLength, SampleRate, ChunkBlend, ChunksPerAttenuation, AttenuationsPerAttenuationLaw: Integer;
    Chunks: TSmallIntDynArray2;
    piggyCodingBits: array[0 .. CPiggyCodingCount - 1] of Byte;
    attenuationLookup : array[0 .. CMaxAttenuation] of Integer;
    memStream: TMemoryStream;
    law, lawAcc: Double;
    bits: Cardinal;

    function GetBits(ABitCount: Integer): Integer;
    begin
      Assert(ABitCount <= bitCount);
      Result := bits and ((1 shl ABitCount) - 1);
      bits := bits shr ABitCount;
      bitCount -= ABitCount;
    end;

    procedure FillBits;
    begin
      if (bitCount < 16) and (ASourceStream.Position < ASourceStream.Size) then
      begin
        w := ASourceStream.ReadWord;
        bits := bits or (w shl bitCount);
        bitCount += 16;
      end;
    end;

    function Attenuate(ASample, AAttenuation: Integer): Integer;
    begin
      Result := SarLongint(ASample * attenuationLookup[AAttenuation] + (1 shl (CAttrShift - 1)), CAttrShift);
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
        ChunkBlend := SampleRate shr 24;
        SampleRate := SampleRate and $ffffff;
        ChunksPerAttenuation := ASourceStream.ReadByte * ChannelCount;
        AttenuationsPerAttenuationLaw := ASourceStream.ReadByte;

        if memStream.Position = 0 then
        begin
          writeln('StreamVersion = ', StreamVersion);
          writeln('SampleRate = ', SampleRate);
          writeln('ChannelCount = ', ChannelCount);
          writeln('ChunkBitDepth = ', ChunkBitDepth);
          writeln('ChunkSize = ', ChunkSize);
          writeln('ChunkBlend = ', ChunkBlend);
        end;

        Assert(StreamVersion = CDecodedStreamVersion, 'StreamVersion not supported');
        Assert(ChunkBlend = 0, 'ChunkBlend not supported');

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

        for iChannel := 0 to ChannelCount - 1 do
          channelSample[iChannel] := SmallInt(ASourceStream.ReadWord);

        for iVariableCoding := 0 to CPiggyCodingCount - 1 do
          piggyCodingBits[iVariableCoding] := ASourceStream.ReadByte;

        bits := 0;
        bitCount := 0;
        variableCodingHeader := -1;
        chunkAttenuation := 0;
        cpaCounter := -1;
        apalCounter := -1;
        for iChunk := 0 to FrameLength - 1 do
        begin
          for iChannel := 0 to ChannelCount - 1 do
          begin
            Dec(cpaCounter);
            if cpaCounter <= 0 then
            begin
              FillBits;

              Dec(apalCounter);
              if apalCounter <= 0 then
              begin
                apalCounter := AttenuationsPerAttenuationLaw;
                attenuationLawDivider := GetBits(CMaxAttenuationLawDiviverBits);

                // compute chunkAttenuation law from attenuationLawDivider
                law := CAttenuationLawNumerator / attenuationLawDivider;
                lawAcc := 1.0;
                for iAttenuation := 0 to CMaxAttenuation do
                begin
                  lawAcc += law * iAttenuation;
                  attenuationLookup[iAttenuation] := round(CAttrMul[ChunkBitDepth = 12] / lawAcc);
                end;
              end;

              cpaCounter := ChunksPerAttenuation;
              chunkAttenuation := GetBits(CMaxAttenuationBits);
            end;

            FillBits;

            chunkNegative[iChannel] := GetBits(1) <> 0;
            chunkReversed[iChannel] := GetBits(1) <> 0;

            if GetBits(1) <> 0 then // has new header?
              variableCodingHeader := GetBits(CPiggyCodingBits);

            FillBits;

            chunkIndex[iChannel] := 0;
            for iVariableCoding := 0 to variableCodingHeader - 1 do
              chunkIndex[iChannel] += 1 shl piggyCodingBits[iVariableCoding];
            chunkIndex[iChannel] += GetBits(piggyCodingBits[variableCodingHeader]);
          end;

          for iSample := 0 to ChunkSize - 1 do
            for iChannel := 0 to ChannelCount - 1 do
            begin
              delta := Chunks[chunkIndex[iChannel], IfThen(chunkReversed[iChannel], ChunkSize - 1 - iSample, iSample)];
              delta := Attenuate(delta, chunkAttenuation);
              if chunkNegative[iChannel] then
                delta := -delta;

              channelSample[iChannel] += delta;

              finalSample := channelSample[iChannel];
              if not InRange(finalSample, Low(SmallInt), High(SmallInt)) then
              begin
                Inc(clippingErrors);
                finalSample := EnsureRange(finalSample, Low(SmallInt), High(SmallInt));
              end;

              memStream.WriteWord(Word(finalSample));
            end;
        end;

        if bitCount >= 16 then // fixup potentially reading 1 spurious word
        begin
          ASourceStream.Seek(-2, soCurrent);
          bitCount -= 16;
        end;

        Assert(bitCount < 16);
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

