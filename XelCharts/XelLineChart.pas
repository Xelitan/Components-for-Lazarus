unit XelLineChart;

//Author: xelitan.com
//License: MIT
//
//TXelLineChart - line, area and scatter plots.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math, Types,
  XelChartTypes, XelChartBase;

type
  TXelPointArray = array of TPoint;

  // How consecutive samples are joined.
  //
  // lmStraight - a segment from sample to sample.  The honest default.
  // lmStepped  - hold each value until halfway to the next sample, then jump.
  //              Right for quantities that change at discrete moments
  //              (a price, a stock level) rather than continuously.
  // lmSmooth   - Catmull-Rom through the samples.  Easier on the eye but it
  //              draws values between the samples that were never measured;
  //              use it for dense series, not for a dozen monthly readings.
  TXelLineMode = (lmStraight, lmStepped, lmSmooth);

  // TXelLineChart
  //
  // Per-series Style picks the mark: ssLine, ssArea, ssPoints or ssLinePoints.
  // Categories names the X ticks when the data is categorical rather than
  // numeric - set it and the X axis prints those strings instead of numbers.
  TXelLineChart = class(TXelCustomChart)
  private
    FCategories : TStrings;
    FLineMode   : TXelLineMode;
    FMarkLast   : Boolean;
    procedure SetCategories(AValue: TStrings);
    procedure SetLineMode(AValue: TXelLineMode);
    procedure SetMarkLast(AValue: Boolean);
    procedure CategoriesChanged(Sender: TObject);
    // Sample points expanded into the polyline actually drawn, so the stroke
    // and the area fill can never disagree.
    procedure BuildPath(const APts: array of TPoint; out APath: TXelPointArray);
  protected
    procedure GetDataRange(out AMinX, AMaxX, AMinY, AMaxY: Double); override;
    procedure DrawPlot(ACanvas: TCanvas; const ARect: TRect;
      AScale: Integer); override;
    procedure DrawOverlay(ACanvas: TCanvas; const ARect: TRect); override;
    function  FormatXTick(AValue: Double): String; override;
    procedure AfterAxisRecalc; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
  published
    // Optional category labels for the X ticks.
    property Categories: TStrings read FCategories write SetCategories;
    property LineMode: TXelLineMode read FLineMode write SetLineMode
      default lmStraight;
    // Put a filled dot plus a direct label on the last point of every series
    // - the one place a label is always worth its ink on a time series.
    property MarkLast: Boolean read FMarkLast write SetMarkLast default False;
  end;

procedure Register;

implementation

{$R txellinechart_images.res}

constructor TXelLineChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCategories := TStringList.Create;
  TStringList(FCategories).OnChange := CategoriesChanged;
  AxisY.AutoZero := True;
  AxisX.AutoZero := False;
end;

destructor TXelLineChart.Destroy;
begin
  FCategories.Free;
  inherited Destroy;
end;

procedure TXelLineChart.CategoriesChanged(Sender: TObject);
begin
  Invalidate;
end;

procedure TXelLineChart.SetCategories(AValue: TStrings);
begin
  FCategories.Assign(AValue);
  Invalidate;
end;

procedure TXelLineChart.SetLineMode(AValue: TXelLineMode);
begin
  if FLineMode = AValue then Exit;
  FLineMode := AValue; Invalidate;
end;

procedure TXelLineChart.BuildPath(const APts: array of TPoint;
  out APath: TXelPointArray);
const
  SEG = 12;                      // samples per Catmull-Rom span
var
  N, I, K, M : Integer;
  P0, P1, P2, P3 : TPoint;
  T, T2, T3  : Double;

  function Clamp(AIndex: Integer): TPoint;
  begin
    if AIndex < 0 then AIndex := 0;
    if AIndex > High(APts) then AIndex := High(APts);
    Result := APts[AIndex];
  end;

