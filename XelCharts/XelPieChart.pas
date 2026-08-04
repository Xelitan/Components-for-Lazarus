unit XelPieChart;

//Author: xelitan.com
//License: MIT
//
//TXelPieChart - pie and donut.  One series, one slice per point.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math, Types,
  XelChartTypes, XelChartBase;

type
  TXelPieLabels = (plNone, plValue, plPercent, plName, plNamePercent);

  // TXelPieChart
  //
  // Reads the first visible series: every point is one slice, its Text is the
  // slice name.  A pie answers "what share of the whole" for a handful of
  // parts - past about six slices the angles stop being comparable, so
  // OtherThreshold folds the tail into a single "Other" slice by default.
  TXelPieChart = class(TXelCustomChart)
  private
    FDonut          : Integer;
    FStartAngle     : Integer;
    FLabels         : TXelPieLabels;
    FOtherThreshold : Double;
    FOtherCaption   : String;
    FExplode        : Integer;
    FExplodeIndex   : Integer;
    // built before each paint
    FVals   : array of Double;
    FTexts  : array of String;
    FCols   : array of TColor;
    FTotal  : Double;
    procedure SetDonut(AValue: Integer);
    procedure SetStartAngle(AValue: Integer);
    procedure SetLabels(AValue: TXelPieLabels);
    procedure SetOtherThreshold(AValue: Double);
    procedure SetOtherCaption(const AValue: String);
    procedure SetExplode(AValue: Integer);
    procedure SetExplodeIndex(AValue: Integer);
    procedure BuildSlices;
    function  SliceCaption(AIndex: Integer): String;
  protected
    function  UsesAxes: Boolean; override;
    procedure GetLegendItems(AItems: TStrings; AColors: TList); override;
    procedure DrawPlot(ACanvas: TCanvas; const ARect: TRect;
      AScale: Integer); override;
    procedure DrawOverlay(ACanvas: TCanvas; const ARect: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
    // Index of the slice under a point, -1 when outside.  Valid after the
    // first paint.
    function SliceAt(AX, AY: Integer): Integer;
  published
    // Hole size in percent of the radius.  0 = full pie, 55 = a donut.
    property Donut: Integer read FDonut write SetDonut default 0;
    // Where the first slice starts, degrees clockwise from twelve o'clock.
    property StartAngle: Integer read FStartAngle write SetStartAngle default 0;
    property Labels: TXelPieLabels read FLabels write SetLabels default plPercent;
    // Slices smaller than this share of the total (in percent) are merged into
    // one "Other" slice.  0 disables the merge.
    property OtherThreshold: Double read FOtherThreshold write SetOtherThreshold;
    property OtherCaption: String read FOtherCaption write SetOtherCaption;
    // Pull one slice out by this many pixels.
    property Explode: Integer read FExplode write SetExplode default 0;
    property ExplodeIndex: Integer read FExplodeIndex write SetExplodeIndex
      default -1;
  end;

procedure Register;

implementation

{$R txelpiechart_images.res}

constructor TXelPieChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDonut          := 0;
  FStartAngle     := 0;
  FLabels         := plPercent;
  FOtherThreshold := 2;
  FOtherCaption   := 'Other';
  FExplode        := 0;
  FExplodeIndex   := -1;
  AxisX.Visible := False;
  AxisY.Visible := False;
end;

function TXelPieChart.UsesAxes: Boolean;
begin
  Result := False;
end;

procedure TXelPieChart.SetDonut(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 90 then AValue := 90;
  if FDonut = AValue then Exit;
  FDonut := AValue; Invalidate;
end;

procedure TXelPieChart.SetStartAngle(AValue: Integer);
begin
  AValue := AValue mod 360;
  if FStartAngle = AValue then Exit;
  FStartAngle := AValue; Invalidate;
end;

procedure TXelPieChart.SetLabels(AValue: TXelPieLabels);
begin
  if FLabels = AValue then Exit;
  FLabels := AValue; Invalidate;
end;

procedure TXelPieChart.SetOtherThreshold(AValue: Double);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 50 then AValue := 50;
  if FOtherThreshold = AValue then Exit;
  FOtherThreshold := AValue; Invalidate;
end;

procedure TXelPieChart.SetOtherCaption(const AValue: String);
begin
  if FOtherCaption = AValue then Exit;
  FOtherCaption := AValue; Invalidate;
end;

procedure TXelPieChart.SetExplode(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 60 then AValue := 60;
  if FExplode = AValue then Exit;
  FExplode := AValue; Invalidate;
end;

procedure TXelPieChart.SetExplodeIndex(AValue: Integer);
begin
  if AValue < -1 then AValue := -1;
  if FExplodeIndex = AValue then Exit;
  FExplodeIndex := AValue; Invalidate;
end;

// ---------------------------------------------------------------------------
// Slice list
// ---------------------------------------------------------------------------

procedure TXelPieChart.BuildSlices;
var
  S        : TXelChartSeries;
  I, N     : Integer;
  Sum      : Double;
  OtherSum : Double;
  V        : Double;
begin
  SetLength(FVals, 0);
  SetLength(FTexts, 0);
  SetLength(FCols, 0);
  FTotal := 0;

  S := nil;
  for I := 0 to Series.Count - 1 do
    if Series[I].Visible and (Series[I].Count > 0) then
    begin
      S := Series[I];
      Break;
    end;
  if S = nil then Exit;

  // negative values have no meaning in a part-of-whole chart
  Sum := 0;
  for I := 0 to S.Count - 1 do
    if S.Y[I] > 0 then Sum := Sum + S.Y[I];
  if Sum <= 0 then Exit;

  N        := 0;
  OtherSum := 0;
  SetLength(FVals, S.Count + 1);
  SetLength(FTexts, S.Count + 1);
  SetLength(FCols, S.Count + 1);

  for I := 0 to S.Count - 1 do
  begin
    V := S.Y[I];
    if V <= 0 then Continue;

    if (FOtherThreshold > 0) and (100 * V / Sum < FOtherThreshold) then
    begin
      OtherSum := OtherSum + V;
      Continue;
    end;

    FVals[N] := V;
    if S.Text[I] <> '' then FTexts[N] := S.Text[I]
                       else FTexts[N] := Format('%d', [I + 1]);
    FCols[N] := XelSeriesColor(N, Theme, PaletteWrap);
    Inc(N);
  end;

  if OtherSum > 0 then
  begin
    FVals[N]  := OtherSum;
    FTexts[N] := FOtherCaption;
    FCols[N]  := XelOtherColor;
    Inc(N);
  end;

  SetLength(FVals, N);
  SetLength(FTexts, N);
  SetLength(FCols, N);
  FTotal := Sum;
end;

function TXelPieChart.SliceCaption(AIndex: Integer): String;
var
  Pct: Double;
begin
  if (AIndex < 0) or (AIndex > High(FVals)) or (FTotal <= 0) then Exit('');
  Pct := 100 * FVals[AIndex] / FTotal;
  case FLabels of
    plValue       : Result := AxisY.FormatValue(FVals[AIndex]);
    plPercent     : Result := Format('%.0f%%', [Pct]);
    plName        : Result := FTexts[AIndex];
    plNamePercent : Result := Format('%s %.0f%%', [FTexts[AIndex], Pct]);
  else
    Result := '';
  end;
end;

procedure TXelPieChart.GetLegendItems(AItems: TStrings; AColors: TList);
var
  I: Integer;
begin
  BuildSlices;
  for I := 0 to High(FVals) do
  begin
    AItems.Add(FTexts[I]);
    AColors.Add(TObject(PtrInt(FCols[I])));
  end;
end;

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

procedure TXelPieChart.DrawPlot(ACanvas: TCanvas; const ARect: TRect;
  AScale: Integer);
var
  I        : Integer;
  CX, CY   : Integer;
  R, RIn   : Integer;
  A0, A1   : Double;
  Acc      : Double;
  Rad      : Double;
  OX, OY   : Integer;
  Mid      : Double;
  Gap      : Integer;

  // Canvas.Pie wants the two ray end points; compute them from an angle
  // measured clockwise from twelve o'clock.
  procedure RayPoint(AAngleDeg: Double; ARadius: Integer;
    ACx, ACy: Integer; out PX, PY: Integer);
  var
    Rd: Double;
  begin
    Rd := DegToRad(AAngleDeg - 90);
    PX := ACx + Round(Cos(Rd) * ARadius);
    PY := ACy + Round(Sin(Rd) * ARadius);
  end;

var
  P1X, P1Y, P2X, P2Y: Integer;
begin
  BuildSlices;
  if (Length(FVals) = 0) or (FTotal <= 0) then Exit;

  CX := (ARect.Left + ARect.Right) div 2;
  CY := (ARect.Top + ARect.Bottom) div 2;
  R  := Math.Min(ARect.Right - ARect.Left, ARect.Bottom - ARect.Top) div 2;
  Dec(R, FExplode * AScale + 2 * AScale);
  if R < 4 then Exit;

  RIn := R * FDonut div 100;
  Gap := Math.Max(1, AScale);

  Acc := 0;
  for I := 0 to High(FVals) do
  begin
    A0 := FStartAngle + 360 * Acc / FTotal;
    Acc := Acc + FVals[I];
    A1 := FStartAngle + 360 * Acc / FTotal;
    if A1 - A0 < 0.05 then Continue;

    OX := 0; OY := 0;
    if (FExplode > 0) and (I = FExplodeIndex) then
    begin
      Mid := (A0 + A1) / 2;
      Rad := DegToRad(Mid - 90);
      OX  := Round(Cos(Rad) * FExplode * AScale);
      OY  := Round(Sin(Rad) * FExplode * AScale);
    end;

    RayPoint(A0, R, CX + OX, CY + OY, P1X, P1Y);
    RayPoint(A1, R, CX + OX, CY + OY, P2X, P2Y);

    ACanvas.Brush.Color := FCols[I];
    ACanvas.Brush.Style := bsSolid;
    // a surface-coloured hairline keeps neighbouring slices apart
    ACanvas.Pen.Color := EffectivePlotColor;
    ACanvas.Pen.Width := Gap;
    ACanvas.Pen.Style := psSolid;

    ACanvas.Pie(CX + OX - R, CY + OY - R, CX + OX + R, CY + OY + R,
                P2X, P2Y, P1X, P1Y);
  end;

  // donut hole
  if RIn > 2 then
  begin
    ACanvas.Brush.Color := EffectivePlotColor;
    ACanvas.Pen.Style   := psClear;
    ACanvas.Ellipse(CX - RIn, CY - RIn, CX + RIn, CY + RIn);
    ACanvas.Pen.Style   := psSolid;
  end;
end;

procedure TXelPieChart.DrawOverlay(ACanvas: TCanvas; const ARect: TRect);
var
  I      : Integer;
  CX, CY : Integer;
  R, RL  : Integer;
  Acc    : Double;
  A0, A1 : Double;
  Mid    : Double;
  Rad    : Double;
  Txt    : String;
  TX, TY : Integer;
begin
  if FLabels = plNone then Exit;
  if (Length(FVals) = 0) or (FTotal <= 0) then Exit;

  CX := (ARect.Left + ARect.Right) div 2;
  CY := (ARect.Top + ARect.Bottom) div 2;
  R  := Math.Min(ARect.Right - ARect.Left, ARect.Bottom - ARect.Top) div 2;
  Dec(R, FExplode + 2);
  if R < 4 then Exit;

  if FDonut > 0 then RL := (R + R * FDonut div 100) div 2
                 else RL := R * 62 div 100;

  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Color  := InkColor;

  Acc := 0;
  for I := 0 to High(FVals) do
  begin
    A0 := FStartAngle + 360 * Acc / FTotal;
    Acc := Acc + FVals[I];
    A1 := FStartAngle + 360 * Acc / FTotal;

    // skip labels that cannot fit — a 3% slice has no room for text
    if (A1 - A0) < 18 then Continue;

    Txt := SliceCaption(I);
    if Txt = '' then Continue;

    Mid := (A0 + A1) / 2;
    Rad := DegToRad(Mid - 90);
    TX  := CX + Round(Cos(Rad) * RL);
    TY  := CY + Round(Sin(Rad) * RL);

    if (FExplode > 0) and (I = FExplodeIndex) then
    begin
      Inc(TX, Round(Cos(Rad) * FExplode));
      Inc(TY, Round(Sin(Rad) * FExplode));
    end;

    ACanvas.TextOut(TX - ACanvas.TextWidth(Txt) div 2,
                    TY - ACanvas.TextHeight(Txt) div 2, Txt);
  end;

  ACanvas.Brush.Style := bsSolid;
end;

function TXelPieChart.SliceAt(AX, AY: Integer): Integer;
var
  CX, CY, R, RIn : Integer;
  DX, DY         : Integer;
  Dist           : Double;
  Ang            : Double;
  I              : Integer;
  Acc            : Double;
  A0, A1         : Double;
begin
  Result := -1;
  if (Length(FVals) = 0) or (FTotal <= 0) then Exit;

  CX := (PlotRect.Left + PlotRect.Right) div 2;
  CY := (PlotRect.Top + PlotRect.Bottom) div 2;
  R  := Math.Min(PlotRect.Right - PlotRect.Left,
                 PlotRect.Bottom - PlotRect.Top) div 2 - FExplode - 2;
  if R < 4 then Exit;
  RIn := R * FDonut div 100;

  DX := AX - CX;
  DY := AY - CY;
  Dist := Sqrt(DX * DX + DY * DY);
  if (Dist > R) or (Dist < RIn) then Exit;

  Ang := RadToDeg(ArcTan2(DY, DX)) + 90 - FStartAngle;
  while Ang < 0 do Ang := Ang + 360;
  while Ang >= 360 do Ang := Ang - 360;

  Acc := 0;
  for I := 0 to High(FVals) do
  begin
    A0 := 360 * Acc / FTotal;
    Acc := Acc + FVals[I];
    A1 := 360 * Acc / FTotal;
    if (Ang >= A0) and (Ang < A1) then Exit(I);
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelPieChart]);
end;

end.
