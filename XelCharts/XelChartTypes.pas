unit XelChartTypes;

//Author: xelitan.com
//License: MIT
//
//Shared types for XelCharts: the categorical palette, axis and legend
//descriptors, the series collection and the supersampling helper.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math,
  IntfGraphics,  // TLazIntfImage
  FPImage;       // TFPColor

type
  TXelChartTheme = (ctLight, ctDark);

  TXelLegendPosition = (lpRight, lpBottom, lpTop, lpLeft);

  TXelSeriesStyle = (ssLine, ssArea, ssPoints, ssLinePoints);

  TXelBarLayout = (blGrouped, blStacked, blOverlapped);

  TXelChartOrientation = (coVertical, coHorizontal);

  // One data point.  Text is an optional per-point label — pie slices and
  // category axes use it, XY charts ignore it.
  TXelChartPoint = record
    X, Y : Double;
    Text : String;
  end;
  TXelChartPoints = array of TXelChartPoint;

const
  XelChartsVersion = '1.0';

  // Categorical palette — eight fixed slots, assigned in order, never cycled.
  // The order itself is the colour-blind-safety mechanism: it was validated so
  // that every adjacent pair stays apart both for normal vision and under CVD
  // simulation, on the chart surface below.  Re-order it and that guarantee is
  // gone.  Values are the same eight hues stepped twice, once for the light
  // surface and once for the dark one.
  XelPaletteLight: array[0..7] of TColor = (
    TColor($D6782A),   // blue     #2a78d6
    TColor($3468EB),   // orange   #eb6834
    TColor($7AAF1B),   // aqua     #1baf7a
    TColor($00A1ED),   // yellow   #eda100
    TColor($A47BE8),   // magenta  #e87ba4
    TColor($008300),   // green    #008300
    TColor($A73A4A),   // violet   #4a3aa7
    TColor($4849E3));  // red      #e34948

  XelPaletteDark: array[0..7] of TColor = (
    TColor($E58739),   // blue     #3987e5
    TColor($2659D9),   // orange   #d95926
    TColor($709E19),   // aqua     #199e70
    TColor($0085C9),   // yellow   #c98500
    TColor($8151D5),   // magenta  #d55181
    TColor($008300),   // green    #008300
    TColor($E98590),   // violet   #9085e9
    TColor($6767E6));  // red      #e66767

  // Colour used for series past slot 8 when PaletteWrap is False — the "Other"
  // bucket.  A ninth hue cannot be invented without breaking the separation
  // guarantee, so the honest answer is a neutral.
  XelOtherColor = TColor($818789);

  // Chart chrome.
  XelSurfaceLight   = TColor($FBFCFC);
  XelSurfaceDark    = TColor($191A1A);
  XelInkLight       = TColor($0B0B0B);
  XelInkDark        = TColor($FFFFFF);
  XelInk2Light      = TColor($4E5152);
  XelInk2Dark       = TColor($B7C2C3);
  XelMutedColor     = TColor($818789);   // same in both modes
  XelGridLight      = TColor($D9E0E1);
  XelGridDark       = TColor($2A2C2C);
  XelBaselineLight  = TColor($B7C2C3);
  XelBaselineDark   = TColor($353838);

