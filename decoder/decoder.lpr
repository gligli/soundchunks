program decoder;

uses Types, SysUtils, Classes, Math, extern;

const
  CAttrShift = 15;
  CAttrMul = round((1 shl CAttrShift) * (High(SmallInt) / 2047));
  CMaxAttenuation = 15;
  CAttenuationLawNumerator = 1;
  CVariableCodingHeaderSize = 2;
  CVariableCodingBlockSize = 3;

var
  GAttenuationLookup : array[0 .. CMaxAttenuation] of Integer;


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
    iChunk, iAttenuation, iSample, iChannel, b, s1, s2, bitCount, variableCodingHeader, delta, finalSample, clippingErrors: Integer;
    w: Word;
    channelSample: TIntegerDynArray;
    chunkIndex: TIntegerDynArray;
    chunkNegative, chunkReversed: TBooleanDynArray;
    StreamVersion, ChannelCount, ChunkBitDepth, ChunkSize, ChunkCount: Integer;
    FrameLength, SampleRate, ChunkBlend, AttenuationDivider: Integer;
    Chunks: TSmallIntDynArray2;
    Attenuations: TByteDynArray;
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

    function Attenuate(ASample, AChunkIdx: Integer): SmallInt;
    begin
      Result := SarLongint(ASample * GAttenuationLookup[Attenuations[AChunkIdx]] + (1 shl (CAttrShift - 1)), CAttrShift);
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
        ChunkCount := ASourceStream.ReadWord and $1fff;
        ChunkBitDepth := ASourceStream.ReadByte;
        ChunkSize := ASourceStream.ReadByte;
        SampleRate := ASourceStream.ReadDWord;
        ChunkBlend := SampleRate shr 24;
        SampleRate := SampleRate and $ffffff;
        AttenuationDivider := ASourceStream.ReadWord;

        // compute attenuation law from AttenuationDivider

        law := CAttenuationLawNumerator / AttenuationDivider;
        lawAcc := 1.0;
        for iAttenuation := 0 to CMaxAttenuation do
        begin
          lawAcc += law * iAttenuation;
          GAttenuationLookup[iAttenuation] := round(CAttrMul / lawAcc);
        end;

        if memStream.Position = 0 then
        begin
          writeln('StreamVersion = ', StreamVersion);
          writeln('SampleRate = ', SampleRate);
          writeln('ChannelCount = ', ChannelCount);
          writeln('ChunkBitDepth = ', ChunkBitDepth);
          writeln('ChunkSize = ', ChunkSize);
          writeln('ChunkBlend = ', ChunkBlend);
        end;

        Assert(ChunkBlend = 0, 'ChunkBlend not supported');

        SetLength(Chunks, ChunkCount, ChunkSize);
        SetLength(Attenuations, ChunkCount);

        // depack Attenuations

        for iChunk := 0 to ChunkCount div 2 - 1 do
        begin
          b := ASourceStream.ReadByte;
          Attenuations[iChunk * 2 + 0] := (b and $f0) shr 4;
          Attenuations[iChunk * 2 + 1] := (b and $0f);
        end;

        if Odd(ChunkCount) then
        begin
          b := ASourceStream.ReadByte;
          Attenuations[ChunkCount - 1] := (b and $f0) shr 4;
        end;

        // depack Chunks

        case ChunkBitDepth of
          8:
            for iChunk := 0 to ChunkCount - 1 do
              for iSample := 0 to ChunkSize - 1 do
              begin
                b := ASourceStream.ReadByte;
                Chunks[iChunk, iSample] := Attenuate((b + Low(ShortInt)) * 2047 div High(ShortInt), iChunk);
              end;
          12:
            for iChunk := 0 to ChunkCount - 1 do
            begin
              for iSample := 0 to ChunkSize div 2 - 1 do
              begin
                b := ASourceStream.ReadByte;
                s1 := Integer(ASourceStream.ReadByte) or ((b and $f0) shl 4);
                s2 := Integer(ASourceStream.ReadByte) or ((b and $0f) shl 8);

                Chunks[iChunk, iSample * 2 + 0] := Attenuate(s1 - 2048, iChunk);
                Chunks[iChunk, iSample * 2 + 1] := Attenuate(s2 - 2048, iChunk);
              end;

              if Odd(ChunkSize) then
              begin
                b := ASourceStream.ReadByte;
                s1 := Integer(ASourceStream.ReadByte) or ((b and $f0) shl 4);

                Chunks[iChunk, ChunkSize - 1] := Attenuate(s1 - 2048, iChunk);
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


        if StreamVersion > 1 then
          for iChannel := 0 to ChannelCount - 1 do
            channelSample[iChannel] := SmallInt(ASourceStream.ReadWord);

        bits := 0;
        bitCount := 0;
        variableCodingHeader := -1;
        for iChunk := 0 to FrameLength - 1 do
        begin
          for iChannel := 0 to ChannelCount - 1 do
          begin
            FillBits;

            chunkNegative[iChannel] := GetBits(1) <> 0;

            if StreamVersion > 0 then
              chunkReversed[iChannel] := GetBits(1) <> 0; // flag starting version 1

            if GetBits(1) <> 0 then // has new header?
              variableCodingHeader := GetBits(CVariableCodingHeaderSize);

            FillBits;

            chunkIndex[iChannel] := 0;
            for iSample := 0 to variableCodingHeader do
              chunkIndex[iChannel] := (chunkIndex[iChannel] shl CVariableCodingBlockSize) or GetBits(CVariableCodingBlockSize);
          end;

          for iSample := 0 to ChunkSize - 1 do
            for iChannel := 0 to ChannelCount - 1 do
            begin
              delta := Chunks[chunkIndex[iChannel], IfThen(chunkReversed[iChannel], ChunkSize - 1 - iSample, iSample)];
              if chunkNegative[iChannel] then
                delta := -delta;

              if StreamVersion > 1 then
              begin
                channelSample[iChannel] += delta;

                finalSample := channelSample[iChannel];
                if not InRange(finalSample, Low(SmallInt), High(SmallInt)) then
                begin
                  Inc(clippingErrors);
                  finalSample := EnsureRange(finalSample, Low(SmallInt), High(SmallInt));
                end;

                memStream.WriteWord(Word(finalSample));
              end
              else
              begin
                Assert(InRange(delta, Low(SmallInt), High(SmallInt)));
                memStream.WriteWord(Word(delta));
              end;
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

