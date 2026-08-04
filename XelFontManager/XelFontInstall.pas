unit XelFontInstall;

// XelFontManager — makes an sfnt font usable by the running process without
// installing it into the system.
//
//   Windows : AddFontResourceExW(..., FR_PRIVATE) on a temporary file, or
//             AddFontMemResourceEx straight from memory.
//   Unix    : FcConfigAppFontAddFile through libfontconfig, loaded lazily.
//             Requires a file on disk, so a temporary one is always written.
//   Other   : not implemented — the temporary file is still produced so the
//             caller can do something else with it.
//
// Author: www.xelitan.com
// License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
{$IFDEF WINDOWS}
  Windows,
{$ENDIF}
{$IFDEF UNIX}
  DynLibs,
{$ENDIF}
  XelFontTypes;

type
  { Everything needed to undo one registration.  Owned by the caller. }
  TXelFontHandle = class
  private
    FMode     : TXelFontRegisterMode;
    FFileName : String;
    FIsTemp   : Boolean;
    FGdiHandle: THandle;
    FData     : TBytes;      // kept alive for the memory route
    FActive   : Boolean;
  public
    destructor Destroy; override;
    procedure Unregister;
    property Mode      : TXelFontRegisterMode read FMode;
    property FileName  : String  read FFileName;
    property IsTemp    : Boolean read FIsTemp;
    property Active    : Boolean read FActive;
  end;

{ Register the sfnt font in AStream (read from the current position to the end)
  for this process only.  Raises EXelFontError on failure. }
function XelRegisterFontStream(AStream: TStream;
  AMode: TXelFontRegisterMode = xfrAuto): TXelFontHandle;

{ Register a font that already sits on disk.  The file is left alone; it must
  stay readable for as long as the font is in use. }
function XelRegisterFontFile(const AFileName: String;
  AMode: TXelFontRegisterMode = xfrAuto): TXelFontHandle;

{ True when this platform can register fonts at runtime at all. }
function XelRuntimeFontsSupported: Boolean;

{ True when this platform implements the given mode natively.  Unsupported
  modes silently fall back to xfrTempFile. }
function XelRegisterModeSupported(AMode: TXelFontRegisterMode): Boolean;

{ Human readable description of the mechanism in use. }
function XelFontInstallBackend: String;

implementation

resourcestring
  SRegisterFailed = 'The system refused the font (%s)';
  SNoBackend      = 'Runtime font registration is not implemented on this platform';
  SNoFontconfig   = 'libfontconfig could not be loaded — runtime fonts are unavailable';
  SEmptyFont      = 'The font stream is empty';

{ ---------------------------------------------------------------------------
  Windows
  --------------------------------------------------------------------------- }

{$IFDEF WINDOWS}
const
  FR_PRIVATE  = $10;
  FR_NOT_ENUM = $20;

function AddFontResourceExW(lpszFilename: PWideChar; fl: DWORD;
  pdv: Pointer): Integer; stdcall; external 'gdi32.dll' name 'AddFontResourceExW';
function RemoveFontResourceExW(lpszFilename: PWideChar; fl: DWORD;
  pdv: Pointer): LongBool; stdcall; external 'gdi32.dll' name 'RemoveFontResourceExW';
function AddFontMemResourceEx(pbFont: Pointer; cbFont: DWORD;
  pdv: Pointer; pcFonts: PDWORD): THandle; stdcall; external 'gdi32.dll' name 'AddFontMemResourceEx';
function RemoveFontMemResourceEx(fh: THandle): LongBool; stdcall;
  external 'gdi32.dll' name 'RemoveFontMemResourceEx';
{$ENDIF}

{ ---------------------------------------------------------------------------
  fontconfig — loaded on demand so the unit still links on systems without it
  --------------------------------------------------------------------------- }

{$IFDEF UNIX}
type
  TFcConfigAppFontAddFile = function(config: Pointer;
    const afile: PAnsiChar): LongBool; cdecl;
  TFcInitLoadConfigAndFonts = function: Pointer; cdecl;

