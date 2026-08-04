unit XelSparkline;

//Author: xelitan.com
//License: MIT
//
//TXelSparkline - a chart stripped down to its shape.
//
//No axes, no grid, no legend, no title: everything that exists to let you read
//a number is gone, because at 16-24 px high there is no room for it and no
//point.  What is left has to survive that height, so the drawing is deliberately
//pixel-aligned and there is no supersampling.
//
//Push() plus Capacity make it a sliding window, which is how a sparkline is
//normally used: the last N samples of something that is still being measured.

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math, Types,
  XelChartTypes;

type
  // skLine     - polyline through the samples
  // skArea     - the same line with the space to the baseline filled
  // skBars     - one thin bar per sample, from the baseline
  // skWinLoss  - equal-height bars up or down; magnitude is ignored.  For
  //              binary series (test passed/failed, day up/down) where the
  //              value carries no information beyond its sign.
  TXelSparkKind = (skLine, skArea, skBars, skWinLoss);

  // snData      - scale to this sparkline's own range.  Best shape, but two
  //               sparklines side by side are then not comparable.
  // snZeroBased - scale from zero to the maximum.
  // snFixed     - scale to Min..Max.  Use this in a list of tiles, where the
  //               reader will compare one row against the next.
  TXelSparkNormalize = (snData, snZeroBased, snFixed);

  TXelSparkHoverEvent = procedure(Sender: TObject; AIndex: Integer;
    AValue: Double) of object;

  // TXelSparkline
  TXelSparkline = class(TGraphicControl)
  private
    FValues      : array of Double;
    FCount       : Integer;
    FCapacity    : Integer;

    FKind        : TXelSparkKind;
    FTheme       : TXelChartTheme;
    FLineColor   : TColor;
    FFillColor   : TColor;
    FLastColor   : TColor;
    FMinMaxColor : TColor;
    FBandColor   : TColor;
    FBaseColor   : TColor;
    FNegColor    : TColor;
    FLineWidth   : Integer;

    FShowLast    : Boolean;
    FShowMinMax  : Boolean;
    FShowBaseline: Boolean;
    FShowBand    : Boolean;
    FBaseline    : Double;
    FBandLow     : Double;
    FBandHigh    : Double;

    FNormalize   : TXelSparkNormalize;
    FMin, FMax   : Double;
    FBarGap      : Integer;

    FHoverIndex  : Integer;
    FShowHover   : Boolean;
    FOnHover     : TXelSparkHoverEvent;

    // design-time entry point; the runtime one is SetData / Push
    FValueText   : TStrings;
    procedure ValueTextChanged(Sender: TObject);
    procedure SetValueText(AValue: TStrings);

    procedure SetKind(AValue: TXelSparkKind);
    procedure SetTheme(AValue: TXelChartTheme);
    procedure SetLineColor(AValue: TColor);
    procedure SetFillColor(AValue: TColor);
    procedure SetLineWidth(AValue: Integer);
    procedure SetShowLast(AValue: Boolean);
    procedure SetShowMinMax(AValue: Boolean);
    procedure SetShowBaseline(AValue: Boolean);
    procedure SetShowBand(AValue: Boolean);
    procedure SetBaseline(AValue: Double);
    procedure SetBandLow(AValue: Double);
    procedure SetBandHigh(AValue: Double);
    procedure SetNormalize(AValue: TXelSparkNormalize);
    procedure SetMin(AValue: Double);
    procedure SetMax(AValue: Double);
    procedure SetBarGap(AValue: Integer);
    procedure SetNegColor(AValue: TColor);
    procedure SetCapacity(AValue: Integer);
    procedure SetShowHover(AValue: Boolean);

    function  GetValue(Index: Integer): Double;
    procedure SetValue(Index: Integer; AValue: Double);
    function  EffLineColor: TColor;
    function  EffFillColor: TColor;
    function  EffNegColor: TColor;
    function  PlotRect: TRect;
    procedure Range(out ALo, AHi: Double);
    function  ValueToY(AValue, ALo, AHi: Double; const R: TRect): Integer;
    function  IndexToX(AIndex: Integer; const R: TRect): Integer;
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    class function GetControlClassDefaultSize: TSize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    procedure SetData(const AValues: array of Double);
    // Append one sample.  With Capacity > 0 the oldest sample drops off, which
    // is what makes this usable for live data.
    procedure Push(AValue: Double);
    procedure Clear;

    // Sample index nearest to a control X coordinate, -1 when there is none.
    function IndexAt(X: Integer): Integer;

    function MinValue: Double;
    function MaxValue: Double;
    function LastValue: Double;
    function Average: Double;

    property Count: Integer read FCount;
    property Values[Index: Integer]: Double read GetValue write SetValue;
    property HoverIndex: Integer read FHoverIndex;
  published
    property Kind: TXelSparkKind read FKind write SetKind default skLine;

    // Design-time data: one number per line.  Ignored once SetData or Push has
    // been called at run time.
    property ValueText: TStrings read FValueText write SetValueText;

    // Number of samples kept by Push; 0 = unlimited.
    property Capacity: Integer read FCapacity write SetCapacity default 0;

    property Theme: TXelChartTheme read FTheme write SetTheme default ctLight;
    // clDefault takes the theme's first palette slot.
    property LineColor: TColor read FLineColor write SetLineColor default clDefault;
    // clDefault derives a tint of LineColor against the control colour.
    property FillColor: TColor read FFillColor write SetFillColor default clDefault;
    property LineWidth: Integer read FLineWidth write SetLineWidth default 1;

    // --- the reference marks: this is what a sparkline is actually for ---

    // Dot on the newest sample.  On by default — "where are we now" is the
    // one question a sparkline is always asked.
    property ShowLast: Boolean read FShowLast write SetShowLast default True;
    property LastColor: TColor read FLastColor write FLastColor default clDefault;
    // Dots on the minimum and the maximum.
    property ShowMinMax: Boolean read FShowMinMax write SetShowMinMax
      default False;
    property MinMaxColor: TColor read FMinMaxColor write FMinMaxColor
      default clGrayText;

    // Horizontal reference line — a target, a mean, a threshold.
    property ShowBaseline: Boolean read FShowBaseline write SetShowBaseline
      default False;
    property Baseline: Double read FBaseline write SetBaseline;
    property BaselineColor: TColor read FBaseColor write FBaseColor
      default clGrayText;

    // Shaded band behind the line — the "normal" range.
    property ShowBand: Boolean read FShowBand write SetShowBand default False;
    property BandLow: Double read FBandLow write SetBandLow;
    property BandHigh: Double read FBandHigh write SetBandHigh;
    property BandColor: TColor read FBandColor write FBandColor default clDefault;

    property NormalizeMode: TXelSparkNormalize read FNormalize
      write SetNormalize default snData;
    property Min: Double read FMin write SetMin;
    property Max: Double read FMax write SetMax;

    // Gap between bars in skBars / skWinLoss, in pixels.
    property BarGap: Integer read FBarGap write SetBarGap default 1;

    // Colour for values below the baseline (skBars) and for down bars
    // (skWinLoss).  clDefault takes the palette's red pole - polarity is the
    // diverging case, and blue/red is the pair the palette validates for it.
    property NegativeColor: TColor read FNegColor write SetNegColor
      default clDefault;

    // Draw a vertical marker under the mouse and fire OnHover.
    property ShowHover: Boolean read FShowHover write SetShowHover default False;
    property OnHover: TXelSparkHoverEvent read FOnHover write FOnHover;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Constraints;
    property Enabled;
    property ParentColor default True;
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

