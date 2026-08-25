program gen_lmc1992_data;

uses Classes, Registry, SysUtils, Types, Math, Process, extern;

procedure DoExternalLTSpice(ACircuitFN, ALTSpicePath: String);
var
  i: Integer;
  Params, Output, ErrOut: String;
  Process: TProcess;
begin
  Process := TProcess.Create(nil);

  Process.CurrentDirectory := '';
  Process.Executable := ALTSpicePath + '\LTSpice.exe';

  Params := '-ascii -b ';
  Params += '"' + ACircuitFN + '" ';
  Process.Parameters.Add(Params);

  Process.ShowWindow := swoHIDE;
  Process.Priority := ppNormal;

  i := 0;
  internalRuncommand(Process, Output, ErrOut, i, False); // destroys Process
end;

const
  TONE_STEPS = 13;
  NEUTRAL_TONE = 6;

var
  ltspicePath, tmpCirFR, tmpRawFN, tmpLogFN, tmpOpRawFN, line, hdr: String;
  iBass, iTreb, iLine, nbVar, nbPoints, freqVar, outVar, valuesStartLine, varIdx, pointIdx: Integer;
  bassPot, trebPot: Double;
  v: Single;
  inVariables, inValues: Boolean;
  reg: TRegistry;
  sl, lineSL, varSL: TStringList;
  dataStream: TFileStream;
begin
  reg := TRegistry.Create;
  try
    reg.OpenKey('\Software\Analog Devices Inc.\LTspice', False);
    ltspicePath := reg.ReadString('Path');
  finally
    reg.Free;
  end;

  WriteLn('ltspicePath: ', ltspicePath);
  Assert(ltspicePath <> '', 'LTspice not found!');

  dataStream := TFileStream.Create(ExtractFilePath(ParamStr(0)) + '..\encoder\lmc1992.dat', fmCreate or fmShareDenyWrite);
  try
    for iBass := 0 to TONE_STEPS - 1 do
      for iTreb := 0 to TONE_STEPS - 1 do
      begin
        bassPot := iBass / (TONE_STEPS - 1);
        trebPot := iTreb / (TONE_STEPS - 1);

        WriteLn(iBass:4, iTreb:4, bassPot:9:3, trebPot:9:3);

        tmpCirFR := ExtractFilePath(ParamStr(0)) + 'spice\tmp_' + IntToStr(iBass) + '_' + IntToStr(iTreb) + '.cir';
        tmpRawFN := ChangeFileExt(tmpCirFR, '.raw');
        tmpOpRawFN := ChangeFileExt(tmpCirFR, '.op.raw');
        tmpLogFN := ChangeFileExt(tmpCirFR, '.log');

        sl := TStringList.Create;
        lineSL := TStringList.Create;
        varSL := TStringList.Create;
        try
          lineSL.Delimiter := #9;
          varSL.Delimiter := ',';

          sl.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'spice\lmc1992_bass_treb.cir');

          for iLine := 0 to sl.Count - 1 do
          begin
            sl[iLine] := StringReplace(sl[iLine], '#bass#', FloatToStr(bassPot, InvariantFormatSettings), []);
            sl[iLine] := StringReplace(sl[iLine], '#treb#', FloatToStr(trebPot, InvariantFormatSettings), []);
          end;

          sl.SaveToFile(tmpCirFR);

          DoExternalLTSpice(tmpCirFR, ltspicePath);

          sl.Clear;

          sl.LoadFromFile(tmpRawFN);

          freqVar := -1;
          outVar := -1;
          nbVar := 0;
          nbPoints := 0;
          valuesStartLine := 0;
          inVariables := False;
          inValues := False;
          for iLine := 0 to sl.Count - 1 do
          begin
            line := sl[iLine];

            if inVariables then
            begin
              if line.StartsWith('Values:') then
              begin
                inVariables := False;
                inValues := True;
                valuesStartLine := iLine + 1;
              end
              else
              begin
                lineSL.DelimitedText := line;

                if lineSL[1] = 'frequency' then
                  freqVar := StrToIntDef(lineSL[0], freqVar);

                if lineSL[1] = 'V(out)' then
                  outVar := StrToIntDef(lineSL[0], outVar);
              end;
            end
            else if inValues then
            begin
              DivMod(iLine - valuesStartLine, nbVar, pointIdx, varIdx);

              if (varIdx = freqVar) or (varIdx = outVar) then
              begin
                lineSL.DelimitedText := line;
                varSL.DelimitedText := lineSL[lineSL.Count - 1];

                v := StrToFloatDef(varSL[0], NaN, InvariantFormatSettings);

                dataStream.Write(v, SizeOf(v));
              end;
            end
            else
            begin
              hdr := 'No. Variables:';
              if line.StartsWith(hdr) then
                nbVar := StrToIntDef(TrimLeft(Copy(line, length(hdr) + 1)), nbVar);

              hdr := 'No. Points:';
              if line.StartsWith(hdr) then
              begin
                nbPoints := StrToIntDef(TrimLeft(Copy(line, length(hdr) + 1)), nbPoints);
                dataStream.WriteDWord(nbPoints);
              end;

              if line.StartsWith('Variables:') then
                inVariables := True;
            end;

          end;

          DeleteFile(tmpCirFR);
          DeleteFile(tmpRawFN);
          DeleteFile(tmpOpRawFN);
          DeleteFile(tmpLogFN);
        finally
          varSL.Free;
          lineSL.Free;
          sl.Free;
        end;
      end;

      WriteLn('Done!');
  finally
    dataStream.Free;
  end;
end.

