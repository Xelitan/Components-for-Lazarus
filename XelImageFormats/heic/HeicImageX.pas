unit HeicImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Heic compressor/decompressor                                  //
// Version:	0.1                                                           //
// Date:	15-SEP-2026                                                   //
// License:     LGPL                                                          //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     Heif.Container, Heif.Decode, Heif.Encode;

  { THeicImage }
type
  THeicImage = class(TGraphic)
  private
    FBmp: TBitmap;
    // Decode a HEIC stream (from its current position to the end) to a top-down,
    // tightly packed RGBA8 buffer (byte order R,G,B,A). AW/AH get the dimensions.
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer);
    procedure DecodeFromStream(Str: TStream);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
  //    function GetEmpty: Boolean; virtual; abstract;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer);override;
  public
    // Encode the internal bitmap to Heic and write it to Str.
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                             CompressionLevel: Integer = 75);
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    constructor Create; override;
    destructor Destroy; override;
    function ToBitmap: TBitmap;
    {$IFDEF FPC}
    // Thread-safe decode: stream -> TLazIntfImage, no widgetset (no TBitmap /
    // Canvas / handle). Safe to call from a worker thread on GTK2/Qt/Cocoa.
    // Caller owns the returned image (nil on failure).
    class function ToIntfImage(Str: TStream): TLazIntfImage;
    {$ENDIF}
  end;

implementation

{ THeicImage }

class procedure THeicImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var
  Data : TBytes;
  Size : NativeInt;
  C    : THeifContainer;
  Img  : THeifImage;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  SetLength(Data, Size);
  if Size > 0 then Str.ReadBuffer(Data[0], Size);

  C := THeifContainer.Create;
  try
    C.LoadFromBytes(Data);
    if not DecodeHeifPrimary(C, Img) then
      raise EHeifDecode.Create('HEIC decode failed');
    // Packed RGBA8, top-down; colour matrix/range and rotation already applied.
    HeifImageToRGBA(Img, ARGBA, AW, AH);
  finally
    C.Free;
  end;
end;

procedure THeicImage.DecodeFromStream(Str: TStream);
var
  RGBA        : TBytes;
  W, H, x, y  : Integer;
  SrcIndex    : NativeInt;
{$IFDEF FPC}
  Intf        : TLazIntfImage;
  Desc        : TRawImageDescription;
  Dst         : PByte;
  BPL         : PtrInt;
{$ELSE}
  Row         : PByte;
{$ENDIF}
begin
  DecodeStreamToRGBA(Str, RGBA, W, H);
  if (W <= 0) or (H <= 0) or
     (NativeUInt(Length(RGBA)) < NativeUInt(W) * NativeUInt(H) * 4) then
    raise EHeifDecode.Create('HEIC decode produced no pixels');

  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(W, H);
  SrcIndex := 0;
{$IFDEF FPC}
  // Fill a TLazIntfImage (widgetset-independent) then load it into FBmp.
  Intf := TLazIntfImage.Create(0, 0);
  try
    Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
    Intf.DataDescription := Desc;
    Intf.SetSize(W, H);
    Dst := PByte(Intf.PixelData);
    BPL := Intf.DataDescription.BytesPerLine;
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do
      begin
        Dst[x * 4 + 0] := RGBA[SrcIndex + 2]; // B
        Dst[x * 4 + 1] := RGBA[SrcIndex + 1]; // G
        Dst[x * 4 + 2] := RGBA[SrcIndex + 0]; // R
        Dst[x * 4 + 3] := RGBA[SrcIndex + 3]; // A
        Inc(SrcIndex, 4);
      end;
      Inc(Dst, BPL);
    end;
    FBmp.LoadFromIntfImage(Intf);
  finally
    Intf.Free;
  end;
{$ELSE}
  // Delphi/VCL: write the DIB scanlines directly (pf32bit is B,G,R,A).
  for y := 0 to H - 1 do
  begin
    Row := PByte(FBmp.ScanLine[y]);
    for x := 0 to W - 1 do
    begin
      Row[x * 4 + 0] := RGBA[SrcIndex + 2]; // B
      Row[x * 4 + 1] := RGBA[SrcIndex + 1]; // G
      Row[x * 4 + 2] := RGBA[SrcIndex + 0]; // R
      Row[x * 4 + 3] := RGBA[SrcIndex + 3]; // A
      Inc(SrcIndex, 4);
    end;
  end;
{$ENDIF}
end;

