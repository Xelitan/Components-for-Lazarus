unit XelZoomImage;

//Author: www.xelitan.com
//License: MIT

{$mode delphi}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, StdCtrls, Math,
  LCLType, LCLIntf, IntfGraphics, FPImage, GraphType;

type
  // What fills the control behind / around the image (and the seams between the
  // scrollbars). For transparent images the alpha is composited over this, and
  // the checkerboard keeps the same cell size everywhere (screen space).
  TXelZoomBackground = (zbColor, zbCheckerboard);

  // An image viewer like TImage with mouse-wheel zoom:
  //   - wheel up zooms in, centered on the cursor, nearest-neighbor so enlarged
  //     pixels stay crisp; scrollbars appear when the image overflows;
  //   - wheel down zooms out with a smooth (halftone / bilinear) filter; a
  //     smaller-than-control image is centered on each axis.
  // Transparent images are alpha-composited over the background; opaque images
  // take a fast GDI path.
  TXelZoomImage = class(TCustomControl)
  private
    FPicture: TPicture;
    FSrcBmp: TBitmap;           // opaque source (fast StretchBlt path)
    FSrcImg: TLazIntfImage;     // source with alpha (per-pixel path); nil if opaque
    FHasAlpha: Boolean;
    FImgW, FImgH: Integer;
    FSrcDirty: Boolean;
    FViewBmp: TBitmap;          // reused scratch buffer for the per-pixel path
    FBackground: TXelZoomBackground;
    FZoom: Double;
    FMinZoom: Double;
    FMaxZoom: Double;
    FZoomStep: Double;
    FZoomLevels: string;
    FLevels: array of Double;   // parsed zoom levels (fractions), ascending
    FOffsetX: Integer;
    FOffsetY: Integer;
    FViewW: Integer;
    FViewH: Integer;
    FHScroll: TScrollBar;
    FVScroll: TScrollBar;
    FUpdatingScroll: Boolean;
    procedure PictureChanged(Sender: TObject);
    procedure SetPicture(AValue: TPicture);
    procedure SetBackground(AValue: TXelZoomBackground);
    procedure SetZoom(AValue: Double);
    procedure SetZoomLevels(const AValue: string);
    procedure EnsureSource;
    procedure DrawBackground(ACanvas: TCanvas; const R: TRect);
    function BgColorAt(vx, vy: Integer): TFPColor;
    function StepLevel(ZoomIn: Boolean): Double;
    procedure ScrollChanged(Sender: TObject);
    procedure UpdateLayout(DesiredOffsetX, DesiredOffsetY: Integer);
    procedure ZoomAt(NewZoom: Double; ClientX, ClientY: Integer);
    procedure PaintOpaque;
    procedure PaintAlpha;
  protected
    procedure Paint; override;
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ZoomToFit;
    procedure ZoomActual;
    property Zoom: Double read FZoom write SetZoom;
    // Code-only (not in the Object Inspector): comma-separated percentages the
    // wheel snaps through. Preset to a sensible scale; set '' for smooth zoom.
    property ZoomLevels: string read FZoomLevels write SetZoomLevels;
  published
    property Picture: TPicture read FPicture write SetPicture;
    property Background: TXelZoomBackground read FBackground write SetBackground default zbColor;
    property MinZoom: Double read FMinZoom write FMinZoom;
    property MaxZoom: Double read FMaxZoom write FMaxZoom;
    property ZoomStep: Double read FZoomStep write FZoomStep;
    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Enabled;
    property Visible;
    property Width default 320;
    property Height default 240;
    property OnClick;
    property OnMouseWheel;
  end;

procedure Register;

implementation

{$R txelzoomimage_images.res}

const
  SB_SIZE     = 16; // scrollbar thickness
  CHECK_SIZE  = 8;  // checkerboard square size (screen pixels)
  CHECK_LIGHT = TColor($00F0F0F0);
  CHECK_DARK  = TColor($00C8C8C8);
  DEFAULT_LEVELS =
    '7,10,15,20,25,30,50,70,100,150,200,300,400,500,600,700,800,1000,1200,1600';

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelZoomImage]);
end;