var
  FcLib             : TLibHandle = NilHandle;
  FcTried           : Boolean = False;
  FcAppFontAddFile  : TFcConfigAppFontAddFile = nil;
  FcInitLoad        : TFcInitLoadConfigAndFonts = nil;

function LoadFontconfig: Boolean;
const
  Candidates: array[0..3] of String = (
    'libfontconfig.so.1', 'libfontconfig.so',
    'libfontconfig.1.dylib', 'libfontconfig.dylib');
var
  I: Integer;
begin
  if FcTried then Exit(FcLib <> NilHandle);
  FcTried := True;

  for I := Low(Candidates) to High(Candidates) do
  begin
    FcLib := LoadLibrary(Candidates[I]);
    if FcLib <> NilHandle then Break;
  end;
  if FcLib = NilHandle then Exit(False);

  Pointer(FcAppFontAddFile) := GetProcedureAddress(FcLib, 'FcConfigAppFontAddFile');
  Pointer(FcInitLoad)       := GetProcedureAddress(FcLib, 'FcInitLoadConfigAndFonts');

  Result := Assigned(FcAppFontAddFile);
  if not Result then
  begin
    UnloadLibrary(FcLib);
    FcLib := NilHandle;
  end
  else if Assigned(FcInitLoad) then
    FcInitLoad;      // make sure a default config exists before we add to it
end;
{$ENDIF}

{ ---------------------------------------------------------------------------
  Capabilities
  --------------------------------------------------------------------------- }

function XelRuntimeFontsSupported: Boolean;
begin
{$IF DEFINED(WINDOWS)}
  Result := True;
{$ELSEIF DEFINED(UNIX)}
  Result := LoadFontconfig;
{$ELSE}
  Result := False;
{$IFEND}
end;

function XelRegisterModeSupported(AMode: TXelFontRegisterMode): Boolean;
begin
  case AMode of
    xfrAuto, xfrTempFile:
      Result := XelRuntimeFontsSupported;
    xfrMemory:
      {$IFDEF WINDOWS} Result := True; {$ELSE} Result := False; {$ENDIF}
  else
    Result := False;
  end;
end;

function XelFontInstallBackend: String;
begin
{$IF DEFINED(WINDOWS)}
  Result := 'GDI (AddFontResourceExW / AddFontMemResourceEx, private)';
{$ELSEIF DEFINED(UNIX)}
  if LoadFontconfig then Result := 'fontconfig (FcConfigAppFontAddFile)'
                    else Result := 'none — libfontconfig not found';
{$ELSE}
  Result := 'none';
{$IFEND}
end;

{ ---------------------------------------------------------------------------
  TXelFontHandle
  --------------------------------------------------------------------------- }

destructor TXelFontHandle.Destroy;
begin
  Unregister;
  inherited Destroy;
end;

procedure TXelFontHandle.Unregister;
begin
  if not FActive then Exit;
  FActive := False;

{$IFDEF WINDOWS}
  case FMode of
    xfrMemory:
      if FGdiHandle <> 0 then
      begin
        RemoveFontMemResourceEx(FGdiHandle);
        FGdiHandle := 0;
      end;
  else
    if FFileName <> '' then
      RemoveFontResourceExW(PWideChar(UnicodeString(FFileName)),
        FR_PRIVATE, nil);
  end;
{$ENDIF}

  { fontconfig has no per-file removal that does not also drop every other
    application font, so a Unix registration simply stays until the process
    exits.  The temporary file is kept for that reason. }
  SetLength(FData, 0);

{$IFDEF WINDOWS}
  if FIsTemp and (FFileName <> '') then SysUtils.DeleteFile(FFileName);
{$ENDIF}
end;

{ ---------------------------------------------------------------------------
  Registration
  --------------------------------------------------------------------------- }

