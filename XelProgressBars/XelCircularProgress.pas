unit XelCircularProgress;

//Author: xelitan.com
//License: MIT

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math,
  IntfGraphics,  // TLazIntfImage, CreateIntfImage, LoadFromIntfImage
  FPImage;       // TFPColor, FPColor

type
  TXelCircularProgress = class(TCustomControl)
  private
    FMin: Integer;
    FMax: Integer;
    FValue: Integer;
    FTrackColor: TColor;
    FProgressColor: TColor;
    FLineWidth: Integer;
    FShowText: Boolean;
    FTextFormat: string;
    FAntialiased: Boolean;
    procedure SetMin(AValue: Integer);
    procedure SetMax(AValue: Integer);
    procedure SetValue(AValue: Integer);
    procedure SetLineWidth(AValue: Integer);
    procedure FillArc(ACanvas: TCanvas; CX, CY, OuterR, InnerR: Integer;
      StartDeg, EndDeg: Double; AColor: TColor);
    // Rysuje komponent na ACanvas przy skali AScale (1 = normalna, 3 = 3x dla AA).
    // Tekst środkowy rysowany jest tylko przy AScale=1 (przy AA – osobno, w Paint).
    // ABackColor = clNone -> tło nie jest wypełniane (pozostaje przezroczyste).
    procedure RenderScaled(ACanvas: TCanvas; AScale: Integer; ADrawText: Boolean;
      ABackColor: TColor);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Min: Integer read FMin write SetMin default 0;
    property Max: Integer read FMax write SetMax default 100;
    property Value: Integer read FValue write SetValue default 0;
    property TrackColor: TColor read FTrackColor write FTrackColor default clSilver;
    property ProgressColor: TColor read FProgressColor write FProgressColor default clBlue;
    property LineWidth: Integer read FLineWidth write SetLineWidth default 12;
    property ShowText: Boolean read FShowText write FShowText default True;

    property TextFormat: string read FTextFormat write FTextFormat;

    property Antialiased: Boolean read FAntialiased write FAntialiased default False;
    property Color;
    property Font;
    property Align;
    property Anchors;
    property Visible;
    property Width default 100;
    property Height default 100;
  end;

procedure Register;

implementation

// AMaskColor <> clNone: piksele dużej bitmapy w tym kolorze traktowane są jako
// "niezamalowane" i zastępowane tłem skopiowanym spod komponentu (przezroczystość),
// a krawędzie antyaliasingu mieszają się z tym tłem.
procedure XelAADownsample(BigBmp: TBitmap; DstCanvas: TCanvas;
  const DstRect: TRect; AScale: Integer; AMaskColor: TColor);
var
  SrcImg, DstImg: TLazIntfImage;
  DstBmp: TBitmap;
  DW, DH, x, y, sx, sy: Integer;
  R, G, B, Cnt, ScaleSq: Cardinal;
  MR, MG, MB, CR, CG, CB: Byte;
  UseMask: Boolean;
  C, BgC: TFPColor;
