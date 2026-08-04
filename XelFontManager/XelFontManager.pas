unit XelFontManager;

// XelFonts — TXelFontManager.
//
// Drop the component on a form, fill its Fonts collection with .ttf / .otf /
// .woff / .woff2 / .svg files (or add them from streams and resources at run
// time) and set Active := True.  Every font is converted to a plain sfnt and
// registered privately for the running process, so it can be used through
// TFont.Name without ever being installed into the system.
//
// Author: www.xelitan.com
// License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  XelFontTypes, XelFontConvert, XelFontInstall;

type
  TXelFontManager = class;
  TXelFontItem    = class;

  TXelFontEvent = procedure(Sender: TObject; AItem: TXelFontItem) of object;
  TXelFontErrorEvent = procedure(Sender: TObject; AItem: TXelFontItem;
    E: Exception; var Handled: Boolean) of object;

  { Where an item's bytes come from. }
  TXelFontSource = (xfsFile, xfsResource, xfsData);

  { TXelFontItem — one font in the manager's collection. }
  TXelFontItem = class(TCollectionItem)
  private
    FSource       : TXelFontSource;
    FFileName     : String;
    FResourceName : String;
    FCaption      : String;
    FEnabled      : Boolean;
    FData         : TMemoryStream;      // owned, used by xfsData
    FHandle       : TXelFontHandle;
    FNames        : TXelFontNames;
    FSourceFormat : TXelFontFormat;
    FLoadedFormat : TXelFontFormat;
    FLastError    : String;
    function  GetLoaded: Boolean;
    function  GetManager: TXelFontManager;
    procedure SetEnabled(AValue: Boolean);
    procedure SetFileName(const AValue: String);
    procedure SetResourceName(const AValue: String);
    { Produce the raw source bytes, whatever the source is.  Caller frees. }
    function  OpenSource: TStream;
  protected
    function GetDisplayName: String; override;
  public
    constructor Create(ACollection: TCollection); override;
    destructor  Destroy; override;
    procedure   Assign(Source: TPersistent); override;

    { Convert and register this font.  Safe to call twice. }
    procedure Load;
    { Hand the font back to the OS. }
    procedure Unload;

    { Replace the item's content with the bytes in AStream. }
    procedure LoadFromStream(AStream: TStream);

    property Manager       : TXelFontManager read GetManager;
    property Source        : TXelFontSource  read FSource;
    property Loaded        : Boolean         read GetLoaded;
    property FamilyName    : String          read FNames.Family;
    property StyleName     : String          read FNames.SubFamily;
    property FullName      : String          read FNames.Full;
    property PostScriptName: String          read FNames.PostScript;
    property SourceFormat  : TXelFontFormat  read FSourceFormat;
    property LoadedFormat  : TXelFontFormat  read FLoadedFormat;
    property LastError     : String          read FLastError;
  published
    { Path to a font file.  Setting it switches the item to xfsFile. }
    property FileName: String read FFileName write SetFileName;
    { Name of an RCDATA resource holding the font.  Switches to xfsResource. }
    property ResourceName: String read FResourceName write SetResourceName;
    { Optional label shown in the collection editor and in GetFamilyNames
      when the font carries no usable name table. }
    property Caption: String read FCaption write FCaption;
    { Skip this item when the manager activates. }
    property Enabled: Boolean read FEnabled write SetEnabled default True;
  end;

  { TXelFontItems — the collection behind TXelFontManager.Fonts. }
  TXelFontItems = class(TOwnedCollection)
  private
    function  GetItem(Index: Integer): TXelFontItem;
    procedure SetItem(Index: Integer; AValue: TXelFontItem);
  public
    constructor Create(AOwner: TPersistent);
    function Add: TXelFontItem;
    function FindByFamily(const AFamily: String): TXelFontItem;
    function FindByFileName(const AFileName: String): TXelFontItem;
    property Items[Index: Integer]: TXelFontItem read GetItem write SetItem; default;
  end;

  { TXelFontManager

      Manager.Fonts.Add.FileName := 'fonts\Inter.woff2';
      Manager.Active := True;
      Label1.Font.Name := Manager.Fonts[0].FamilyName;

    Fonts stay registered until Active is set back to False or the component
    is destroyed.  Nothing is written to the system font directory and no
    registry key is touched. }
  TXelFontManager = class(TComponent)
  private
    FFonts        : TXelFontItems;
    FActive       : Boolean;
    FAutoActivate : Boolean;
    FConvert      : TXelFontConvert;
    FRegisterMode : TXelFontRegisterMode;
    FRaiseErrors  : Boolean;
    FLastError    : String;
    FOnFontLoaded : TXelFontEvent;
    FOnError      : TXelFontErrorEvent;
    procedure SetActive(AValue: Boolean);
    procedure SetFonts(AValue: TXelFontItems);
    function  GetLoadedCount: Integer;
  protected
    procedure Loaded; override;
    { Returns True when the caller should re-raise. }
    function  HandleError(AItem: TXelFontItem; E: Exception): Boolean;
    procedure DoFontLoaded(AItem: TXelFontItem);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    { --- adding fonts --- }

    function AddFile(const AFileName: String): TXelFontItem;
    function AddStream(AStream: TStream; const ACaption: String = ''): TXelFontItem;
    function AddResource(const AResourceName: String): TXelFontItem;

    { Add every font file in ADirectory.  Returns how many items were added. }
    function AddDirectory(const ADirectory: String;
      ARecursive: Boolean = False): Integer;

    { --- activation --- }

    procedure Activate;
    procedure Deactivate;

    { --- queries --- }

    { Family names of the fonts that are currently registered. }
    procedure GetFamilyNames(AList: TStrings);
    function  IsRegistered(const AFamily: String): Boolean;
    function  FindByFamily(const AFamily: String): TXelFontItem;

    { What this platform can actually do — see XelFontInstall. }
    class function RuntimeFontsSupported: Boolean;
    class function Backend: String;

    property LoadedCount: Integer read GetLoadedCount;
    property LastError: String read FLastError;
  published
    property Fonts: TXelFontItems read FFonts write SetFonts;

    { Setting True converts and registers every enabled font.  Ignored while
      the component is being designed. }
    property Active: Boolean read FActive write SetActive default False;

    { Activate automatically once the form has finished streaming in. }
    property AutoActivate: Boolean read FAutoActivate write FAutoActivate
      default False;

    { xfcAuto keeps TrueType fonts as they are; xfcOTF rebuilds them as CFF
      OpenType, which drops hinting. }
    property Convert: TXelFontConvert read FConvert write FConvert
      default xfcAuto;

    { xfrTempFile is enumerable by font pickers, xfrMemory touches no disk. }
    property RegisterMode: TXelFontRegisterMode read FRegisterMode
      write FRegisterMode default xfrAuto;

    { False collects failures in LastError instead of raising. }
    property RaiseErrors: Boolean read FRaiseErrors write FRaiseErrors
      default True;

    property OnFontLoaded: TXelFontEvent read FOnFontLoaded write FOnFontLoaded;
    property OnError: TXelFontErrorEvent read FOnError write FOnError;
  end;

procedure Register;

implementation

{$R txelfontmanager_images.res}

const
  { RT_RCDATA as a resource-type pointer; spelled out here so the unit does
    not have to pull in Windows or LCLType. }
  XEL_RCDATA = PChar(PtrUInt(10));

resourcestring
  SNoSource   = 'Font item %d has neither FileName nor data';
  SNoFile     = 'Font file "%s" not found';
  SNoResource = 'Font resource "%s" not found';
  SNoNames    = 'The converted font has no usable name table';
  SUnnamed    = '(font %d)';

{ ===========================================================================
  TXelFontItem
  =========================================================================== }

constructor TXelFontItem.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FEnabled      := True;
  FSource       := xfsFile;
  FSourceFormat := xffUnknown;
  FLoadedFormat := xffUnknown;
end;

destructor TXelFontItem.Destroy;
begin
  Unload;
  FData.Free;
  inherited Destroy;
end;

procedure TXelFontItem.Assign(Source: TPersistent);
var
  S: TXelFontItem;
begin
  if Source is TXelFontItem then
  begin
    S := TXelFontItem(Source);
    FSource       := S.FSource;
    FFileName     := S.FFileName;
    FResourceName := S.FResourceName;
    FCaption      := S.FCaption;
    FEnabled      := S.FEnabled;
    if S.FData <> nil then
    begin
      if FData = nil then FData := TMemoryStream.Create;
      FData.Clear;
      S.FData.Position := 0;
      FData.CopyFrom(S.FData, S.FData.Size);
    end;
    Changed(False);
  end
  else
    inherited Assign(Source);
end;

function TXelFontItem.GetManager: TXelFontManager;
begin
  if (Collection <> nil) and (Collection.Owner is TXelFontManager) then
    Result := TXelFontManager(Collection.Owner)
  else
    Result := nil;
end;

function TXelFontItem.GetLoaded: Boolean;
begin
  Result := (FHandle <> nil) and FHandle.Active;
end;

function TXelFontItem.GetDisplayName: String;
begin
  if FNames.Family <> '' then
  begin
    Result := FNames.Family;
    if (FNames.SubFamily <> '') and
       (CompareText(FNames.SubFamily, 'Regular') <> 0) then
      Result := Result + ' ' + FNames.SubFamily;
  end
  else if FCaption <> '' then
    Result := FCaption
  else if FFileName <> '' then
    Result := ExtractFileName(FFileName)
  else if FResourceName <> '' then
    Result := FResourceName
  else
    Result := Format(SUnnamed, [Index]);
end;

procedure TXelFontItem.SetEnabled(AValue: Boolean);
begin
  if FEnabled = AValue then Exit;
  FEnabled := AValue;
  if (not FEnabled) and Loaded then Unload;
  Changed(False);
end;

procedure TXelFontItem.SetFileName(const AValue: String);
begin
  if FFileName = AValue then Exit;
  Unload;
  FFileName := AValue;
  if AValue <> '' then FSource := xfsFile;
  FSourceFormat := xffUnknown;
  Changed(False);
end;

procedure TXelFontItem.SetResourceName(const AValue: String);
begin
  if FResourceName = AValue then Exit;
  Unload;
  FResourceName := AValue;
  if AValue <> '' then FSource := xfsResource;
  FSourceFormat := xffUnknown;
  Changed(False);
end;

procedure TXelFontItem.LoadFromStream(AStream: TStream);
begin
  Unload;
  if FData = nil then FData := TMemoryStream.Create;
  FData.Clear;
  FData.CopyFrom(AStream, 0);
  FData.Position := 0;
  FSource       := xfsData;
  FSourceFormat := xffUnknown;
  Changed(False);
end;

function TXelFontItem.OpenSource: TStream;
var
  MS: TMemoryStream;
begin
  case FSource of
    xfsFile:
      begin
        if FFileName = '' then
          raise EXelFontError.CreateFmt(SNoSource, [Index]);
        if not FileExists(FFileName) then
          raise EXelFontError.CreateFmt(SNoFile, [FFileName]);
        Result := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyWrite);
      end;

    xfsResource:
      begin
        if FResourceName = '' then
          raise EXelFontError.CreateFmt(SNoSource, [Index]);
        try
          Result := TResourceStream.Create(HInstance, FResourceName, XEL_RCDATA);
        except
          raise EXelFontError.CreateFmt(SNoResource, [FResourceName]);
        end;
      end;

    xfsData:
      begin
        if (FData = nil) or (FData.Size = 0) then
          raise EXelFontError.CreateFmt(SNoSource, [Index]);
        MS := TMemoryStream.Create;
        try
          FData.Position := 0;
          MS.CopyFrom(FData, FData.Size);
          MS.Position := 0;
        except
          MS.Free;
          raise;
        end;
        Result := MS;
      end;
  else
    raise EXelFontError.CreateFmt(SNoSource, [Index]);
  end;
end;

procedure TXelFontItem.Load;
var
  Mgr  : TXelFontManager;
  Src  : TStream;
  Sfnt : TMemoryStream;
  Conv : TXelFontConvert;
  Mode : TXelFontRegisterMode;
begin
  if Loaded then Exit;
  FLastError := '';

  Mgr  := Manager;
  Conv := xfcAuto;
  Mode := xfrAuto;
  if Mgr <> nil then
  begin
    Conv := Mgr.Convert;
    Mode := Mgr.RegisterMode;
  end;

  Src  := nil;
  Sfnt := TMemoryStream.Create;
  try
    try
      Src := OpenSource;
      FSourceFormat := XelDetectFontFormat(Src);
      if (FSourceFormat = xffUnknown) and (FFileName <> '') then
        FSourceFormat := XelFontFormatByExt(FFileName);

      FLoadedFormat := XelFontToSfnt(Src, Sfnt, Conv, FSourceFormat);

      Sfnt.Position := 0;
      if not XelReadSfntNames(Sfnt, FNames) then
        { registration would still work, but the caller could never name the
          font, so this counts as a failure }
        raise EXelFontError.Create(SNoNames);

      Sfnt.Position := 0;
      FHandle := XelRegisterFontStream(Sfnt, Mode);
    except
      on E: Exception do
      begin
        FLastError := E.Message;
        FreeAndNil(FHandle);
        if (Mgr = nil) or Mgr.HandleError(Self, E) then raise;
        Exit;
      end;
    end;
  finally
    Sfnt.Free;
    Src.Free;
  end;

  if Mgr <> nil then Mgr.DoFontLoaded(Self);
end;

procedure TXelFontItem.Unload;
begin
  FreeAndNil(FHandle);
  FNames.Family     := '';
  FNames.SubFamily  := '';
  FNames.Full       := '';
  FNames.PostScript := '';
  FLoadedFormat := xffUnknown;
end;

{ ===========================================================================
  TXelFontItems
  =========================================================================== }

constructor TXelFontItems.Create(AOwner: TPersistent);
begin
  inherited Create(AOwner, TXelFontItem);
end;

function TXelFontItems.GetItem(Index: Integer): TXelFontItem;
begin
  Result := TXelFontItem(inherited Items[Index]);
end;

procedure TXelFontItems.SetItem(Index: Integer; AValue: TXelFontItem);
begin
  inherited Items[Index] := AValue;
end;

function TXelFontItems.Add: TXelFontItem;
begin
  Result := TXelFontItem(inherited Add);
end;

function TXelFontItems.FindByFamily(const AFamily: String): TXelFontItem;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if CompareText(Items[I].FamilyName, AFamily) = 0 then Exit(Items[I]);
  Result := nil;
end;

function TXelFontItems.FindByFileName(const AFileName: String): TXelFontItem;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if CompareText(Items[I].FileName, AFileName) = 0 then Exit(Items[I]);
  Result := nil;
end;

{ ===========================================================================
  TXelFontManager
  =========================================================================== }

constructor TXelFontManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FFonts        := TXelFontItems.Create(Self);
  FConvert      := xfcAuto;
  FRegisterMode := xfrAuto;
  FRaiseErrors  := True;
end;

destructor TXelFontManager.Destroy;
begin
  Deactivate;
  FFonts.Free;
  inherited Destroy;
end;

procedure TXelFontManager.SetFonts(AValue: TXelFontItems);
begin
  FFonts.Assign(AValue);
end;

procedure TXelFontManager.SetActive(AValue: Boolean);
begin
  if FActive = AValue then Exit;

  if csLoading in ComponentState then
  begin
    FActive := AValue;      // remember, act in Loaded
    Exit;
  end;

  if AValue then Activate else Deactivate;
end;

procedure TXelFontManager.Loaded;
begin
  inherited Loaded;
  if csDesigning in ComponentState then Exit;
  if FActive or FAutoActivate then
  begin
    FActive := False;
    Activate;
  end;
end;

function TXelFontManager.GetLoadedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FFonts.Count - 1 do
    if FFonts[I].Loaded then Inc(Result);
end;

function TXelFontManager.HandleError(AItem: TXelFontItem; E: Exception): Boolean;
var
  Handled: Boolean;
begin
  FLastError := E.Message;
  Handled := False;
  if Assigned(FOnError) then FOnError(Self, AItem, E, Handled);
  Result := FRaiseErrors and (not Handled);
end;

procedure TXelFontManager.DoFontLoaded(AItem: TXelFontItem);
begin
  if Assigned(FOnFontLoaded) then FOnFontLoaded(Self, AItem);
end;

{ --- adding --- }

function TXelFontManager.AddFile(const AFileName: String): TXelFontItem;
begin
  Result := FFonts.Add;
  Result.FileName := AFileName;
  if FActive and Result.Enabled then Result.Load;
end;

function TXelFontManager.AddStream(AStream: TStream;
  const ACaption: String): TXelFontItem;
begin
  Result := FFonts.Add;
  Result.Caption := ACaption;
  Result.LoadFromStream(AStream);
  if FActive and Result.Enabled then Result.Load;
end;

function TXelFontManager.AddResource(const AResourceName: String): TXelFontItem;
begin
  Result := FFonts.Add;
  Result.ResourceName := AResourceName;
  if FActive and Result.Enabled then Result.Load;
end;

function TXelFontManager.AddDirectory(const ADirectory: String;
  ARecursive: Boolean): Integer;
var
  Count: Integer;

  procedure Scan(const APath: String);
  var
    SR  : TSearchRec;
    Full: String;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := IncludeTrailingPathDelimiter(APath) + SR.Name;

        if (SR.Attr and faDirectory) <> 0 then
        begin
          if ARecursive then Scan(Full);
          Continue;
        end;

        if XelFontFormatByExt(SR.Name) in
           [xffTTF, xffOTF, xffWOFF, xffWOFF2, xffSVG] then
        begin
          AddFile(Full);
          Inc(Count);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  Count := 0;
  Scan(ExcludeTrailingPathDelimiter(ADirectory));
  Result := Count;
end;

{ --- activation --- }

procedure TXelFontManager.Activate;
var
  I: Integer;
begin
  if FActive then Exit;
  FLastError := '';
  FActive := True;
  for I := 0 to FFonts.Count - 1 do
    if FFonts[I].Enabled then FFonts[I].Load;
end;

procedure TXelFontManager.Deactivate;
var
  I: Integer;
begin
  FActive := False;
  for I := 0 to FFonts.Count - 1 do
    FFonts[I].Unload;
end;

{ --- queries --- }

procedure TXelFontManager.GetFamilyNames(AList: TStrings);
var
  I: Integer;
begin
  AList.BeginUpdate;
  try
    AList.Clear;
    for I := 0 to FFonts.Count - 1 do
      if FFonts[I].Loaded and (FFonts[I].FamilyName <> '') then
        if AList.IndexOf(FFonts[I].FamilyName) < 0 then
          AList.AddObject(FFonts[I].FamilyName, FFonts[I]);
  finally
    AList.EndUpdate;
  end;
end;

function TXelFontManager.IsRegistered(const AFamily: String): Boolean;
var
  Item: TXelFontItem;
begin
  Item := FFonts.FindByFamily(AFamily);
  Result := (Item <> nil) and Item.Loaded;
end;

function TXelFontManager.FindByFamily(const AFamily: String): TXelFontItem;
begin
  Result := FFonts.FindByFamily(AFamily);
end;

class function TXelFontManager.RuntimeFontsSupported: Boolean;
begin
  Result := XelRuntimeFontsSupported;
end;

class function TXelFontManager.Backend: String;
begin
  Result := XelFontInstallBackend;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelFontManager]);
end;

end.