function DoRegisterFile(AHandle: TXelFontHandle): Boolean;
begin
{$IF DEFINED(WINDOWS)}
  Result := AddFontResourceExW(PWideChar(UnicodeString(AHandle.FFileName)),
    FR_PRIVATE, nil) > 0;
{$ELSEIF DEFINED(UNIX)}
  if not LoadFontconfig then
    raise EXelFontError.Create(SNoFontconfig);
  Result := FcAppFontAddFile(nil, PAnsiChar(AnsiString(AHandle.FFileName)));
{$ELSE}
  Result := False;
  raise EXelFontError.Create(SNoBackend);
{$IFEND}
end;

function XelRegisterFontFile(const AFileName: String;
  AMode: TXelFontRegisterMode): TXelFontHandle;
begin
  if AMode = xfrAuto then AMode := xfrTempFile;
  if not XelRegisterModeSupported(AMode) then AMode := xfrTempFile;

  Result := TXelFontHandle.Create;
  Result.FMode     := AMode;
  Result.FFileName := AFileName;
  Result.FIsTemp   := False;
  try
    if AMode = xfrMemory then
    begin
      { load the file and go through the memory route }
      with TMemoryStream.Create do
      try
        LoadFromFile(AFileName);
        Position := 0;
        SetLength(Result.FData, Size);
        if Size > 0 then Move(Memory^, Result.FData[0], Size);
      finally
        Free;
      end;
{$IFDEF WINDOWS}
      Result.FGdiHandle := AddFontMemResourceEx(@Result.FData[0],
        Length(Result.FData), nil, nil);
      if Result.FGdiHandle = 0 then
        raise EXelFontError.CreateFmt(SRegisterFailed, ['memory']);
{$ENDIF}
    end
    else
      if not DoRegisterFile(Result) then
        raise EXelFontError.CreateFmt(SRegisterFailed,
          [ExtractFileName(AFileName)]);

    Result.FActive := True;
  except
    Result.Free;
    raise;
  end;
end;

function XelRegisterFontStream(AStream: TStream;
  AMode: TXelFontRegisterMode): TXelFontHandle;
var
  Data : TBytes;
  Left : Int64;
  FS   : TFileStream;
  Tmp  : String;
{$IFDEF WINDOWS}
  Cnt  : DWORD;
{$ENDIF}
begin
  if AMode = xfrAuto then AMode := xfrTempFile;
  if not XelRegisterModeSupported(AMode) then AMode := xfrTempFile;

  Left := AStream.Size - AStream.Position;
  if Left <= 0 then raise EXelFontError.Create(SEmptyFont);
  SetLength(Data, Left);
  AStream.ReadBuffer(Data[0], Left);

  Result := TXelFontHandle.Create;
  Result.FMode := AMode;
  try
    if AMode = xfrMemory then
    begin
      Result.FData := Data;
{$IFDEF WINDOWS}
      Cnt := 0;
      Result.FGdiHandle := AddFontMemResourceEx(@Result.FData[0],
        Length(Result.FData), nil, @Cnt);
      if Result.FGdiHandle = 0 then
        raise EXelFontError.CreateFmt(SRegisterFailed, ['memory']);
{$ELSE}
      raise EXelFontError.Create(SNoBackend);
{$ENDIF}
    end
    else
    begin
      Tmp := SysUtils.GetTempFileName('', 'xfn');
      FS := TFileStream.Create(Tmp, fmCreate);
      try
        FS.WriteBuffer(Data[0], Length(Data));
      finally
        FS.Free;
      end;
      Result.FFileName := Tmp;
      Result.FIsTemp   := True;

      if not DoRegisterFile(Result) then
      begin
        SysUtils.DeleteFile(Tmp);
        raise EXelFontError.CreateFmt(SRegisterFailed, ['temporary file']);
      end;
    end;

    Result.FActive := True;
  except
    Result.Free;
    raise;
  end;
end;

{$IFDEF UNIX}
finalization
  if FcLib <> NilHandle then
  begin
    UnloadLibrary(FcLib);
    FcLib := NilHandle;
  end;
{$ENDIF}

end.
