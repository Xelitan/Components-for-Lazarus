unit FLIFImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	FLIF port                                                     //
// Version:	0.1                                                           //
// Date:	04-AUG-2026                                                   //
// License:     Apache 2/LGPL                                                 //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     flif_types, flif_io, flif_image, flif_dec, flif_enc, BitmapEveryX;

  // TFLIFImage
type
  TFLIFImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
    // Encode the internal bitmap to FLIF and write it to Str.
    //   IsLossless       : FLIF is a lossless format; True keeps it that way.
    //                      False asks for the lossy mode, whose strength comes
    //                      from CompressionLevel.
    //   CompressionLevel : 0..100 (higher = better quality). Ignored when
    //                      IsLossless is True.
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = True;
                             CompressionLevel: Integer = 75);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer);override;

  public
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    constructor Create; override;
    destructor Destroy; override;
    function ToBitmap: TBitmap;
  end;

implementation

// TFLIFImage

procedure TFLIFImage.DecodeFromStream(Str: TStream);
var
  Data    : array of Byte;
  DataSize: NativeUInt;
  IO      : TBlobIO;
  Imgs    : TImages;
  Options : TFlifOptions;
  MD      : TMetadataOptions;
  Img     : TImage;
  Pixels  : PByte;
  Row     : PByte;
  W, H, X, Y, NP, Shift: Integer;
  I: Integer;
begin
  DataSize := NativeUInt(Str.Size - Str.Position);
  if DataSize = 0 then
    raise EInvalidGraphic.Create('FLIF: empty stream');

  SetLength(Data, DataSize);
  Str.ReadBuffer(Data[0], DataSize);

  Options := DefaultOptions;
  MD := DefaultMetadataOptions;
  SetLength(Imgs, 0);
  Pixels := nil;

  IO := TBlobIO.CreateFromBuffer(@Data[0], SizeInt(DataSize));
  try
    if not FlifDecode(IO, Imgs, Options, MD) then
      if Length(Imgs) = 0 then
        raise EInvalidGraphic.Create('FLIF decode failed');
    if Length(Imgs) = 0 then
      raise EInvalidGraphic.Create('FLIF: no frames');

    // An animation decodes to several frames; a TGraphic shows one, so the
    // first is taken and the rest released.
    Img := Imgs[0];
    W := Integer(Img.Cols);
    H := Integer(Img.Rows);
    if (W <= 0) or (H <= 0) then
      raise EInvalidGraphic.Create('FLIF: bad dimensions');

    NP := Img.NumPlanes;
    // FLIF carries its own bit depth; anything deeper than 8 is shifted down
    // rather than clipped, so highlights survive.
    if Img.GetDepth > 8 then Shift := Img.GetDepth - 8 else Shift := 0;

    GetMem(Pixels, NativeUInt(W) * NativeUInt(H) * 4);
    for Y := 0 to H - 1 do
    begin
      Row := Pixels + NativeUInt(Y) * NativeUInt(W) * 4;
      for X := 0 to W - 1 do
      begin
        if NP >= 3 then
        begin
          // Bitmap_Every wants B,G,R,A; FLIF planes are R,G,B(,A)
          Row[X * 4 + 0] := Byte(EnsureRange(Img.GetVal(2, Y, X) shr Shift, 0, 255));
          Row[X * 4 + 1] := Byte(EnsureRange(Img.GetVal(1, Y, X) shr Shift, 0, 255));
          Row[X * 4 + 2] := Byte(EnsureRange(Img.GetVal(0, Y, X) shr Shift, 0, 255));
        end
        else
        begin
          // greyscale: one plane feeds all three channels
          Row[X * 4 + 0] := Byte(EnsureRange(Img.GetVal(0, Y, X) shr Shift, 0, 255));
          Row[X * 4 + 1] := Row[X * 4 + 0];
          Row[X * 4 + 2] := Row[X * 4 + 0];
        end;
        if NP >= 4 then
          Row[X * 4 + 3] := Byte(EnsureRange(Img.GetVal(3, Y, X) shr Shift, 0, 255))
        else
          Row[X * 4 + 3] := 255;
      end;
    end;

    FBmp.Free;
    FBmp := Bitmap_Every(Pixels, W, H);
  finally
    if Pixels <> nil then FreeMem(Pixels);
    for I := 0 to High(Imgs) do Imgs[I].Free;
    SetLength(Imgs, 0);
    IO.Free;
  end;
end;

