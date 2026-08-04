unit XelFontPreview;

// XelFontManager — TXelFontPreview, a visual sample of a runtime font.
//
// Point it at a TXelFontManager and either an index into its Fonts collection
// or a family name, and it paints SampleText in that font.  When the font is
// not registered (yet) the control says so instead of silently falling back
// to the system default.
//
// Author: www.xelitan.com
// License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Graphics, Controls, LCLType, LCLIntf,
  XelFontTypes, XelFontManager;

type
  TXelPreviewLayout = (xplLeft, xplCenter, xplRight);

  { TXelFontPreview }
  TXelFontPreview = class(TGraphicControl)
  private
    FManager      : TXelFontManager;
    FFontIndex    : Integer;
    FFamilyName   : String;
    FSampleText   : String;
    FSampleSize   : Integer;
    FSampleStyle  : TFontStyles;
    FSampleColor  : TColor;
    FShowName     : Boolean;
    FShowMissing  : Boolean;
    FLayout       : TXelPreviewLayout;
    FBorderStyle  : TBorderStyle;
    FMargin       : Integer;
    procedure SetManager(AValue: TXelFontManager);
    procedure SetFontIndex(AValue: Integer);
    procedure SetFamilyName(const AValue: String);
    procedure SetSampleText(const AValue: String);
    procedure SetSampleSize(AValue: Integer);
    procedure SetSampleStyle(AValue: TFontStyles);
    procedure SetSampleColor(AValue: TColor);
    procedure SetShowName(AValue: Boolean);
    procedure SetLayout(AValue: TXelPreviewLayout);
    procedure SetBorderStyle(AValue: TBorderStyle);
    procedure SetMargin(AValue: Integer);
    function  GetItem: TXelFontItem;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
    procedure Paint; override;
    class function GetControlClassDefaultSize: TSize; override;
  public
    constructor Create(AOwner: TComponent); override;

    { Family name actually used for painting, '' when nothing resolved. }
    function ResolvedFamily: String;
    { True when the resolved family is registered and ready to paint. }
    function FontReady: Boolean;

    { Apply the previewed font to any TFont — handy for pushing the choice
      out to the rest of the form. }
    procedure ApplyTo(AFont: TFont);

    property Item: TXelFontItem read GetItem;
  published
    { The manager holding the font. }
    property FontManager: TXelFontManager read FManager write SetManager;

    { Index into FontManager.Fonts.  -1 means "use FamilyName instead". }
    property FontIndex: Integer read FFontIndex write SetFontIndex default -1;

    { Family to preview when FontIndex is -1. }
    property FamilyName: String read FFamilyName write SetFamilyName;

    property SampleText: String read FSampleText write SetSampleText;
    property SampleSize: Integer read FSampleSize write SetSampleSize default 24;
    property SampleStyle: TFontStyles read FSampleStyle write SetSampleStyle default [];
    property SampleColor: TColor read FSampleColor write SetSampleColor default clWindowText;

    { Draw the family name above the sample, in the control's own Font. }
    property ShowFontName: Boolean read FShowName write SetShowName default True;

    { Draw an explanation when the font is not registered. }
    property ShowMissing: Boolean read FShowMissing write FShowMissing default True;

    property Layout: TXelPreviewLayout read FLayout write SetLayout default xplLeft;
    property BorderStyle: TBorderStyle read FBorderStyle write SetBorderStyle
      default bsSingle;
    property Margin: Integer read FMargin write SetMargin default 6;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color default clWindow;
    property Constraints;
    property Enabled;
    property Font;
    property ParentColor default False;
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

procedure Register;

implementation

{$R txelfontpreview_images.res}

resourcestring
  SNoManager  = '(no FontManager assigned)';
  SNoFont     = '(no font selected)';
  SNotLoaded  = 'Font "%s" is not registered — set FontManager.Active := True';
  SDefSample  = 'The quick brown fox jumps over the lazy dog  0123456789';

{ ---------------------------------------------------------------------------
  Construction
  --------------------------------------------------------------------------- }

constructor TXelFontPreview.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FFontIndex   := -1;
  FSampleText  := SDefSample;
  FSampleSize  := 24;
  FSampleColor := clWindowText;
  FShowName    := True;
  FShowMissing := True;
  FLayout      := xplLeft;
  FBorderStyle := bsSingle;
  FMargin      := 6;
  Color        := clWindow;
  ParentColor  := False;
  with GetControlClassDefaultSize do
    SetInitialBounds(0, 0, cx, cy);
end;

class function TXelFontPreview.GetControlClassDefaultSize: TSize;
begin
  Result.cx := 320;
  Result.cy := 72;
end;

{ ---------------------------------------------------------------------------
  Property setters
  --------------------------------------------------------------------------- }

procedure TXelFontPreview.SetManager(AValue: TXelFontManager);
begin
  if FManager = AValue then Exit;
  if FManager <> nil then FManager.RemoveFreeNotification(Self);
  FManager := AValue;
  if FManager <> nil then FManager.FreeNotification(Self);
  Invalidate;
end;

procedure TXelFontPreview.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FManager) then
  begin
    FManager := nil;
    Invalidate;
  end;
end;

