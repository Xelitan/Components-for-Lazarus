unit XelBarChart;

//Author: xelitan.com
//License: MIT
//
//TXelBarChart - grouped, stacked and overlapped bars, vertical or horizontal.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math, Types,
  XelChartTypes, XelChartBase;

type
  // TXelBarChart
  //
  // Bars are laid out per category index (X = 0, 1, 2 ...), so a series added
  // with SetData or Add lands in the right slot without any X bookkeeping.
  // Categories names the ticks.
  TXelBarChart = class(TXelCustomChart)
  private
    FCategories  : TStrings;
    FLayout      : TXelBarLayout;
    FOrientation : TXelChartOrientation;
    FBarSpacing  : Integer;
    FGroupSpacing: Integer;
    FCornerRadius: Integer;
    procedure SetCategories(AValue: TStrings);
    procedure SetLayout(AValue: TXelBarLayout);
    procedure SetOrientation(AValue: TXelChartOrientation);
    procedure SetBarSpacing(AValue: Integer);
    procedure SetGroupSpacing(AValue: Integer);
    procedure SetCornerRadius(AValue: Integer);
    procedure CategoriesChanged(Sender: TObject);
    function  CategoryCount: Integer;
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
    property Categories: TStrings read FCategories write SetCategories;
    property Layout: TXelBarLayout read FLayout write SetLayout default blGrouped;
    property Orientation: TXelChartOrientation read FOrientation
      write SetOrientation default coVertical;
    // Gap between bars inside one group, in pixels.
    property BarSpacing: Integer read FBarSpacing write SetBarSpacing default 2;
    // Share of the category slot left empty, in percent.
    property GroupSpacing: Integer read FGroupSpacing write SetGroupSpacing
      default 30;
    // Rounded data-end radius.  4 px reads as a deliberate cap; 0 is square.
    property CornerRadius: Integer read FCornerRadius write SetCornerRadius
      default 4;
  end;

procedure Register;

implementation

{$R txelbarchart_images.res}

constructor TXelBarChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCategories := TStringList.Create;
  TStringList(FCategories).OnChange := CategoriesChanged;
  FLayout       := blGrouped;
  FOrientation  := coVertical;
  FBarSpacing   := 2;
  FGroupSpacing := 30;
  FCornerRadius := 4;
  // a bar chart with a cut baseline misrepresents proportions
  AxisY.AutoZero := True;
  AxisX.ShowGrid := False;
  AxisX.TickCount := 2;
end;

destructor TXelBarChart.Destroy;
begin
  FCategories.Free;
  inherited Destroy;
end;

procedure TXelBarChart.CategoriesChanged(Sender: TObject);
begin
  Invalidate;
end;

procedure TXelBarChart.SetCategories(AValue: TStrings);
begin
  FCategories.Assign(AValue);
  Invalidate;
end;

procedure TXelBarChart.SetLayout(AValue: TXelBarLayout);
begin
  if FLayout = AValue then Exit;
  FLayout := AValue; Invalidate;
end;

procedure TXelBarChart.SetOrientation(AValue: TXelChartOrientation);
begin
  if FOrientation = AValue then Exit;
  FOrientation := AValue; Invalidate;
end;