procedure Register;

implementation

{$R txelsparkline_images.res}

constructor TXelSparkline.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FValueText := TStringList.Create;
  TStringList(FValueText).OnChange := ValueTextChanged;

  FKind        := skLine;
  FTheme       := ctLight;
  FLineColor   := clDefault;
  FFillColor   := clDefault;
  FLastColor   := clDefault;
  FMinMaxColor := clGrayText;
  FBandColor   := clDefault;
  FBaseColor   := clGrayText;
  FNegColor    := clDefault;
  FLineWidth   := 1;
  FShowLast    := True;
  FNormalize   := snData;
  FMin         := 0;
  FMax         := 100;
  FBarGap      := 1;
  FHoverIndex  := -1;
  ParentColor  := True;

  with GetControlClassDefaultSize do SetInitialBounds(0, 0, cx, cy);
end;

destructor TXelSparkline.Destroy;
begin
  FValueText.Free;
  inherited Destroy;
end;

class function TXelSparkline.GetControlClassDefaultSize: TSize;
begin
  Result.cx := 120;
  Result.cy := 24;
end;

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

procedure TXelSparkline.ValueTextChanged(Sender: TObject);
var
  I  : Integer;
  D  : Double;
  FS : TFormatSettings;
begin
  // design-time text -> samples; both '.' and ',' accepted as the separator
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FCount := 0;
  SetLength(FValues, FValueText.Count);
  for I := 0 to FValueText.Count - 1 do
    if TryStrToFloat(StringReplace(Trim(FValueText[I]), ',', '.',
         [rfReplaceAll]), D, FS) then
    begin
      FValues[FCount] := D;
      Inc(FCount);
    end;
  Invalidate;
