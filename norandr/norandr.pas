program norandr;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, CRT, Process, RegExpr, FileUtil;

type
  TResolution = record
    W, H: Integer;
  end;

const
  ConfPath = '/etc/X11/xorg.conf.d/10-monitor.conf';
  CommonRes: array[0..11] of TResolution = (
    (W: 640;  H: 480),
    (W: 800;  H: 600),
    (W: 1024; H: 768),
    (W: 1280; H: 720),
    (W: 1280; H: 1024),
    (W: 1366; H: 768),
    (W: 1440; H: 900),
    (W: 1600; H: 900),
    (W: 1680; H: 1050),
    (W: 1920; H: 1080),
    (W: 1920; H: 1200),
    (W: 2560; H: 1440)
  );

var
  WidthStr, HeightStr, RefreshStr: string;
  Focus, ListIndex: Integer;
  CvtHeader, CvtName, CvtParams: string;
  DispName, DriverName, PciAddr: string;
  MessageStr: string;
  Quit: Boolean;

function RunCommand(const Cmd: string; out Output: string): Integer;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  N: LongInt;
begin
  Output := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Cmd);
    P.Options := [poUsePipes, poStderrToOutPut, poWaitOnExit];
    P.Execute;

    repeat
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Output, Length(Output) + N);
        Move(Buf[0], Output[Length(Output) - N + 1], N);
      end;
    until N = 0;

    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

procedure SplitLines(const S: string; Lines: TStrings);
var
  i, Start: Integer;
  Line: string;
begin
  Lines.Clear;
  Start := 1;

  for i := 1 to Length(S) do
    if S[i] = #10 then
    begin
      Line := Copy(S, Start, i - Start);
      if (Line <> '') and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
      Lines.Add(Line);
      Start := i + 1;
    end;

  if Start <= Length(S) then
  begin
    Line := Copy(S, Start, MaxInt);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    Lines.Add(Line);
  end;
end;

function ExtractDisplayName(const Path: string; out Disp: string): Boolean;
var
  re: TRegExpr;
  Base: string;
begin
  Base := ExtractFileName(ExtractFileDir(Path));

  re := TRegExpr.Create('^card[0-9]+-(.+)$');
  try
    Result := re.Exec(Base);
    if Result then
      Disp := re.Match[1]
    else
      Disp := '';
  finally
    re.Free;
  end;
end;

function FindActiveDisplay(out DispName: string): Boolean;
var
  OutStr, Path, Status, Candidate: string;
  Lines: TStringList;
  i: Integer;
  ConnectedFound, OtherFound: Boolean;
  ConnectedName, OtherName: string;
begin
  DispName := '';
  RunCommand('ls -1 /sys/class/drm/card*-*/status 2>/dev/null', OutStr);

  Lines := TStringList.Create;
  try
    SplitLines(OutStr, Lines);

    ConnectedFound := False;
    OtherFound := False;
    ConnectedName := '';
    OtherName := '';

    for i := 0 to Lines.Count - 1 do
    begin
      Path := Trim(Lines[i]);
      if Path = '' then
        Continue;

      RunCommand('cat ' + QuotedStr(Path), Status);
      Status := Trim(Status);

      if not ExtractDisplayName(Path, Candidate) then
        Continue;

      if Status = 'connected' then
      begin
        ConnectedName := Candidate;
        ConnectedFound := True;
        Break;
      end
      else if (Status <> 'disconnected') and (not OtherFound) then
      begin
        OtherName := Candidate;
        OtherFound := True;
      end;
    end;

    if ConnectedFound then
    begin
      DispName := ConnectedName;
      Result := True;
    end
    else if OtherFound then
    begin
      DispName := OtherName;
      Result := True;
    end
    else
      Result := False;
  finally
    Lines.Free;
  end;
end;

function KernelToXorgDriver(const K: string): string;
begin
  if K = 'i915' then
    Result := 'intel'
  else if K = 'nvidia' then
    Result := 'nvidia'
  else if K = 'nouveau' then
    Result := 'nouveau'
  else if K = 'amdgpu' then
    Result := 'amdgpu'
  else if K = 'radeon' then
    Result := 'radeon'
  else
    Result := K;