procedure THeicImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function THeicImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function THeicImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function THeicImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure THeicImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure THeicImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure THeicImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure THeicImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure THeicImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure THeicImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
  CompressionLevel: Integer = 75);
var
  W, H, x, y, Q : Integer;
  DstIndex      : NativeInt;
  RGB           : TBytes;
  Data          : TBytes;
{$IFDEF FPC}
  Intf          : TLazIntfImage;
  Col           : TFPColor;
{$ELSE}
  Row           : PByte;
{$ENDIF}
begin
  W := FBmp.Width;
  H := FBmp.Height;
  if (W <= 0) or (H <= 0) then Exit;
  FBmp.PixelFormat := pf32bit;

  // Gather the bitmap as packed, top-down RGB8 for the encoder.
  SetLength(RGB, NativeInt(W) * NativeInt(H) * 3);
  DstIndex := 0;
{$IFDEF FPC}
  Intf := FBmp.CreateIntfImage;
  try
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        Col := Intf.Colors[x, y];       // channels are 16-bit (0..$FFFF)
        RGB[DstIndex + 0] := Col.Red   shr 8;
        RGB[DstIndex + 1] := Col.Green shr 8;
        RGB[DstIndex + 2] := Col.Blue  shr 8;
        Inc(DstIndex, 3);
      end;
  finally
    Intf.Free;
  end;
{$ELSE}
  for y := 0 to H - 1 do
  begin
    Row := PByte(FBmp.ScanLine[y]);     // pf32bit is B,G,R,A
    for x := 0 to W - 1 do
    begin
      RGB[DstIndex + 0] := Row[x * 4 + 2]; // R
      RGB[DstIndex + 1] := Row[x * 4 + 1]; // G
      RGB[DstIndex + 2] := Row[x * 4 + 0]; // B
      Inc(DstIndex, 3);
    end;
  end;
{$ENDIF}

  // Quality 0..100 (higher = better). The current encoder path has no
  // transform-bypass, so "lossless" maps to maximum quality (QP 0).
  if IsLossless then Q := 100 else Q := CompressionLevel;
  if Q < 0 then Q := 0 else if Q > 100 then Q := 100;

  // 4:2:0 chroma (the common HEIC case).
  Data := EncodeHeifFromRGB(RGB, W, H, Q, 1);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure THeicImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

constructor THeicImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor THeicImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function THeicImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

{$IFDEF FPC}
class function THeicImage.ToIntfImage(Str: TStream): TLazIntfImage;
var
  Pixels      : TBytes;
  W, H, x, y  : Integer;
  RequiredSize: NativeUInt;
  SrcIndex    : NativeInt;
  Desc        : TRawImageDescription;
  Dst         : PByte;
  BPL         : PtrInt;
begin
  Result := nil;
  try
    DecodeStreamToRGBA(Str, Pixels, W, H); // pure-Pascal decode -> RGBA8
  except
    Exit;                                  // nil on any decode failure
  end;
  RequiredSize := NativeUInt(W) * NativeUInt(H) * 4;
  if (W <= 0) or (H <= 0) or
     (NativeUInt(Length(Pixels)) < RequiredSize) then Exit;

  Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
  Result := TLazIntfImage.Create(0, 0);
  Result.DataDescription := Desc;
  Result.SetSize(W, H);
  Dst := PByte(Result.PixelData);
  BPL := Result.DataDescription.BytesPerLine;
  SrcIndex := 0;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      Dst[x * 4 + 0] := Pixels[SrcIndex + 2]; // B
      Dst[x * 4 + 1] := Pixels[SrcIndex + 1]; // G
      Dst[x * 4 + 2] := Pixels[SrcIndex + 0]; // R
      Dst[x * 4 + 3] := Pixels[SrcIndex + 3]; // A
      Inc(SrcIndex, 4);
    end;
    Inc(Dst, BPL);
  end;
end;
{$ENDIF}

initialization
  TPicture.RegisterFileFormat('Heic','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heif','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heifs','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heics','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avci','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avcs','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('hif','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avif','Heic Image', THeicImage);

finalization
  TPicture.UnregisterGraphicClass(THeicImage);

end.