end;

procedure TXelSparkline.SetValueText(AValue: TStrings);
begin
  FValueText.Assign(AValue);
end;

procedure TXelSparkline.SetData(const AValues: array of Double);
var
  I: Integer;
begin
  SetLength(FValues, Length(AValues));
  for I := 0 to High(AValues) do FValues[I] := AValues[I];
  FCount := Length(AValues);
  if (FCapacity > 0) and (FCount > FCapacity) then
  begin
    for I := 0 to FCapacity - 1 do
      FValues[I] := FValues[FCount - FCapacity + I];
    FCount := FCapacity;
    SetLength(FValues, FCount);
  end;
  FHoverIndex := -1;
  Invalidate;
end;

procedure TXelSparkline.Push(AValue: Double);
var
  I: Integer;
begin
  if (FCapacity > 0) and (FCount >= FCapacity) then
  begin
    // slide the window; a ring buffer would save the moves but at sparkline
    // sizes (tens to a few hundred samples) this is not worth the complexity
    for I := 0 to FCapacity - 2 do FValues[I] := FValues[I + 1];
    FCount := FCapacity - 1;
  end;

  if FCount >= Length(FValues) then
    SetLength(FValues, Length(FValues) * 2 + 16);
  FValues[FCount] := AValue;
  Inc(FCount);
  Invalidate;
end;

procedure TXelSparkline.Clear;
begin
  FCount := 0;
  SetLength(FValues, 0);
  FHoverIndex := -1;
  Invalidate;
end;

function TXelSparkline.GetValue(Index: Integer): Double;
begin
  if (Index < 0) or (Index >= FCount) then Exit(0);
  Result := FValues[Index];
end;

procedure TXelSparkline.SetValue(Index: Integer; AValue: Double);
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  FValues[Index] := AValue;
  Invalidate;
end;

function TXelSparkline.MinValue: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FValues[0];
  for I := 1 to FCount - 1 do
    if FValues[I] < Result then Result := FValues[I];
end;

function TXelSparkline.MaxValue: Double;
var I: Integer;
begin
  if FCount = 0 then Exit(0);
  Result := FValues[0];
  for I := 1 to FCount - 1 do
    if FValues[I] > Result then Result := FValues[I];
end;

function TXelSparkline.LastValue: Double;
begin
  if FCount = 0 then Result := 0 else Result := FValues[FCount - 1];
end;

function TXelSparkline.Average: Double;
var I: Integer;
begin
  Result := 0;
  if FCount = 0 then Exit;
  for I := 0 to FCount - 1 do Result := Result + FValues[I];
  Result := Result / FCount;
end;

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