end;

function FindDriver(out Driver: string; out PciAddr: string): Boolean;
var
  OutStr, FirstLine, KernelDrv: string;
  Lines: TStringList;
  re: TRegExpr;
begin
  Driver := '';
  PciAddr := '';

  RunCommand('lspci | grep -i VGA', OutStr);
  if Trim(OutStr) = '' then
    RunCommand('lspci | grep -iE "VGA|3D|Display"', OutStr);

  Lines := TStringList.Create;
  try
    SplitLines(OutStr, Lines);

    if Lines.Count = 0 then
      Exit(False);

    FirstLine := Lines[0];

    re := TRegExpr.Create('^([0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f])');
    try
      if not re.Exec(FirstLine) then
        Exit(False);
      PciAddr := re.Match[1];
    finally
      re.Free;
    end;
  finally
    Lines.Free;
  end;

  RunCommand('lspci -vv -s ' + PciAddr, OutStr);

  re := TRegExpr.Create('Kernel driver in use:\s*(\S+)');
  try
    if re.Exec(OutStr) then
    begin
      KernelDrv := re.Match[1];
      Driver := KernelToXorgDriver(KernelDrv);
    end
    else
      Driver := 'modesetting';

    Result := True;
  finally
    re.Free;
  end;
end;

function WriteXorgConf(const DispName, ModelineName, ModelineParams,
  Driver: string; out ErrMsg: string): Boolean;
var
  SL: TStringList;
  ConfDir, Backup, Dummy: string;
begin
  Result := False;
  ErrMsg := '';

  ConfDir := ExtractFileDir(ConfPath);

  if not DirectoryExists(ConfDir) then
  begin
    if not ForceDirectories(ConfDir) then
    begin
      ErrMsg := 'Cannot create directory: ' + ConfDir;
      Exit;
    end;
  end;

  if FileExists(ConfPath) then
  begin
    Backup := ConfPath + '.bak.' + FormatDateTime('yyyymmddhhnnss', Now);
    RunCommand('cp -a ' + QuotedStr(ConfPath) + ' ' + QuotedStr(Backup), Dummy);
  end;

  SL := TStringList.Create;
  try
    SL.Add('Section "Monitor"');
    SL.Add('    Identifier "' + DispName + '"');
    SL.Add('    Modeline "' + ModelineName + '" ' + ModelineParams);
    SL.Add('    Option "PreferredMode" "' + ModelineName + '"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Screen"');
    SL.Add('    Identifier "Screen0"');
    SL.Add('    Monitor "' + DispName + '"');
    SL.Add('    DefaultDepth 24');
    SL.Add('    SubSection "Display"');
    SL.Add('        Modes "' + ModelineName + '"');
    SL.Add('    EndSubSection');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Device"');
    SL.Add('    Identifier "Device0"');
    SL.Add('    Driver "' + Driver + '"');
    SL.Add('EndSection');

    try
      SL.SaveToFile(ConfPath);
      Result := True;
    except
      on E: Exception do
      begin
        ErrMsg := E.Message;
        Result := False;
      end;
    end;
  finally
    SL.Free;
  end;
end;

procedure CallCvt;
var
  Cmd, OutStr, Line: string;
  Lines: TStringList;
  i: Integer;
  re: TRegExpr;
  Name, Params, Header: string;