type
  // TXelChartAxis — one scale.  With AutoScale on, Min and Max are recomputed
  // from the data and rounded outward to readable tick steps.
  TXelChartAxis = class(TPersistent)
  private
    FOwnerCtl    : TControl;
    FVisible     : Boolean;
    FTitle       : String;
    FMin, FMax   : Double;
    FAutoScale   : Boolean;
    FAutoZero    : Boolean;
    FTickCount   : Integer;
    FShowGrid    : Boolean;
    FShowLabels  : Boolean;
    FLabelFormat : String;
    FInverted    : Boolean;
    // filled in by the chart before painting
    FCalcMin     : Double;
    FCalcMax     : Double;
    FCalcStep    : Double;
    procedure Changed;
    procedure SetVisible(AValue: Boolean);
    procedure SetTitle(const AValue: String);
    procedure SetMin(AValue: Double);
    procedure SetMax(AValue: Double);
    procedure SetAutoScale(AValue: Boolean);
    procedure SetAutoZero(AValue: Boolean);
    procedure SetTickCount(AValue: Integer);
    procedure SetShowGrid(AValue: Boolean);
    procedure SetShowLabels(AValue: Boolean);
    procedure SetLabelFormat(const AValue: String);
    procedure SetInverted(AValue: Boolean);
  public
    constructor Create(AOwner: TControl);
    procedure Assign(Source: TPersistent); override;

    // Round [ALo, AHi] outward to a readable range and pick a tick step.
    procedure Recalc(ALo, AHi: Double);
    // Pin the scale exactly, skipping the nice-number rounding.  Category
    // charts need this: slot 3 has to land on 3, not on whatever a readable
    // tick step would round it to.
    procedure ForceRange(AMin, AMax, AStep: Double);
    // Format one tick value using LabelFormat.
    function  FormatValue(AValue: Double): String;

    property CalcMin : Double read FCalcMin;
    property CalcMax : Double read FCalcMax;
    property CalcStep: Double read FCalcStep;
  published
    property Visible: Boolean read FVisible write SetVisible default True;
    property Title: String read FTitle write SetTitle;
    // Used when AutoScale is False.
    property Min: Double read FMin write SetMin;
    property Max: Double read FMax write SetMax;
    property AutoScale: Boolean read FAutoScale write SetAutoScale default True;
    // Stretch an auto-scaled range down (or up) to include zero.  Bar charts
    // want this on: a bar chart with a cut baseline lies about proportions.
    property AutoZero: Boolean read FAutoZero write SetAutoZero default True;
    property TickCount: Integer read FTickCount write SetTickCount default 5;
    property ShowGrid: Boolean read FShowGrid write SetShowGrid default True;
    property ShowLabels: Boolean read FShowLabels write SetShowLabels default True;
    property LabelFormat: String read FLabelFormat write SetLabelFormat;
    property Inverted: Boolean read FInverted write SetInverted default False;
  end;

  // TXelChartLegend — identity for two or more series.  It is on by default:
  // with several series, colour alone is not an acceptable key.
  TXelChartLegend = class(TPersistent)
  private
    FOwnerCtl : TControl;
    FVisible  : Boolean;
    FPosition : TXelLegendPosition;
    FFrame    : Boolean;
    FSpacing  : Integer;
    procedure Changed;
    procedure SetVisible(AValue: Boolean);
    procedure SetPosition(AValue: TXelLegendPosition);
    procedure SetFrame(AValue: Boolean);
    procedure SetSpacing(AValue: Integer);
  public
    constructor Create(AOwner: TControl);
    procedure Assign(Source: TPersistent); override;
  published
    property Visible: Boolean read FVisible write SetVisible default True;
    property Position: TXelLegendPosition read FPosition write SetPosition
      default lpRight;
    property Frame: Boolean read FFrame write SetFrame default False;
    property Spacing: Integer read FSpacing write SetSpacing default 8;
  end;

  // TXelChartSeries — one line, one set of bars, one pie.
  TXelChartSeries = class(TCollectionItem)
  private
    FTitle      : String;
    FColor      : TColor;
    FVisible    : Boolean;
    FStyle      : TXelSeriesStyle;
    FLineWidth  : Integer;
    FPointSize  : Integer;
    FShowLabels : Boolean;
    FPoints     : TXelChartPoints;
    FCount      : Integer;
    function  GetPoint(Index: Integer): TXelChartPoint;
    procedure SetPoint(Index: Integer; const AValue: TXelChartPoint);
    function  GetX(Index: Integer): Double;
    function  GetY(Index: Integer): Double;
    procedure SetY(Index: Integer; AValue: Double);
    function  GetText(Index: Integer): String;
    procedure SetTitle(const AValue: String);
    procedure SetColor(AValue: TColor);
    procedure SetVisible(AValue: Boolean);
    procedure SetStyle(AValue: TXelSeriesStyle);
    procedure SetLineWidth(AValue: Integer);
    procedure SetPointSize(AValue: Integer);
    procedure SetShowLabels(AValue: Boolean);
  protected
    function GetDisplayName: String; override;
  public
    constructor Create(ACollection: TCollection); override;
    procedure Assign(Source: TPersistent); override;

    // Append a point.  Add() uses the current Count as X, which is what a
    // category chart wants; AddXY() is for real XY data.
    function  Add(AY: Double; const AText: String = ''): Integer;
    function  AddXY(AX, AY: Double; const AText: String = ''): Integer;
    procedure Clear;
    procedure Delete(Index: Integer);

    // Replace the whole series in one go.
    procedure SetData(const AValues: array of Double);

    function MinX: Double;
    function MaxX: Double;
    function MinY: Double;
    function MaxY: Double;
    function SumY: Double;

    // Colour actually painted: FColor when set, otherwise the palette slot for
    // this series' index.
    function EffectiveColor: TColor;

    property Count: Integer read FCount;
    property Points[Index: Integer]: TXelChartPoint read GetPoint write SetPoint;
    property X[Index: Integer]: Double read GetX;
    property Y[Index: Integer]: Double read GetY write SetY;
    property Text[Index: Integer]: String read GetText;
  published
    property Title: String read FTitle write SetTitle;
    // clDefault means "take the next palette slot".
    property Color: TColor read FColor write SetColor default clDefault;
    property Visible: Boolean read FVisible write SetVisible default True;
    property Style: TXelSeriesStyle read FStyle write SetStyle default ssLine;
    property LineWidth: Integer read FLineWidth write SetLineWidth default 2;
    property PointSize: Integer read FPointSize write SetPointSize default 8;
    // Direct labels on this series.  Meant to be used on one or two series,
    // not on all of them and never on every point of a dense line.
    property ShowLabels: Boolean read FShowLabels write SetShowLabels default False;
  end;

  TXelChartSeriesList = class(TOwnedCollection)
  private
    FOwnerCtl    : TControl;
    FTheme       : TXelChartTheme;
    FPaletteWrap : Boolean;
    function  GetItem(Index: Integer): TXelChartSeries;
    procedure SetItem(Index: Integer; AValue: TXelChartSeries);
  protected
    procedure Update(Item: TCollectionItem); override;
  public
    constructor Create(AOwner: TControl);
    function Add: TXelChartSeries;
    function FindByTitle(const ATitle: String): TXelChartSeries;
    function VisibleCount: Integer;
    // Kept in step by the owning chart so a series can resolve its palette
    // slot without reaching back into the control.
    property Theme: TXelChartTheme read FTheme write FTheme;
    property PaletteWrap: Boolean read FPaletteWrap write FPaletteWrap;
    property Items[Index: Integer]: TXelChartSeries read GetItem write SetItem; default;
  end;

