unit BPGImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	BPG port                                                      //
// Version:	0.1                                                           //
// Date:	04-AUG-2026                                                   //
// License:     LGPL                                                          //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     bpg_common, bpg_putbits, bpg_hevc_defs, bpg_container,
     bpg_frame, bpg_output, bpg_enc, bpg_enc_rd, BitmapEveryX;

  // TBPGImage
type
  TBPGImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
    // Encode the internal bitmap to BPG and write it to Str.
    //   IsLossless       : True = exact reconstruction (4:4:4 RGB, no quantiser).
    //   CompressionLevel : lossy quality 0..100 (higher = better quality),
    //                      mapped onto the format's quantiser 51..0.
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
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

// TBPGImage

procedure TBPGImage.DecodeFromStream(Str: TStream);
var
  Data    : array of Byte;
  DataSize: NativeUInt;
  Img     : PBPGDecoderContext;
  Info    : TBPGImageInfo;
  Pixels  : PByte;
  Row     : PByte;
  W, H, Y, X, T: Integer;
begin
  DataSize := NativeUInt(Str.Size - Str.Position);
  if DataSize = 0 then
    raise EInvalidGraphic.Create('BPG: empty stream');

  SetLength(Data, DataSize);
  Str.ReadBuffer(Data[0], DataSize);

  Img := bpg_decoder_open;
  if Img = nil then
    raise EInvalidGraphic.Create('BPG: out of memory');
  Pixels := nil;
  try
    if bpg_decoder_decode(Img, @Data[0], Integer(DataSize)) < 0 then
      raise EInvalidGraphic.Create('BPG decode failed');
    if bpg_decoder_get_info(Img, @Info) < 0 then
      raise EInvalidGraphic.Create('BPG: no image information');

    W := Integer(Info.width);
    H := Integer(Info.height);
    if (W <= 0) or (H <= 0) then
      raise EInvalidGraphic.Create('BPG: bad dimensions');

    // Always ask for 8-bit RGBA, whatever the file's own depth and chroma
    // format are; the decoder converts. Bitmap_Every wants BGRA, so the red
    // and blue bytes are swapped on the way out.
    if bpg_decoder_start(Img, BPG_OUTPUT_FORMAT_RGBA32) < 0 then
      raise EInvalidGraphic.Create('BPG: unsupported output format');

    GetMem(Pixels, NativeUInt(W) * NativeUInt(H) * 4);
    for Y := 0 to H - 1 do
    begin
      Row := Pixels + NativeUInt(Y) * NativeUInt(W) * 4;
      if bpg_decoder_get_line(Img, Row) < 0 then
        raise EInvalidGraphic.Create('BPG: truncated image');
      for X := 0 to W - 1 do
      begin
        T := Row[X * 4];
        Row[X * 4] := Row[X * 4 + 2];
        Row[X * 4 + 2] := Byte(T);
      end;
    end;

    FBmp.Free;
    FBmp := Bitmap_Every(Pixels, W, H);
  finally
    if Pixels <> nil then FreeMem(Pixels);
    bpg_decoder_close(Img);
  end;
end;

procedure TBPGImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TBPGImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TBPGImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TBPGImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TBPGImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TBPGImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TBPGImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TBPGImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if source is tgraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0,0, Src);
  end;
end;

procedure TBPGImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TBPGImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                                   CompressionLevel: Integer = 75);
var
  Enc: TBpgEncoder;
  Out_: TByteBuf;
  W, H, CW, CH, X, Y, SX, SY, Qp, q: Integer;
  flags1, flags2: Integer;
  R, G, Bl, Yv, Cb, Cr: Integer;
  CbF, CrF: array of Integer;
  Row: PByte;

  procedure PlanePut(CIdx, PX, PY, V: Integer); inline;
  begin
    (PWord(Enc.Src^.Data[CIdx] + PY * Enc.Src^.Linesize[CIdx]) + PX)^ := Word(V);
  end;