begin
  N := Length(APts);
  SetLength(APath, 0);
  if N = 0 then Exit;

  case FLineMode of
    lmStepped:
      begin
        SetLength(APath, N * 2);
        M := 0;
        APath[M] := APts[0]; Inc(M);
        for I := 0 to N - 2 do
        begin
          K := (APts[I].X + APts[I + 1].X) div 2;
          APath[M] := Point(K, APts[I].Y);     Inc(M);
          APath[M] := Point(K, APts[I + 1].Y); Inc(M);
        end;
        APath[M] := APts[N - 1]; Inc(M);
        SetLength(APath, M);
      end;

    lmSmooth:
      begin
        if N < 3 then
        begin
          SetLength(APath, N);
          for I := 0 to N - 1 do APath[I] := APts[I];
          Exit;
        end;
        SetLength(APath, (N - 1) * SEG + 1);
        M := 0;
        for I := 0 to N - 2 do
        begin
          P0 := Clamp(I - 1);
          P1 := APts[I];
          P2 := APts[I + 1];
          P3 := Clamp(I + 2);
          for K := 0 to SEG - 1 do
          begin
            T  := K / SEG;
            T2 := T * T;
            T3 := T2 * T;
            APath[M].X := Round(0.5 * ((2 * P1.X) +
              (-P0.X + P2.X) * T +
              (2 * P0.X - 5 * P1.X + 4 * P2.X - P3.X) * T2 +
              (-P0.X + 3 * P1.X - 3 * P2.X + P3.X) * T3));
            APath[M].Y := Round(0.5 * ((2 * P1.Y) +
              (-P0.Y + P2.Y) * T +
              (2 * P0.Y - 5 * P1.Y + 4 * P2.Y - P3.Y) * T2 +
              (-P0.Y + 3 * P1.Y - 3 * P2.Y + P3.Y) * T3));
            Inc(M);
          end;
        end;
        APath[M] := APts[N - 1]; Inc(M);
        SetLength(APath, M);
      end;

  else
    SetLength(APath, N);
    for I := 0 to N - 1 do APath[I] := APts[I];
  end;
end;

procedure TXelLineChart.SetMarkLast(AValue: Boolean);
begin
  if FMarkLast = AValue then Exit;
  FMarkLast := AValue; Invalidate;
end;

procedure TXelLineChart.GetDataRange(out AMinX, AMaxX, AMinY, AMaxY: Double);
begin
  inherited GetDataRange(AMinX, AMaxX, AMinY, AMaxY);
  // a single-point series would give a zero-wide X range
  if AMaxX = AMinX then AMaxX := AMinX + 1;
end;

procedure TXelLineChart.DrawPlot(ACanvas: TCanvas; const ARect: TRect;
  AScale: Integer);
var
  I, J    : Integer;
  S       : TXelChartSeries;
  Col     : TColor;
  Pts     : array of TPoint;
  Path    : TXelPointArray;
  Poly    : array of TPoint;
  N, PN   : Integer;
  Zero    : Integer;
  Rad     : Integer;