// Palette slot for a series index.  Past slot 8 the answer is the neutral
// "Other" colour unless AWrap is True.
function XelSeriesColor(AIndex: Integer; ATheme: TXelChartTheme;
  AWrap: Boolean = False): TColor;

// Theme colours.
function XelSurfaceColor(ATheme: TXelChartTheme): TColor;
function XelInkColor(ATheme: TXelChartTheme): TColor;
function XelInk2Color(ATheme: TXelChartTheme): TColor;
function XelGridColor(ATheme: TXelChartTheme): TColor;
function XelBaselineColor(ATheme: TXelChartTheme): TColor;

// Mix two colours; AAmount 0 = A, 255 = B.
function XelBlend(A, B: TColor; AAmount: Byte): TColor;

// "Nice" number for axis stepping — 1, 2, 2.5, 5 or 10 times a power of ten.
function XelNiceNum(ARange: Double; ARound: Boolean): Double;

// Supersampling downscale, same approach as the other Xel controls: draw at
// AScale times the size, then average AScale x AScale blocks down.
procedure XelChartDownsample(ABigBmp: TBitmap; ADstCanvas: TCanvas;
  const ADstRect: TRect; AScale: Integer);

implementation

// ---------------------------------------------------------------------------
// Colour helpers
// ---------------------------------------------------------------------------

