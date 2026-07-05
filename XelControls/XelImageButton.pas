unit XelImageButton;

{$mode delphi}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, Forms;

type
  TXelButtonState = (bsNormal, bsHover, bsPressed);

  TXelImageButton = class(TCustomControl)
  private
    FImageNormal: TBitmap;
    FImageHover: TBitmap;
    FImagePressed: TBitmap;
    FState: TXelButtonState;
    FCaption: TCaption;
    FModalResult: Integer;
    procedure SetImageNormal(AValue: TBitmap);
    procedure SetImageHover(AValue: TBitmap);
    procedure SetImagePressed(AValue: TBitmap);
    procedure BitmapChanged(Sender: TObject);
    function CurrentImage: TBitmap;
  protected
    procedure Paint; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure Click; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property ImageNormal: TBitmap read FImageNormal write SetImageNormal;
    property ImageHover: TBitmap read FImageHover write SetImageHover;
    property ImagePressed: TBitmap read FImagePressed write SetImagePressed;
    property Caption: TCaption read FCaption write FCaption;
    property ModalResult: Integer read FModalResult write FModalResult default 0;
    property OnClick;
    property Enabled;
    property Visible;
    property Hint;
    property ShowHint;
    property Align;
    property Anchors;
    property Width default 80;
    property Height default 30;
  end;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelImageButton]);
end;

constructor TXelImageButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FState := bsNormal;
  Width  := 80;
  Height := 30;

  FImageNormal  := TBitmap.Create;
  FImageHover   := TBitmap.Create;
  FImagePressed := TBitmap.Create;
  FImageNormal.OnChange  := BitmapChanged;
  FImageHover.OnChange   := BitmapChanged;
  FImagePressed.OnChange := BitmapChanged;

  ControlStyle := ControlStyle + [csClickEvents];
end;

destructor TXelImageButton.Destroy;
begin
  FImageNormal.Free;
  FImageHover.Free;
  FImagePressed.Free;
  inherited Destroy;
end;

procedure TXelImageButton.SetImageNormal(AValue: TBitmap);
begin FImageNormal.Assign(AValue); end;

procedure TXelImageButton.SetImageHover(AValue: TBitmap);
begin FImageHover.Assign(AValue); end;

procedure TXelImageButton.SetImagePressed(AValue: TBitmap);
begin FImagePressed.Assign(AValue); end;

procedure TXelImageButton.BitmapChanged(Sender: TObject);
begin
  Invalidate;
end;

function TXelImageButton.CurrentImage: TBitmap;
begin
  case FState of
    bsHover:
      if not FImageHover.Empty then Result := FImageHover
      else Result := FImageNormal;
    bsPressed:
      if not FImagePressed.Empty then Result := FImagePressed
      else Result := FImageNormal;
  else
    Result := FImageNormal;
  end;
end;

procedure TXelImageButton.Paint;
var
  Img: TBitmap;
  R: TRect;
  TW, TH: Integer;
begin
  R := ClientRect;
  Img := CurrentImage;

  if not Img.Empty then
    Canvas.StretchDraw(R, Img)
  else
  begin
    // Fallback: draw a basic button-like look
    case FState of
      bsPressed: Canvas.Brush.Color := clBtnShadow;
      bsHover:   Canvas.Brush.Color := clHighlight;
    else
      Canvas.Brush.Color := clBtnFace;
    end;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(R);
  end;

  // Draw caption on top if set
  if FCaption <> '' then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Assign(Font);
    TW := Canvas.TextWidth(FCaption);
    TH := Canvas.TextHeight(FCaption);
    Canvas.TextOut(R.Left + (R.Right - R.Left - TW) div 2,
                   R.Top  + (R.Bottom - R.Top - TH) div 2,
                   FCaption);
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TXelImageButton.MouseEnter;
begin
  inherited MouseEnter;
  if Enabled then
  begin
    FState := bsHover;
    Invalidate;
  end;
end;

procedure TXelImageButton.MouseLeave;
begin
  inherited MouseLeave;
  FState := bsNormal;
  Invalidate;
end;

procedure TXelImageButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Enabled then
  begin
    FState := bsPressed;
    Invalidate;
  end;
end;

procedure TXelImageButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Enabled then
  begin
    FState := bsHover;
    Invalidate;
  end;
end;

procedure TXelImageButton.Click;
begin
  inherited Click;
  // Handle ModalResult if placed on a form
  if FModalResult <> 0 then
    if Owner is TCustomForm then
      (Owner as TCustomForm).ModalResult := FModalResult;
end;

end.
