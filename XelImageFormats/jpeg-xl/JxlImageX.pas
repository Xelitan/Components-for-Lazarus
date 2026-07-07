unit JxlImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Jxl port                                                      //
// Version:	0.3                                                           //
// Date:	17-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     jxl_encoder, jxlimage;

  { TJxlImage }
type
  TJxlImage = class(TGraphic)
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
    // Encode the internal bitmap to Jxl and write it to Str.
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                             CompressionLevel: Integer = 75);
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    constructor Create; override;
    destructor Destroy; override;
    function ToBitmap: TBitmap;
  end;

implementation

{ TJxlImage }


procedure TJxlImage.DecodeFromStream(Str: TStream);
var
  Pixels: TBytes;
  W, H: Integer;
  X, Y: Integer;
  SrcIndex: NativeInt;
  RequiredSize: NativeUInt;
  P: PByteArray;
  Dec: TJxlDecoder;
begin
  Dec := TJxlDecoder.Create;
  try
    Dec.LoadFromStream(Str);

    W := Dec.Width;
    H := Dec.Height;
    Pixels := Dec.GetRGBA8;

    RequiredSize := NativeUInt(W) * NativeUInt(H) * 4;

    if (W <= 0) or
       (H <= 0) or
       (NativeUInt(Length(Pixels)) < RequiredSize) then
      raise EInvalidGraphic.Create('JXL decode failed');

    FBmp.PixelFormat := pf32bit;
    FBmp.SetSize(W, H);

    SrcIndex := 0;

    for Y := 0 to H - 1 do
    begin
      P := FBmp.ScanLine[Y];

      for X := 0 to W - 1 do
      begin
        P[X * 4 + 0] := Pixels[SrcIndex + 2];
        P[X * 4 + 1] := Pixels[SrcIndex + 1];
        P[X * 4 + 2] := Pixels[SrcIndex + 0];
        P[X * 4 + 3] := Pixels[SrcIndex + 3];

        Inc(SrcIndex, 4);
      end;
    end;
  finally
    Dec.Free;
  end;
end;

procedure TJxlImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TJxlImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TJxlImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TJxlImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TJxlImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TJxlImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TJxlImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TJxlImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TJxlImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TJxlImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
  CompressionLevel: Integer = 75);
var
  RGB, JXL: TBytes;
  W, H: Integer;
  x, y: Integer;
  SrcIndex: NativeInt;
  Quality: Integer;
  P: PByteArray;
begin
  if (Str = nil) or
     (FBmp = nil) or
     (FBmp.Width <= 0) or
     (FBmp.Height <= 0) or
     (NativeUInt(FBmp.Width) * NativeUInt(FBmp.Height) >
      NativeUInt(MaxInt div 4)) then
    raise EInvalidGraphic.Create('JXL encode failed');

  W := FBmp.Width;
  H := FBmp.Height;

  FBmp.PixelFormat := pf32bit;

  SetLength(RGB, W * H * 4);

  SrcIndex := 0;

  for y := 0 to H - 1 do
  begin
    P := FBmp.ScanLine[y];

    for x := 0 to W - 1 do
    begin
      RGB[SrcIndex + 0] := P[x * 4 + 2];
      RGB[SrcIndex + 1] := P[x * 4 + 1];
      RGB[SrcIndex + 2] := P[x * 4 + 0];
      RGB[SrcIndex + 3] := P[x * 4 + 3];

      Inc(SrcIndex, 4);
    end;
  end;

  if IsLossless then  Quality := 100
  else
  begin
    Quality := CompressionLevel;

    if Quality < 1 then  Quality := 1
    else if Quality > 100 then  Quality := 100;
  end;

  JXL := JxlEncodeRGBA8(RGB, W, H, Quality);

  if Length(JXL) = 0 then
    raise EInvalidGraphic.Create('JXL encode failed');

  Str.WriteBuffer(JXL[0], Length(JXL));
end;

procedure TJxlImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

constructor TJxlImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TJxlImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TJxlImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('Jxl','JPEG XL Image', TJxlImage);

finalization
  TPicture.UnregisterGraphicClass(TJxlImage);

end.
