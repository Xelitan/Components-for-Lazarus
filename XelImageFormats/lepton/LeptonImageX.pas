unit LeptonImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description: Lepton (JPEG re-compression) TPicture binding                 //
// Target:      Win64, Free Pascal, Delphi                                    //
// License:     Apache-2.0                                                    //
// Copyright:   (c) 2026 Xelitan.com.                                         //
//              All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Types,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     LeptonFeatures, LeptonFile;

type
  { TLeptonImage }
  // .lep is a re-compressed JPEG bitstream. Loading decompresses it back to
  // JPEG in memory and decodes that through the standard TJPEGImage.
  // Saving compresses the internal bitmap (re-encoded as JPEG) back to .lep.
  TLeptonImage = class(TGraphic)
  private
    FBmp: TBitmap;
    procedure DecodeFromStream(Str: TStream);
    procedure EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer); override;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    function ToBitmap: TBitmap;
  end;

implementation

{ TLeptonImage }

procedure TLeptonImage.DecodeFromStream(Str: TStream);
var
  Jpg: TMemoryStream;
  JpgImg: TJPEGImage;
begin
  Jpg := TMemoryStream.Create;
  try
    try
      DecodeLepton(Str, Jpg, TEnabledFeatures.CompatLeptonVectorRead);
    except
      on E: Exception do
        raise EInvalidGraphic.Create('Lepton decode failed: ' + E.Message);
    end;

    if Jpg.Size <= 0 then
      raise EInvalidGraphic.Create('Lepton decode produced empty JPEG');

    Jpg.Position := 0;
    JpgImg := TJPEGImage.Create;
    try
      JpgImg.LoadFromStream(Jpg);
      FBmp.PixelFormat := pf32bit;
      FBmp.SetSize(JpgImg.Width, JpgImg.Height);
      FBmp.Canvas.Draw(0, 0, JpgImg);
    finally
      JpgImg.Free;
    end;
  finally
    Jpg.Free;
  end;
end;

procedure TLeptonImage.EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
var
  Jpg: TMemoryStream;
  JpgImg: TJPEGImage;
  q: Integer;
begin
  if (FBmp = nil) or (FBmp.Width <= 0) or (FBmp.Height <= 0) then
    raise EInvalidGraphic.Create('Lepton encode: empty bitmap');

  q := CompressionLevel;
  if q < 1 then q := 1
  else if q > 100 then q := 100;

  Jpg := TMemoryStream.Create;
  JpgImg := TJPEGImage.Create;
  try
    JpgImg.CompressionQuality := q;
    JpgImg.Assign(FBmp);
    JpgImg.SaveToStream(Jpg);
    Jpg.Position := 0;
    try
      EncodeLepton(Jpg, Str, TEnabledFeatures.CompatLeptonVectorWrite);
    except
      on E: Exception do
        raise EInvalidGraphic.Create('Lepton encode failed: ' + E.Message);
    end;
  finally
    JpgImg.Free;
    Jpg.Free;
  end;
end;

procedure TLeptonImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TLeptonImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TLeptonImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TLeptonImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TLeptonImage.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TLeptonImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TLeptonImage.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TLeptonImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TLeptonImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TLeptonImage.SaveToStream(Stream: TStream);
begin
  EncodeToStream(Stream, 75);
end;

constructor TLeptonImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
end;

destructor TLeptonImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TLeptonImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('Lep', 'Lepton JPEG', TLeptonImage);

finalization
  TPicture.UnregisterGraphicClass(TLeptonImage);

end.