procedure TFLIFImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TFLIFImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TFLIFImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TFLIFImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TFLIFImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TFLIFImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TFLIFImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TFLIFImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TFLIFImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TFLIFImage.EncodeToStream(Str: TStream; IsLossless: Boolean = True;
                                    CompressionLevel: Integer = 75);
var
  IO      : TFlifIO;
  Imgs    : TImages;
  Options : TFlifOptions;
  Img     : TImage;
  W, H, X, Y, q: Integer;
  Row     : PByte;
  Desc    : array of string;
  NbPixels: QWord;
  I: Integer;

  procedure AddDesc(const D: string);
  begin
    SetLength(Desc, Length(Desc) + 1);
    Desc[High(Desc)] := D;
  end;

begin
  if (FBmp = nil) or (FBmp.Width <= 0) or (FBmp.Height <= 0) then
    raise EInvalidGraphic.Create('FLIF encode: empty bitmap');

  // Ensure a known 32-bit (B,G,R,A) layout for ScanLine.
  FBmp.PixelFormat := pf32bit;
  W := FBmp.Width;
  H := FBmp.Height;

  Options := DefaultOptions;
  if IsLossless then
    Options.loss := 0
  else
  begin
    // FLIF's loss runs the other way from a quality: 0 is lossless and larger
    // values throw more away.
    q := CompressionLevel;
    if q < 0   then q := 0;
    if q > 100 then q := 100;
    Options.loss := Round((100 - q) * 100 / 100);
  end;

  Img := TImage.Create(Cardinal(W), Cardinal(H), 0, 255, 3);
  try
    for Y := 0 to H - 1 do
    begin
      Row := FBmp.ScanLine[Y];
      for X := 0 to W - 1 do
      begin
        // ScanLine is B,G,R,A; FLIF planes are R,G,B
        Img.SetVal(0, Y, X, Row[X * 4 + 2]);
        Img.SetVal(1, Y, X, Row[X * 4 + 1]);
        Img.SetVal(2, Y, X, Row[X * 4 + 0]);
      end;
    end;

    SetLength(Imgs, 1);
    Imgs[0] := Img;

    // The preamble the reference encoder runs before FlifEncode. It is not
    // optional: Options.method starts as feUndefined, which the encoder
    // rejects outright, and palette_size and learn_repeats start at -1 meaning
    // "decide for me". The transform list and its ORDER belong to the format,
    // not to taste. Mirrored from flifpas.lpr.
    NbPixels := QWord(H) * QWord(W);
    SetLength(Desc, 0);
    if NbPixels > 2 then
    begin
      if Options.plc <> 0 then AddDesc('Channel_Compact');
      if Options.ycocg <> 0 then AddDesc('YCoCg');
      AddDesc('PermutePlanes');
      AddDesc('Bounds');
    end;
    if Options.palette_size = -1 then
    begin
      Options.palette_size := DEFAULT_MAX_PALETTE_SIZE;
      if NbPixels div 3 < DEFAULT_MAX_PALETTE_SIZE then
        Options.palette_size := Integer(NbPixels div 3);
    end;
    if (Options.loss = 0) and (Options.palette_size <> 0) then
    begin
      AddDesc('Palette_Alpha');
      AddDesc('Palette');
    end;
    if (Options.loss = 0) and (NbPixels > 10000) then
      AddDesc('Color_Buckets');
    if Options.method = feUndefined then
    begin
      if NbPixels < 10000 then Options.method := feNonInterlaced
      else Options.method := feInterlaced;
    end;
    if Options.learn_repeats < 0 then Options.learn_repeats := TREE_LEARN_REPEATS;

    IO := TFlifIO.Create;   // memory buffer
    try
      if not FlifEncode(IO, Imgs, Desc, Options) then
        raise EInvalidGraphic.Create('FLIF encode failed');
      IO.Flush;
      if IO.BytesUsed <= 0 then
        raise EInvalidGraphic.Create('FLIF encode produced nothing');
      Str.WriteBuffer(IO.Data^, IO.BytesUsed);
    finally
      IO.Free;
    end;
  finally
    for I := 0 to High(Imgs) do
      if Imgs[I] <> nil then Imgs[I].Free;
    SetLength(Imgs, 0);
  end;
end;

procedure TFLIFImage.SaveToStream(Stream: TStream);
begin
  // Default: lossless, which is what FLIF is for.
  EncodeToStream(Stream, True, 75);
end;

constructor TFLIFImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TFLIFImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TFLIFImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('FLIF','FLIF Image', TFLIFImage);

finalization
  TPicture.UnregisterGraphicClass(TFLIFImage);

end.
