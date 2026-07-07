unit JBig2ImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JBIG2 decoder, ported from Apache PDFBox jbig2                //
// Version:	0.1                                                           //
// Date:	24-JUN-2026                                                   //
// License:     Apache-2.0                                                    //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Types,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     PdfJbig2;

  { TJBig2Image }
type
  TJBig2Image = class(TGraphic)
  private
    FBmp: TBitmap;
    FGlobals: TBytes;
    procedure DecodeBytes(const Data: TBytes);
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
    // Supply the /JBIG2Globals stream bytes before LoadFromStream (optional).
    procedure SetGlobals(const Globals: TBytes);
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    // Decode straight from byte buffers (the form the PDF reader uses).
    procedure LoadFromBytes(const Data, Globals: TBytes);
    function ToBitmap: TBitmap;
  end;

// Decode a JBIG2 image to 8-bit grayscale, 1 byte per pixel, row-major,
// 0 = black and 255 = white (the same convention as PdfCcitt's output, so it
// feeds the renderer's DrawRawDeviceGray path directly). Globals may be empty.
function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;

implementation

function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;
begin
  Result := DecodeJBIG2(Data, Globals, W, H, Gray);
end;

{ TJBig2Image }

constructor TJBig2Image.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
end;

destructor TJBig2Image.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

procedure TJBig2Image.SetGlobals(const Globals: TBytes);
begin
  FGlobals := Globals;
end;

procedure TJBig2Image.DecodeBytes(const Data: TBytes);
var
  gray: TBytes;
  w, h, x, y, v: Integer;
  Row: PByte;
begin
  if not DecodeJBIG2(Data, FGlobals, w, h, gray) then Exit;
  if (w <= 0) or (h <= 0) then Exit;

  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(w, h);
  for y := 0 to h - 1 do
  begin
    Row := PByte(FBmp.ScanLine[y]);
    for x := 0 to w - 1 do
    begin
      v := gray[y * w + x];           // 0 = black, 255 = white
      // 32-bit DIB rows are BGRA on Windows.
      Row[x * 4 + 0] := v;
      Row[x * 4 + 1] := v;
      Row[x * 4 + 2] := v;
      Row[x * 4 + 3] := 255;
    end;
  end;
end;

procedure TJBig2Image.LoadFromBytes(const Data, Globals: TBytes);
begin
  FGlobals := Globals;
  DecodeBytes(Data);
end;

procedure TJBig2Image.LoadFromStream(Stream: TStream);
var Bytes: TBytes; n: Integer;
begin
  n := Stream.Size - Stream.Position;
  if n <= 0 then Exit;
  SetLength(Bytes, n);
  Stream.ReadBuffer(Bytes[0], n);
  DecodeBytes(Bytes);
end;

procedure TJBig2Image.SaveToStream(Stream: TStream);
begin
  // Encoding is not supported.
end;

function TJBig2Image.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

procedure TJBig2Image.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TJBig2Image.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TJBig2Image.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

function TJBig2Image.GetTransparent: Boolean;
begin
  Result := False;
end;

procedure TJBig2Image.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TJBig2Image.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TJBig2Image.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TJBig2Image.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then
  begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

initialization
  TPicture.RegisterFileFormat('Jb2','JBIG2 Image', TJBig2Image);

finalization
  TPicture.UnregisterGraphicClass(TJBig2Image);

end.