begin
  DW      := DstRect.Right  - DstRect.Left;
  DH      := DstRect.Bottom - DstRect.Top;
  ScaleSq := Cardinal(AScale * AScale);

  MR := 0; MG := 0; MB := 0;
  UseMask := AMaskColor <> clNone;
  if UseMask then
  begin
    MR := Red(ColorToRGB(AMaskColor));
    MG := Green(ColorToRGB(AMaskColor));
    MB := Blue(ColorToRGB(AMaskColor));
  end;

  SrcImg := BigBmp.CreateIntfImage;
  DstBmp := TBitmap.Create;
  try
    DstBmp.PixelFormat := pf24bit;
    DstBmp.SetSize(DW, DH);
    // Skopiuj aktualne tło spod komponentu (parent narysował je przed Paint)
    DstBmp.Canvas.CopyRect(Rect(0, 0, DW, DH), DstCanvas, DstRect);
    DstImg := DstBmp.CreateIntfImage;
    try
      for y := 0 to DH - 1 do
        for x := 0 to DW - 1 do
        begin
          R := 0; G := 0; B := 0; Cnt := 0;
          for sy := 0 to AScale - 1 do
            for sx := 0 to AScale - 1 do
            begin
              C  := SrcImg.Colors[x * AScale + sx, y * AScale + sy];
              CR := C.Red   shr 8;
              CG := C.Green shr 8;
              CB := C.Blue  shr 8;
              if UseMask and (CR = MR) and (CG = MG) and (CB = MB) then
                Continue; // subpiksel niezamalowany -> wejdzie kolor tła
              Inc(R, CR);
              Inc(G, CG);
              Inc(B, CB);
              Inc(Cnt);
            end;
          if Cnt < ScaleSq then
          begin
            BgC := DstImg.Colors[x, y];
            Inc(R, (BgC.Red   shr 8) * (ScaleSq - Cnt));
            Inc(G, (BgC.Green shr 8) * (ScaleSq - Cnt));
            Inc(B, (BgC.Blue  shr 8) * (ScaleSq - Cnt));
          end;
          DstImg.Colors[x, y] := FPColor(
            Word((R div ScaleSq) shl 8),
            Word((G div ScaleSq) shl 8),
            Word((B div ScaleSq) shl 8),
            $FFFF);
        end;
      DstBmp.LoadFromIntfImage(DstImg);
    finally
      DstImg.Free;
    end;
    DstCanvas.Draw(DstRect.Left, DstRect.Top, DstBmp);
  finally
    SrcImg.Free;
    DstBmp.Free;
  end;
end;

// ---------------------------------------------------------------------------

constructor TXelCircularProgress.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMin           := 0;
  FMax           := 100;
  FValue         := 0;
  FTrackColor    := clSilver;
  FProgressColor := clBlue;
  FLineWidth     := 12;
  FShowText      := True;
  FTextFormat    := '%d%%';
  FAntialiased   := False;
  Width  := 100;
  Height := 100;
  ControlStyle := ControlStyle - [csOpaque];
end;

procedure TXelCircularProgress.SetMin(AValue: Integer);
begin
  FMin := AValue;
  if FValue < FMin then FValue := FMin;
  Invalidate;
end;

procedure TXelCircularProgress.SetMax(AValue: Integer);
begin
  FMax := AValue;
  if FValue > FMax then FValue := FMax;
  Invalidate;
end;

procedure TXelCircularProgress.SetValue(AValue: Integer);
begin
  AValue := Math.Max(FMin, Math.Min(FMax, AValue));
  if FValue = AValue then Exit;
  FValue := AValue;
  Invalidate;
end;

procedure TXelCircularProgress.SetLineWidth(AValue: Integer);
begin
  FLineWidth := Math.Max(1, AValue);
  Invalidate;
end;

procedure TXelCircularProgress.FillArc(ACanvas: TCanvas; CX, CY, OuterR, InnerR: Integer;
  StartDeg, EndDeg: Double; AColor: TColor);
var
  Steps, i, N: Integer;
  StartRad, EndRad, StepRad, Angle: Double;
  Pts: array of TPoint;
begin
  if Abs(EndDeg - StartDeg) < 0.5 then Exit;
  Steps := Math.Max(6, Abs(Round((EndDeg - StartDeg) / 2)));
  N := Steps + 1;
  SetLength(Pts, N * 2);

  StartRad := StartDeg * Pi / 180;
  EndRad   := EndDeg   * Pi / 180;
  StepRad  := (EndRad - StartRad) / Steps;

  for i := 0 to Steps do
  begin
    Angle := StartRad + i * StepRad;
    Pts[i].X := CX + Round(OuterR * Cos(Angle));
    Pts[i].Y := CY + Round(OuterR * Sin(Angle));
  end;
  for i := 0 to Steps do
  begin
    Angle := EndRad - i * StepRad;
    Pts[N + i].X := CX + Round(InnerR * Cos(Angle));
    Pts[N + i].Y := CY + Round(InnerR * Sin(Angle));
  end;

  ACanvas.Brush.Color := AColor;
  ACanvas.Pen.Color   := AColor;
  ACanvas.Pen.Width   := 1;
  ACanvas.Polygon(Pts);
end;

procedure TXelCircularProgress.RenderScaled(ACanvas: TCanvas; AScale: Integer;
  ADrawText: Boolean; ABackColor: TColor);