begin
  if (Trim(WidthStr) = '') or (Trim(HeightStr) = '') then
  begin
    MessageStr := 'Width and height are required.';
    Exit;
  end;

  Cmd := 'cvt ' + Trim(WidthStr) + ' ' + Trim(HeightStr);
  if Trim(RefreshStr) <> '' then
    Cmd := Cmd + ' ' + Trim(RefreshStr);

  RunCommand(Cmd, OutStr);

  Lines := TStringList.Create;
  try
    SplitLines(OutStr, Lines);

    Header := '';
    Name := '';
    Params := '';

    re := TRegExpr.Create('Modeline\s+"([^"]+)"\s+(.+)$');
    try
      for i := 0 to Lines.Count - 1 do
      begin
        Line := Trim(Lines[i]);

        if (Line <> '') and (Line[1] = '#') and (Header = '') then
          Header := Line;

        if re.Exec(Line) then
        begin
          Name := re.Match[1];
          Params := Trim(re.Match[2]);
          Break;
        end;
      end;
    finally
      re.Free;
    end;

    if Name <> '' then
    begin
      CvtHeader := Header;
      CvtName := Name;
      CvtParams := Params;
      MessageStr := 'cvt OK.';
    end
    else
    begin
      CvtHeader := '';
      CvtName := '';
      CvtParams := '';
      MessageStr := 'cvt failed: ' + Trim(OutStr);
    end;
  finally
    Lines.Free;
  end;
end;

procedure FindDisplayAction;
var
  D: string;
begin
  if FindActiveDisplay(D) then
  begin
    DispName := D;
    MessageStr := 'Display found: ' + D;
  end
  else
    MessageStr := 'No active display found.';
end;

procedure FindDriverAction;
var
  Drv, Pci: string;
begin
  if FindDriver(Drv, Pci) then
  begin
    DriverName := Drv;
    PciAddr := Pci;
    MessageStr := 'Driver: ' + Drv + '  PCI: ' + Pci;
  end
  else
    MessageStr := 'No VGA driver found.';
end;

procedure WriteConfigAction;
var
  Err: string;
begin
  if CvtName = '' then
  begin
    MessageStr := 'Call cvt first.';
    Exit;
  end;

  if DispName = '' then
  begin
    MessageStr := 'Find display first.';
    Exit;
  end;

  if DriverName = '' then
  begin
    MessageStr := 'Find driver first.';
    Exit;
  end;

  if WriteXorgConf(DispName, CvtName, CvtParams, DriverName, Err) then
    MessageStr := 'Wrote ' + ConfPath + '. Backup created if old file existed.'
  else
    MessageStr := 'Write failed: ' + Err;
end;

procedure RestartDisplayManagerAction;
var
  OutStr: string;
begin
  RunCommand(
    'systemctl restart display-manager 2>&1 || ' +
    'systemctl restart lightdm 2>&1 || ' +
    'systemctl restart gdm 2>&1 || ' +
    'systemctl restart sddm 2>&1',
    OutStr
  );
  MessageStr := 'Restart attempted: ' + Trim(OutStr);
end;


procedure DrawScreen;
var
  Row, Col, Idx: Integer;
  ResTxt: string;
begin
  ClrScr;

  TextColor(LightCyan);
  WriteLn(' Xorg Mode Tool');
  TextColor(LightGray);
  WriteLn(' Run as root. Writes ',ConfPath);
  WriteLn;

  Write(' Width: ');
  if Focus = 0 then TextColor(Yellow) else TextColor(LightGray);
  Write('[', WidthStr, ']');

  TextColor(LightGray);
  Write('   Height: ');
  if Focus = 1 then TextColor(Yellow) else TextColor(LightGray);
  Write('[', HeightStr, ']');

  TextColor(LightGray);
  Write('   Refresh: ');
  if Focus = 2 then TextColor(Yellow) else TextColor(LightGray);
  Write('[', RefreshStr, ']');

  TextColor(LightGray);
  WriteLn;
  WriteLn;

  TextColor(LightCyan);
  WriteLn(' Resolutions (arrows to navigate, Enter to apply):');

  for Row := 0 to 2 do
  begin
    Write('  ');
    for Col := 0 to 3 do
    begin
      Idx := Row * 4 + Col;
      if Idx > High(CommonRes) then
        Break;

      if Idx = ListIndex then
      begin
        if Focus = 3 then TextColor(Yellow) else TextColor(LightGreen);
        Write('>');
      end
      else
      begin
        TextColor(LightGray);
        Write(' ');
      end;

      ResTxt := IntToStr(CommonRes[Idx].W) + 'x' + IntToStr(CommonRes[Idx].H);
      Write(Format('%-10s', [ResTxt]));
    end;
    TextColor(LightGray);
    WriteLn;
  end;

  WriteLn;

  TextColor(LightCyan);
  Write(' CVT: ');
  TextColor(LightGray);
  if CvtHeader <> '' then
    WriteLn(CvtHeader)
  else
    WriteLn('(not called yet)');

  if CvtName <> '' then
    WriteLn('      Modeline "', CvtName, '" ', CvtParams);
  WriteLn;

  TextColor(LightCyan);
  Write(' Display: ');
  TextColor(LightGray);
  WriteLn(DispName, '   Driver: ', DriverName, '   PCI: ', PciAddr);
  WriteLn;

  TextColor(LightCyan);
  Write(' Messages: ');
  TextColor(LightGray);
  WriteLn(MessageStr);
  WriteLn;

  TextColor(LightGray);
  WriteLn(' Tab: field  Arrows: navigate  Enter: apply/call cvt');
  WriteLn(' C: cvt  F: find display  D: find driver  W: write  R: restart  Q: quit');
