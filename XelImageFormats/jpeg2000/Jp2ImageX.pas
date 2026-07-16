unit Jp2ImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Jpeg 2000 port                                                //
// Version:	0.2                                                           //
// Date:	24-JUN-2026                                                   //
// License:     JasPer-2.0 (similar to MIT )                                  //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     JP2KCommon, JP2KCodec, JP2KDecGen;

  { TJp2Image }
type
  TJp2Image = class(TGraphic)
  private
    FBmp: TBitmap;
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
    // Encode the internal bitmap to Jp2 and write it to Str.
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

{ TJp2Image }


procedure TJp2Image.DecodeFromStream(Str: TStream);
var
  Img: TJp2kImage;
  Bytes: TBytes;
  W, H, x, y, idx, n, sh: Integer;
  r, g, b: Integer;
  Row: PByte;

  function ClampByte(v: Integer): Byte;
  begin
    if v < 0 then v := 0
    else if v > 255 then v := 255;
    Result := Byte(v);
  end;

begin
  n := Str.Size - Str.Position;
  if n <= 0 then Exit;

  SetLength(Bytes, n);
  Str.ReadBuffer(Bytes[0], n);

  Img := DecodeGeneral(Bytes);    // handles both .jp2 and raw .jpc
  try
    W := Img.W;
    H := Img.H;
    if (W <= 0) or (H <= 0) then Exit;

    // Bring the decoded sample precision down/up to 8 bits per channel
    sh := Img.Prec - 8;

    FBmp.PixelFormat := pf32bit;
    FBmp.SetSize(W, H);

    for y := 0 to H - 1 do
    begin
      Row := PByte(FBmp.ScanLine[y]);
      for x := 0 to W - 1 do
      begin
        idx := y * W + x;
        if Img.NumComps >= 3 then
        begin
          r := Img.Comps[0][idx];
          g := Img.Comps[1][idx];
          b := Img.Comps[2][idx];
        end
        else
        begin
          r := Img.Comps[0][idx];
          g := r;
          b := r;
        end;

        if sh > 0 then
        begin
          r := r shr sh; g := g shr sh; b := b shr sh;
        end
        else if sh < 0 then
        begin
          r := r shl (-sh); g := g shl (-sh); b := b shl (-sh);
        end;

        // 32-bit DIB rows are BGRA on Windows
        Row[x * 4 + 0] := ClampByte(b);
        Row[x * 4 + 1] := ClampByte(g);
        Row[x * 4 + 2] := ClampByte(r);
        Row[x * 4 + 3] := 255;
      end;
    end;
  finally
    Img.Free;
  end;
end;

procedure TJp2Image.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TJp2Image.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TJp2Image.GetTransparent: Boolean;
begin
  Result := False;
end;

function TJp2Image.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TJp2Image.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TJp2Image.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TJp2Image.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TJp2Image.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TJp2Image.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TJp2Image.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
  CompressionLevel: Integer = 75);
var
  Img: TJp2kImage;
  Opt: TEncodeOptions;
  W, H, x, y, idx: Integer;
  Row: PByte;
  Bytes: TBytes;
  q: Integer;
begin
  if FBmp = nil then Exit;

  FBmp.PixelFormat := pf32bit;
  W := FBmp.Width;
  H := FBmp.Height;
  if (W <= 0) or (H <= 0) then Exit;

  // RGB, 8 bits/channel. The colour transform (MCT) needs exactly 3 components,
  //  so we drop the (unused) alpha channel here.
  Img := TJp2kImage.Create(W, H, 3, 8);
  try
    for y := 0 to H - 1 do
    begin
      Row := PByte(FBmp.ScanLine[y]);
      for x := 0 to W - 1 do
      begin
        idx := y * W + x;
        // 32-bit DIB rows are BGRA on Windows.
        Img.Comps[0][idx] := Row[x * 4 + 2];   // R
        Img.Comps[1][idx] := Row[x * 4 + 1];   // G
        Img.Comps[2][idx] := Row[x * 4 + 0];   // B
      end;
    end;

    Opt := DefaultEncodeOptions;
    Opt.Reversible := IsLossless;   // True = lossless 5/3+RCT, else lossy 9/7+ICT
    Opt.UseMct := True;             // colour-decorrelate (RCT/ICT) for 3 comps
    Opt.NumLevels := 0;             // auto (~5 DWT levels) - best compression

    if IsLossless then
      Opt.Step := 1.0               // ignored in reversible mode
    else
    begin
      // Map quality (1..100) to the irreversible quantiser step: higher quality
      //  => smaller step => less loss. Tuned on photographic content so the
      //  default (75) is visually near-lossless (~45 dB PSNR):
      //      q=100 ~0.13   q=90 ~0.35    q=75 ~0.59 (default)
      //      q=50  ~1.4    q=25 ~3.4     q=10 ~5.7
      //  The encoder writes a conformant expounded QCD, so the resulting .jp2
      //  opens correctly in any standard viewer, not just this library.
      q := CompressionLevel;
      if q < 1 then q := 1
      else if q > 100 then q := 100;
      Opt.Step := Power(2.0, (60 - q) / 20.0);
    end;

    Bytes := EncodeToJp2(Img, Opt);
    if Length(Bytes) > 0 then
      Str.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Img.Free;
  end;
end;

procedure TJp2Image.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

constructor TJp2Image.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TJp2Image.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TJp2Image.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

{$IFDEF FPC}
class function TJp2Image.ToIntfImage(Str: TStream): TLazIntfImage;
var
  Img : TJp2kImage;
  Bytes: TBytes;
  W, H, x, y, idx, n, sh, r, g, b: Integer;
  Desc: TRawImageDescription;
  Dst : PByte;
  BPL : PtrInt;

  function ClampByte(v: Integer): Byte;
  begin
    if v < 0 then v := 0
    else if v > 255 then v := 255;
    Result := Byte(v);
  end;

begin
  Result := nil;
  n := Str.Size - Str.Position;
  if n <= 0 then Exit;
  SetLength(Bytes, n);
  Str.ReadBuffer(Bytes[0], n);

  Img := DecodeGeneral(Bytes);   // pure Pascal; handles .jp2 and raw .jpc
  try
    W := Img.W;
    H := Img.H;
    if (W <= 0) or (H <= 0) then Exit;
    sh := Img.Prec - 8;

    Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
    Result := TLazIntfImage.Create(0, 0);
    Result.DataDescription := Desc;
    Result.SetSize(W, H);
    Dst := PByte(Result.PixelData);
    BPL := Result.DataDescription.BytesPerLine;

    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do
      begin
        idx := y * W + x;
        if Img.NumComps >= 3 then
        begin
          r := Img.Comps[0][idx];
          g := Img.Comps[1][idx];
          b := Img.Comps[2][idx];
        end
        else
        begin
          r := Img.Comps[0][idx];
          g := r;
          b := r;
        end;

        if sh > 0 then
        begin
          r := r shr sh; g := g shr sh; b := b shr sh;
        end
        else if sh < 0 then
        begin
          r := r shl (-sh); g := g shl (-sh); b := b shl (-sh);
        end;

        Dst[x * 4 + 0] := ClampByte(b);
        Dst[x * 4 + 1] := ClampByte(g);
        Dst[x * 4 + 2] := ClampByte(r);
        Dst[x * 4 + 3] := 255;
      end;
      Inc(Dst, BPL);
    end;
  finally
    Img.Free;
  end;
end;
{$ENDIF}

initialization
  TPicture.RegisterFileFormat('Jp2','JPEG 2000 Image', TJp2Image);

finalization
  TPicture.UnregisterGraphicClass(TJp2Image);

end.