constructor TXelZoomImage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  FZoom       := 1.0;
  FMinZoom    := 0.05;
  FMaxZoom    := 64.0;
  FZoomStep   := 1.2;
  FBackground := zbColor;
  FSrcDirty   := True;

  FPicture := TPicture.Create;
  FPicture.OnChange := PictureChanged;
  FSrcBmp  := TBitmap.Create;
  FViewBmp := TBitmap.Create;
  FViewBmp.PixelFormat := pf24bit;

  FHScroll := TScrollBar.Create(Self);
  FHScroll.Parent   := Self;
  FHScroll.Kind     := sbHorizontal;
  FHScroll.Visible  := False;
  FHScroll.OnChange := ScrollChanged;

  FVScroll := TScrollBar.Create(Self);
  FVScroll.Parent   := Self;
  FVScroll.Kind     := sbVertical;
  FVScroll.Visible  := False;
  FVScroll.OnChange := ScrollChanged;

  SetZoomLevels(DEFAULT_LEVELS); // preset zoom scale; wheel snaps through it

  Width  := 320;
  Height := 240;
end;

destructor TXelZoomImage.Destroy;
begin
  FSrcImg.Free;
  FViewBmp.Free;
  FSrcBmp.Free;
  FPicture.Free;
  inherited Destroy;
end;

procedure TXelZoomImage.EnsureSource;
var
  TmpImg: TLazIntfImage;
begin
  if not FSrcDirty then Exit;
  FSrcDirty := False;
  FreeAndNil(FSrcImg);
  FHasAlpha := False;

  if (FPicture.Graphic = nil) or FPicture.Graphic.Empty then
  begin
    FImgW := 0;
    FImgH := 0;
    FSrcBmp.SetSize(0, 0);
    Exit;
  end;

  FImgW := FPicture.Width;
  FImgH := FPicture.Height;

  // Render the picture to an opaque bitmap (also the fast-path source).
  FSrcBmp.PixelFormat := pf24bit;
  FSrcBmp.SetSize(FImgW, FImgH);
  FSrcBmp.Canvas.Draw(0, 0, FPicture.Graphic);

  // Detect a real alpha channel; if present, keep an RGBA image for compositing.
  if FPicture.Graphic is TRasterImage then
  begin
    TmpImg := TRasterImage(FPicture.Graphic).CreateIntfImage;
    if TmpImg.DataDescription.AlphaPrec > 0 then
    begin
      FHasAlpha := True;
      FSrcImg := TmpImg;
    end
    else
      TmpImg.Free;
  end;
end;

procedure TXelZoomImage.PictureChanged(Sender: TObject);
begin
  FSrcDirty := True;
  EnsureSource;
  UpdateLayout(0, 0); // show a new image centered at the current zoom
end;

procedure TXelZoomImage.SetPicture(AValue: TPicture);
begin
  FPicture.Assign(AValue); // triggers PictureChanged via OnChange
end;

procedure TXelZoomImage.SetBackground(AValue: TXelZoomBackground);
begin
  if FBackground = AValue then Exit;
  FBackground := AValue;
  Invalidate;
end;

procedure TXelZoomImage.SetZoom(AValue: Double);
begin
  ZoomAt(AValue, FViewW div 2, FViewH div 2);
end;

procedure TXelZoomImage.SetZoomLevels(const AValue: string);
var
  Parts: TStringList;
  i, j: Integer;
  v, tmp: Double;
begin
  FZoomLevels := AValue;
  SetLength(FLevels, 0);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := AValue;
    for i := 0 to Parts.Count - 1 do
    begin
      v := StrToFloatDef(Trim(Parts[i]), 0);
      if v > 0 then
      begin
        SetLength(FLevels, Length(FLevels) + 1);
        FLevels[High(FLevels)] := v / 100.0; // percent -> fraction
      end;
    end;
  finally
    Parts.Free;
  end;
  for i := 0 to High(FLevels) - 1 do
    for j := i + 1 to High(FLevels) do
      if FLevels[j] < FLevels[i] then
      begin
        tmp := FLevels[i]; FLevels[i] := FLevels[j]; FLevels[j] := tmp;
      end;
end;

function TXelZoomImage.StepLevel(ZoomIn: Boolean): Double;
var
  i: Integer;