end;

procedure ApplyResolutionFromList;
begin
  WidthStr := IntToStr(CommonRes[ListIndex].W);
  HeightStr := IntToStr(CommonRes[ListIndex].H);
  MessageStr := 'Applied resolution from list.';
end;

procedure HandleExtendedKey(K: Char);
begin
  case K of
    #72: // Up
      if (Focus = 3) and (ListIndex >= 4) then
        Dec(ListIndex, 4);

    #80: // Down
      if (Focus = 3) and (ListIndex + 4 <= High(CommonRes)) then
        Inc(ListIndex, 4);

    #75: // Left
      if Focus = 3 then
      begin
        if (ListIndex mod 4) > 0 then
          Dec(ListIndex);
      end
      else if Focus > 0 then
        Dec(Focus);

    #77: // Right
      if Focus = 3 then
      begin
        if ((ListIndex mod 4) < 3) and (ListIndex < High(CommonRes)) then
          Inc(ListIndex);
      end
      else if Focus < 3 then
        Inc(Focus);
  end;
end;

procedure HandleKey(K: Char);
begin
  case K of
    #9:  Focus := (Focus + 1) mod 4;
    #15: Focus := (Focus + 3) mod 4;

    #13:
      if Focus = 3 then
        ApplyResolutionFromList
      else
        CallCvt;

    #8:
      if Focus in [0..2] then
      begin
        case Focus of
          0: if WidthStr <> '' then Delete(WidthStr, Length(WidthStr), 1);
          1: if HeightStr <> '' then Delete(HeightStr, Length(HeightStr), 1);
          2: if RefreshStr <> '' then Delete(RefreshStr, Length(RefreshStr), 1);
        end;
      end;

    'c', 'C': CallCvt;
    'f', 'F': FindDisplayAction;
    'd', 'D': FindDriverAction;
    'w', 'W': WriteConfigAction;
    'r', 'R': RestartDisplayManagerAction;
    'q', 'Q': Quit := True;
  else
    if (Focus in [0..2]) and (K in ['0'..'9']) then
    begin
      case Focus of
        0: WidthStr := WidthStr + K;
        1: HeightStr := HeightStr + K;
        2: RefreshStr := RefreshStr + K;
      end;
    end;
  end;
end;

var
  K: Char;

begin
  WidthStr := '1920';
  HeightStr := '1080';
  RefreshStr := '';
  Focus := 0;
  ListIndex := 9;

  CvtHeader := '';
  CvtName := '';
  CvtParams := '';

  DispName := '';
  DriverName := '';
  PciAddr := '';

  MessageStr := 'Ready.';
  Quit := False;

  repeat
    DrawScreen;
    K := ReadKey;

    if K = #0 then
    begin
      K := ReadKey;
      HandleExtendedKey(K);
    end
    else
      HandleKey(K);
  until Quit;

  ClrScr;
  WriteLn('Bye.');
end.
