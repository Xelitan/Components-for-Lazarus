unit XelRatingStars;

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, Math;

type
  TXelRatingStars = class(TCustomControl)
  private
    FMaxStars: Integer;
    FValue: Integer;
    FReadOnly: Boolean;
    FStarColor: TColor;
    FEmptyColor: TColor;
    FStarSize: Integer;
    FHoverValue: Integer;
    FHovering: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetMaxStars(AValue: Integer);
    procedure SetValue(AValue: Integer);
    procedure SetStarSize(AValue: Integer);
    function XToStarIndex(AX: Integer): Integer;
    procedure DrawStar(CX, CY, R: Integer; Filled: Boolean);
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property MaxStars: Integer read FMaxStars write SetMaxStars default 5;
    property Value: Integer read FValue write SetValue default 0;
    property ReadOnly: Boolean read FReadOnly write FReadOnly default False;
    property StarColor: TColor read FStarColor write FStarColor default $0000AAFF;
    property EmptyColor: TColor read FEmptyColor write FEmptyColor default clSilver;
    property StarSize: Integer read FStarSize write SetStarSize default 24;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Enabled;
    property Visible;
    property Hint;
    property ShowHint;
  end;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelRatingStars]);
end;

constructor TXelRatingStars.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMaxStars   := 5;
  FValue      := 0;
  FStarSize   := 24;
  FStarColor  := $0000AAFF;
  FEmptyColor := clSilver;
  FHovering   := False;
  Width  := 5 * 30;
  Height := 30;
  ControlStyle := ControlStyle + [csClickEvents];
end;

procedure TXelRatingStars.SetMaxStars(AValue: Integer);
begin
  FMaxStars := Max(1, AValue);
  Width := FMaxStars * (FStarSize + 6);
  Invalidate;
end;

procedure TXelRatingStars.SetValue(AValue: Integer);
begin
  AValue := Max(0, Min(FMaxStars, AValue));
  if FValue = AValue then Exit;
  FValue := AValue;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TXelRatingStars.SetStarSize(AValue: Integer);
begin
  FStarSize := Max(8, AValue);
  Height := FStarSize + 6;
  Width  := FMaxStars * (FStarSize + 6);
  Invalidate;
end;

function TXelRatingStars.XToStarIndex(AX: Integer): Integer;
var
  StarW: Integer;
begin
  StarW := Width div FMaxStars;
  Result := (AX div StarW) + 1;
  Result := Max(0, Min(FMaxStars, Result));
end;

procedure TXelRatingStars.DrawStar(CX, CY, R: Integer; Filled: Boolean);
const
  Points = 5;
var
  Pts: array[0..9] of TPoint;
  i: Integer;
  Angle, InnerR: Double;
begin
  InnerR := R * 0.42;
  for i := 0 to Points - 1 do
  begin
    Angle := -Pi / 2 + i * (2 * Pi / Points);
    Pts[i * 2].X := CX + Round(R * Cos(Angle));
    Pts[i * 2].Y := CY + Round(R * Sin(Angle));
    Angle := Angle + Pi / Points;
    Pts[i * 2 + 1].X := CX + Round(InnerR * Cos(Angle));
    Pts[i * 2 + 1].Y := CY + Round(InnerR * Sin(Angle));
  end;
  if Filled then
  begin
    Canvas.Brush.Color := FStarColor;
    Canvas.Pen.Color   := FStarColor;
  end
  else
  begin
    Canvas.Brush.Color := FEmptyColor;
    Canvas.Pen.Color   := FEmptyColor;
  end;
  Canvas.Polygon(Pts);
end;

procedure TXelRatingStars.Paint;
var
  i, StarW, CX, CY, R, DisplayValue: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);

  StarW := Width div FMaxStars;
  CY    := Height div 2;
  R     := FStarSize div 2;

  if FHovering and not FReadOnly then
    DisplayValue := FHoverValue
  else
    DisplayValue := FValue;

  for i := 1 to FMaxStars do
  begin
    CX := (i - 1) * StarW + StarW div 2;
    DrawStar(CX, CY, R, i <= DisplayValue);
  end;
end;

procedure TXelRatingStars.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if not FReadOnly then
  begin
    FHovering   := True;
    FHoverValue := XToStarIndex(X);
    Invalidate;
  end;
end;

procedure TXelRatingStars.MouseLeave;
begin
  inherited MouseLeave;
  FHovering := False;
  Invalidate;
end;

procedure TXelRatingStars.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and not FReadOnly and Enabled then
    SetValue(XToStarIndex(X));
end;

end.