begin
  Result := FZoom;
  if Length(FLevels) = 0 then
  begin
    if ZoomIn then Result := FZoom * FZoomStep else Result := FZoom / FZoomStep;
    Exit;
  end;
  if ZoomIn then
  begin
    for i := 0 to High(FLevels) do
      if FLevels[i] > FZoom * 1.0001 then Exit(FLevels[i]);
    Result := FLevels[High(FLevels)];
  end
  else
  begin
    for i := High(FLevels) downto 0 do
      if FLevels[i] < FZoom * 0.9999 then Exit(FLevels[i]);
    Result := FLevels[0];
  end;
end;

function TXelZoomImage.BgColorAt(vx, vy: Integer): TFPColor;
begin
  if FBackground = zbColor then
    Result := TColorToFPColor(ColorToRGB(Color))
  else if ((vx div CHECK_SIZE) + (vy div CHECK_SIZE)) and 1 = 0 then
    Result := TColorToFPColor(CHECK_LIGHT)
  else
    Result := TColorToFPColor(CHECK_DARK);
end;

procedure TXelZoomImage.DrawBackground(ACanvas: TCanvas; const R: TRect);
var
  x, y: Integer;
  Cell: TRect;
begin
  if FBackground = zbColor then
  begin
    ACanvas.Brush.Color := Color;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.FillRect(R);
    Exit;
  end;

  ACanvas.Brush.Style := bsSolid;
  y := (R.Top div CHECK_SIZE) * CHECK_SIZE;
  while y < R.Bottom do
  begin
    x := (R.Left div CHECK_SIZE) * CHECK_SIZE;
    while x < R.Right do
    begin
      if ((x div CHECK_SIZE) + (y div CHECK_SIZE)) and 1 = 0 then
        ACanvas.Brush.Color := CHECK_LIGHT
      else
        ACanvas.Brush.Color := CHECK_DARK;
      Cell := Rect(Max(x, R.Left), Max(y, R.Top),
                   Min(x + CHECK_SIZE, R.Right), Min(y + CHECK_SIZE, R.Bottom));
      ACanvas.FillRect(Cell);
      Inc(x, CHECK_SIZE);
    end;
    Inc(y, CHECK_SIZE);
  end;
end;

procedure TXelZoomImage.UpdateLayout(DesiredOffsetX, DesiredOffsetY: Integer);
var
  SW, SH: Integer;
  vw, vh: Integer;
  needH, needV: Boolean;
begin
  if FImgW = 0 then
  begin
    FHScroll.Visible := False;
    FVScroll.Visible := False;
    FOffsetX := 0;
    FOffsetY := 0;
    FViewW := ClientWidth;
    FViewH := ClientHeight;
    Invalidate;
    Exit;
  end;

  SW := Round(FImgW * FZoom);
  SH := Round(FImgH * FZoom);

  vw := ClientWidth;
  vh := ClientHeight;
  needV := SH > vh;
  if needV then Dec(vw, SB_SIZE);
  needH := SW > vw;
  if needH then Dec(vh, SB_SIZE);
  if (not needV) and (SH > vh) then
  begin
    needV := True;
    Dec(vw, SB_SIZE);
  end;
  FViewW := vw;
  FViewH := vh;

  if needH then
  begin
    if DesiredOffsetX > 0 then DesiredOffsetX := 0;
    if DesiredOffsetX < vw - SW then DesiredOffsetX := vw - SW;
    FOffsetX := DesiredOffsetX;
  end
  else
    FOffsetX := (vw - SW) div 2;

  if needV then
  begin
    if DesiredOffsetY > 0 then DesiredOffsetY := 0;
    if DesiredOffsetY < vh - SH then DesiredOffsetY := vh - SH;
    FOffsetY := DesiredOffsetY;
  end
  else
    FOffsetY := (vh - SH) div 2;

  FUpdatingScroll := True;
  if needH then
  begin
    FHScroll.SetBounds(0, ClientHeight - SB_SIZE, vw, SB_SIZE);
    FHScroll.Min        := 0;
    FHScroll.Max        := SW;
    FHScroll.PageSize   := vw;
    FHScroll.LargeChange := Max(1, vw - 8);
    FHScroll.SmallChange := Max(1, vw div 16);
    FHScroll.Position   := -FOffsetX;
    FHScroll.Visible    := True;
  end
  else
    FHScroll.Visible := False;

  if needV then
  begin
    FVScroll.SetBounds(ClientWidth - SB_SIZE, 0, SB_SIZE, vh);
    FVScroll.Min        := 0;
    FVScroll.Max        := SH;
    FVScroll.PageSize   := vh;
    FVScroll.LargeChange := Max(1, vh - 8);
    FVScroll.SmallChange := Max(1, vh div 16);
    FVScroll.Position   := -FOffsetY;
    FVScroll.Visible    := True;
  end
  else
    FVScroll.Visible := False;
  FUpdatingScroll := False;

  Invalidate;