procedure TXelSparkline.SetCapacity(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if FCapacity = AValue then Exit;
  FCapacity := AValue;
  if (FCapacity > 0) and (FCount > FCapacity) then
    SetData(Copy(FValues, FCount - FCapacity, FCapacity));
end;

procedure TXelSparkline.SetKind(AValue: TXelSparkKind);
begin
  if FKind = AValue then Exit;
  FKind := AValue; Invalidate;
end;

procedure TXelSparkline.SetTheme(AValue: TXelChartTheme);
begin
  if FTheme = AValue then Exit;
  FTheme := AValue; Invalidate;
end;

procedure TXelSparkline.SetLineColor(AValue: TColor);
begin
  if FLineColor = AValue then Exit;
  FLineColor := AValue; Invalidate;
end;

procedure TXelSparkline.SetFillColor(AValue: TColor);
begin
  if FFillColor = AValue then Exit;
  FFillColor := AValue; Invalidate;
end;

procedure TXelSparkline.SetLineWidth(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if AValue > 8 then AValue := 8;
  if FLineWidth = AValue then Exit;
  FLineWidth := AValue; Invalidate;
end;

procedure TXelSparkline.SetShowLast(AValue: Boolean);
begin
  if FShowLast = AValue then Exit;
  FShowLast := AValue; Invalidate;
end;

procedure TXelSparkline.SetShowMinMax(AValue: Boolean);
begin
  if FShowMinMax = AValue then Exit;
  FShowMinMax := AValue; Invalidate;
end;

procedure TXelSparkline.SetShowBaseline(AValue: Boolean);
begin
  if FShowBaseline = AValue then Exit;
  FShowBaseline := AValue; Invalidate;
end;

procedure TXelSparkline.SetShowBand(AValue: Boolean);
begin
  if FShowBand = AValue then Exit;
  FShowBand := AValue; Invalidate;
end;

procedure TXelSparkline.SetBaseline(AValue: Double);
begin
  if FBaseline = AValue then Exit;
  FBaseline := AValue; Invalidate;
end;

procedure TXelSparkline.SetBandLow(AValue: Double);
begin
  if FBandLow = AValue then Exit;
  FBandLow := AValue; Invalidate;
end;

procedure TXelSparkline.SetBandHigh(AValue: Double);
begin
  if FBandHigh = AValue then Exit;
  FBandHigh := AValue; Invalidate;
end;

procedure TXelSparkline.SetNormalize(AValue: TXelSparkNormalize);
begin
  if FNormalize = AValue then Exit;
  FNormalize := AValue; Invalidate;
end;

procedure TXelSparkline.SetMin(AValue: Double);
begin
  if FMin = AValue then Exit;
  FMin := AValue; Invalidate;
end;

procedure TXelSparkline.SetMax(AValue: Double);
begin
  if FMax = AValue then Exit;
  FMax := AValue; Invalidate;
end;

procedure TXelSparkline.SetBarGap(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 20 then AValue := 20;
  if FBarGap = AValue then Exit;
  FBarGap := AValue; Invalidate;
end;

procedure TXelSparkline.SetNegColor(AValue: TColor);
begin
  if FNegColor = AValue then Exit;
  FNegColor := AValue; Invalidate;
end;

procedure TXelSparkline.SetShowHover(AValue: Boolean);
begin
  if FShowHover = AValue then Exit;
  FShowHover := AValue;
  if not FShowHover then FHoverIndex := -1;
  Invalidate;
end;

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

function TXelSparkline.EffLineColor: TColor;
begin
  if FLineColor <> clDefault then Result := FLineColor
                             else Result := XelSeriesColor(0, FTheme);
end;

function TXelSparkline.EffFillColor: TColor;
begin
  if FFillColor <> clDefault then Result := FFillColor
                             else Result := XelBlend(EffLineColor, Color, 175);
end;

function TXelSparkline.EffNegColor: TColor;
begin
  if FNegColor <> clDefault then Result := FNegColor
                             else Result := XelSeriesColor(7, FTheme);   // red
end;

function TXelSparkline.PlotRect: TRect;
var
  Inset: Integer;
begin
  Result := ClientRect;
  // leave room for the marker dots so they are not clipped in half
  Inset := 1;
  if FShowLast or FShowMinMax then Inset := 3;
  InflateRect(Result, -Inset, -Inset);
  if Result.Right <= Result.Left then Result.Right := Result.Left + 1;
  if Result.Bottom <= Result.Top then Result.Bottom := Result.Top + 1;
end;

procedure TXelSparkline.Range(out ALo, AHi: Double);
var
  Mode: TXelSparkNormalize;
begin
  Mode := FNormalize;
  // A bar encodes magnitude by its length from the baseline, so a bar scaled
  // to the data range misrepresents the proportions - the smallest value comes
  // out as no bar at all.  snData silently becomes snZeroBased for bars; ask
  // for snFixed explicitly if you really want a cut baseline.
  if (FKind = skBars) and (Mode = snData) then Mode := snZeroBased;

  case Mode of
    snFixed:
      begin
        ALo := FMin;
        AHi := FMax;
      end;
    snZeroBased:
      begin
        ALo := Math.Min(0, MinValue);
        AHi := Math.Max(0, MaxValue);
      end;
  else
    ALo := MinValue;
    AHi := MaxValue;
  end;

  // a band or a baseline outside the range would be drawn off-screen
  if FShowBand then
  begin
    ALo := Math.Min(ALo, FBandLow);
    AHi := Math.Max(AHi, FBandHigh);
  end;
  if FShowBaseline then
  begin
    ALo := Math.Min(ALo, FBaseline);
    AHi := Math.Max(AHi, FBaseline);
  end;

  if AHi <= ALo then
  begin
    // flat series — centre it instead of dividing by zero
    ALo := ALo - 0.5;
    AHi := AHi + 0.5;
  end;
end;

function TXelSparkline.ValueToY(AValue, ALo, AHi: Double;
  const R: TRect): Integer;
begin
  Result := R.Bottom - Round((AValue - ALo) / (AHi - ALo) *
                             (R.Bottom - R.Top));
  if Result < R.Top then Result := R.Top;
  if Result > R.Bottom then Result := R.Bottom;
end;

function TXelSparkline.IndexToX(AIndex: Integer; const R: TRect): Integer;
begin
  if FCount <= 1 then Exit(R.Left);
  Result := R.Left + Round(AIndex / (FCount - 1) * (R.Right - R.Left));
end;

function TXelSparkline.IndexAt(X: Integer): Integer;
var
  R: TRect;
begin
  Result := -1;
  if FCount = 0 then Exit;
  R := PlotRect;
  if FCount = 1 then Exit(0);
  Result := Round((X - R.Left) / (R.Right - R.Left) * (FCount - 1));
  if Result < 0 then Result := 0;
  if Result > FCount - 1 then Result := FCount - 1;
end;

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

procedure TXelSparkline.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Idx: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not (FShowHover or Assigned(FOnHover)) then Exit;

  Idx := IndexAt(X);
  if Idx = FHoverIndex then Exit;
  FHoverIndex := Idx;
  if FShowHover then Invalidate;
  if Assigned(FOnHover) and (Idx >= 0) then FOnHover(Self, Idx, FValues[Idx]);
end;

procedure TXelSparkline.MouseLeave;
begin
  inherited MouseLeave;
  if FHoverIndex <> -1 then
  begin
    FHoverIndex := -1;
    if FShowHover then Invalidate;
  end;
end;

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

procedure TXelSparkline.Paint;
var
  R        : TRect;
  Lo, Hi   : Double;
  I        : Integer;
  Pts      : array of TPoint;
  Poly     : array of TPoint;
  ZeroY    : Integer;
  BarW     : Integer;
  X0, X1   : Integer;
  Y        : Integer;
  Col      : TColor;
  MinI     : Integer;
  MaxI     : Integer;
  Rad      : Integer;
  Half     : Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  if FCount = 0 then Exit;

  R := PlotRect;
  Range(Lo, Hi);
  Col := EffLineColor;

  // --- reference band, behind everything ---
  if FShowBand and (FBandHigh > FBandLow) then
  begin
    if FBandColor = clDefault then
      Canvas.Brush.Color := XelBlend(XelMutedColor, Color, 210)
    else
      Canvas.Brush.Color := FBandColor;
    Canvas.Brush.Style := bsSolid;
    Canvas.FillRect(R.Left, ValueToY(FBandHigh, Lo, Hi, R),
                    R.Right, ValueToY(FBandLow, Lo, Hi, R));
  end;

  // --- reference line ---
  if FShowBaseline then
  begin
    Y := ValueToY(FBaseline, Lo, Hi, R);
    Canvas.Pen.Color := FBaseColor;
    Canvas.Pen.Style := psDot;
    Canvas.Pen.Width := 1;
    Canvas.Line(R.Left, Y, R.Right, Y);
    Canvas.Pen.Style := psSolid;
  end;

  // --- the marks ---
  case FKind of
    skBars, skWinLoss:
      begin
        BarW := (R.Right - R.Left) div FCount - FBarGap;
        if BarW < 1 then BarW := 1;

        if FKind = skWinLoss then
        begin
          Half  := (R.Top + R.Bottom) div 2;
          ZeroY := Half;
        end
        else
        begin
          ZeroY := ValueToY(Math.Max(Lo, Math.Min(0, Hi)), Lo, Hi, R);
          if Lo > 0 then ZeroY := R.Bottom;
        end;

        Canvas.Pen.Style := psClear;
        for I := 0 to FCount - 1 do
        begin
          X0 := R.Left + (R.Right - R.Left) * I div FCount;
          X1 := X0 + BarW;

          if FKind = skWinLoss then
          begin
            if FValues[I] = 0 then Continue;
            Canvas.Brush.Color := Col;
            if FValues[I] > 0 then
              Canvas.FillRect(X0, Half - (R.Bottom - R.Top) div 4, X1, Half)
            else
            begin
              Canvas.Brush.Color := EffNegColor;
              Canvas.FillRect(X0, Half, X1, Half + (R.Bottom - R.Top) div 4);
            end;
          end
          else
          begin
            if FValues[I] < 0 then Canvas.Brush.Color := EffNegColor
                              else Canvas.Brush.Color := Col;
            Y := ValueToY(FValues[I], Lo, Hi, R);
            if Y <= ZeroY then Canvas.FillRect(X0, Y, X1, ZeroY + 1)
                          else Canvas.FillRect(X0, ZeroY, X1, Y + 1);
          end;
        end;
        Canvas.Pen.Style := psSolid;
      end;

  else
    // skLine and skArea
    SetLength(Pts, FCount);
    for I := 0 to FCount - 1 do
    begin
      Pts[I].X := IndexToX(I, R);
      Pts[I].Y := ValueToY(FValues[I], Lo, Hi, R);
    end;

    if (FKind = skArea) and (FCount >= 2) then
    begin
      SetLength(Poly, FCount + 2);
      for I := 0 to FCount - 1 do Poly[I] := Pts[I];
      Poly[FCount]     := Point(Pts[FCount - 1].X, R.Bottom);
      Poly[FCount + 1] := Point(Pts[0].X, R.Bottom);
      Canvas.Brush.Color := EffFillColor;
      Canvas.Brush.Style := bsSolid;
      Canvas.Pen.Style   := psClear;
      Canvas.Polygon(Poly);
      Canvas.Pen.Style   := psSolid;
    end;

    if FCount >= 2 then
    begin
      Canvas.Pen.Color := Col;
      Canvas.Pen.Width := FLineWidth;
      Canvas.Polyline(Pts);
      Canvas.Pen.Width := 1;
    end
    else
    begin
      // a single sample still deserves to be visible
      Canvas.Brush.Color := Col;
      Canvas.Pen.Style   := psClear;
      Canvas.FillRect(Pts[0].X - 1, Pts[0].Y - 1, Pts[0].X + 2, Pts[0].Y + 2);
      Canvas.Pen.Style   := psSolid;
    end;
  end;

  // --- hover marker ---
  if FShowHover and (FHoverIndex >= 0) then
  begin
    X0 := IndexToX(FHoverIndex, R);
    Canvas.Pen.Color := XelMutedColor;
    Canvas.Pen.Style := psSolid;
    Canvas.Line(X0, R.Top, X0, R.Bottom);
  end;

  // --- reference dots, on top of everything ---
  Rad := 2;
  if FShowMinMax then
  begin
    MinI := 0;
    MaxI := 0;
    for I := 1 to FCount - 1 do
    begin
      if FValues[I] < FValues[MinI] then MinI := I;
      if FValues[I] > FValues[MaxI] then MaxI := I;
    end;

    Canvas.Brush.Color := FMinMaxColor;
    Canvas.Pen.Color   := Color;
    Canvas.Pen.Width   := 1;
    X0 := IndexToX(MinI, R); Y := ValueToY(FValues[MinI], Lo, Hi, R);
    Canvas.Ellipse(X0 - Rad, Y - Rad, X0 + Rad + 1, Y + Rad + 1);
    X0 := IndexToX(MaxI, R); Y := ValueToY(FValues[MaxI], Lo, Hi, R);
    Canvas.Ellipse(X0 - Rad, Y - Rad, X0 + Rad + 1, Y + Rad + 1);
  end;

  if FShowLast then
  begin
    if FLastColor = clDefault then Canvas.Brush.Color := Col
                              else Canvas.Brush.Color := FLastColor;
    Canvas.Pen.Color := Color;
    Canvas.Pen.Width := 1;
    X0 := IndexToX(FCount - 1, R);
    if FKind in [skBars, skWinLoss] then
      X0 := R.Left + (R.Right - R.Left) * (FCount - 1) div FCount;
    Y := ValueToY(FValues[FCount - 1], Lo, Hi, R);
    Canvas.Ellipse(X0 - Rad, Y - Rad, X0 + Rad + 1, Y + Rad + 1);
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelSparkline]);
end;

end.