function XelSeriesColor(AIndex: Integer; ATheme: TXelChartTheme;
  AWrap: Boolean): TColor;
begin
  if AIndex < 0 then AIndex := 0;
  if AIndex > 7 then
  begin
    if not AWrap then Exit(XelOtherColor);
    AIndex := AIndex mod 8;
  end;
  if ATheme = ctDark then Result := XelPaletteDark[AIndex]
                     else Result := XelPaletteLight[AIndex];
end;

function XelSurfaceColor(ATheme: TXelChartTheme): TColor;
begin
  if ATheme = ctDark then Result := XelSurfaceDark else Result := XelSurfaceLight;
end;

function XelInkColor(ATheme: TXelChartTheme): TColor;
begin
  if ATheme = ctDark then Result := XelInkDark else Result := XelInkLight;
end;

function XelInk2Color(ATheme: TXelChartTheme): TColor;
begin
  if ATheme = ctDark then Result := XelInk2Dark else Result := XelInk2Light;
end;

function XelGridColor(ATheme: TXelChartTheme): TColor;
begin
  if ATheme = ctDark then Result := XelGridDark else Result := XelGridLight;
end;

function XelBaselineColor(ATheme: TXelChartTheme): TColor;
begin
  if ATheme = ctDark then Result := XelBaselineDark else Result := XelBaselineLight;
end;

function XelBlend(A, B: TColor; AAmount: Byte): TColor;
var
  RA, GA, BA, RB, GB, BB: Integer;
  Inv: Integer;
begin
  A := ColorToRGB(A);
  B := ColorToRGB(B);
  RA := A and $FF; GA := (A shr 8) and $FF; BA := (A shr 16) and $FF;
  RB := B and $FF; GB := (B shr 8) and $FF; BB := (B shr 16) and $FF;
  Inv := 255 - AAmount;
  Result := TColor(
    ((RA * Inv + RB * AAmount) div 255) or
    (((GA * Inv + GB * AAmount) div 255) shl 8) or
    (((BA * Inv + BB * AAmount) div 255) shl 16));
end;

function XelNiceNum(ARange: Double; ARound: Boolean): Double;
var
  Expo : Integer;
  Frac : Double;
  Nice : Double;
begin
  if ARange <= 0 then Exit(1);
  Expo := Floor(Log10(ARange));
  Frac := ARange / Power(10, Expo);

  if ARound then
  begin
    if Frac < 1.5 then Nice := 1
    else if Frac < 3   then Nice := 2
    else if Frac < 7   then Nice := 5
    else                    Nice := 10;
  end
  else
  begin
    if Frac <= 1 then Nice := 1
    else if Frac <= 2 then Nice := 2
    else if Frac <= 5 then Nice := 5
    else                   Nice := 10;
  end;

  Result := Nice * Power(10, Expo);
end;

// ---------------------------------------------------------------------------
// Supersampling
// ---------------------------------------------------------------------------

procedure XelChartDownsample(ABigBmp: TBitmap; ADstCanvas: TCanvas;
  const ADstRect: TRect; AScale: Integer);
var
  SrcImg, DstImg : TLazIntfImage;
  DstBmp         : TBitmap;
  DW, DH         : Integer;
  x, y, sx, sy   : Integer;
  R, G, B        : Cardinal;
  ScaleSq        : Cardinal;
  C              : TFPColor;
