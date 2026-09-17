program nvidia_norandr;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, CRT, Process, RegExpr;

type
  TResolution = record
    W, H: Integer;
  end;

const
  ConfPath = '/etc/X11/xorg.conf';
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
  HorizStr, VertStr: string;
  Focus, ListIndex: Integer;
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

procedure LoadCurrentValues;
var
  SL: TStringList;
  re: TRegExpr;
  i, j, w, h, FoundIdx: Integer;
begin
  if not FileExists(ConfPath) then Exit;
  SL := TStringList.Create;
  re := TRegExpr.Create;
  try
    try
      SL.LoadFromFile(ConfPath);
    except
      Exit;
    end;

    re.Expression := '^\s*HorizSync\s+(.*)$';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        HorizStr := Trim(re.Match[1]);
        Break;
      end;

    re.Expression := '^\s*VertRefresh\s+(.*)$';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        VertStr := Trim(re.Match[1]);
        Break;
      end;

    re.Expression := 'Option\s+"metamodes"\s+"(\d+)x(\d+)';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        w := StrToIntDef(re.Match[1], 0);
        h := StrToIntDef(re.Match[2], 0);
        if (w > 0) and (h > 0) then
        begin
          FoundIdx := -1;
          for j := Low(CommonRes) to High(CommonRes) do
            if (CommonRes[j].W = w) and (CommonRes[j].H = h) then
            begin
              FoundIdx := j;
              Break;
            end;
          if FoundIdx >= 0 then ListIndex := FoundIdx;
        end;
        Break;
      end;

    MessageStr := 'Loaded current ' + ConfPath;
  finally
    re.Free;
    SL.Free;
  end;
end;

function PatchConf(const SrcPath, HorizRange, VertRange, MetaMode: string;
  out ErrMsg: string): Boolean;
var
  SL: TStringList;
  re: TRegExpr;
  i: Integer;
  Changed: Boolean;
begin
  Result := False;
  ErrMsg := '';
  SL := TStringList.Create;
  re := TRegExpr.Create;
  try
    try
      SL.LoadFromFile(SrcPath);
    except
      on E: Exception do
      begin
        ErrMsg := E.Message;
        Exit;
      end;
    end;

    Changed := False;

    re.Expression := '^(\s*HorizSync\s+).*$';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        SL[i] := re.Match[1] + HorizRange;
        Changed := True;
      end;

    re.Expression := '^(\s*VertRefresh\s+).*$';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        SL[i] := re.Match[1] + VertRange;
        Changed := True;
      end;

    re.Expression := '^(\s*Option\s+"metamodes"\s+")[^"]*(".*)$';
    for i := 0 to SL.Count - 1 do
      if re.Exec(SL[i]) then
      begin
        SL[i] := re.Match[1] + MetaMode + re.Match[2];
        Changed := True;
      end;

    if not Changed then
    begin
      ErrMsg := 'No HorizSync/VertRefresh/metamodes lines found.';
      Exit;
    end;

    try
      SL.SaveToFile(SrcPath);
      Result := True;
    except
      on E: Exception do
        ErrMsg := E.Message;
    end;
  finally
    re.Free;
    SL.Free;
  end;
end;

function WriteNvidiaTemplate(const HorizRange, VertRange, MetaMode: string;
  out ErrMsg: string): Boolean;
var
  SL: TStringList;
begin
  Result := False;
  ErrMsg := '';
  SL := TStringList.Create;
  try
    SL.Add('# nvidia-norandr: X configuration file');
    SL.Add('');
    SL.Add('Section "ServerLayout"');
    SL.Add('    Identifier     "Layout0"');
    SL.Add('    Screen      0  "Screen0" 0 0');
    SL.Add('    InputDevice    "Keyboard0" "CoreKeyboard"');
    SL.Add('    InputDevice    "Mouse0" "CorePointer"');
    SL.Add('    Option         "Xinerama" "0"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Files"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "InputDevice"');
    SL.Add('    Identifier     "Mouse0"');
    SL.Add('    Driver         "mouse"');
    SL.Add('    Option         "Protocol" "auto"');
    SL.Add('    Option         "Device" "/dev/psaux"');
    SL.Add('    Option         "Emulate3Buttons" "no"');
    SL.Add('    Option         "ZAxisMapping" "4 5"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "InputDevice"');
    SL.Add('    Identifier     "Keyboard0"');
    SL.Add('    Driver         "kbd"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Monitor"');
    SL.Add('    Identifier     "Monitor0"');
    SL.Add('    VendorName     "Unknown"');
    SL.Add('    ModelName      "CRT-1"');
    SL.Add('    HorizSync       ' + HorizRange);
    SL.Add('    VertRefresh     ' + VertRange);
    SL.Add('    Option         "DPMS"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Device"');
    SL.Add('    Identifier     "Device0"');
    SL.Add('    Driver         "nvidia"');
    SL.Add('    VendorName     "NVIDIA Corporation"');
    SL.Add('EndSection');
    SL.Add('');
    SL.Add('Section "Screen"');
    SL.Add('    Identifier     "Screen0"');
    SL.Add('    Device         "Device0"');
    SL.Add('    Monitor        "Monitor0"');
    SL.Add('    DefaultDepth    24');
    SL.Add('    Option         "Stereo" "0"');
    SL.Add('    Option         "nvidiaXineramaInfoOrder" "CRT-1"');
    SL.Add('    Option         "metamodes" "' + MetaMode + '"');
    SL.Add('    Option         "SLI" "Off"');
    SL.Add('    Option         "MultiGPU" "Off"');
    SL.Add('    Option         "BaseMosaic" "off"');
    SL.Add('    SubSection     "Display"');
    SL.Add('        Depth       24');
    SL.Add('    EndSubSection');
    SL.Add('EndSection');

    try
      SL.SaveToFile(ConfPath);
      Result := True;
    except
      on E: Exception do
        ErrMsg := E.Message;
    end;
  finally
    SL.Free;
  end;
