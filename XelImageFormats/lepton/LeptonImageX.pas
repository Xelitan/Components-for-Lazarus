unit LeptonImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description: Lepton (JPEG re-compression) TPicture binding                 //
// Target:      Win64, Free Pascal, Delphi                                    //
// License:     Apache-2.0                                                    //
// Copyright:   (c) 2026 Xelitan.com.                                         //
//              All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Types,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType, FPReadJPEG,{$ENDIF}
     LeptonFeatures, LeptonFile;

type
  { TLeptonImage }
  // .lep is a re-compressed JPEG bitstream. Loading decompresses it back to
  // JPEG in memory and decodes that through the standard TJPEGImage.
  // Saving compresses the internal bitmap (re-encoded as JPEG) back to .lep.
  TLeptonImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
    procedure EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer); override;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    function ToBitmap: TBitmap;
    {$IFDEF FPC}
    // Thread-safe decode: stream -> TLazIntfImage. Lepton decompresses to a JPEG
    // in memory (pure Pascal) and that JPEG is decoded with FPImage's reader -
    // NOT TJPEGImage+Canvas - so it touches NO widgetset. Safe to call from a
    // worker thread on GTK2/Qt/Cocoa. Caller owns the returned image (nil on fail).
    // When AMaxW/AMaxH > 0 the embedded JPEG is decoded at a reduced DCT scale
    // (jsHalf/Quarter/Eighth) sized to that frame - faster, less memory. Passing
    // 0 (the default) decodes full size.
    class function ToIntfImage(Str: TStream; AMaxW: Integer = 0;
      AMaxH: Integer = 0): TLazIntfImage;
    {$ENDIF}
  end;

implementation

{ TLeptonImage }

procedure TLeptonImage.DecodeFromStream(Str: TStream);
var
  Jpg: TMemoryStream;
  JpgImg: TJPEGImage;
begin
  Jpg := TMemoryStream.Create;
  try
    try
      DecodeLepton(Str, Jpg, TEnabledFeatures.CompatLeptonVectorRead);
    except
      on E: Exception do
        raise EInvalidGraphic.Create('Lepton decode failed: ' + E.Message);
    end;

    if Jpg.Size <= 0 then
      raise EInvalidGraphic.Create('Lepton decode produced empty JPEG');

    Jpg.Position := 0;
    JpgImg := TJPEGImage.Create;
    try
      JpgImg.LoadFromStream(Jpg);
      FBmp.PixelFormat := pf32bit;
      FBmp.SetSize(JpgImg.Width, JpgImg.Height);
      FBmp.Canvas.Draw(0, 0, JpgImg);
    finally
      JpgImg.Free;
    end;
  finally
    Jpg.Free;
  end;
end;

procedure TLeptonImage.EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
var
  Jpg: TMemoryStream;
  JpgImg: TJPEGImage;
  q: Integer;
begin
  if (FBmp = nil) or (FBmp.Width <= 0) or (FBmp.Height <= 0) then
    raise EInvalidGraphic.Create('Lepton encode: empty bitmap');

  q := CompressionLevel;
  if q < 1 then q := 1
  else if q > 100 then q := 100;

  Jpg := TMemoryStream.Create;
  JpgImg := TJPEGImage.Create;
  try
    JpgImg.CompressionQuality := q;
    JpgImg.Assign(FBmp);
    JpgImg.SaveToStream(Jpg);
    Jpg.Position := 0;
    try
      EncodeLepton(Jpg, Str, TEnabledFeatures.CompatLeptonVectorWrite);
    except
      on E: Exception do
        raise EInvalidGraphic.Create('Lepton encode failed: ' + E.Message);
    end;
  finally
    JpgImg.Free;
    Jpg.Free;
  end;
end;

procedure TLeptonImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TLeptonImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TLeptonImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TLeptonImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TLeptonImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TLeptonImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TLeptonImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TLeptonImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TLeptonImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TLeptonImage.SaveToStream(Stream: TStream);
begin
  EncodeToStream(Stream, 75);
end;

constructor TLeptonImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
end;

destructor TLeptonImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TLeptonImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