begin
  DW := ADstRect.Right  - ADstRect.Left;
  DH := ADstRect.Bottom - ADstRect.Top;
  if (DW <= 0) or (DH <= 0) then Exit;
  ScaleSq := Cardinal(AScale * AScale);

  SrcImg := ABigBmp.CreateIntfImage;
  DstBmp := TBitmap.Create;
  try
    DstBmp.PixelFormat := pf32bit;
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
          C.Red   := Word((R div ScaleSq) * 257);
          C.Green := Word((G div ScaleSq) * 257);
          C.Blue  := Word((B div ScaleSq) * 257);
          C.Alpha := alphaOpaque;
          DstImg.Colors[x, y] := C;
        end;

      DstBmp.LoadFromIntfImage(DstImg);
      ADstCanvas.Draw(ADstRect.Left, ADstRect.Top, DstBmp);
    finally
      DstImg.Free;
    end;
  finally
    DstBmp.Free;
    SrcImg.Free;
  end;
end;

// ===========================================================================
// TXelChartAxis
// ===========================================================================

constructor TXelChartAxis.Create(AOwner: TControl);
begin
  inherited Create;
  FOwnerCtl    := AOwner;
  FVisible     := True;
  FAutoScale   := True;
  FAutoZero    := True;
  FTickCount   := 5;
  FShowGrid    := True;
  FShowLabels  := True;
  FLabelFormat := '%g';
  FMin         := 0;
  FMax         := 100;
  FCalcMin     := 0;
  FCalcMax     := 100;
  FCalcStep    := 20;
end;

procedure TXelChartAxis.Changed;
begin
  if FOwnerCtl <> nil then FOwnerCtl.Invalidate;
end;

procedure TXelChartAxis.Assign(Source: TPersistent);
var
  S: TXelChartAxis;
begin
  if Source is TXelChartAxis then
  begin
    S := TXelChartAxis(Source);
    FVisible     := S.FVisible;
    FTitle       := S.FTitle;
    FMin         := S.FMin;
    FMax         := S.FMax;
    FAutoScale   := S.FAutoScale;
    FAutoZero    := S.FAutoZero;
    FTickCount   := S.FTickCount;
    FShowGrid    := S.FShowGrid;
    FShowLabels  := S.FShowLabels;
    FLabelFormat := S.FLabelFormat;
    FInverted    := S.FInverted;
    Changed;
  end
  else
    inherited Assign(Source);
end;

procedure TXelChartAxis.SetVisible(AValue: Boolean);
begin
  if FVisible = AValue then Exit;
  FVisible := AValue; Changed;
end;

procedure TXelChartAxis.SetTitle(const AValue: String);
begin
  if FTitle = AValue then Exit;
  FTitle := AValue; Changed;
end;

procedure TXelChartAxis.SetMin(AValue: Double);
begin
  if FMin = AValue then Exit;
  FMin := AValue; Changed;
end;

procedure TXelChartAxis.SetMax(AValue: Double);
begin
  if FMax = AValue then Exit;
  FMax := AValue; Changed;
end;

procedure TXelChartAxis.SetAutoScale(AValue: Boolean);
begin
  if FAutoScale = AValue then Exit;
  FAutoScale := AValue; Changed;
end;

procedure TXelChartAxis.SetAutoZero(AValue: Boolean);
begin
  if FAutoZero = AValue then Exit;
  FAutoZero := AValue; Changed;
end;

procedure TXelChartAxis.SetTickCount(AValue: Integer);
begin
  if AValue < 2 then AValue := 2;
  if AValue > 30 then AValue := 30;
  if FTickCount = AValue then Exit;
  FTickCount := AValue; Changed;
end;

procedure TXelChartAxis.SetShowGrid(AValue: Boolean);
begin
  if FShowGrid = AValue then Exit;
  FShowGrid := AValue; Changed;
end;

procedure TXelChartAxis.SetShowLabels(AValue: Boolean);
begin
  if FShowLabels = AValue then Exit;
  FShowLabels := AValue; Changed;
