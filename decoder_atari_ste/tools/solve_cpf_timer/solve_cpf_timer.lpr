program solve_cpf_timer;
uses
  Math;
const
  CMFPFreq = 2457600.0;
  CSoundFreq = 8010613.0;
  CSoundDiv = 320;
  CChunkSize = 6;
  CMFPDivs: array[0 .. 6] of Integer = (4, 10, 16, 50, 64, 100, 200);
var
  iCPF, iMFPDiv, iMFPData: Integer;
  bestCPF, bestMFPDiv, bestMFPData: Integer;
  best, v: Double;
begin
  best := Infinity;
  bestCPF := -1;
  bestMFPDiv := -1;
  bestMFPData := -1;
  for iCPF := 24 to 84 do
    for iMFPDiv := Low(CMFPDivs) to High(CMFPDivs) do
      for iMFPData := 1 to 256 do
      begin
        v := 1.0 / (CSoundFreq / CSoundDiv / CChunkSize / iCPF) - 1.0 / (CMFPFreq / CMFPDivs[iMFPDiv] / iMFPData);

        if (v >= 0) and (Abs(v) < Abs(best)) then
        begin
          best := v;
          bestCPF := iCPF;
          bestMFPDiv := CMFPDivs[iMFPDiv];
          bestMFPData := iMFPData;
        end;
      end;
  writeln('best :', best*1e6:12:6, 'uS, bestCPF :', bestCPF:4, ', bestMFPDiv :', bestMFPDiv:4, ', bestMFPData :', bestMFPData:4);
  writeln('sample buffer size :', CChunkSize * iCPF:8);
  ReadLn;
end.