{$IFDEF FPC}
// Reads a JPEG's pixel size straight from the SOF marker (no decode). Thread-safe.
function LepReadJpegSize(Str: TStream; out W, H: Integer): Boolean;
var
  b, marker, lenHi, lenLo: Byte;
  segLen: Integer;
  prec, hHi, hLo, wHi, wLo: Byte;
begin
  Result := False; W := 0; H := 0;
  Str.Position := 0;
  if (Str.Read(b, 1) <> 1) or (b <> $FF) then Exit;
  if (Str.Read(b, 1) <> 1) or (b <> $D8) then Exit;   // SOI
  while True do
  begin
    if Str.Read(b, 1) <> 1 then Exit;
    if b <> $FF then Continue;
    repeat
      if Str.Read(marker, 1) <> 1 then Exit;
    until marker <> $FF;
    if (marker = $D8) or (marker = $D9) or (marker = $01) or
       ((marker >= $D0) and (marker <= $D7)) then
      Continue;                                        // standalone, no length
    if Str.Read(lenHi, 1) <> 1 then Exit;
    if Str.Read(lenLo, 1) <> 1 then Exit;
    segLen := lenHi * 256 + lenLo;
    if segLen < 2 then Exit;
    if (marker >= $C0) and (marker <= $CF) and
       (marker <> $C4) and (marker <> $C8) and (marker <> $CC) then
    begin                                              // SOF: precision, H, W
      if (Str.Read(prec, 1) <> 1) or (Str.Read(hHi, 1) <> 1) or
         (Str.Read(hLo, 1) <> 1) or (Str.Read(wHi, 1) <> 1) or
         (Str.Read(wLo, 1) <> 1) then Exit;
      H := hHi * 256 + hLo;
      W := wHi * 256 + wLo;
      Result := (W > 0) and (H > 0);
      Exit;
    end
    else
      Str.Position := Str.Position + (segLen - 2);
  end;
end;

// Largest DCT downscale that keeps the decoded image >= the AMaxW x AMaxH frame.
function LepPickJpegScale(W, H, AMaxW, AMaxH: Integer): TJPEGScale;
var
  ratio: Double;
begin
  Result := jsFullSize;
  if (W <= 0) or (H <= 0) or (AMaxW <= 0) or (AMaxH <= 0) then Exit;
  ratio := W / AMaxW;
  if H / AMaxH > ratio then ratio := H / AMaxH;
  if ratio >= 8 then Result := jsEighth
  else if ratio >= 4 then Result := jsQuarter
  else if ratio >= 2 then Result := jsHalf;
end;

class function TLeptonImage.ToIntfImage(Str: TStream; AMaxW: Integer = 0;
  AMaxH: Integer = 0): TLazIntfImage;
var
  Jpg   : TMemoryStream;
  Reader: TFPReaderJPEG;
  Desc  : TRawImageDescription;
  jw, jh: Integer;
begin
  Result := nil;
  Jpg := TMemoryStream.Create;
  try
    try
      DecodeLepton(Str, Jpg, TEnabledFeatures.CompatLeptonVectorRead); // pure Pascal
      if Jpg.Size <= 0 then Exit;

      Desc.Init_BPP32_B8G8R8A8_BIO_TTB(0, 0);
      Result := TLazIntfImage.Create(0, 0);
      Result.DataDescription := Desc;
      Reader := TFPReaderJPEG.Create;
      try
        if (AMaxW > 0) and (AMaxH > 0) and LepReadJpegSize(Jpg, jw, jh) then
          Reader.Scale := LepPickJpegScale(jw, jh, AMaxW, AMaxH);
        Reader.Performance := jpBestSpeed;
        Jpg.Position := 0;
        Result.LoadFromStream(Jpg, Reader);  // FPImage JPEG decode -> memory
      finally
        Reader.Free;
      end;
    except
      FreeAndNil(Result);
    end;
  finally
    Jpg.Free;
  end;
end;
{$ENDIF}

initialization
  TPicture.RegisterFileFormat('Lep', 'Lepton JPEG', TLeptonImage);

finalization
  TPicture.UnregisterGraphicClass(TLeptonImage);

end.