begin
  if (FBmp = nil) or (FBmp.Width <= 0) or (FBmp.Height <= 0) then
    raise EInvalidGraphic.Create('BPG encode: empty bitmap');

  // Ensure a known 32-bit (B,G,R,A) layout for ScanLine.
  FBmp.PixelFormat := pf32bit;
  W := FBmp.Width;
  H := FBmp.Height;

  // CompressionLevel is a quality, the format carries a quantiser, and the two
  // run in opposite directions: 100 -> qp 0, 0 -> qp 51.
  q := CompressionLevel;
  if q < 0   then q := 0;
  if q > 100 then q := 100;
  Qp := 51 - Round(q * 51 / 100);

  bpg_enc_rd_enable(True);
  bpg_enc_lossless(IsLossless);

  // 4:4:4 codes the three planes as G, B, R with no colour conversion, which
  // is the only way a lossless file can be exact. Lossy uses 4:2:0.
  if IsLossless then
  begin
    if bpg_enc_init(Enc, W, H, 3, 8, Qp) < 0 then
      raise EInvalidGraphic.Create('BPG encode: init failed');
  end
  else
    if bpg_enc_init(Enc, W, H, 1, 8, Qp) < 0 then
      raise EInvalidGraphic.Create('BPG encode: init failed');

  try
    // The coded picture is rounded up to a whole minimum coding block; the true
    // size travels in the header and the decoder crops to it. Fill the pad with
    // edge pixels so it costs almost nothing to code.
    CW := Enc.Ctx.sps^.width;
    CH := Enc.Ctx.sps^.height;

    if IsLossless then
    begin
      for Y := 0 to CH - 1 do
      begin
        SY := Y; if SY >= H then SY := H - 1;
        Row := FBmp.ScanLine[SY];
        for X := 0 to CW - 1 do
        begin
          SX := X; if SX >= W then SX := W - 1;
          // ScanLine is B,G,R,A; the coded planes are G, B, R
          PlanePut(0, X, Y, Row[SX * 4 + 1]);
          PlanePut(1, X, Y, Row[SX * 4 + 0]);
          PlanePut(2, X, Y, Row[SX * 4 + 2]);
        end;
      end;
    end
    else
    begin
      // BT.601 full range, the inverse of the decoder's ycc_to_rgb24 with
      // k_r = 0.299 and k_b = 0.114. Chroma is box averaged over the 2x2 luma
      // samples it covers, which is where 4:2:0 places it.
      SetLength(CbF, CW * CH);
      SetLength(CrF, CW * CH);
      for Y := 0 to CH - 1 do
      begin
        SY := Y; if SY >= H then SY := H - 1;
        Row := FBmp.ScanLine[SY];
        for X := 0 to CW - 1 do
        begin
          SX := X; if SX >= W then SX := W - 1;
          Bl := Row[SX * 4 + 0];
          G  := Row[SX * 4 + 1];
          R  := Row[SX * 4 + 2];
          Yv := Round(0.299 * R + 0.587 * G + 0.114 * Bl);
          CbF[Y * CW + X] := Round((Bl - Yv) / 1.772) + 128;
          CrF[Y * CW + X] := Round((R - Yv) / 1.402) + 128;
          PlanePut(0, X, Y, av_clip_c(Yv, 0, 255));
        end;
      end;
      for Y := 0 to (CH div 2) - 1 do
        for X := 0 to (CW div 2) - 1 do
        begin
          Cb := (CbF[(2 * Y) * CW + 2 * X] + CbF[(2 * Y) * CW + 2 * X + 1] +
                 CbF[(2 * Y + 1) * CW + 2 * X] + CbF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
          Cr := (CrF[(2 * Y) * CW + 2 * X] + CrF[(2 * Y) * CW + 2 * X + 1] +
                 CrF[(2 * Y + 1) * CW + 2 * X] + CrF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
          PlanePut(1, X, Y, av_clip_c(Cb, 0, 255));
          PlanePut(2, X, Y, av_clip_c(Cr, 0, 255));
        end;
    end;

    if bpg_enc_picture(Enc) < 0 then
      raise EInvalidGraphic.Create('BPG encode failed');

    buf_init(Out_);
    try
      buf_put_byte(Out_, $42);
      buf_put_byte(Out_, $50);
      buf_put_byte(Out_, $47);
      buf_put_byte(Out_, $FB);
      // format in the top three bits, no alpha, bit_depth - 8 in the low nibble
      if IsLossless then flags1 := BPG_FORMAT_444 shl 5
      else flags1 := BPG_FORMAT_420 shl 5;
      buf_put_byte(Out_, Byte(flags1));
      // colour space, no extension, not premultiplied, full range, not animated
      if IsLossless then flags2 := (BPG_CS_RGB shl 4)
      else flags2 := (BPG_CS_YCbCr shl 4);
      buf_put_byte(Out_, Byte(flags2));
      put_ue_var(Out_, Cardinal(W));
      put_ue_var(Out_, Cardinal(H));
      // hevc_data_len 0 means "to the end of the file"
      put_ue_var(Out_, 0);

      put_ue_var(Out_, Cardinal(Enc.MspsTail.Len));
      buf_put(Out_, Enc.MspsTail.Buf, Enc.MspsTail.Len);

      // the first NAL carries no start code, the rest do
      put_nal_no_startcode(Out_, NAL_PPS, Enc.PpsRbsp.Buf, Enc.PpsRbsp.Len);
      put_nal(Out_, NAL_IDR_W_RADL, 1, Enc.SliceRbsp.Buf, Enc.SliceRbsp.Len);

      Str.WriteBuffer(Out_.Buf^, Out_.Len);
    finally
      buf_free(Out_);
    end;
  finally
    bpg_enc_free(Enc);
  end;
end;

procedure TBPGImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

constructor TBPGImage.Create;
begin
  inherited Create;

  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1,1);
end;

destructor TBPGImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TBPGImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('BPG','BPG Image', TBPGImage);

finalization
  TPicture.UnregisterGraphicClass(TBPGImage);

end.