procedure TXelBarChart.SetBarSpacing(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 40 then AValue := 40;
  if FBarSpacing = AValue then Exit;
  FBarSpacing := AValue; Invalidate;
end;

procedure TXelBarChart.SetGroupSpacing(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 80 then AValue := 80;
  if FGroupSpacing = AValue then Exit;
  FGroupSpacing := AValue; Invalidate;
end;

procedure TXelBarChart.SetCornerRadius(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 20 then AValue := 20;
  if FCornerRadius = AValue then Exit;
  FCornerRadius := AValue; Invalidate;
end;

function TXelBarChart.CategoryCount: Integer;
var
  I: Integer;
begin
  Result := FCategories.Count;
  for I := 0 to Series.Count - 1 do
    if Series[I].Visible and (Series[I].Count > Result) then
      Result := Series[I].Count;
end;

function TXelBarChart.FormatXTick(AValue: Double): String;
begin
  Result := '';   // category names are drawn per slot in DrawOverlay
end;

procedure TXelBarChart.AfterAxisRecalc;
var
  N: Integer;
begin
  // Slot J must land exactly on J, so the X scale is pinned to the category
  // range instead of being rounded to readable ticks.
  N := CategoryCount;
  if N < 1 then N := 1;
  AxisX.ForceRange(-0.5, N - 0.5, 1);
end;

procedure TXelBarChart.GetDataRange(out AMinX, AMaxX, AMinY, AMaxY: Double);
var
  I, J, N : Integer;
  PosSum  : Double;
  NegSum  : Double;
  S       : TXelChartSeries;
begin
  N := CategoryCount;
  AMinX := -0.5;
  AMaxX := N - 0.5;
  if N = 0 then AMaxX := 0.5;

  AMinY := 0;
  AMaxY := 0;

  if FLayout = blStacked then
  begin
    // the stack total is what has to fit
    for J := 0 to N - 1 do
    begin
      PosSum := 0;
      NegSum := 0;
      for I := 0 to Series.Count - 1 do
      begin
        S := Series[I];
        if (not S.Visible) or (J >= S.Count) then Continue;
        if S.Y[J] >= 0 then PosSum := PosSum + S.Y[J]
                       else NegSum := NegSum + S.Y[J];
      end;
      AMaxY := Math.Max(AMaxY, PosSum);
      AMinY := Math.Min(AMinY, NegSum);
    end;
  end
  else
    for I := 0 to Series.Count - 1 do
    begin
      S := Series[I];
      if (not S.Visible) or (S.Count = 0) then Continue;
      AMaxY := Math.Max(AMaxY, S.MaxY);
      AMinY := Math.Min(AMinY, S.MinY);
    end;

  if AMaxY = AMinY then AMaxY := AMinY + 1;
end;

procedure TXelBarChart.DrawPlot(ACanvas: TCanvas; const ARect: TRect;
  AScale: Integer);
var
  N, VisCount   : Integer;
  I, J, Slot    : Integer;
  S             : TXelChartSeries;
  SlotW         : Integer;
  GroupW        : Integer;
  BarW          : Integer;
  CX            : Integer;
  X0, X1        : Integer;
  YZero, YVal   : Integer;
  Col           : TColor;
  PosBase       : array of Double;
  NegBase       : array of Double;
  Base, Top_    : Double;
  Rad           : Integer;
  Gap           : Integer;
  YA, YB        : Integer;

  procedure Bar(AL, AT, AR, AB: Integer; AColor: TColor);
  begin
    if AR - AL < 1 then AR := AL + 1;
    if AB - AT < 1 then AB := AT + 1;
    ACanvas.Brush.Color := AColor;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Pen.Style   := psClear;
    if (Rad > 0) and (AR - AL > Rad * 2) and (AB - AT > Rad * 2) then
      ACanvas.RoundRect(AL, AT, AR, AB, Rad * 2, Rad * 2)
    else
      ACanvas.Rectangle(AL, AT, AR, AB);
    ACanvas.Pen.Style := psSolid;
  end;

begin
  N := CategoryCount;
  if N = 0 then Exit;

  VisCount := Series.VisibleCount;
  if VisCount = 0 then Exit;

  Rad := FCornerRadius * AScale;
  Gap := Math.Max(1, 2 * AScale);   // 2 px surface gap between fills

  // widths come from the 1x plot rect and are scaled once; ARect is already
  // the supersampled buffer, so measuring it here would scale them twice
  SlotW  := (PlotRect.Right - PlotRect.Left) div N;
  GroupW := SlotW - (SlotW * FGroupSpacing) div 100;
  if GroupW < 2 then GroupW := 2;

  YZero := (ValueToY(0, PlotRect) - PlotRect.Top) * AScale;

  SetLength(PosBase, N);
  SetLength(NegBase, N);

  if FLayout = blStacked then
  begin
    // draw bottom-up so each segment sits on the previous one
    for J := 0 to N - 1 do begin PosBase[J] := 0; NegBase[J] := 0; end;

    for I := 0 to Series.Count - 1 do
    begin
      S := Series[I];
      if (not S.Visible) or (S.Count = 0) then Continue;
      Col := S.EffectiveColor;

      for J := 0 to Math.Min(N, S.Count) - 1 do
      begin
        CX := (ValueToX(J, PlotRect) - PlotRect.Left) * AScale;
        X0 := CX - GroupW * AScale div 2;
        X1 := X0 + GroupW * AScale;

        if S.Y[J] >= 0 then
        begin
          Base := PosBase[J];
          Top_ := Base + S.Y[J];
          PosBase[J] := Top_;
        end
        else
        begin
          Base := NegBase[J];
          Top_ := Base + S.Y[J];
          NegBase[J] := Top_;
        end;

        YA := (ValueToY(Base, PlotRect) - PlotRect.Top) * AScale;
        YB := (ValueToY(Top_, PlotRect) - PlotRect.Top) * AScale;
        if YA > YB then Bar(X0, YB, X1, YA - Gap, Col)
                   else Bar(X0, YA + Gap, X1, YB, Col);
      end;
    end;
    Exit;
  end;

  // --- grouped / overlapped ---
  if FLayout = blOverlapped then
    BarW := GroupW * AScale
  else
    BarW := (GroupW * AScale - (VisCount - 1) * FBarSpacing * AScale) div VisCount;
  if BarW < 1 then BarW := 1;

  Slot := 0;
  for I := 0 to Series.Count - 1 do
  begin
    S := Series[I];
    if (not S.Visible) or (S.Count = 0) then Continue;
    Col := S.EffectiveColor;

    for J := 0 to Math.Min(N, S.Count) - 1 do
    begin
      CX := (ValueToX(J, PlotRect) - PlotRect.Left) * AScale;

      if FLayout = blOverlapped then
      begin
        // each next series a little narrower, drawn on top
        X0 := CX - (BarW - Slot * BarW div (VisCount + 1)) div 2;
        X1 := X0 + (BarW - Slot * BarW div (VisCount + 1));
      end
      else
      begin
        X0 := CX - GroupW * AScale div 2 +
              Slot * (BarW + FBarSpacing * AScale);
        X1 := X0 + BarW;
      end;

      YVal := (ValueToY(S.Y[J], PlotRect) - PlotRect.Top) * AScale;
      if YVal <= YZero then Bar(X0, YVal, X1, YZero, Col)
                       else Bar(X0, YZero, X1, YVal, Col);
    end;
    Inc(Slot);
  end;
end;

procedure TXelBarChart.DrawOverlay(ACanvas: TCanvas; const ARect: TRect);
var
  N, I, J, Slot, VisCount : Integer;
  S      : TXelChartSeries;
  SlotW  : Integer;
  GroupW : Integer;
  BarW   : Integer;
  CX     : Integer;
  Txt    : String;
  W      : Integer;
begin
  N := CategoryCount;
  if N = 0 then Exit;
  VisCount := Series.VisibleCount;
  if VisCount = 0 then Exit;

  SlotW  := (ARect.Right - ARect.Left) div N;
  GroupW := SlotW - (SlotW * FGroupSpacing) div 100;
  BarW   := Math.Max(1,
    (GroupW - (VisCount - 1) * FBarSpacing) div VisCount);

  // --- category names under the slots ---
  if AxisX.Visible and AxisX.ShowLabels and (FCategories.Count > 0) then
  begin
    ACanvas.Brush.Style := bsClear;
    ACanvas.Font.Color  := XelMutedColor;
    for J := 0 to Math.Min(N, FCategories.Count) - 1 do
    begin
      CX  := ValueToX(J, ARect);
      Txt := FCategories[J];
      W   := ACanvas.TextWidth(Txt);
      if W > SlotW then Continue;    // no room, better blank than overlapping
      ACanvas.TextOut(CX - W div 2, ARect.Bottom + 6, Txt);
    end;
    ACanvas.Brush.Style := bsSolid;
  end;

  // --- direct value labels ---
  Slot := 0;
  for I := 0 to Series.Count - 1 do
  begin
    S := Series[I];
    if (not S.Visible) or (S.Count = 0) then Continue;

    if S.ShowLabels then
      for J := 0 to Math.Min(N, S.Count) - 1 do
      begin
        CX := ValueToX(J, ARect);
        if FLayout = blGrouped then
          CX := CX - GroupW div 2 + Slot * (BarW + FBarSpacing) + BarW div 2;
        if S.Text[J] <> '' then Txt := S.Text[J]
                           else Txt := AxisY.FormatValue(S.Y[J]);
        DrawValueLabel(ACanvas, CX, ValueToY(S.Y[J], ARect), Txt, S.Y[J] < 0);
      end;

    Inc(Slot);
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelBarChart]);
end;

end.