procedure TXelFontPreview.SetFontIndex(AValue: Integer);
begin
  if AValue < -1 then AValue := -1;
  if FFontIndex = AValue then Exit;
  FFontIndex := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetFamilyName(const AValue: String);
begin
  if FFamilyName = AValue then Exit;
  FFamilyName := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetSampleText(const AValue: String);
begin
  if FSampleText = AValue then Exit;
  FSampleText := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetSampleSize(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if AValue > 400 then AValue := 400;
  if FSampleSize = AValue then Exit;
  FSampleSize := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetSampleStyle(AValue: TFontStyles);
begin
  if FSampleStyle = AValue then Exit;
  FSampleStyle := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetSampleColor(AValue: TColor);
begin
  if FSampleColor = AValue then Exit;
  FSampleColor := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetShowName(AValue: Boolean);
begin
  if FShowName = AValue then Exit;
  FShowName := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetLayout(AValue: TXelPreviewLayout);
begin
  if FLayout = AValue then Exit;
  FLayout := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetBorderStyle(AValue: TBorderStyle);
begin
  if FBorderStyle = AValue then Exit;
  FBorderStyle := AValue;
  Invalidate;
end;

procedure TXelFontPreview.SetMargin(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if FMargin = AValue then Exit;
  FMargin := AValue;
  Invalidate;
end;

{ ---------------------------------------------------------------------------
  Resolution
  --------------------------------------------------------------------------- }

function TXelFontPreview.GetItem: TXelFontItem;
begin
  Result := nil;
  if FManager = nil then Exit;
  if (FFontIndex >= 0) and (FFontIndex < FManager.Fonts.Count) then
    Result := FManager.Fonts[FFontIndex]
  else if FFamilyName <> '' then
    Result := FManager.FindByFamily(FFamilyName);
end;

function TXelFontPreview.ResolvedFamily: String;
var
  It: TXelFontItem;
begin
  It := GetItem;
  if (It <> nil) and (It.FamilyName <> '') then Exit(It.FamilyName);
  Result := FFamilyName;
end;

function TXelFontPreview.FontReady: Boolean;
var
  It: TXelFontItem;
begin
  It := GetItem;
  if It <> nil then Exit(It.Loaded);
  Result := (FManager <> nil) and (FFamilyName <> '') and
            FManager.IsRegistered(FFamilyName);
end;

procedure TXelFontPreview.ApplyTo(AFont: TFont);
begin
  if AFont = nil then Exit;
  if not FontReady then Exit;
  AFont.Name  := ResolvedFamily;
  AFont.Size  := FSampleSize;
  AFont.Style := FSampleStyle;
end;

{ ---------------------------------------------------------------------------
  Painting
  --------------------------------------------------------------------------- }

procedure TXelFontPreview.Paint;
var
  R        : TRect;
  Fam      : String;
  Ready    : Boolean;
  Y        : Integer;
  TextW    : Integer;
  X        : Integer;
  Caption_ : String;
  Msg      : String;
begin
  R := ClientRect;

  Canvas.Brush.Color := Color;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(R);

  if FBorderStyle = bsSingle then
  begin
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(R);
    Canvas.Brush.Style := bsSolid;
    InflateRect(R, -1, -1);
  end;

  InflateRect(R, -FMargin, -FMargin);
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;

  Fam   := ResolvedFamily;
  Ready := FontReady;
  Y     := R.Top;

  { --- header line, drawn in the control's own font --- }
  if FShowName then
  begin
    Canvas.Font.Assign(Font);
    Canvas.Font.Color := clGrayText;

    if FManager = nil then Caption_ := SNoManager
    else if Fam = '' then Caption_ := SNoFont
    else if Item <> nil then
    begin
      Caption_ := Fam;
      if (Item.StyleName <> '') and
         (CompareText(Item.StyleName, 'Regular') <> 0) then
        Caption_ := Caption_ + ' ' + Item.StyleName;
      if Item.LoadedFormat <> xffUnknown then
        Caption_ := Caption_ + '  · ' + XelFontFormatNames[Item.LoadedFormat];
    end
    else
      Caption_ := Fam;

    Canvas.TextOut(R.Left, Y, Caption_);
    Inc(Y, Canvas.TextHeight('Wg') + 2);
  end;

  if (FManager = nil) or (Fam = '') then Exit;

  { --- the sample itself --- }
  if Ready then
  begin
    Canvas.Font.Name    := Fam;
    Canvas.Font.Size    := FSampleSize;
    Canvas.Font.Style   := FSampleStyle;
    Canvas.Font.Color   := FSampleColor;
    Canvas.Font.Quality := fqAntialiased;

    TextW := Canvas.TextWidth(FSampleText);
    case FLayout of
      xplCenter: X := R.Left + ((R.Right - R.Left) - TextW) div 2;
      xplRight : X := R.Right - TextW;
    else
      X := R.Left;
    end;
    if X < R.Left then X := R.Left;

    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(X, Y, FSampleText);
    Canvas.Brush.Style := bsSolid;
  end
  else if FShowMissing then
  begin
    Canvas.Font.Assign(Font);
    Canvas.Font.Color := clRed;
    Msg := Format(SNotLoaded, [Fam]);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(R.Left, Y, Msg);
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelFontPreview]);
end;

end.