end;

procedure TXelZoomImage.ScrollChanged(Sender: TObject);
begin
  if FUpdatingScroll then Exit;
  if FHScroll.Visible then FOffsetX := -FHScroll.Position;
  if FVScroll.Visible then FOffsetY := -FVScroll.Position;
  Invalidate;
end;

procedure TXelZoomImage.ZoomAt(NewZoom: Double; ClientX, ClientY: Integer);
var
  OldZoom: Double;
  SrcX, SrcY: Double;
begin
  if FImgW = 0 then Exit;
  if NewZoom < FMinZoom then NewZoom := FMinZoom;
  if NewZoom > FMaxZoom then NewZoom := FMaxZoom;
  OldZoom := FZoom;
  if Abs(NewZoom - OldZoom) < 1E-6 then Exit;

  SrcX := (ClientX - FOffsetX) / OldZoom;
  SrcY := (ClientY - FOffsetY) / OldZoom;

  FZoom := NewZoom;

  UpdateLayout(Round(ClientX - SrcX * FZoom), Round(ClientY - SrcY * FZoom));
end;

procedure TXelZoomImage.ZoomToFit;
var
  z: Double;
begin
  if FImgW = 0 then Exit;
  z := Min(ClientWidth / FImgW, ClientHeight / FImgH);
  if z < FMinZoom then z := FMinZoom;
  if z > FMaxZoom then z := FMaxZoom;
  FZoom := z;
  UpdateLayout(0, 0);
end;

procedure TXelZoomImage.ZoomActual;
begin
  FZoom := 1.0;
  UpdateLayout(FOffsetX, FOffsetY);
end;

procedure TXelZoomImage.Resize;
begin
  inherited Resize;
  UpdateLayout(FOffsetX, FOffsetY);
end;

function TXelZoomImage.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  if Result then Exit;
  if FImgW = 0 then Exit;

  P := ScreenToClient(MousePos);
  ZoomAt(StepLevel(WheelDelta > 0), P.X, P.Y);
  Result := True;
end;

// Opaque images: scale only the visible source sub-rectangle with the GDI
// stretch blitter (crisp nearest when enlarging, smooth halftone when shrinking).
procedure TXelZoomImage.PaintOpaque;
var
  srcL, srcT, srcR, srcB, sw, sh, dx, dy, dw, dh: Integer;
begin
  srcL := Max(0,     Floor((0 - FOffsetX) / FZoom));
  srcT := Max(0,     Floor((0 - FOffsetY) / FZoom));
  srcR := Min(FImgW, Ceil((FViewW - FOffsetX) / FZoom));
  srcB := Min(FImgH, Ceil((FViewH - FOffsetY) / FZoom));
  sw := srcR - srcL;
  sh := srcB - srcT;
  if (sw <= 0) or (sh <= 0) then Exit;

  dx := Round(FOffsetX + srcL * FZoom);
  dy := Round(FOffsetY + srcT * FZoom);
  dw := Round(sw * FZoom);
  dh := Round(sh * FZoom);

  IntersectClipRect(Canvas.Handle, 0, 0, FViewW, FViewH);
  if FZoom >= 1.0 then
    SetStretchBltMode(Canvas.Handle, COLORONCOLOR)
  else
    SetStretchBltMode(Canvas.Handle, HALFTONE);
  StretchBlt(Canvas.Handle, dx, dy, dw, dh,
             FSrcBmp.Canvas.Handle, srcL, srcT, sw, sh, SRCCOPY);
end;