end;

procedure TXelChartAxis.SetLabelFormat(const AValue: String);
begin
  if FLabelFormat = AValue then Exit;
  FLabelFormat := AValue; Changed;
end;

procedure TXelChartAxis.SetInverted(AValue: Boolean);
begin
  if FInverted = AValue then Exit;
  FInverted := AValue; Changed;
end;

procedure TXelChartAxis.Recalc(ALo, AHi: Double);
var
  Range, Step: Double;
begin
  if not FAutoScale then
  begin
    FCalcMin := FMin;
    FCalcMax := FMax;
    if FCalcMax <= FCalcMin then FCalcMax := FCalcMin + 1;
    FCalcStep := XelNiceNum((FCalcMax - FCalcMin) / (FTickCount - 1), True);
    if FCalcStep <= 0 then FCalcStep := (FCalcMax - FCalcMin) / (FTickCount - 1);
    Exit;
  end;

  if FAutoZero then
  begin
    if ALo > 0 then ALo := 0;
    if AHi < 0 then AHi := 0;
  end;

  if AHi <= ALo then
  begin
    // flat data — invent a readable window around it
    if AHi = 0 then begin ALo := 0; AHi := 1; end
    else begin ALo := AHi - Abs(AHi) * 0.5; AHi := AHi + Abs(AHi) * 0.5; end;
  end;

  Range := XelNiceNum(AHi - ALo, False);
  Step  := XelNiceNum(Range / (FTickCount - 1), True);
  if Step <= 0 then Step := 1;

  FCalcMin  := Floor(ALo / Step) * Step;
  FCalcMax  := Ceil (AHi / Step) * Step;
  FCalcStep := Step;

  // guard against rounding leaving an empty range
  if FCalcMax <= FCalcMin then FCalcMax := FCalcMin + Step;
end;

procedure TXelChartAxis.ForceRange(AMin, AMax, AStep: Double);
begin
  FCalcMin := AMin;
  FCalcMax := AMax;
  if FCalcMax <= FCalcMin then FCalcMax := FCalcMin + 1;
  if AStep <= 0 then AStep := (FCalcMax - FCalcMin) / 4;
  FCalcStep := AStep;
end;

function TXelChartAxis.FormatValue(AValue: Double): String;
begin
  if FLabelFormat = '' then
    Result := FloatToStr(AValue)
  else
    try
      Result := Format(FLabelFormat, [AValue]);
    except
      Result := FloatToStr(AValue);
    end;
end;

// ===========================================================================
// TXelChartLegend
// ===========================================================================

constructor TXelChartLegend.Create(AOwner: TControl);
begin
  inherited Create;
  FOwnerCtl := AOwner;
  FVisible  := True;
  FPosition := lpRight;
  FFrame    := False;
  FSpacing  := 8;
end;

procedure TXelChartLegend.Changed;
begin
  if FOwnerCtl <> nil then FOwnerCtl.Invalidate;
end;

procedure TXelChartLegend.Assign(Source: TPersistent);
var
  S: TXelChartLegend;
begin
  if Source is TXelChartLegend then
  begin
    S := TXelChartLegend(Source);
    FVisible  := S.FVisible;
    FPosition := S.FPosition;
    FFrame    := S.FFrame;
    FSpacing  := S.FSpacing;
    Changed;
  end
  else
    inherited Assign(Source);
end;

procedure TXelChartLegend.SetVisible(AValue: Boolean);
begin
  if FVisible = AValue then Exit;
  FVisible := AValue; Changed;
end;

procedure TXelChartLegend.SetPosition(AValue: TXelLegendPosition);
begin
  if FPosition = AValue then Exit;
  FPosition := AValue; Changed;
end;

procedure TXelChartLegend.SetFrame(AValue: Boolean);
begin
  if FFrame = AValue then Exit;
  FFrame := AValue; Changed;
end;

