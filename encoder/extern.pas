unit extern;

{$mode ObjFPC}{$H+}
{$ModeSwitch advancedrecords}
{$TYPEDADDRESS ON}

interface

uses
  logger, Windows, Classes, SysUtils, Types, Process, strutils, math;

type
  TDoubleDynArray2 = array of TDoubleDynArray;
  TDoubleDynArray3 = array of TDoubleDynArray2;
  TSmallIntDynArray2 = array of TSmallIntDynArray;
  TIntegerDynArray2 = array of TIntegerDynArray;

  { format of WAV file header }
  TWavHeader = record         { parameter description }
    rId             : longint; { 'RIFF'  4 characters }
    rLen            : longint; { length of DATA + FORMAT chunk }
    { FORMAT CHUNK }
    wId             : longint; { 'WAVE' }
    fId             : longint; { 'fmt ' }
    fLen            : longint; { length of FORMAT DATA = 16 }
    { format data }
    wFormatTag      : word;    { $01 = PCM }
    nChannels       : word;    { 1 = mono, 2 = stereo }
    nSamplesPerSec  : longint; { Sample frequency ie 11025}
    nAvgBytesPerSec : longint; { = nChannels * nSamplesPerSec *
                                 (nBitsPerSample/8) }
    nBlockAlign     : word;    { = nChannels * (nBitsPerSAmple / 8 }
    wBitsPerSample  : word;    { 8 or 16 }
    { DATA CHUNK }
    dId             : longint; { 'data' }
    wSampleLength   : longint; { length of SAMPLE DATA }
      { sample data : offset 44 }
      { for 8 bit mono = s[0],s[1]... :byte}
      { for 8 bit stereo = sleft[0],sright[0],sleft[1],sright[1]... :byte}
      { for 16 bit mono = s[0],s[1]... :word}
      { for 16 bit stereo = sleft[0],sright[0],sleft[1],sright[1]... :word}
  end;

  TANNsplitRule = (
  		ANN_KD_STD = 0,      // the optimized kd-splitting rule
  		ANN_KD_MIDPT = 1,    // midpoint split
  		ANN_KD_FAIR	= 2,     // fair split
  		ANN_KD_SL_MIDPT = 3, // sliding midpoint splitting method
  		ANN_KD_SL_FAIR = 4,  // sliding fair split method
  		ANN_KD_SUGGEST = 5 // the authors' suggestion for best
  );

  TANNFloat = Double;
  PANNFloat = ^TANNFloat;
  PPANNFloat = ^PANNFloat;
  TANNFloatDynArray = array of TANNFloat;
  TANNFloatDynArray2 = array of TANNFloatDynArray;

  TANNkdtree = record
  end;

  PANNkdtree = ^TANNkdtree;

  stCLOptions = record
    bModelType: Boolean;
    bForgetFactorEnabled: Boolean;
    fSPL: Single;
  end;
  PstCLOptions = ^stCLOptions;

  WaveFormat = record
    iNumOfBits,
    iNumOfChannel,
    iSamplingRate: Integer;
  end;
  PWaveFormat = ^WaveFormat;

  stAudioData = record
    pRefData,
    pTestData: array[0..1] of PSmallInt;
  end;
  PstAudioData = ^stAudioData;

  TCompareFunction=function(Item1,Item2,UserParameter:Pointer):Integer;
  TEvalFunc = function(const arg: TDoubleDynArray; data: Pointer): Double of object;

  TSpinlock = LongInt;
  PSpinLock = ^TSpinlock;

  { TKRng }

  TKRng = record
    x, y, z, w: UInt64;
    procedure init();
    function randInt(): UInt64; // Xorshift RNG; http://www.jstatsoft.org/v08/i14/paper
    function random(): Double;
  end;

  TYakmo = record
  end;

  PYakmo = ^TYakmo;

procedure SpinEnter(Lock: PSpinLock); register; assembler;
procedure SpinEnterSleep(Lock: PSpinLock); register; assembler;
procedure SpinLeave(Lock: PSpinLock); register; assembler;

procedure Exchange(var a, b: Integer); overload;
procedure Exchange(var a, b: Cardinal); overload;
procedure Exchange(var a, b: Double); overload;
procedure Exchange(var a, b: Single); overload;

function iDivDef(x, y, def: Integer): Integer;overload;inline;
function iDivDef(x, y, def: Int64): Int64;overload;inline;
function DivDef(x, y, def: Double): Double;inline;
function NanDef(x, def: Double): Double; inline;

function lerp(x, y, alpha: Double): Double; inline;
function muLaw(x: Double): Double; inline;

function NumberOfProcessors: Integer;
function HalfNumberOfProcessors: Integer;
function QuarterNumberOfProcessors: Integer;

procedure DoExternalSKLearn(Dataset: TDoubleDynArray2;  ClusterCount, Precision: Integer; Compiled, PrintProgress: Boolean; var Clusters: TIntegerDynArray; var Centroids: TDoubleDynArray2);
procedure DoExternalSOX(AFNIn, AFNOut: String; SampleRate: Integer = 0; ForceMono: Boolean = False);
function DoExternalEAQUAL(AFNRef, AFNTest: String; PrintStats, UseDIX: Boolean; BlockLength: Integer): Double;

procedure LZCompress(ASourceStream: TStream; PrintProgress, Decompress: Boolean; ADestStream: TStream);

procedure GenerateSVMLightData(Dataset: TDoubleDynArray2; Output: TStringList; Header: Boolean);
function GenerateSVMLightFile(Dataset: TDoubleDynArray2; Header: Boolean): String;
function GetSVMLightLine(index: Integer; lines: TStringList): TDoubleDynArray;
function GetSVMLightClusterCount(lines: TStringList): Integer;

function ann_kdtree_create(pa: PPANNFloat; n, dd, bs: Integer; split: TANNsplitRule): PANNkdtree; cdecl; external 'ANN.dll';
procedure ann_kdtree_destroy(akd: PANNkdtree); cdecl; external 'ANN.dll';
function ann_kdtree_search(akd: PANNkdtree; q: PANNFloat; eps: TANNFloat; err: PANNFloat): Integer; cdecl; external 'ANN.dll';
function ann_kdtree_pri_search(akd: PANNkdtree; q: PANNFloat; eps: TANNFloat; err: PANNFloat): Integer; cdecl; external 'ANN.dll';
procedure ann_kdtree_search_multi(akd: PANNkdtree; idxs: PInteger; errs: PANNFloat; cnt: Integer; q: PANNFloat; eps: TANNFloat); cdecl; external 'ANN.dll';
procedure ann_kdtree_pri_search_multi(akd: PANNkdtree; idxs: PInteger; errs: PANNFloat; cnt: Integer; q: PANNFloat; eps: TANNFloat); cdecl; external 'ANN.dll';

function yakmo_create(k: Cardinal; restartCount: Cardinal; maxIter: Integer; initType: Integer; initSeed: Integer; doNormalize: Integer; isVerbose: Integer): PYakmo; stdcall; external 'yakmo.dll';
procedure yakmo_destroy(ay: PYakmo); stdcall; external 'yakmo.dll';
procedure yakmo_set_num_threads(num_threads: Integer); stdcall; external 'yakmo.dll';
procedure yakmo_load_train_data(ay: PYakmo; rowCount: Cardinal; colCount: Cardinal; dataset: PPDouble); stdcall; external 'yakmo.dll';
procedure yakmo_load_train_data_weighted(ay: PYakmo; rowCount: Cardinal; colCount: Cardinal; dataset: PPDouble; weights: PCardinal); stdcall; external 'yakmo.dll';
procedure yakmo_train_on_data(ay: PYakmo; pointToCluster: PInteger); stdcall; external 'yakmo.dll';
procedure yakmo_get_centroids(ay: PYakmo; centroids: PPDouble); stdcall; external 'yakmo.dll';

function eaqualCreateInstance: Pointer; cdecl; external 'libEAQUAL.dll';
procedure eaqualKillInstance(pInstance: Pointer); cdecl; external 'libEAQUAL.dll';
function eaqualInitInstance(pInstance: Pointer; pCLOptions: PstCLOptions; pWFormat: PWaveFormat): Cardinal; cdecl; external 'libEAQUAL.dll';
function eaqualProcessInstance(pInstance: Pointer; pAudioData: PstAudioData): Cardinal; cdecl; external 'libEAQUAL.dll';
function eaqualEndInstance(pInstance: Pointer; pfResults: PPDouble; piResultLength: PInteger): Cardinal; cdecl; external 'libEAQUAL.dll';

function InvariantFormatSettings: TFormatSettings;
function internalRuncommand(p:TProcess;var outputstring:string;
                            var stderrstring:string; var exitstatus:integer; PrintOut: Boolean):integer;

procedure QuickSort(var AData;AFirstItem,ALastItem:Int64;AItemSize:Integer;ACompareFunction:TCompareFunction;AUserParameter:Pointer=nil);
function DichotomyFind(var AData,AKey;AFirstItem,ALastItem:Int64;AItemSize:Integer;ACompareFunction:TCompareFunction;AUserParameter:Pointer=nil): Integer;

function GetActiveProcessorCount(GroupNumber: Word): DWORD; stdcall; external 'kernel32.dll';

function EuclideanToPSNR(AEuclidean: Double): Double;
function PSNRToEuclidean(APSNR: Double): Double;

function GridReduceMinimize(Func: TEvalFunc; var X: TDoubleDynArray; GridSize: array of Integer; GridExtents: array of Double; EpsilonReduce: Double; VerboseTag: String = ''; Data: Pointer = nil): Double;

const
  ALL_PROCESSOR_GROUPS = High(Word);
  cBestPSNR = 20.0 * Ln(High(Word)) / Ln(10.0);
  cPhi = (1 + sqrt(5)) / 2;
  cInvPhi = 1 / cPhi;

implementation

var
  GTempAutoInc : Integer = 0;
  GInvariantFormatSettings: TFormatSettings;
  GNumberOfProcessors: Integer = 0;

// SpinLock code from https://wiki.osdev.org/Spinlock

procedure SpinEnter(Lock: PSpinLock); register; assembler;
label acquireLock, spin_with_pause, acquired;
asm
  acquireLock:
      lock bts [lock],0        // Attempt to acquire the lock (in case lock is uncontended)
      jnc acquired

  spin_with_pause:
      pause                    // Tell CPU we're spinning
      test dword [lock],1      // Is the lock free?
      jnz spin_with_pause      // no, wait
      jmp acquireLock          // retry

  acquired:
end;

procedure SpinSleep;
begin
  Sleep(1);
end;

procedure SpinEnterSleep(Lock: PSpinLock); register; assembler;
label acquireLock, spin_with_pause, sleep, acquired;
asm
  push  rax

  acquireLock:
      lock  bts [lock],0       // Attempt to acquire the lock (in case lock is uncontended)
      jnc   acquired

      xor   eax,eax

  spin_with_pause:
      inc   eax
      test  eax,$fffe0000
      jnz   sleep
      pause                    // Tell CPU we're spinning
      test  dword [lock],1     // Is the lock free?
      jnz   spin_with_pause    // no, wait
      jmp   acquireLock        // retry

  sleep:
      push  rcx
      call  SpinSleep
      pop   rcx
      jmp   acquireLock

  acquired:

  pop  rax
end;

procedure SpinLeave(Lock: PSpinLock); register; assembler;
asm
  mov dword [Lock],0
end;

procedure Exchange(var a, b: Integer);
var
  tmp: Integer;
begin
  tmp := b;
  b := a;
  a := tmp;
end;

procedure Exchange(var a, b: Cardinal);
var
  tmp: Cardinal;
begin
  tmp := b;
  b := a;
  a := tmp;
end;

procedure Exchange(var a, b: Double);
var
  tmp: Double;
begin
  tmp := b;
  b := a;
  a := tmp;
end;

procedure Exchange(var a, b: Single);
var
  tmp: Double;
begin
  tmp := b;
  b := a;
  a := tmp;
end;

function iDivDef(x, y, def: Integer): Integer;
begin
  Result := def;
  if y <> 0 then
    Result := x div y;
end;

function iDivDef(x, y, def: Int64): Int64;
begin
  Result := def;
  if y <> 0 then
    Result := x div y;
end;

function DivDef(x, y, def: Double): Double;
begin
  Result := def;
  if y <> 0 then
    Result := x / y;
end;

function NanDef(x, def: Double): Double; inline;
begin
  Result := x;
  if IsNan(Result) then
    Result := def;
end;

function lerp(x, y, alpha: Double): Double;
begin
  Result := x + (y - x) * alpha;
end;

function muLaw(x: Double): Double;
const
  CMu = 255.0;
begin
  Result := Sign(x) * Ln(1.0 + CMu * Abs(x)) / Ln(1.0 + CMu);
end;

function NumberOfProcessors: Integer;
begin
  Result := GNumberOfProcessors;
end;

function HalfNumberOfProcessors: Integer;
begin
  Result := max(1, GNumberOfProcessors div 2);
end;

function QuarterNumberOfProcessors: Integer;
begin
  Result := max(1, GNumberOfProcessors div 4);
end;

procedure QuickSort(var AData;AFirstItem,ALastItem:Int64;AItemSize:Integer;ACompareFunction:TCompareFunction;AUserParameter:Pointer=nil);
var I, J, P: Int64;
    PData,P1,P2: PByte;
    Tmp: array[0..4095] of Byte;
begin
  if ALastItem <= AFirstItem then
    Exit;

  Assert(AItemSize < SizeOf(Tmp),'AItemSize too big!');
  PData:=PByte(@AData);
  repeat
    I := AFirstItem;
    J := ALastItem;
    P := (AFirstItem + ALastItem) shr 1;
    repeat
      P1:=PData;Inc(P1,I*AItemSize);
      P2:=PData;Inc(P2,P*AItemSize);
      while ACompareFunction(P1, P2, AUserParameter) < 0 do
      begin
        Inc(I);
        Inc(P1,AItemSize);
      end;
      P1:=PData;Inc(P1,J*AItemSize);
      //P2:=PData;Inc(P2,P*AItemSize); already done
      while ACompareFunction(P1, P2, AUserParameter) > 0 do
      begin
        Dec(J);
        Dec(P1,AItemSize);
      end;
      if I <= J then
      begin
        P1:=PData;Inc(P1,I*AItemSize);
        P2:=PData;Inc(P2,J*AItemSize);
        Move(P2^, Tmp[0], AItemSize);
        Move(P1^, P2^, AItemSize);
        Move(Tmp[0], P1^, AItemSize);

        if P = I then
          P := J
        else if P = J then
          P := I;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if AFirstItem < J then QuickSort(AData,AFirstItem,J,AItemSize,ACompareFunction,AUserParameter);
    AFirstItem := I;
  until I >= ALastItem;
end;

function DichotomyFind(var AData,AKey;AFirstItem,ALastItem:Int64;AItemSize:Integer;ACompareFunction:TCompareFunction;AUserParameter:Pointer=nil): Integer;
{ Searches for the first item <= Key, returns True if exact match,
  sets index to the index of the found string. }
var
  I,L,R,Dir: Integer;
  PData,PKey,P: PByte;
begin
  // Use binary search.
  L := AFirstItem;
  R := ALastItem;
  PData:=PByte(@AData);
  PKey:=PByte(@AKey);
  while L<=R do
  begin
    I := L + (R - L) div 2;
    P := PData; Inc(P, I * AItemSize);
    Dir := ACompareFunction(P, PKey, AUserParameter);
    if Dir < 0 then
      L := I+1
    else begin
      R := I-1;
      if Dir = 0 then
        L := I;
    end;
  end;
  Result := L;
  if not InRange(Result, AFirstItem, ALastItem) then
    Result := -1;
end;

const
  READ_BYTES = 65536; // not too small to avoid fragmentation when reading large files.

// helperfunction that does the bulk of the work.
// We need to also collect stderr output in order to avoid
// lock out if the stderr pipe is full.
function internalRuncommand(p:TProcess;var outputstring:string;
                            var stderrstring:string; var exitstatus:integer; PrintOut: Boolean):integer;
var
    numbytes,bytesread,available : integer;
    outputlength, stderrlength : integer;
    stderrnumbytes,stderrbytesread, PrintLastPos, prp : integer;
begin
  result:=-1;
  try
    try
    p.Options :=  [poUsePipes];
    bytesread:=0;
    outputlength:=0;
    stderrbytesread:=0;
    stderrlength:=0;
    PrintLastPos:=1;
    p.Execute;
    while p.Running do
      begin
        // Only call ReadFromStream if Data from corresponding stream
        // is already available, otherwise, on  linux, the read call
        // is blocking, and thus it is not possible to be sure to handle
        // big data amounts bboth on output and stderr pipes. PM.
        available:=P.Output.NumBytesAvailable;
        if  available > 0 then
          begin
            if (BytesRead + available > outputlength) then
              begin
                outputlength:=BytesRead + READ_BYTES;
                Setlength(outputstring,outputlength);
              end;
            NumBytes := p.Output.Read(outputstring[1+bytesread], available);

            // output to screen
            prp := Pos(#10, Copy(outputstring, PrintLastPos, bytesread - PrintLastPos + NumBytes));
            if PrintOut and (prp <> 0) then
            begin
              Write(Copy(outputstring, PrintLastPos, prp));
              PrintLastPos += prp;
            end;

            if NumBytes > 0 then
              Inc(BytesRead, NumBytes);
          end
        // The check for assigned(P.stderr) is mainly here so that
        // if we use poStderrToOutput in p.Options, we do not access invalid memory.
        else if assigned(P.stderr) and (P.StdErr.NumBytesAvailable > 0) then
          begin
            available:=P.StdErr.NumBytesAvailable;
            if (StderrBytesRead + available > stderrlength) then
              begin
                stderrlength:=StderrBytesRead + READ_BYTES;
                Setlength(stderrstring,stderrlength);
              end;
            StderrNumBytes := p.StdErr.Read(stderrstring[1+StderrBytesRead], available);

            if StderrNumBytes > 0 then
              Inc(StderrBytesRead, StderrNumBytes);
          end
        else
          Sleep(10);
      end;

    if PrintOut then
      Write(Copy(stderrstring, PrintLastPos, StderrBytesRead - PrintLastPos));

    // Get left output after end of execution
    available:=P.Output.NumBytesAvailable;
    while available > 0 do
      begin
        if (BytesRead + available > outputlength) then
          begin
            outputlength:=BytesRead + READ_BYTES;
            Setlength(outputstring,outputlength);
          end;
        NumBytes := p.Output.Read(outputstring[1+bytesread], available);
        if NumBytes > 0 then
          Inc(BytesRead, NumBytes);
        available:=P.Output.NumBytesAvailable;
      end;
    setlength(outputstring,BytesRead);
    while assigned(P.stderr) and (P.Stderr.NumBytesAvailable > 0) do
      begin
        available:=P.Stderr.NumBytesAvailable;
        if (StderrBytesRead + available > stderrlength) then
          begin
            stderrlength:=StderrBytesRead + READ_BYTES;
            Setlength(stderrstring,stderrlength);
          end;
        StderrNumBytes := p.StdErr.Read(stderrstring[1+StderrBytesRead], available);
        if StderrNumBytes > 0 then
          Inc(StderrBytesRead, StderrNumBytes);
      end;
    setlength(stderrstring,StderrBytesRead);
    exitstatus:=p.exitstatus;
    result:=0; // we came to here, document that.
    except
      on e : Exception do
         begin
           result:=1;
           setlength(outputstring,BytesRead);
         end;
     end;
  finally
    p.free;
  end;
end;

procedure LZCompress(ASourceStream: TStream; PrintProgress, Decompress: Boolean; ADestStream: TStream);
var
  Process: TProcess;
  RetCode: Integer;
  Output, ErrOut, SrcFN, DstFN: String;
  SrcStream, DstStream: TFileStream;
begin
  Process := TProcess.Create(nil);
  Process.CurrentDirectory := ExtractFilePath(ParamStr(0));
  Process.Executable := 'lzma.exe';

  SrcFN := GetTempFileName('', 'lz-' + IntToStr(GetCurrentThreadId) + '.dat');
  DstFN := ChangeFileExt(SrcFN, ExtractFileExt(SrcFN) + '.lzma');

  SrcStream := TFileStream.Create(SrcFN, fmCreate or fmShareDenyWrite);
  try
    ASourceStream.Seek(0, soBeginning);
    SrcStream.CopyFrom(ASourceStream, ASourceStream.Size);
  finally
    SrcStream.Free;
  end;

  if Decompress then
    Process.Parameters.Add('d "' + SrcFN + '" "' + DstFN + '"')
  else
    Process.Parameters.Add('e "' + SrcFN + '" "' + DstFN + '" -lc0 -pb1');
  Process.ShowWindow := swoHIDE;
  Process.Priority := ppIdle;

  RetCode := 0;
  internalRuncommand(Process, Output, ErrOut, RetCode, PrintProgress); // destroys Process

  DstStream := TFileStream.Create(DstFN, fmOpenRead or fmShareDenyWrite);
  try
    ADestStream.CopyFrom(DstStream, DstStream.Size);
  finally
    DstStream.Free;
  end;

  DeleteFile(PChar(SrcFN));
  DeleteFile(PChar(DstFN));
end;

procedure DoExternalSKLearn(Dataset: TDoubleDynArray2; ClusterCount, Precision: Integer; Compiled, PrintProgress: Boolean;
  var Clusters: TIntegerDynArray; var Centroids: TDoubleDynArray2);
var
  i, j, st: Integer;
  InFN, Line, Output, ErrOut: String;
  SL, Shuffler, LineParser: TStringList;
  Process: TProcess;
  OutputStream: TMemoryStream;
  pythonExe: array[0..MAX_PATH-1] of Char;
begin
  SL := TStringList.Create;
  Shuffler := TStringList.Create;
  LineParser := TStringList.Create;
  OutputStream := TMemoryStream.Create;
  try
    for i := 0 to High(Dataset) do
    begin
      Line := IntToStr(i) + ' ';
      for j := 0 to High(Dataset[0]) do
        Line := Line + FloatToStr(Dataset[i, j]) + ' ';
      SL.Add(Line);
    end;

    InFN := GetTempFileName('', 'dataset-'+IntToStr(InterLockedIncrement(GTempAutoInc))+'.txt');
    SL.SaveToFile(InFN);
    SL.Clear;

    Process := TProcess.Create(nil);
    Process.CurrentDirectory := ExtractFilePath(ParamStr(0));

    if Compiled then
    begin
      Process.Executable := 'cluster.exe';
    end
    else
    begin
      if SearchPath(nil, 'python.exe', nil, MAX_PATH, pythonExe, nil) = 0 then
        pythonExe := 'python.exe';
      Process.Executable := pythonExe;
    end;

    for i := 0 to GetEnvironmentVariableCount - 1 do
      Process.Environment.Add(GetEnvironmentString(i));
    Process.Environment.Add('MKL_NUM_THREADS=1');
    Process.Environment.Add('NUMEXPR_NUM_THREADS=1');
    Process.Environment.Add('OMP_NUM_THREADS=1');

    if not Compiled then
      Process.Parameters.Add('cluster.py');
    Process.Parameters.Add('-i "' + InFN + '" -n ' + IntToStr(ClusterCount) + ' -t ' + FloatToStr(intpower(10.0, -Precision + 1)));
    if PrintProgress then
      Process.Parameters.Add('-d');
    Process.ShowWindow := swoHIDE;
    Process.Priority := ppIdle;

    st := 0;
    internalRuncommand(Process, Output, ErrOut, st, PrintProgress); // destroys Process

    SL.LoadFromFile(InFN + '.membership');

    SetLength(Clusters, SL.Count);
    for i := 0 to SL.Count - 1 do
    begin
      Line := SL[i];
      Clusters[i] := StrToIntDef(Line, -1);
    end;

    SL.LoadFromFile(InFN + '.cluster_centres');

    LineParser.Delimiter := ' ';
    SetLength(Centroids, SL.Count, Length(Dataset[0]));
    for j := 0 to SL.Count - 1 do
    begin
      LineParser.DelimitedText := SL[j];
      for i := 0 to LineParser.Count - 1 do
        Centroids[j, i] := StrToFloatDef(LineParser[i], 0.0, InvariantFormatSettings);
    end;

    DeleteFile(PChar(InFN));
    DeleteFile(PChar(InFN + '.membership'));
    DeleteFile(PChar(InFN + '.cluster_centres'));

  finally
    OutputStream.Free;
    Shuffler.Free;
    SL.Free;
  end;
end;

procedure DoExternalSOX(AFNIn, AFNOut: String; SampleRate: Integer; ForceMono: Boolean);
var
  i: Integer;
  Params, Output, ErrOut: String;
  Process: TProcess;
begin
  Process := TProcess.Create(nil);

  Process.CurrentDirectory := ExtractFilePath(ParamStr(0));
  Process.Executable := 'sox\sox.exe';

  Params := '';
  Params += '"' + AFNIn + '" ';
  if ForceMono then
    Params += '-c 1 ';
  Params += '"' + AFNOut + '"';
  if SampleRate > 0 then
    Params += ' rate -v ' + IntToStr(SampleRate);
  Process.Parameters.Add(Params);

  Process.ShowWindow := swoHIDE;
  Process.Priority := ppNormal;

  i := 0;
  internalRuncommand(Process, Output, ErrOut, i, False); // destroys Process
end;

function DoExternalEAQUAL(AFNRef, AFNTest: String; PrintStats, UseDIX: Boolean; BlockLength: Integer): Double;
var
  i: Integer;
  Line, Output, ErrOut, SilFN: String;
  OutSL: TStringList;
  Process: TProcess;
  OutputStream: TMemoryStream;
begin
  SilFN := GetTempFileName('', 'silent-'+IntToStr(GetCurrentThreadId)+'.txt');

  Process := TProcess.Create(nil);
  OutSL := TStringList.Create;
  OutputStream := TMemoryStream.Create;
  try
    Process.CurrentDirectory := ExtractFilePath(ParamStr(0));
    Process.Executable := 'eaqual.exe';
    Process.Parameters.Add('-fref "' + AFNRef + '" -ftest "' + AFNTest + '"' + ifthen(BlockLength > 0, ' -blklen ' + IntToStr(BlockLength)));
    if not PrintStats then
      Process.Parameters.Add('-silent "' + SilFN + '"');
    Process.ShowWindow := swoHIDE;
    Process.Priority := ppIdle;

    i := 0;
    internalRuncommand(Process, Output, ErrOut, i, False); // destroys Process

    Result := -10.0;
    if PrintStats or not FileExists(SilFN) then
    begin
      OutSL.LineBreak := #13#10;
      OutSL.Text := Output;
      WriteLn(Output);
      WriteLn(ErrOut);

      for i := 0 to OutSL.Count - 1 do
      begin
        Line := OutSL[i];
        if (Pos('Resulting ODG:', Line) = 1) and not UseDIX or (Pos('Resulting DIX:', Line) = 1) and UseDIX then
        begin
          TryStrToFloat(RightStr(Line, Pos(#9, ReverseString(Line)) - 1), Result);
          Break;
        end;
      end;
    end
    else
    begin
      OutSL.LineBreak := #10;
      OutSL.LoadFromFile(SilFN);
      Line := OutSL[2];
      OutSL.Delimiter := #9;
      OutSL.DelimitedText := Line;
      TryStrToFloat(OutSL[Ord(UseDIX)], Result);
    end;

    DeleteFile(SilFN);

  finally
    OutputStream.Free;
    OutSL.Free;
  end;
end;

procedure GenerateSVMLightData(Dataset: TDoubleDynArray2; Output: TStringList; Header: Boolean);
var
  i, j, cnt: Integer;
  Line: String;
begin
  Output.Clear;
  Output.LineBreak := sLineBreak;

  if Header then
  begin
    Output.Add('1 # m');
    Output.Add(IntToStr(Length(Dataset)) + ' # k');
    Output.Add(IntToStr(Length(Dataset[0])) + ' # number of features');
  end;

  for i := 0 to High(Dataset) do
  begin
    Line := Format('%d ', [i], GInvariantFormatSettings);

    cnt := Length(Dataset[i]);
    j := 0;

    while cnt > 16 do
    begin
      Line := Format('%s %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f %d:%.12f',
        [
          Line,
          j + 1,  Dataset[i, j + 0],  j + 2,  Dataset[i, j + 1],  j + 3,  Dataset[i, j + 2],  j + 4,  Dataset[i, j + 3],
          j + 5,  Dataset[i, j + 4],  j + 6,  Dataset[i, j + 5],  j + 7,  Dataset[i, j + 6],  j + 8,  Dataset[i, j + 7],
          j + 9,  Dataset[i, j + 8],  j + 10, Dataset[i, j + 9],  j + 11, Dataset[i, j + 10], j + 12, Dataset[i, j + 11],
          j + 13, Dataset[i, j + 12], j + 14, Dataset[i, j + 13], j + 15, Dataset[i, j + 14], j + 16, Dataset[i, j + 15]
        ],
        GInvariantFormatSettings);
      Dec(cnt, 16);
      Inc(j, 16);
    end;

    while cnt > 0 do
    begin
      Line := Format('%s %d:%.12f', [Line, j + 1,  Dataset[i, j]], GInvariantFormatSettings);
      Dec(cnt);
      Inc(j);
    end;

    Output.Add(Line);
  end;
end;

function GenerateSVMLightFile(Dataset: TDoubleDynArray2; Header: Boolean): String;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    GenerateSVMLightData(Dataset, SL, Header);

    Result := GetTempFileName('', 'dataset-'+IntToStr(InterLockedIncrement(GTempAutoInc))+'.txt');

    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

function GetLineInt(line: String): Integer;
begin
  Result := StrToInt(copy(line, 1, Pos(' ', line) - 1));
end;

function GetSVMLightLine(index: Integer; lines: TStringList): TDoubleDynArray;
var
  i, p, np, clusterCount, restartCount: Integer;
  line, val, sc: String;

begin
  // TODO: so far, only compatible with YAKMO centroids

  restartCount := GetLineInt(lines[0]);
  clusterCount := GetLineInt(lines[1]);
  SetLength(Result, GetLineInt(lines[2]) + 1);

  Assert(InRange(index, 0, clusterCount - 1), 'wrong index!');

  line := lines[3 + clusterCount * (restartCount - 1) + index];
  for i := 0 to High(Result) do
  begin
    sc := ' ' + IntToStr(i) + ':';

    p := Pos(sc, line);
    if p = 0 then
    begin
      Result[i] := 0.0; //svmlight zero elimination
    end
    else
    begin
      p += Length(sc);

      np := PosEx(' ', line, p);
      if np = 0 then
        np := Length(line) + 1;
      val := Copy(line, p, np - p);

      //writeln(i, #9 ,index,#9,p,#9,np,#9, val);

      if Pos('nan', val) = 0 then
        Result[i] := StrToFloat(val, GInvariantFormatSettings)
      else
        Result[i] := abs(NaN); // Quiet NaN
    end;
  end;
end;

function GetSVMLightClusterCount(lines: TStringList): Integer;
begin
  Result := GetLineInt(lines[1]);
end;

function InvariantFormatSettings: TFormatSettings;
begin
  Result := GInvariantFormatSettings;
end;

function EuclideanToPSNR(AEuclidean: Double): Double;
begin
  Result := cBestPSNR - 10.0 * Log10(Max(1.0, AEuclidean));
end;

function PSNRToEuclidean(APSNR: Double): Double;
begin
  Result := Power(10.0, (cBestPSNR - APSNR) * 0.1);
end;

{ TKRng }

procedure TKRng.init();
begin
  x := 123456789;
  y := 362436069;
  z := 521288629;
  w := 88675123;
end;

function TKRng.randInt(): UInt64;
var
  t: UInt64;
begin
  t := (x xor (x shl 11)); x := y; y := z; z := w;
  w := (w xor (w shr 19)) xor (t xor (t shr 8));
  Result := w;
end;

function TKRng.random: Double;
begin
  Result := randInt() / High(UInt64);
end;

function GridReduceMinimize(Func: TEvalFunc; var X: TDoubleDynArray; GridSize: array of Integer;
 GridExtents: array of Double; EpsilonReduce: Double; VerboseTag: String; Data: Pointer): Double;
var
  XBestFunc, bestX: TDoubleDynArray;
  reduce: TDoubleDynArray;

  procedure DoX(AIndex: Integer);
  var
    iX: Integer;
    gs, iGrid: Integer;
    f: Double;
    lX: TDoubleDynArray;
  begin
    iX := AIndex;
    if IsZero(reduce[iX], EpsilonReduce) then
      Exit;

    lX := Copy(X);
    gs := GridSize[iX];

    for iGrid := -gs to gs - 1 do
    begin
      lX[iX] := X[iX] + lerp(-GridExtents[iX], GridExtents[iX], (iGrid + gs) / (2 * gs)) * reduce[iX];

      f := Func(lX, data);

      if f < XBestFunc[iX] then
      begin
        XBestFunc[iX] := f;
        bestX[iX] := lX[iX];
      end;
    end;
  end;

var
  iter, iX: Integer;
  bestFunc: Double;
begin
  Assert(Length(X) = Length(GridSize));
  Assert(Length(X) = Length(GridExtents));

  SetLength(XBestFunc, Length(X));
  SetLength(bestX, Length(X));

  SetLength(reduce, Length(X));
  for iX := 0 to High(X) do
    reduce[iX] := 1.0;

  iter := 0;
  repeat

    for iX := 0 to High(X) do
    begin
      bestX[iX] := X[iX];
      XBestFunc[iX] := Infinity;
    end;

    for iX := 0 to High(X) do
      DoX(iX);

    Inc(iter);
    bestFunc := MinValue(XBestFunc);

    for iX := 0 to High(X) do
      if XBestFunc[iX] = bestFunc then
      begin
        X[iX] := bestX[iX];
        reduce[iX] *= cInvPhi;

        if VerboseTag <> '' then
          WriteLn(VerboseTag, ', Iter:', iter:4, ', BestX:', iX:4, ', Reduce:', reduce[iX]:12:9, ', Func:', bestFunc:20:9);
      end;

  until IsZero(MaxValue(reduce), EpsilonReduce);

  Result := bestFunc;
end;

initialization
  GetLocaleFormatSettings(LOCALE_INVARIANT, GInvariantFormatSettings);
  GNumberOfProcessors := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
end.

