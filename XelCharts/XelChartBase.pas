unit XelChartBase;

//Author: xelitan.com
//License: MIT
//
//TXelCustomChart - layout, title, axes, grid and legend.  The concrete charts
//(TXelLineChart, TXelBarChart, TXelPieChart) only fill in DrawPlot.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math, Types, LCLType,
  XelChartTypes;

type
  // TXelCustomChart
  TXelCustomChart = class(TCustomControl)
  private
    FSeries       : TXelChartSeriesList;
    FAxisX        : TXelChartAxis;
    FAxisY        : TXelChartAxis;
    FLegend       : TXelChartLegend;
    FTitle        : String;
    FFooter       : String;
    FTheme        : TXelChartTheme;
    FPaletteWrap  : Boolean;
    FAntialiased  : Boolean;
    FPadding      : Integer;
    FPlotColor    : TColor;
    FUpdateCount  : Integer;
    FOnPlotClick  : TNotifyEvent;
    procedure SetTitle(const AValue: String);
    procedure SetFooter(const AValue: String);
    procedure SetTheme(AValue: TXelChartTheme);
    procedure SetPaletteWrap(AValue: Boolean);
    procedure SetAntialiased(AValue: Boolean);
    procedure SetPadding(AValue: Integer);
    procedure SetPlotColor(AValue: TColor);
    procedure SetSeries(AValue: TXelChartSeriesList);
    procedure SetAxisX(AValue: TXelChartAxis);
    procedure SetAxisY(AValue: TXelChartAxis);
    procedure SetLegend(AValue: TXelChartLegend);
  protected
    // plot rectangle in control coordinates, valid during Paint
    FPlotRect : TRect;

    procedure Paint; override;
    procedure Click; override;

    // --- overridables ---

    // True when this chart type uses X/Y axes.  Pie says False.
    function  UsesAxes: Boolean; virtual;
    // Data range the axes have to cover.  Called before every paint.
    procedure GetDataRange(out AMinX, AMaxX, AMinY, AMaxY: Double); virtual;
    // Draw the marks.  ARect is the plot area in ACanvas coordinates and
    // AScale is 1 or the supersampling factor — multiply pen widths and
    // radii by it, never the coordinates (those are already scaled).
    procedure DrawPlot(ACanvas: TCanvas; const ARect: TRect;
      AScale: Integer); virtual; abstract;
    // Anything that must stay crisp — direct labels, slice callouts.  Always
    // called on the control's own canvas at 1x, after the (possibly
    // supersampled) marks have landed.
    procedure DrawOverlay(ACanvas: TCanvas; const ARect: TRect); virtual;
    // Text for one X tick.  Category charts override it to print names.
    function  FormatXTick(AValue: Double): String; virtual;
    // Called right after both axes have been recalculated, before anything is
    // drawn.  Category charts use it to pin the X scale with ForceRange.
    procedure AfterAxisRecalc; virtual;
    // Legend entries.  Bar and line charts list series; pie lists slices.
    procedure GetLegendItems(AItems: TStrings; AColors: TList); virtual;

    // --- helpers for descendants ---

    function  ValueToX(AValue: Double; const ARect: TRect): Integer;
    function  ValueToY(AValue: Double; const ARect: TRect): Integer;
    function  InkColor: TColor;
    function  Ink2Color: TColor;
    function  SurfaceColor: TColor;
    function  EffectivePlotColor: TColor;
    // Fill colour for areas and bars: the series colour pulled towards the
    // plot surface so overlapping fills stay readable.
    function  FillTint(AColor: TColor; AAmount: Byte = 150): TColor;
    // Draw a value label centred on (X, Y) in ink, never in the series colour.
    procedure DrawValueLabel(ACanvas: TCanvas; X, Y: Integer;
      const AText: String; ABelow: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    procedure BeginUpdate;
    procedure EndUpdate;

    // Convenience: one call to fill a chart from an array.
    function AddSeries(const ATitle: String;
      const AValues: array of Double): TXelChartSeries;
    procedure ClearSeries;

    // Render into any canvas — printing, PNG export, a report.
    procedure PaintTo(ACanvas: TCanvas; const ARect: TRect);
    procedure SaveToBitmap(ABitmap: TBitmap);
    procedure SaveToFile(const AFileName: String);

    property PlotRect: TRect read FPlotRect;
  published
    property Series: TXelChartSeriesList read FSeries write SetSeries;
    property AxisX: TXelChartAxis read FAxisX write SetAxisX;
    property AxisY: TXelChartAxis read FAxisY write SetAxisY;
    property Legend: TXelChartLegend read FLegend write SetLegend;

    property Title: String read FTitle write SetTitle;
    property Footer: String read FFooter write SetFooter;

    // Switches the whole chart between the light and the dark colour set.
    // The dark steps are chosen for a dark surface, not derived by inverting
    // the light ones.
    property Theme: TXelChartTheme read FTheme write SetTheme default ctLight;

    // The palette has eight slots and they are never cycled: a ninth series
    // would repeat a hue and break the identity mapping.  Leave this False
    // and series nine and up paint in the neutral "Other" grey; set it True
    // only when you know the extra series are not compared against the
    // first eight.
    property PaletteWrap: Boolean read FPaletteWrap write SetPaletteWrap
      default False;

    // Supersample the plot area 3x.  Text, axes and legend are always drawn
    // at 1x so they stay crisp.
    property Antialiased: Boolean read FAntialiased write SetAntialiased
      default True;

    property Padding: Integer read FPadding write SetPadding default 12;
    // clDefault follows the theme surface.
    property PlotColor: TColor read FPlotColor write SetPlotColor default clDefault;

    property OnPlotClick: TNotifyEvent read FOnPlotClick write FOnPlotClick;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Constraints;
    property Enabled;
    property Font;
    property ParentFont;
    property ParentShowHint;
    property PopupMenu;
    property ShowHint;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

implementation

const
  AA_SCALE   = 3;
  TICK_LEN   = 4;
  SWATCH     = 10;

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

constructor TXelCustomChart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FSeries      := TXelChartSeriesList.Create(Self);
  FAxisX       := TXelChartAxis.Create(Self);
  FAxisY       := TXelChartAxis.Create(Self);
  FLegend      := TXelChartLegend.Create(Self);
  FTheme       := ctLight;
  FPaletteWrap := False;
  FAntialiased := True;
  FPadding     := 12;
  FPlotColor   := clDefault;
  FSeries.Theme := FTheme;
  FAxisX.LabelFormat := '%g';
  FAxisY.LabelFormat := '%g';
  SetInitialBounds(0, 0, 420, 260);
end;

destructor TXelCustomChart.Destroy;
begin
  FLegend.Free;
  FAxisY.Free;
  FAxisX.Free;
  FSeries.Free;
  inherited Destroy;
end;

procedure TXelCustomChart.BeginUpdate;
begin
  Inc(FUpdateCount);
end;

procedure TXelCustomChart.EndUpdate;
begin
  if FUpdateCount > 0 then Dec(FUpdateCount);
  if FUpdateCount = 0 then Invalidate;
end;

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

procedure TXelCustomChart.SetTitle(const AValue: String);
begin
  if FTitle = AValue then Exit;
  FTitle := AValue; Invalidate;
end;

procedure TXelCustomChart.SetFooter(const AValue: String);
begin
  if FFooter = AValue then Exit;
  FFooter := AValue; Invalidate;
end;

procedure TXelCustomChart.SetTheme(AValue: TXelChartTheme);
begin
  if FTheme = AValue then Exit;
  FTheme := AValue;
  FSeries.Theme := AValue;
  Invalidate;
end;

procedure TXelCustomChart.SetPaletteWrap(AValue: Boolean);
begin
  if FPaletteWrap = AValue then Exit;
  FPaletteWrap := AValue;
  FSeries.PaletteWrap := AValue;
  Invalidate;
end;

procedure TXelCustomChart.SetAntialiased(AValue: Boolean);
begin
  if FAntialiased = AValue then Exit;
  FAntialiased := AValue; Invalidate;
end;

procedure TXelCustomChart.SetPadding(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 80 then AValue := 80;
  if FPadding = AValue then Exit;
  FPadding := AValue; Invalidate;
end;

procedure TXelCustomChart.SetPlotColor(AValue: TColor);
begin
  if FPlotColor = AValue then Exit;
  FPlotColor := AValue; Invalidate;
end;

procedure TXelCustomChart.SetSeries(AValue: TXelChartSeriesList);
begin
  FSeries.Assign(AValue);
end;

procedure TXelCustomChart.SetAxisX(AValue: TXelChartAxis);
begin
  FAxisX.Assign(AValue);
end;

procedure TXelCustomChart.SetAxisY(AValue: TXelChartAxis);
begin
  FAxisY.Assign(AValue);
end;

procedure TXelCustomChart.SetLegend(AValue: TXelChartLegend);
begin
  FLegend.Assign(AValue);
end;

// ---------------------------------------------------------------------------
// Colour helpers
// ---------------------------------------------------------------------------

function TXelCustomChart.InkColor: TColor;
begin
  Result := XelInkColor(FTheme);
end;

function TXelCustomChart.Ink2Color: TColor;
begin
  Result := XelInk2Color(FTheme);
end;

function TXelCustomChart.SurfaceColor: TColor;
begin
  Result := XelSurfaceColor(FTheme);
end;

function TXelCustomChart.EffectivePlotColor: TColor;
begin
  if FPlotColor = clDefault then Result := SurfaceColor
                            else Result := FPlotColor;
end;

function TXelCustomChart.FillTint(AColor: TColor; AAmount: Byte): TColor;
begin
  Result := XelBlend(AColor, EffectivePlotColor, AAmount);
end;

// ---------------------------------------------------------------------------
// Scale mapping
// ---------------------------------------------------------------------------

function TXelCustomChart.ValueToX(AValue: Double; const ARect: TRect): Integer;
var
  Span: Double;
  T   : Double;
begin
  Span := FAxisX.CalcMax - FAxisX.CalcMin;
  if Span = 0 then Span := 1;
  T := (AValue - FAxisX.CalcMin) / Span;
  if FAxisX.Inverted then T := 1 - T;
  Result := ARect.Left + Round(T * (ARect.Right - ARect.Left));
end;

function TXelCustomChart.ValueToY(AValue: Double; const ARect: TRect): Integer;
var
  Span: Double;
  T   : Double;
begin
  Span := FAxisY.CalcMax - FAxisY.CalcMin;
  if Span = 0 then Span := 1;
  T := (AValue - FAxisY.CalcMin) / Span;
  if FAxisY.Inverted then T := 1 - T;
  Result := ARect.Bottom - Round(T * (ARect.Bottom - ARect.Top));
end;

// ---------------------------------------------------------------------------
// Overridable defaults
// ---------------------------------------------------------------------------

function TXelCustomChart.UsesAxes: Boolean;
begin
  Result := True;
end;

procedure TXelCustomChart.DrawOverlay(ACanvas: TCanvas; const ARect: TRect);
begin
  // nothing by default
end;

function TXelCustomChart.FormatXTick(AValue: Double): String;
begin
  Result := FAxisX.FormatValue(AValue);
end;

procedure TXelCustomChart.AfterAxisRecalc;
begin
  // nothing by default
end;

procedure TXelCustomChart.GetDataRange(out AMinX, AMaxX, AMinY, AMaxY: Double);
var
  I     : Integer;
  S     : TXelChartSeries;
  First : Boolean;
begin
  AMinX := 0; AMaxX := 1; AMinY := 0; AMaxY := 1;
  First := True;
  for I := 0 to FSeries.Count - 1 do
  begin
    S := FSeries[I];
    if (not S.Visible) or (S.Count = 0) then Continue;
    if First then
    begin
      AMinX := S.MinX; AMaxX := S.MaxX;
      AMinY := S.MinY; AMaxY := S.MaxY;
      First := False;
    end
    else
    begin
      AMinX := Math.Min(AMinX, S.MinX);
      AMaxX := Math.Max(AMaxX, S.MaxX);
      AMinY := Math.Min(AMinY, S.MinY);
      AMaxY := Math.Max(AMaxY, S.MaxY);
    end;
  end;
end;

procedure TXelCustomChart.GetLegendItems(AItems: TStrings; AColors: TList);
var
  I: Integer;
  S: TXelChartSeries;
begin
  for I := 0 to FSeries.Count - 1 do
  begin
    S := FSeries[I];
    if (not S.Visible) or (S.Count = 0) then Continue;
    AItems.Add(S.DisplayName);
    AColors.Add(TObject(PtrInt(S.EffectiveColor)));
  end;
end;

// ---------------------------------------------------------------------------
// Value labels
// ---------------------------------------------------------------------------

procedure TXelCustomChart.DrawValueLabel(ACanvas: TCanvas; X, Y: Integer;
  const AText: String; ABelow: Boolean);
var
  W, H: Integer;
begin
  if AText = '' then Exit;
  W := ACanvas.TextWidth(AText);
  H := ACanvas.TextHeight(AText);
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Color  := InkColor;
  if ABelow then ACanvas.TextOut(X - W div 2, Y + 3, AText)
            else ACanvas.TextOut(X - W div 2, Y - H - 3, AText);
  ACanvas.Brush.Style := bsSolid;
end;

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

procedure TXelCustomChart.Paint;
begin
  PaintTo(Canvas, ClientRect);
end;

procedure TXelCustomChart.PaintTo(ACanvas: TCanvas; const ARect: TRect);
var
  R           : TRect;
  Plot        : TRect;
  MinX, MaxX  : Double;
  MinY, MaxY  : Double;
  TitleH      : Integer;
  FooterH     : Integer;
  LegendItems : TStringList;
  LegendCols  : TList;
  LegendW     : Integer;
  LegendH     : Integer;
  I           : Integer;
  W           : Integer;
  V           : Double;
  S           : String;
  Px, Py      : Integer;
  MaxLabelW   : Integer;
  LastRight   : Integer;
  LineH       : Integer;
  Big         : TBitmap;
  BigRect     : TRect;
  LX, LY      : Integer;

  procedure DrawLegendBlock(AX, AY, AW, AH: Integer; AVertical: Boolean);
  var
    K, CX, CY, TW: Integer;
  begin
    if FLegend.Frame then
    begin
      ACanvas.Pen.Color   := XelBaselineColor(FTheme);
      ACanvas.Brush.Style := bsClear;
      ACanvas.Rectangle(AX, AY, AX + AW, AY + AH);
      ACanvas.Brush.Style := bsSolid;
    end;

    CX := AX + 2;
    CY := AY + 2;
    for K := 0 to LegendItems.Count - 1 do
    begin
      ACanvas.Brush.Color := TColor(PtrInt(LegendCols[K]));
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Pen.Style   := psClear;
      ACanvas.Rectangle(CX, CY + (LineH - SWATCH) div 2,
                        CX + SWATCH, CY + (LineH - SWATCH) div 2 + SWATCH);
      ACanvas.Pen.Style := psSolid;

      ACanvas.Brush.Style := bsClear;
      ACanvas.Font.Color  := Ink2Color;
      ACanvas.TextOut(CX + SWATCH + 5, CY, LegendItems[K]);
      ACanvas.Brush.Style := bsSolid;

      TW := SWATCH + 5 + ACanvas.TextWidth(LegendItems[K]) + FLegend.Spacing;
      if AVertical then Inc(CY, LineH)
                   else Inc(CX, TW);
    end;
  end;

begin
  R := ARect;

  // --- surface ---
  ACanvas.Brush.Color := EffectivePlotColor;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Pen.Style   := psClear;
  ACanvas.FillRect(R);
  ACanvas.Pen.Style   := psSolid;

  ACanvas.Font.Assign(Font);
  LineH := ACanvas.TextHeight('Wg') + 2;

  InflateRect(R, -FPadding, -FPadding);
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;

  // --- title and footer ---
  TitleH  := 0;
  FooterH := 0;

  if FTitle <> '' then
  begin
    ACanvas.Font.Style  := ACanvas.Font.Style + [fsBold];
    ACanvas.Font.Color  := InkColor;
    ACanvas.Brush.Style := bsClear;
    ACanvas.TextOut(R.Left, R.Top, FTitle);
    TitleH := ACanvas.TextHeight(FTitle) + 8;
    ACanvas.Font.Style := ACanvas.Font.Style - [fsBold];
    ACanvas.Brush.Style := bsSolid;
  end;

  if FFooter <> '' then
  begin
    ACanvas.Font.Color  := XelMutedColor;
    ACanvas.Brush.Style := bsClear;
    FooterH := ACanvas.TextHeight(FFooter) + 6;
    ACanvas.TextOut(R.Left, R.Bottom - FooterH + 6, FFooter);
    ACanvas.Brush.Style := bsSolid;
  end;

  Inc(R.Top, TitleH);
  Dec(R.Bottom, FooterH);

  // --- legend ---
  LegendItems := TStringList.Create;
  LegendCols  := TList.Create;
  try
    GetLegendItems(LegendItems, LegendCols);

    // one series needs no legend box — the title already names it
    if FLegend.Visible and (LegendItems.Count >= 2) then
    begin
      case FLegend.Position of
        lpRight, lpLeft:
          begin
            LegendW := 0;
            for I := 0 to LegendItems.Count - 1 do
            begin
              W := SWATCH + 5 + ACanvas.TextWidth(LegendItems[I]);
              if W > LegendW then LegendW := W;
            end;
            Inc(LegendW, FLegend.Spacing + 4);
            LegendH := LegendItems.Count * LineH + 4;

            if FLegend.Position = lpRight then
            begin
              LX := R.Right - LegendW;
              Dec(R.Right, LegendW);
            end
            else
            begin
              LX := R.Left;
              Inc(R.Left, LegendW);
            end;
            LY := R.Top;
            DrawLegendBlock(LX, LY, LegendW - 4, LegendH, True);
          end;

        lpTop, lpBottom:
          begin
            LegendW := 0;
            for I := 0 to LegendItems.Count - 1 do
              Inc(LegendW, SWATCH + 5 + ACanvas.TextWidth(LegendItems[I]) +
                           FLegend.Spacing);
            LegendH := LineH + 4;
            LX := R.Left;
            if FLegend.Position = lpTop then
            begin
              LY := R.Top;
              Inc(R.Top, LegendH + FLegend.Spacing);
            end
            else
            begin
              LY := R.Bottom - LegendH;
              Dec(R.Bottom, LegendH + FLegend.Spacing);
            end;
            DrawLegendBlock(LX, LY, LegendW, LegendH, False);
          end;
      end;
    end;

    if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;

    // --- axes ---
    Plot := R;

    if UsesAxes then
    begin
      GetDataRange(MinX, MaxX, MinY, MaxY);
      FAxisX.Recalc(MinX, MaxX);
      FAxisY.Recalc(MinY, MaxY);
      AfterAxisRecalc;

      // room for the Y labels
      MaxLabelW := 0;
      if FAxisY.Visible and FAxisY.ShowLabels then
      begin
        V := FAxisY.CalcMin;
        while V <= FAxisY.CalcMax + FAxisY.CalcStep * 0.001 do
        begin
          W := ACanvas.TextWidth(FAxisY.FormatValue(V));
          if W > MaxLabelW then MaxLabelW := W;
          V := V + FAxisY.CalcStep;
        end;
        Inc(MaxLabelW, TICK_LEN + 6);
      end;
      Inc(Plot.Left, MaxLabelW);
      if FAxisY.Title <> '' then Inc(Plot.Left, LineH);

      if FAxisX.Visible and FAxisX.ShowLabels then
        Dec(Plot.Bottom, LineH + TICK_LEN + 2);
      if FAxisX.Title <> '' then Dec(Plot.Bottom, LineH);

      // half a line of headroom so the top label is not clipped
      Inc(Plot.Top, LineH div 2);
      Dec(Plot.Right, 4);
    end;

    if (Plot.Right <= Plot.Left) or (Plot.Bottom <= Plot.Top) then Exit;
    FPlotRect := Plot;

    // --- grid, drawn under the marks ---
    if UsesAxes then
    begin
      ACanvas.Pen.Style := psSolid;
      ACanvas.Pen.Width := 1;

      if FAxisY.Visible and FAxisY.ShowGrid then
      begin
        ACanvas.Pen.Color := XelGridColor(FTheme);
        V := FAxisY.CalcMin;
        while V <= FAxisY.CalcMax + FAxisY.CalcStep * 0.001 do
        begin
          Py := ValueToY(V, Plot);
          ACanvas.Line(Plot.Left, Py, Plot.Right, Py);
          V := V + FAxisY.CalcStep;
        end;
      end;

      if FAxisX.Visible and FAxisX.ShowGrid then
      begin
        ACanvas.Pen.Color := XelGridColor(FTheme);
        V := FAxisX.CalcMin;
        while V <= FAxisX.CalcMax + FAxisX.CalcStep * 0.001 do
        begin
          Px := ValueToX(V, Plot);
          ACanvas.Line(Px, Plot.Top, Px, Plot.Bottom);
          V := V + FAxisX.CalcStep;
        end;
      end;
    end;

    // --- the marks ---
    if FAntialiased and (Plot.Right - Plot.Left < 1200) and
       (Plot.Bottom - Plot.Top < 1200) then
    begin
      Big := TBitmap.Create;
      try
        Big.PixelFormat := pf32bit;
        Big.SetSize((Plot.Right - Plot.Left) * AA_SCALE,
                    (Plot.Bottom - Plot.Top) * AA_SCALE);
        Big.Canvas.Brush.Color := EffectivePlotColor;
        Big.Canvas.FillRect(0, 0, Big.Width, Big.Height);
        Big.Canvas.Font.Assign(Font);

        BigRect := Rect(0, 0, Big.Width - 1, Big.Height - 1);

        // redraw the grid inside the buffer, otherwise the fill above hides it
        if UsesAxes then
        begin
          Big.Canvas.Pen.Width := AA_SCALE;
          Big.Canvas.Pen.Color := XelGridColor(FTheme);
          if FAxisY.Visible and FAxisY.ShowGrid then
          begin
            V := FAxisY.CalcMin;
            while V <= FAxisY.CalcMax + FAxisY.CalcStep * 0.001 do
            begin
              Py := ValueToY(V, Plot) - Plot.Top;
              Big.Canvas.Line(0, Py * AA_SCALE, Big.Width, Py * AA_SCALE);
              V := V + FAxisY.CalcStep;
            end;
          end;
          if FAxisX.Visible and FAxisX.ShowGrid then
          begin
            V := FAxisX.CalcMin;
            while V <= FAxisX.CalcMax + FAxisX.CalcStep * 0.001 do
            begin
              Px := ValueToX(V, Plot) - Plot.Left;
              Big.Canvas.Line(Px * AA_SCALE, 0, Px * AA_SCALE, Big.Height);
              V := V + FAxisX.CalcStep;
            end;
          end;
        end;

        DrawPlot(Big.Canvas, BigRect, AA_SCALE);
        XelChartDownsample(Big, ACanvas, Plot, AA_SCALE);
      finally
        Big.Free;
      end;
    end
    else
      DrawPlot(ACanvas, Plot, 1);

    // --- crisp overlay: direct labels and callouts ---
    ACanvas.Font.Assign(Font);
    DrawOverlay(ACanvas, Plot);

    // --- axis lines, ticks and labels, always at 1x ---
    if UsesAxes then
    begin
      ACanvas.Font.Assign(Font);
      ACanvas.Pen.Width := 1;
      ACanvas.Pen.Color := XelBaselineColor(FTheme);

      if FAxisY.Visible then
        ACanvas.Line(Plot.Left, Plot.Top, Plot.Left, Plot.Bottom);
      if FAxisX.Visible then
        ACanvas.Line(Plot.Left, Plot.Bottom, Plot.Right, Plot.Bottom);

      ACanvas.Brush.Style := bsClear;
      ACanvas.Font.Color  := XelMutedColor;

      if FAxisY.Visible and FAxisY.ShowLabels then
      begin
        V := FAxisY.CalcMin;
        while V <= FAxisY.CalcMax + FAxisY.CalcStep * 0.001 do
        begin
          Py := ValueToY(V, Plot);
          ACanvas.Pen.Color := XelBaselineColor(FTheme);
          ACanvas.Line(Plot.Left - TICK_LEN, Py, Plot.Left, Py);
          S := FAxisY.FormatValue(V);
          ACanvas.TextOut(Plot.Left - TICK_LEN - 4 - ACanvas.TextWidth(S),
                          Py - LineH div 2, S);
          V := V + FAxisY.CalcStep;
        end;
      end;

      if FAxisX.Visible and FAxisX.ShowLabels then
      begin
        LastRight := Low(Integer);
        V := FAxisX.CalcMin;
        while V <= FAxisX.CalcMax + FAxisX.CalcStep * 0.001 do
        begin
          Px := ValueToX(V, Plot);
          S  := FormatXTick(V);
          if S <> '' then
          begin
            ACanvas.Pen.Color := XelBaselineColor(FTheme);
            ACanvas.Line(Px, Plot.Bottom, Px, Plot.Bottom + TICK_LEN);
            W := ACanvas.TextWidth(S);
            // drop a label rather than let it collide with its neighbour
            if Px - W div 2 > LastRight then
            begin
              ACanvas.TextOut(Px - W div 2, Plot.Bottom + TICK_LEN + 2, S);
              LastRight := Px + W div 2 + 6;
            end;
          end;
          V := V + FAxisX.CalcStep;
        end;
      end;

      ACanvas.Font.Color := Ink2Color;
      if FAxisX.Title <> '' then
        ACanvas.TextOut(
          (Plot.Left + Plot.Right - ACanvas.TextWidth(FAxisX.Title)) div 2,
          R.Bottom - LineH, FAxisX.Title);
      if FAxisY.Title <> '' then
        ACanvas.TextOut(R.Left, R.Top, FAxisY.Title);

      ACanvas.Brush.Style := bsSolid;
    end;
  finally
    LegendCols.Free;
    LegendItems.Free;
  end;
end;

procedure TXelCustomChart.Click;
begin
  inherited Click;
  if Assigned(FOnPlotClick) then FOnPlotClick(Self);
end;

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

procedure TXelCustomChart.SaveToBitmap(ABitmap: TBitmap);
begin
  ABitmap.PixelFormat := pf24bit;
  ABitmap.SetSize(Width, Height);
  PaintTo(ABitmap.Canvas, Rect(0, 0, Width, Height));
end;

procedure TXelCustomChart.SaveToFile(const AFileName: String);
var
  Bmp: TBitmap;
  Png: TPortableNetworkGraphic;
begin
  Bmp := TBitmap.Create;
  try
    SaveToBitmap(Bmp);
    if SameText(ExtractFileExt(AFileName), '.png') then
    begin
      Png := TPortableNetworkGraphic.Create;
      try
        Png.Assign(Bmp);
        Png.SaveToFile(AFileName);
      finally
        Png.Free;
      end;
    end
    else
      Bmp.SaveToFile(AFileName);
  finally
    Bmp.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Convenience
// ---------------------------------------------------------------------------

function TXelCustomChart.AddSeries(const ATitle: String;
  const AValues: array of Double): TXelChartSeries;
begin
  Result := FSeries.Add;
  Result.Title := ATitle;
  Result.SetData(AValues);
end;

procedure TXelCustomChart.ClearSeries;
begin
  FSeries.Clear;
  Invalidate;
end;

end.