var
  W, H, CX, CY, OuterR, InnerR, LineW: Integer;
  Pct, EndAngle: Double;
  LabelText: string;
  TW, TH: Integer;
begin
  W     := Width  * AScale;
  H     := Height * AScale;
  LineW := FLineWidth * AScale;

  if ABackColor <> clNone then
  begin
    ACanvas.Brush.Color := ABackColor;
    ACanvas.Pen.Color   := ABackColor;
    ACanvas.FillRect(0, 0, W, H);
  end;

  CX     := W div 2;
  CY     := H div 2;
  OuterR := Math.Min(CX, CY) - AScale;
  InnerR := OuterR - LineW;
  if InnerR < 0 then InnerR := 0;

  FillArc(ACanvas, CX, CY, OuterR, InnerR, -90, 270, FTrackColor);


  if FMax > FMin then
    Pct := (FValue - FMin) / (FMax - FMin)
  else
    Pct := 0;
  EndAngle := -90.0 + Pct * 360.0;
  if Pct > 0 then
    FillArc(ACanvas, CX, CY, OuterR, InnerR, -90, EndAngle, FProgressColor);


  if ADrawText and FShowText then
  begin
    LabelText := Format(FTextFormat, [Round(Pct * 100)]);
    ACanvas.Brush.Style := bsClear;
    ACanvas.Font.Assign(Font);
    if AScale > 1 then ACanvas.Font.Size := Font.Size * AScale;
    TW := ACanvas.TextWidth(LabelText);
    TH := ACanvas.TextHeight(LabelText);
    ACanvas.TextOut(CX - TW div 2, CY - TH div 2, LabelText);
    ACanvas.Brush.Style := bsSolid;
  end;
end;

procedure TXelCircularProgress.Paint;
const
  AA_SCALE = 3;
  // Kandydaci na kolor-maskę przezroczystości; wybierany jest pierwszy,
  // który nie koliduje z TrackColor/ProgressColor.
  MaskCandidates: array[0..2] of TColor = ($FF00FF, $02FE01, $FE0203);
var
  BigBmp: TBitmap;
  Pct: Double;
  LabelText: string;
  BackC, MaskC: TColor;
  i: Integer;
  TransparentBack: Boolean;
begin
  // Brak jawnie ustawionego koloru -> tło przezroczyste
  TransparentBack := (Color = clDefault) or (Color = clNone);

  if FAntialiased then
  begin
    if TransparentBack then
    begin
      MaskC := MaskCandidates[0];
      for i := 0 to High(MaskCandidates) do
        if (ColorToRGB(FTrackColor) <> MaskCandidates[i]) and
           (ColorToRGB(FProgressColor) <> MaskCandidates[i]) then
        begin
          MaskC := MaskCandidates[i];
          Break;
        end;
      BackC := MaskC;
    end
    else
    begin
      BackC := ColorToRGB(Color);
      MaskC := clNone;
    end;

    BigBmp := TBitmap.Create;
    try
      BigBmp.PixelFormat := pf24bit;
      BigBmp.SetSize(Width * AA_SCALE, Height * AA_SCALE);

      RenderScaled(BigBmp.Canvas, AA_SCALE, False, BackC);

      XelAADownsample(BigBmp, Canvas, ClientRect, AA_SCALE, MaskC);
    finally
      BigBmp.Free;
    end;

    if FShowText then
    begin
      if FMax > FMin then Pct := (FValue - FMin) / (FMax - FMin) else Pct := 0;
      LabelText := Format(FTextFormat, [Round(Pct * 100)]);
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Assign(Font);
      Canvas.TextOut(
        Width  div 2 - Canvas.TextWidth(LabelText)  div 2,
        Height div 2 - Canvas.TextHeight(LabelText) div 2,
        LabelText);
      Canvas.Brush.Style := bsSolid;
    end;
  end
  else
  begin
    // Bez AA: przy przezroczystym tle nie wypełniamy - parent narysował je przed Paint
    if TransparentBack then
      BackC := clNone
    else
      BackC := ColorToRGB(Color);
    RenderScaled(Canvas, 1, True, BackC);
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelCircularProgress]);
end;

initialization
  RegisterClasses([TXelCircularProgress]);

end.
