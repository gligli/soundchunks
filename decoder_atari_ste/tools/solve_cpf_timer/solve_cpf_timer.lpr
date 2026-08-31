program solve_cpf_timer;
uses
  Math, Types, fgl, SysUtils, StrUtils;
const
  CMFPFreq = 2457600.0;
  CSoundFreq = 8010613.33333333333333333333;
  CSoundDiv = 320;
  CChunkSize = 7;
  CMFPDivs: array[0 .. 6] of Integer = (4, 10, 16, 50, 64, 100, 200);

var
  iCPF, iMFPDiv, iMFPData: Integer;
  bestCPF, bestMFPDiv, bestMFPData: Integer;
   mfpDataPer, bestV, bestW, v, w: Extended;
begin
  bestV := MaxSingle;
  bestW := -MaxSingle;
  bestCPF := -1;
  bestMFPDiv := -1;
  bestMFPData := -1;
  for iCPF := 32 to 42 do
  begin
    v := iCPF * CSoundDiv * CChunkSize / CSoundFreq;
    for iMFPDiv := Low(CMFPDivs) to High(CMFPDivs) do
    begin
      mfpDataPer := CMFPDivs[iMFPDiv] / CMFPFreq;

      for iMFPData := 1 to 255 do
      begin
        w := (iMFPData) * mfpDataPer;

        if (w < v) and (Abs(v - w) < Abs(bestV - bestW)) then
        begin
          bestV := v;
          bestW := w;
          bestCPF := iCPF;
          bestMFPDiv := CMFPDivs[iMFPDiv];
          bestMFPData := iMFPData;
        end;
      end;
    end;
  end;
  writeln('best:', (bestV - bestW)*1e6:12:9, 'uS, bestCPF:', bestCPF:4, ', bestMFPDiv:', bestMFPDiv:4, ', bestMFPData:', bestMFPData:4);
  writeln('sample buffer size:', CChunkSize * bestCPF:8);

  ReadLn;
end.