// Transparent images: render the visible footprint pixel by pixel, compositing
// the image's alpha over the (screen-space) background.
procedure TXelZoomImage.PaintAlpha;
var
  fpL, fpT, fpR, fpB, bw, bh: Integer;
  SW, SH: Integer;
  bx, by, vx, vy: Integer;
  fx, fy: Double;
  x0, y0, x1, y1: Integer;
  dxf, dyf, a: Double;
  bg, s, c00, c10, c01, c11: TFPColor;
  dst: TLazIntfImage;

  function SampleBilinear: TFPColor;
  begin
    c00 := FSrcImg.Colors[x0, y0];
    c10 := FSrcImg.Colors[x1, y0];
    c01 := FSrcImg.Colors[x0, y1];
    c11 := FSrcImg.Colors[x1, y1];
    Result.red   := Round((c00.red  *(1-dxf)+c10.red  *dxf)*(1-dyf) + (c01.red  *(1-dxf)+c11.red  *dxf)*dyf);
    Result.green := Round((c00.green*(1-dxf)+c10.green*dxf)*(1-dyf) + (c01.green*(1-dxf)+c11.green*dxf)*dyf);
    Result.blue  := Round((c00.blue *(1-dxf)+c10.blue *dxf)*(1-dyf) + (c01.blue *(1-dxf)+c11.blue *dxf)*dyf);
    Result.alpha := Round((c00.alpha*(1-dxf)+c10.alpha*dxf)*(1-dyf) + (c01.alpha*(1-dxf)+c11.alpha*dxf)*dyf);
  end;

begin
  SW := Round(FImgW * FZoom);
  SH := Round(FImgH * FZoom);

  fpL := Max(0, FOffsetX);
  fpT := Max(0, FOffsetY);
  fpR := Min(FViewW, FOffsetX + SW);
  fpB := Min(FViewH, FOffsetY + SH);
  bw := fpR - fpL;
  bh := fpB - fpT;
  if (bw <= 0) or (bh <= 0) then Exit;

  FViewBmp.SetSize(bw, bh);
  dst := FViewBmp.CreateIntfImage;
  try
    for by := 0 to bh - 1 do
    begin
      vy := fpT + by;
      for bx := 0 to bw - 1 do
      begin
        vx := fpL + bx;
        bg := BgColorAt(vx, vy);
        fx := (vx - FOffsetX) / FZoom;
        fy := (vy - FOffsetY) / FZoom;

        if FZoom >= 1.0 then
        begin
          // nearest neighbor -> crisp pixels
          x0 := Min(FImgW - 1, Max(0, Trunc(fx)));
          y0 := Min(FImgH - 1, Max(0, Trunc(fy)));
          s := FSrcImg.Colors[x0, y0];
        end
        else
        begin
          x0 := Min(FImgW - 1, Max(0, Floor(fx)));
          y0 := Min(FImgH - 1, Max(0, Floor(fy)));
          x1 := Min(FImgW - 1, x0 + 1);
          y1 := Min(FImgH - 1, y0 + 1);
          dxf := fx - Floor(fx);
          dyf := fy - Floor(fy);
          s := SampleBilinear;
        end;

        a := s.alpha / alphaOpaque;
        bg.red   := Round(bg.red   * (1 - a) + s.red   * a);
        bg.green := Round(bg.green * (1 - a) + s.green * a);
        bg.blue  := Round(bg.blue  * (1 - a) + s.blue  * a);
        bg.alpha := alphaOpaque;
        dst.Colors[bx, by] := bg;
      end;
    end;
    FViewBmp.LoadFromIntfImage(dst);
  finally
    dst.Free;
  end;

  Canvas.Draw(fpL, fpT, FViewBmp);
end;

procedure TXelZoomImage.Paint;
begin
  // Background over the whole client (also fills the corner between scrollbars).
  DrawBackground(Canvas, ClientRect);

  EnsureSource;
  if FImgW = 0 then Exit;

  if FHasAlpha and Assigned(FSrcImg) then
    PaintAlpha
  else
    PaintOpaque;

  // Re-cover the strips occupied by the scrollbars and the corner between them
  // so a rounded StretchBlt edge can never bleed into those areas. The corner
  // gets clBtnFace (the surrounding chrome colour), not the image background,
  // so it looks like a continuation of the form. The strips themselves are
  // overdrawn by the scrollbars anyway.
  Canvas.Brush.Color := clBtnFace;
  Canvas.Brush.Style := bsSolid;
  if FVScroll.Visible then
    Canvas.FillRect(Rect(FViewW, 0, ClientWidth, ClientHeight));
  if FHScroll.Visible then
    Canvas.FillRect(Rect(0, FViewH, ClientWidth, ClientHeight));
end;

initialization
  RegisterClasses([TXelZoomImage]);

end.
