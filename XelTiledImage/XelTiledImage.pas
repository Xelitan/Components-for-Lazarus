unit XelTiledImage;

//Author: www.xelitan.com
//License: MIT

{$mode delphi}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, LCLType;

type
  { TGraphicControl, not TCustomControl: a windowed control would always
    cover sibling TLabel/TImage (graphic controls) regardless of z-order. }
  TXelTiledImage = class(TGraphicControl)
  private
    FPicture: TPicture;
    FTileHorizontal: Boolean;
    FTileVertical: Boolean;
    procedure SetPicture(AValue: TPicture);
    procedure SetTileHorizontal(AValue: Boolean);
    procedure SetTileVertical(AValue: Boolean);
    procedure PictureChanged(Sender: TObject);
  protected
    class function GetControlClassDefaultSize: TSize; override;
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property Picture: TPicture read FPicture write SetPicture;
    property TileHorizontal: Boolean read FTileHorizontal write SetTileHorizontal default True;
    property TileVertical: Boolean read FTileVertical write SetTileVertical default True;
    property Align;
    property Anchors;
    property Visible;
    property Color;
    property ParentColor default True;
  end;

procedure Register;

implementation

{$R txeltiledimage_images.res}

constructor TXelTiledImage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPicture := TPicture.Create;
  FPicture.OnChange := PictureChanged;
  FTileHorizontal := True;
  FTileVertical   := True;
  ParentColor     := True;

  with GetControlClassDefaultSize do
    SetInitialBounds(0, 0, CX, CY);
end;

class function TXelTiledImage.GetControlClassDefaultSize: TSize;
begin
  Result.CX := 128;
  Result.CY := 128;
end;

destructor TXelTiledImage.Destroy;
begin
  FPicture.Free;
  inherited Destroy;
end;

procedure TXelTiledImage.SetPicture(AValue: TPicture);
begin
  FPicture.Assign(AValue);
end;

procedure TXelTiledImage.SetTileHorizontal(AValue: Boolean);
begin
  if FTileHorizontal = AValue then Exit;
  FTileHorizontal := AValue;
  Invalidate;
end;

procedure TXelTiledImage.SetTileVertical(AValue: Boolean);
begin
  if FTileVertical = AValue then Exit;
  FTileVertical := AValue;
  Invalidate;
end;

procedure TXelTiledImage.PictureChanged(Sender: TObject);
begin
  Invalidate;
end;

procedure TXelTiledImage.Paint;
var
  X, Y, ImgW, ImgH: Integer;
begin

  if (FPicture = nil) or (FPicture.Graphic = nil) or FPicture.Graphic.Empty then
  begin
    if csDesigning in ComponentState then
    begin
      Canvas.Brush.Color := clAppWorkSpace;
      Canvas.Pen.Color   := clGray;
      Canvas.Rectangle(ClientRect);
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color  := clWhite;
      Canvas.TextOut(4, 4, 'TXelTiledImage');
      Canvas.Brush.Style := bsSolid;
    end;
    Exit;
  end;

  ImgW := FPicture.Width;
  ImgH := FPicture.Height;
  if (ImgW = 0) or (ImgH = 0) then Exit;

  if FTileHorizontal and FTileVertical then
  begin
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        Canvas.Draw(X, Y, FPicture.Graphic);
        Inc(X, ImgW);
      end;
      Inc(Y, ImgH);
    end;
  end
  else if FTileHorizontal then
  begin
    X := 0;
    while X < Width do
    begin
      Canvas.Draw(X, 0, FPicture.Graphic);
      Inc(X, ImgW);
    end;
  end
  else if FTileVertical then
  begin
    Y := 0;
    while Y < Height do
    begin
      Canvas.Draw(0, Y, FPicture.Graphic);
      Inc(Y, ImgH);
    end;
  end
  else
    Canvas.Draw(0, 0, FPicture.Graphic);
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelTiledImage]);
end;

initialization
  RegisterClasses([TXelTiledImage]);

end.