end;

procedure WriteConfigAction;
var
  Err, MetaMode, Backup, Dummy: string;
begin
  if (Trim(HorizStr) = '') or (Trim(VertStr) = '') then
  begin
    MessageStr := 'HorizSync and VertRefresh are required.';
    Exit;
  end;

  MetaMode := IntToStr(CommonRes[ListIndex].W) + 'x' +
              IntToStr(CommonRes[ListIndex].H) + ' +0 +0';

  if FileExists(ConfPath) then
  begin
    Backup := ConfPath + '.bak.' + FormatDateTime('yyyymmddhhnnss', Now);
    RunCommand('cp -a ' + QuotedStr(ConfPath) + ' ' + QuotedStr(Backup), Dummy);
    if not PatchConf(ConfPath, HorizStr, VertStr, MetaMode, Err) then
    begin
      MessageStr := 'Patch failed: ' + Err;
      Exit;
    end;
  end
  else
  begin
    if not WriteNvidiaTemplate(HorizStr, VertStr, MetaMode, Err) then
    begin
      MessageStr := 'Write failed: ' + Err;
      Exit;
    end;
  end;

  MessageStr := 'Wrote ' + ConfPath + '  "' + MetaMode + '"';
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
  MessageStr := 'Restart attempted.';
end;

procedure DrawScreen;
var
  Row, Col, Idx: Integer;
  ResTxt, MetaMode: string;
begin
  ClrScr;

  TextColor(LightCyan);
  WriteLn(' nvidia-norandr - nvidia xorg.conf writer');
  TextColor(LightGray);
  WriteLn(' Writes ', ConfPath);
  WriteLn;

  Write(' HorizSync:   ');
  if Focus = 0 then TextColor(Yellow) else TextColor(LightGray);
  WriteLn('[', HorizStr, ']');

  TextColor(LightGray);
  Write(' VertRefresh: ');
  if Focus = 1 then TextColor(Yellow) else TextColor(LightGray);
  WriteLn('[', VertStr, ']');

  TextColor(LightGray);
  WriteLn;

  TextColor(LightCyan);
  WriteLn(' Resolution (arrows to move, Enter to apply):');
  TextColor(LightGray);

  for Row := 0 to 2 do
  begin
    Write('  ');
    for Col := 0 to 3 do
    begin
      Idx := Row * 4 + Col;
      if Idx > High(CommonRes) then Break;

      if Idx = ListIndex then
      begin
        if Focus = 2 then TextColor(Yellow) else TextColor(LightGreen);
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

  MetaMode := IntToStr(CommonRes[ListIndex].W) + 'x' +
              IntToStr(CommonRes[ListIndex].H) + ' +0 +0';
  TextColor(LightCyan);
  Write(' metamodes: ');
  TextColor(LightGray);
  WriteLn('"', MetaMode, '"');
  WriteLn;

  TextColor(LightCyan);
  Write(' Status: ');
  TextColor(LightGray);
  WriteLn(MessageStr);
  WriteLn;

  TextColor(LightGray);
  WriteLn(' Tab: field  Arrows: nav  Enter: apply  W: write  R: restart  Q: quit');
end;

procedure ApplyResolutionFromList;
begin
  MessageStr := 'Selected ' + IntToStr(CommonRes[ListIndex].W) + 'x' +
                IntToStr(CommonRes[ListIndex].H) + '.';
end;

procedure HandleExtendedKey(K: Char);
begin
  case K of
    #72: // Up
      if (Focus = 2) and (ListIndex >= 4) then
        Dec(ListIndex, 4);
    #80: // Down
      if (Focus = 2) and (ListIndex + 4 <= High(CommonRes)) then
        Inc(ListIndex, 4);
    #75: // Left
      if Focus = 2 then
      begin
        if (ListIndex mod 4) > 0 then Dec(ListIndex);
      end
      else if Focus > 0 then
        Dec(Focus);
    #77: // Right
      if Focus = 2 then
      begin
        if ((ListIndex mod 4) < 3) and (ListIndex < High(CommonRes)) then
          Inc(ListIndex);
      end
      else if Focus < 2 then
        Inc(Focus);
  end;
end;

procedure HandleKey(K: Char);
begin
  case K of
    #9:  Focus := (Focus + 1) mod 3;
    #15: Focus := (Focus + 2) mod 3;

    #13:
      if Focus = 2 then
        ApplyResolutionFromList
      else
        Focus := (Focus + 1) mod 3;

    #8:
      if Focus = 0 then
      begin
        if HorizStr <> '' then Delete(HorizStr, Length(HorizStr), 1);
      end
      else if Focus = 1 then
      begin
        if VertStr <> '' then Delete(VertStr, Length(VertStr), 1);
      end;

    'w', 'W': WriteConfigAction;
    'r', 'R': RestartDisplayManagerAction;
    'q', 'Q': Quit := True;
  else
    if (Focus in [0, 1]) and (K >= #32) and (K <= #126) then
    begin
      if Focus = 0 then
        HorizStr := HorizStr + K
      else
        VertStr := VertStr + K;
    end;
  end;
end;

var
  K: Char;

begin
  HorizStr := '30.0 - 80.0';
  VertStr := '55.0 - 75.0';
  Focus := 0;
  ListIndex := 9; // 1920x1080

  MessageStr := 'Ready. W writes ' + ConfPath;
  LoadCurrentValues;

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