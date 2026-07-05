unit XelToggleSwitch;

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics,
  IntfGraphics,  // TLazIntfImage, CreateIntfImage, LoadFromIntfImage
  Math, FPImage;       // TFPColor, FPColor

type
  TXelToggleSwitch = class(TCustomControl)
  private
    FChecked: Boolean;
    FOnColor: TColor;
    FOffColor: TColor;
    FThumbColor: TColor;
    FAntialiased: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
    // Rysuje przełącznik na ACanvas przy skali AScale.
    // AW, AH to CAŁKOWITY rozmiar (Width*AScale, Height*AScale).
    procedure RenderScaled(ACanvas: TCanvas; AW, AH: Integer);
  protected
    procedure Paint; override;
    procedure Click; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Checked: Boolean read FChecked write SetChecked default False;
    property OnColor: TColor read FOnColor write FOnColor default clGreen;
    property OffColor: TColor read FOffColor write FOffColor default clSilver;
    property ThumbColor: TColor read FThumbColor write FThumbColor default clWhite;
    // Antyaliasing – supersampling 3x (przenośny, bez API systemowych)
    property Antialiased: Boolean read FAntialiased write FAntialiased default False;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnClick;
    property Enabled;
    property Visible;
    property Hint;
    property ShowHint;
    property Color;
    property ParentColor default True;
    property Width default 52;
    property Height default 28;
  end;

procedure Register;

implementation

// ---------------------------------------------------------------------------
// Przenośny supersampling: BigBmp (narysowane w skali AScale) -> DstCanvas
// Używa wyłącznie LCL/FCL: IntfGraphics + FPImage, bez API platformy.
// ---------------------------------------------------------------------------
procedure XelAADownsample(BigBmp: TBitmap; DstCanvas: TCanvas;
  const DstRect: TRect; AScale: Integer);
var
  SrcImg, DstImg: TLazIntfImage;
  DstBmp: TBitmap;
  DW, DH, x, y, sx, sy: Integer;
  R, G, B, ScaleSq: Cardinal;
  C: TFPColor;
begin
  DW      := DstRect.Right  - DstRect.Left;
  DH      := DstRect.Bottom - DstRect.Top;
  ScaleSq := Cardinal(AScale * AScale);

  SrcImg := BigBmp.CreateIntfImage;
  DstBmp := TBitmap.Create;
  try
    DstBmp.PixelFormat := pf24bit;
    DstBmp.SetSize(DW, DH);
    DstImg := DstBmp.CreateIntfImage;
    try
      for y := 0 to DH - 1 do
        for x := 0 to DW - 1 do
        begin
          R := 0; G := 0; B := 0;
          for sy := 0 to AScale - 1 do
            for sx := 0 to AScale - 1 do
            begin
              C := SrcImg.Colors[x * AScale + sx, y * AScale + sy];
              Inc(R, C.Red   shr 8);
              Inc(G, C.Green shr 8);
              Inc(B, C.Blue  shr 8);
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

constructor TXelToggleSwitch.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FOnColor     := clGreen;
  FOffColor    := clSilver;
  FThumbColor  := clWhite;
  FAntialiased := False;
  Width  := 52;
  Height := 28;
  ParentColor  := True;
  ControlStyle := ControlStyle + [csClickEvents];
end;

procedure TXelToggleSwitch.SetChecked(AValue: Boolean);
begin
  if FChecked = AValue then Exit;
  FChecked := AValue;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TXelToggleSwitch.Click;
begin
  if Enabled then SetChecked(not FChecked);
  inherited Click;
end;

// Rysuje na ACanvas o rozmiarze AW × AH.
// Działa w dowolnej skali; nie odwołuje się do Self.Width / Self.Height.
procedure TXelToggleSwitch.RenderScaled(ACanvas: TCanvas; AW, AH: Integer);
const
  // Padding jako ułamek wysokości; użycie proporcji zamiast stałej px
  // sprawia, że wygląd jest identyczny w każdej skali.
  PAD_FRAC = 0.12; // ~3px przy 28px
var
  Pad, Diameter, ThumbX: Integer;
  TrackColor: TColor;
begin
  Pad      := Max(1, Round(AH * PAD_FRAC));
  Diameter := AH - Pad * 2;

  if FChecked then TrackColor := FOnColor
  else TrackColor := FOffColor;

  // Tor – zaokrąglony prostokąt
  ACanvas.Brush.Color := TrackColor;
  ACanvas.Pen.Color   := TrackColor;
  ACanvas.Pen.Width   := 1;
  ACanvas.RoundRect(0, 0, AW, AH, AH, AH);

  // Kciuk – okrąg
  ACanvas.Brush.Color := FThumbColor;
  ACanvas.Pen.Color   := clGray;
  ACanvas.Pen.Width   := Max(1, AH div 14);

  if FChecked then
    ThumbX := AW - Diameter - Pad
  else
    ThumbX := Pad;

  ACanvas.Ellipse(ThumbX, Pad, ThumbX + Diameter, Pad + Diameter);

  ACanvas.Pen.Width := 1;
end;

procedure TXelToggleSwitch.Paint;
const
  AA_SCALE = 3;
var
  BigBmp: TBitmap;
begin
  if FAntialiased then
  begin
    BigBmp := TBitmap.Create;
    try
      BigBmp.PixelFormat := pf24bit;
      BigBmp.SetSize(Width * AA_SCALE, Height * AA_SCALE);
      // Tło – kolor rodzica (konieczne, bo zaokrąglone rogi muszą przejść w tło)
      BigBmp.Canvas.Brush.Color := Color;
      BigBmp.Canvas.FillRect(0, 0, BigBmp.Width, BigBmp.Height);
      RenderScaled(BigBmp.Canvas, Width * AA_SCALE, Height * AA_SCALE);
      XelAADownsample(BigBmp, Canvas, ClientRect, AA_SCALE);
    finally
      BigBmp.Free;
    end;
  end
  else
  begin
    Canvas.Brush.Color := Color;
    Canvas.FillRect(ClientRect);
    RenderScaled(Canvas, Width, Height);
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelToggleSwitch]);
end;

initialization
  RegisterClasses([TXelToggleSwitch]);

end.