procedure TXelChartLegend.SetSpacing(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if FSpacing = AValue then Exit;
  FSpacing := AValue; Changed;
end;

// ===========================================================================
// TXelChartSeries
// ===========================================================================

constructor TXelChartSeries.Create(ACollection: TCollection);
begin
  inherited Create(ACollection);
  FColor      := clDefault;
  FVisible    := True;
  FStyle      := ssLine;
  FLineWidth  := 2;
  FPointSize  := 8;
  FShowLabels := False;
  FCount      := 0;
end;

procedure TXelChartSeries.Assign(Source: TPersistent);
var
  S: TXelChartSeries;
  I: Integer;
begin
  if Source is TXelChartSeries then
  begin
    S := TXelChartSeries(Source);
    FTitle      := S.FTitle;
    FColor      := S.FColor;
    FVisible    := S.FVisible;
    FStyle      := S.FStyle;
    FLineWidth  := S.FLineWidth;
    FPointSize  := S.FPointSize;
    FShowLabels := S.FShowLabels;
    FCount      := S.FCount;
    SetLength(FPoints, FCount);
    for I := 0 to FCount - 1 do FPoints[I] := S.FPoints[I];
    Changed(False);
  end
  else
    inherited Assign(Source);
end;

function TXelChartSeries.GetDisplayName: String;
begin
  if FTitle <> '' then Result := FTitle
                  else Result := Format('Series %d', [Index + 1]);
end;

function TXelChartSeries.GetPoint(Index: Integer): TXelChartPoint;
begin
  if (Index < 0) or (Index >= FCount) then
    raise EListError.CreateFmt('Series point index %d out of range', [Index]);
  Result := FPoints[Index];
end;

procedure TXelChartSeries.SetPoint(Index: Integer; const AValue: TXelChartPoint);
begin
  if (Index < 0) or (Index >= FCount) then
    raise EListError.CreateFmt('Series point index %d out of range', [Index]);
  FPoints[Index] := AValue;
  Changed(False);
end;

function TXelChartSeries.GetX(Index: Integer): Double;
begin
  Result := GetPoint(Index).X;
end;

function TXelChartSeries.GetY(Index: Integer): Double;
begin
  Result := GetPoint(Index).Y;
end;

procedure TXelChartSeries.SetY(Index: Integer; AValue: Double);
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  FPoints[Index].Y := AValue;
  Changed(False);
end;

function TXelChartSeries.GetText(Index: Integer): String;
begin
  Result := GetPoint(Index).Text;
end;

procedure TXelChartSeries.SetTitle(const AValue: String);
begin
  if FTitle = AValue then Exit;
  FTitle := AValue; Changed(False);
end;

procedure TXelChartSeries.SetColor(AValue: TColor);
begin
  if FColor = AValue then Exit;
  FColor := AValue; Changed(False);
end;

procedure TXelChartSeries.SetVisible(AValue: Boolean);
begin
  if FVisible = AValue then Exit;
  FVisible := AValue; Changed(False);
end;

procedure TXelChartSeries.SetStyle(AValue: TXelSeriesStyle);
begin
  if FStyle = AValue then Exit;
  FStyle := AValue; Changed(False);
end;

procedure TXelChartSeries.SetLineWidth(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if AValue > 20 then AValue := 20;
  if FLineWidth = AValue then Exit;
  FLineWidth := AValue; Changed(False);
end;

procedure TXelChartSeries.SetPointSize(AValue: Integer);
begin
  if AValue < 2 then AValue := 2;
  if AValue > 40 then AValue := 40;
  if FPointSize = AValue then Exit;
  FPointSize := AValue; Changed(False);
end;

procedure TXelChartSeries.SetShowLabels(AValue: Boolean);
begin
  if FShowLabels = AValue then Exit;
  FShowLabels := AValue; Changed(False);
end;

function TXelChartSeries.Add(AY: Double; const AText: String): Integer;
begin
  Result := AddXY(FCount, AY, AText);
end;

function TXelChartSeries.AddXY(AX, AY: Double; const AText: String): Integer;
begin
  if FCount >= Length(FPoints) then
    SetLength(FPoints, Length(FPoints) * 2 + 16);
  FPoints[FCount].X    := AX;
  FPoints[FCount].Y    := AY;
  FPoints[FCount].Text := AText;
  Result := FCount;
  Inc(FCount);
  Changed(False);
end;

procedure TXelChartSeries.Clear;
begin
  FCount := 0;
  SetLength(FPoints, 0);
  Changed(False);
end;

procedure TXelChartSeries.Delete(Index: Integer);
var
  I: Integer;
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  for I := Index to FCount - 2 do FPoints[I] := FPoints[I + 1];
  Dec(FCount);
  Changed(False);
end;

procedure TXelChartSeries.SetData(const AValues: array of Double);
var
  I: Integer;
begin
  FCount := 0;
  SetLength(FPoints, Length(AValues));
  for I := 0 to High(AValues) do
  begin
    FPoints[I].X    := I;
    FPoints[I].Y    := AValues[I];
    FPoints[I].Text := '';
  end;
  FCount := Length(AValues);
  Changed(False);
end;

function TXelChartSeries.MinX: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FPoints[0].X;
  for I := 1 to FCount - 1 do
    if FPoints[I].X < Result then Result := FPoints[I].X;
end;

function TXelChartSeries.MaxX: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FPoints[0].X;
  for I := 1 to FCount - 1 do
    if FPoints[I].X > Result then Result := FPoints[I].X;
end;

function TXelChartSeries.MinY: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FPoints[0].Y;
  for I := 1 to FCount - 1 do
    if FPoints[I].Y < Result then Result := FPoints[I].Y;
end;

function TXelChartSeries.MaxY: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FPoints[0].Y;
  for I := 1 to FCount - 1 do
    if FPoints[I].Y > Result then Result := FPoints[I].Y;
end;

function TXelChartSeries.SumY: Double;
var I: Integer;
begin
  Result := 0;
  for I := 0 to FCount - 1 do Result := Result + FPoints[I].Y;
end;

function TXelChartSeries.EffectiveColor: TColor;
var
  Theme: TXelChartTheme;
  Wrap : Boolean;
begin
  if FColor <> clDefault then Exit(FColor);

  Theme := ctLight;
  Wrap  := False;
  if Collection is TXelChartSeriesList then
  begin
    Theme := TXelChartSeriesList(Collection).Theme;
    Wrap  := TXelChartSeriesList(Collection).PaletteWrap;
  end;
  Result := XelSeriesColor(Index, Theme, Wrap);
end;

// ===========================================================================
// TXelChartSeriesList
// ===========================================================================

constructor TXelChartSeriesList.Create(AOwner: TControl);
begin
  inherited Create(AOwner, TXelChartSeries);
  FOwnerCtl := AOwner;
end;

function TXelChartSeriesList.GetItem(Index: Integer): TXelChartSeries;
begin
  Result := TXelChartSeries(inherited Items[Index]);
end;

procedure TXelChartSeriesList.SetItem(Index: Integer; AValue: TXelChartSeries);
begin
  inherited Items[Index] := AValue;
end;

procedure TXelChartSeriesList.Update(Item: TCollectionItem);
begin
  inherited Update(Item);
  if FOwnerCtl <> nil then FOwnerCtl.Invalidate;
end;

function TXelChartSeriesList.Add: TXelChartSeries;
begin
  Result := TXelChartSeries(inherited Add);
end;

function TXelChartSeriesList.FindByTitle(const ATitle: String): TXelChartSeries;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if CompareText(Items[I].Title, ATitle) = 0 then Exit(Items[I]);
  Result := nil;
end;

function TXelChartSeriesList.VisibleCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if Items[I].Visible and (Items[I].Count > 0) then Inc(Result);
end;

end.