begin
  // The plot rectangle handed to us is already in ACanvas space, but
  // ValueToX / ValueToY work against the control's plot rect, so shift the
  // result by the same offset and multiply by AScale.

  Zero := ValueToY(0, PlotRect);
  if Zero < PlotRect.Top then Zero := PlotRect.Top;
  if Zero > PlotRect.Bottom then Zero := PlotRect.Bottom;
  Zero := (Zero - PlotRect.Top) * AScale;

  for I := 0 to Series.Count - 1 do
  begin
    S := Series[I];
    if (not S.Visible) or (S.Count = 0) then Continue;
    Col := S.EffectiveColor;

    SetLength(Pts, S.Count);
    for J := 0 to S.Count - 1 do
    begin
      Pts[J].X := (ValueToX(S.X[J], PlotRect) - PlotRect.Left) * AScale;
      Pts[J].Y := (ValueToY(S.Y[J], PlotRect) - PlotRect.Top)  * AScale;
    end;
    N := Length(Pts);
    BuildPath(Pts, Path);
    PN := Length(Path);

    // --- area fill, following exactly the path the stroke will take ---
    if (S.Style = ssArea) and (PN >= 2) then
    begin
      SetLength(Poly, PN + 2);
      for J := 0 to PN - 1 do Poly[J] := Path[J];
      Poly[PN]     := Point(Path[PN - 1].X, Zero);
      Poly[PN + 1] := Point(Path[0].X, Zero);

      ACanvas.Brush.Color := FillTint(Col, 170);
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Pen.Style   := psClear;
      ACanvas.Polygon(Poly);
      ACanvas.Pen.Style   := psSolid;
    end;

    // --- the line ---
    if (S.Style in [ssLine, ssArea, ssLinePoints]) and (PN >= 2) then
    begin
      ACanvas.Pen.Color := Col;
      ACanvas.Pen.Width := S.LineWidth * AScale;
      ACanvas.Pen.Style := psSolid;
      ACanvas.Polyline(Path);
      ACanvas.Pen.Width := 1;
    end;

    // --- point markers ---
    if S.Style in [ssPoints, ssLinePoints] then
    begin
      Rad := Math.Max(2, S.PointSize * AScale div 2);
      ACanvas.Brush.Color := Col;
      ACanvas.Brush.Style := bsSolid;
      // a surface-coloured ring keeps overlapping markers apart
      ACanvas.Pen.Color := EffectivePlotColor;
      ACanvas.Pen.Width := Math.Max(1, 2 * AScale);
      for J := 0 to N - 1 do
        ACanvas.Ellipse(Pts[J].X - Rad, Pts[J].Y - Rad,
                        Pts[J].X + Rad, Pts[J].Y + Rad);
      ACanvas.Pen.Width := 1;
    end;

    // --- last point emphasis ---
    if FMarkLast and (N > 0) then
    begin
      Rad := Math.Max(2, 4 * AScale);
      ACanvas.Brush.Color := Col;
      ACanvas.Pen.Color   := EffectivePlotColor;
      ACanvas.Pen.Width   := Math.Max(1, 2 * AScale);
      ACanvas.Ellipse(Pts[N - 1].X - Rad, Pts[N - 1].Y - Rad,
                      Pts[N - 1].X + Rad, Pts[N - 1].Y + Rad);
      ACanvas.Pen.Width := 1;
    end;
  end;

end;

procedure TXelLineChart.DrawOverlay(ACanvas: TCanvas; const ARect: TRect);
var
  I, J : Integer;
  S    : TXelChartSeries;
  Txt  : String;
begin
  for I := 0 to Series.Count - 1 do
  begin
    S := Series[I];
    if (not S.Visible) or (S.Count = 0) then Continue;

    if S.ShowLabels then
    begin
      for J := 0 to S.Count - 1 do
      begin
        if S.Text[J] <> '' then Txt := S.Text[J]
                           else Txt := AxisY.FormatValue(S.Y[J]);
        DrawValueLabel(ACanvas, ValueToX(S.X[J], ARect),
          ValueToY(S.Y[J], ARect), Txt, False);
      end;
    end
    else if FMarkLast then
    begin
      J := S.Count - 1;
      if S.Text[J] <> '' then Txt := S.Text[J]
                         else Txt := AxisY.FormatValue(S.Y[J]);
      DrawValueLabel(ACanvas, ValueToX(S.X[J], ARect),
        ValueToY(S.Y[J], ARect), Txt, False);
    end;
  end;
end;

procedure TXelLineChart.AfterAxisRecalc;
var
  N, I: Integer;
begin
  if FCategories.Count = 0 then Exit;
  // one tick per category, landing exactly on the sample index
  N := FCategories.Count;
  for I := 0 to Series.Count - 1 do
    if Series[I].Visible and (Series[I].Count > N) then N := Series[I].Count;
  if N < 2 then N := 2;
  AxisX.ForceRange(0, N - 1, 1);
end;

function TXelLineChart.FormatXTick(AValue: Double): String;
var
  I: Integer;
begin
  I := Round(AValue);
  if (FCategories.Count > 0) and (I >= 0) and (I < FCategories.Count) and
     (Abs(AValue - I) < 0.001) then
    Result := FCategories[I]
  else if FCategories.Count > 0 then
    Result := ''
  else
    Result := inherited FormatXTick(AValue);
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelLineChart]);
end;

end.
