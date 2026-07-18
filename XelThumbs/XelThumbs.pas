unit XelThumbs;

//  Author: www.xelitan.com
//  License: MIT
//=====================================================================================
//  TXelThumbs - a visual component displaying image thumbnails from a directory.
//
//  - Thumbnails are loaded in separate threads (1..20, ThreadCount property).
//  - All REGISTERED graphic formats are supported
//    (GetGraphicClassForFileExtension). WebP is handled via TWebPImage.ToBitmap
//    (enable the USE_XELFORMATS directive and the corresponding unit in 'uses'); other
//    formats, e.g. TJPEGImage, are drawn onto the Canvas of an intermediate bitmap.
//  - Thumbnail scaling is done with a custom bilinear filter
//    written entirely in Pascal - not StretchDraw.
//  - Configurable thumbnail size, margins and a caption (file name) below the thumbnail.
//  - The OnSelect and OnItemClick events return the file name as a parameter.
//
//  CROSS-PLATFORM NOTE
//  -------------------
//  Only Win32/GDI (and, by luck, GTK3) tolerate GUI/GDI calls from a non-main
//  thread. GTK2, Qt5, Qt6 and Cocoa are NOT thread-safe and crash if the
//  widgetset is touched off the main thread. Therefore the worker threads only
//  ever use pure-memory FPImage code (TLazIntfImage, no widgetset handle). Any
//  operation that needs the widgetset (TBitmap handle, Canvas, TGraphic /
//  XelImageFormats decoders) runs on the main thread via Synchronize.
//

{$mode delphi}{$H+}

// Uncomment the line below if you want to use XelImageFormats
{$DEFINE USE_XELFORMATS}

interface

uses
  Classes, SysUtils, Types, Math, Controls, Graphics, LCLType, LCLIntf,
  IntfGraphics, FPimage, GraphType, StdCtrls, Forms, SyncObjs,
  // FPImage readers - pure Pascal, no widgetset. Being in 'uses' registers them
  // with FPImage so TLazIntfImage.LoadFromFile can decode these in worker threads.
  FPReadPNG, FPReadJPEG, FPReadBMP, FPReadGIF, FPReadTGA, FPReadTiff,
  FPReadXPM, FPReadPNM, FPReadPCX, FPReadPSD
  {$IFDEF USE_XELFORMATS},
  WebPImageX, LeptonImageX, SvgImageX, Jp2ImageX, JxlImageX, JBig2ImageX
  {$ENDIF};

type
  TXelThumbEvent = procedure(Sender: TObject; const AFileName: string) of object;

  TThumbState = (tsPending, tsLoading, tsDone, tsError);

  // A single thumbnail
  TThumbItem = class
  public
    FileName: string;          // full path
    DisplayName: string;       // file name only
    Bitmap: TBitmap;           // finished thumbnail (nil until loaded)
    State: TThumbState;
    Bounds: TRect;             // cell position in content coordinates
    destructor Destroy; override;
  end;

  TXelThumbs = class;

  // Thread that loads thumbnails
  TThumbLoader = class(TThread)
  private
    FOwner: TXelThumbs;
    FCurIndex: Integer;
    FCurImage: TLazIntfImage;
    // used to hand a decode job to the main thread (Synchronize)
    FDecodeFile: string;
    FDecodeResult: TLazIntfImage;
    procedure StoreResult;
    procedure DecodeOnMainThread;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TXelThumbs);
  end;

  // TXelThumbs
  TXelThumbs = class(TCustomControl)
  private
    FItems: TList;             // list of TThumbItem
    FLock: TCriticalSection;   // protects the job queue / list
    FLoaders: TList;           // active TThumbLoader threads
    FActiveLoaders: Integer;

    FDirectory: string;
    FThumbWidth: Integer;
    FThumbHeight: Integer;
    FMargin: Integer;
    FShowCaption: Boolean;
    FCaptionHeight: Integer;
    FThreadCount: Integer;
    FItemIndex: Integer;

    FScrollBar: TScrollBar;
    FColumns: Integer;
    FContentHeight: Integer;

    FOnSelect: TXelThumbEvent;
    FOnItemClick: TXelThumbEvent;

    procedure SetDirectory(const Value: string);
    procedure SetThumbWidth(Value: Integer);
    procedure SetThumbHeight(Value: Integer);
    procedure SetMargin(Value: Integer);
    procedure SetShowCaption(Value: Boolean);
    procedure SetThreadCount(Value: Integer);
    procedure SetItemIndex(Value: Integer);

    procedure ClearItems;
    procedure StopLoaders;
    procedure StartLoaders;
    procedure RecalcLayout;
    procedure ScrollBarChange(Sender: TObject);
    procedure UpdateScrollBar;
    function MaxScrollOffset: Integer;
    function CellHeight: Integer;
    function CellWidth: Integer;
    function ItemAtPos(X, Y: Integer): Integer;

    // called by worker threads
    function GetNextJob: Integer;
    // scales a decoded (thread-safe) image down to the thumbnail frame; frees ASrc
    function ResizeToThumb(ASrc: TLazIntfImage): TLazIntfImage;
  protected
    procedure Loaded; override;
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Reload;
    function ItemCount: Integer;
    function FileNameByIndex(AIndex: Integer): string;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
  published
    property Directory: string read FDirectory write SetDirectory;
    property ThumbWidth: Integer read FThumbWidth write SetThumbWidth default 128;
    property ThumbHeight: Integer read FThumbHeight write SetThumbHeight default 128;
    property Margin: Integer read FMargin write SetMargin default 8;
    property ShowCaption: Boolean read FShowCaption write SetShowCaption default True;
    property ThreadCount: Integer read FThreadCount write SetThreadCount default 4;

    property OnSelect: TXelThumbEvent read FOnSelect write FOnSelect;
    property OnItemClick: TXelThumbEvent read FOnItemClick write FOnItemClick;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color default clWindow;
    property Enabled;
    property PopupMenu;
    property ShowHint;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
  end;

procedure Register;

implementation

{$R txelthumbs_images.res}

const
  CAPTION_PAD = 4;

// ============================ Bilinear scaling =============================

// Bilinear filter written entirely in Pascal. It operates on TLazIntfImage,
// i.e. on memory - without a GDI context, which makes it thread-safe.
function BilinearResize(Src: TLazIntfImage; NewW, NewH: Integer): TLazIntfImage;
var
  x, y, x0, y0, x1, y1: Integer;
  gx, gy, fx, fy: Double;
  c00, c10, c01, c11, top, bot, res: TFPColor;
  sw, sh: Integer;

  function LerpW(a, b: Word; t: Double): Word; inline;
  begin
    Result := Word(Round(a + (Integer(b) - Integer(a)) * t));
  end;

begin
  Result := TLazIntfImage.Create(0, 0);
  // take over the pixel format from the source, so we don't call functions
  // that depend on a GDI context
  Result.DataDescription := Src.DataDescription;
  Result.SetSize(NewW, NewH);

  sw := Src.Width;
  sh := Src.Height;
  if (sw = 0) or (sh = 0) or (NewW = 0) or (NewH = 0) then
    Exit;

  for y := 0 to NewH - 1 do
  begin
    if NewH > 1 then gy := y * (sh - 1) / (NewH - 1) else gy := 0;
    y0 := Trunc(gy);
    y1 := Min(y0 + 1, sh - 1);
    fy := gy - y0;

    for x := 0 to NewW - 1 do
    begin
      if NewW > 1 then gx := x * (sw - 1) / (NewW - 1) else gx := 0;
      x0 := Trunc(gx);
      x1 := Min(x0 + 1, sw - 1);
      fx := gx - x0;

      c00 := Src.Colors[x0, y0];
      c10 := Src.Colors[x1, y0];
      c01 := Src.Colors[x0, y1];
      c11 := Src.Colors[x1, y1];

      top.red   := LerpW(c00.red,   c10.red,   fx);
      top.green := LerpW(c00.green, c10.green, fx);
      top.blue  := LerpW(c00.blue,  c10.blue,  fx);
      top.alpha := LerpW(c00.alpha, c10.alpha, fx);

      bot.red   := LerpW(c01.red,   c11.red,   fx);
      bot.green := LerpW(c01.green, c11.green, fx);
      bot.blue  := LerpW(c01.blue,  c11.blue,  fx);
      bot.alpha := LerpW(c01.alpha, c11.alpha, fx);

      res.red   := LerpW(top.red,   bot.red,   fy);
      res.green := LerpW(top.green, bot.green, fy);
      res.blue  := LerpW(top.blue,  bot.blue,  fy);
      res.alpha := LerpW(top.alpha, bot.alpha, fy);

      Result.Colors[x, y] := res;
    end;
  end;
end;

// Loads any registered format into a TBitmap. MAIN-THREAD ONLY - it uses the
// widgetset (Canvas, TGraphic decoders, XelImageFormats.ToBitmap). Called from
// the worker only via Synchronize(DecodeOnMainThread).
function LoadGraphicAsBitmap(const AFileName: string): TBitmap;
var
  GraphicClass: TGraphicClass;
  G: TGraphic;
  Bmp: TBitmap;
  {$IFDEF USE_XELFORMATS}
  Ret: TBitmap;
  {$ENDIF}
begin
  Result := nil;
  GraphicClass := GetGraphicClassForFileExtension(ExtractFileExt(AFileName));
  if GraphicClass = nil then
    Exit;

  G := GraphicClass.Create;
  try
    G.LoadFromFile(AFileName);
    {$IFDEF USE_XELFORMATS}
    if (G is TWebPImage) or (G is TLeptonImage) or (G is TJxlImage) or
       (G is TJp2Image) or (G is TJBig2Image) or (G is TSvgImage) then
    begin
      Ret := nil;
      if G is TWebPImage then Ret := TWebPImage(G).ToBitmap
      else if G is TLeptonImage then Ret := TLeptonImage(G).ToBitmap
      else if G is TJxlImage then Ret := TJxlImage(G).ToBitmap
      else if G is TJp2Image then Ret := TJp2Image(G).ToBitmap
      else if G is TJBig2Image then Ret := TJBig2Image(G).ToBitmap
      else if G is TSvgImage then Ret := TSvgImage(G).ToBitmap;
      if Ret <> nil then
      begin
        // Ret is owned by G (it is G's internal bitmap) - copy, don't take it.
        Result := TBitmap.Create;
        Result.Assign(Ret);
      end;
      Exit; // 'finally' below frees G (and thus Ret)
    end;
    {$ENDIF}
    if G is TBitmap then
    begin
      Result := TBitmap.Create;
      Result.Assign(G);
    end
    else
    begin
      // e.g. TJPEGImage has no ToBitmap - draw onto the Canvas of an intermediate bitmap
      Bmp := TBitmap.Create;
      try
        Bmp.PixelFormat := pf32bit;
        Bmp.SetSize(G.Width, G.Height);
        Bmp.Canvas.Brush.Color := clWhite;
        Bmp.Canvas.FillRect(0, 0, Bmp.Width, Bmp.Height);
        Bmp.Canvas.Draw(0, 0, G);
      except
        Bmp.Free;
        raise;
      end;
      Result := Bmp;
    end;
  finally
    G.Free;
  end;
end;

// Reads a JPEG's pixel dimensions straight from the SOF marker without decoding
// the image. Pure stream parsing - thread-safe. Leaves the stream position moved.
function ReadJpegSize(Str: TStream; out W, H: Integer): Boolean;
var
  b, marker, lenHi, lenLo: Byte;
  segLen: Integer;
  prec, hHi, hLo, wHi, wLo: Byte;
begin
  Result := False; W := 0; H := 0;
  Str.Position := 0;
  if Str.Read(b, 1) <> 1 then Exit;
  if b <> $FF then Exit;
  if Str.Read(b, 1) <> 1 then Exit;
  if b <> $D8 then Exit;               // SOI
  while True do
  begin
    if Str.Read(b, 1) <> 1 then Exit;
    if b <> $FF then Continue;         // resync to next marker prefix
    repeat                             // skip fill bytes ($FF $FF ...)
      if Str.Read(marker, 1) <> 1 then Exit;
    until marker <> $FF;
    // standalone markers carry no length: SOI/EOI/TEM and RST0..RST7
    if (marker = $D8) or (marker = $D9) or (marker = $01) or
       ((marker >= $D0) and (marker <= $D7)) then
      Continue;
    if Str.Read(lenHi, 1) <> 1 then Exit;
    if Str.Read(lenLo, 1) <> 1 then Exit;
    segLen := lenHi * 256 + lenLo;     // includes the 2 length bytes
    if segLen < 2 then Exit;
    // SOF0..SOF15 (C0..CF) hold the frame size, except DHT/JPG/DAC (C4/C8/CC)
    if (marker >= $C0) and (marker <= $CF) and
       (marker <> $C4) and (marker <> $C8) and (marker <> $CC) then
    begin
      if Str.Read(prec, 1) <> 1 then Exit;
      if Str.Read(hHi, 1) <> 1 then Exit;
      if Str.Read(hLo, 1) <> 1 then Exit;
      if Str.Read(wHi, 1) <> 1 then Exit;
      if Str.Read(wLo, 1) <> 1 then Exit;
      H := hHi * 256 + hLo;
      W := wHi * 256 + wLo;
      Result := (W > 0) and (H > 0);
      Exit;
    end
    else
      Str.Position := Str.Position + (segLen - 2); // skip the rest of this segment
  end;
end;

// Picks the largest libjpeg DCT downscale (1/1, 1/2, 1/4, 1/8) that still leaves
// the decoded image at least as large as the AMaxW x AMaxH thumbnail frame, so
// the final bilinear pass is always a down-scale (no quality loss from upscaling).
function PickJpegScale(W, H, AMaxW, AMaxH: Integer): TJPEGScale;
var
  ratio: Double;
begin
  Result := jsFullSize;
  if (W <= 0) or (H <= 0) or (AMaxW <= 0) or (AMaxH <= 0) then Exit;
  ratio := Max(W / AMaxW, H / AMaxH);
  if ratio >= 8 then Result := jsEighth
  else if ratio >= 4 then Result := jsQuarter
  else if ratio >= 2 then Result := jsHalf;
end;

// Extensions decoded by the XelImageFormats pipeline (see XelDecodeToIntf).
// FPImage has no reader for any of them, so the generic FPImage loader must not
// be handed these files - it would probe the whole reader registry, fail to
// identify the stream and raise EFPImageException. Keep this list in sync with
// XelDecodeToIntf (both call this function).
function IsXelImageExt(const ALowerExt: string): Boolean;
begin
  Result := (ALowerExt = '.webp') or (ALowerExt = '.jxl')  or
            (ALowerExt = '.jp2')  or (ALowerExt = '.jpc')  or
            (ALowerExt = '.j2k')  or (ALowerExt = '.lep')  or
            (ALowerExt = '.jbig2') or (ALowerExt = '.jb2');
end;

// Thread-safe image loader. Uses ONLY FPImage (pure Pascal, no widgetset), so it
// is safe to call from a worker thread on every platform (GTK2/Qt/Cocoa included).
// For JPEGs it decodes at a reduced DCT scale (jsHalf/Quarter/Eighth) chosen from
// the real image size vs the AMaxW x AMaxH thumbnail frame - much faster and far
// less memory than decoding full size just to shrink it afterwards.
// Returns nil if FPImage has no reader for this file (or it is corrupt); the
// caller then falls back to a main-thread widgetset decode.
function LoadIntfImageThreadSafe(const AFileName: string;
  AMaxW, AMaxH: Integer): TLazIntfImage;
var
  Desc: TRawImageDescription;
  ext: string;
  fs: TFileStream;
  reader: TFPReaderJPEG;
  jw, jh: Integer;
begin
  Result := nil;
  ext := LowerCase(ExtractFileExt(AFileName));

  if (ext = '.jpg') or (ext = '.jpeg') or (ext = '.jpe') then
  begin
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      Result := TLazIntfImage.Create(0, 0);
      try
        Desc.Init_BPP32_B8G8R8A8_BIO_TTB(0, 0);
        Result.DataDescription := Desc;
        reader := TFPReaderJPEG.Create;
        try
          if ReadJpegSize(fs, jw, jh) then
            reader.Scale := PickJpegScale(jw, jh, AMaxW, AMaxH);
          reader.Performance := jpBestSpeed; // fast IDCT - fine for thumbnails
          fs.Position := 0;
          Result.LoadFromStream(fs, reader);
        finally
          reader.Free;
        end;
      except
        FreeAndNil(Result);
      end;
    finally
      fs.Free;
    end;
    Exit;
  end;

  // Only use the generic FPImage loader if FPImage actually has a reader for
  // this extension. Otherwise LoadFromFile falls back to probing the whole
  // reader registry, fails to identify the stream and raises
  // EFPImageException('Can''t determine image type of stream'). The caller
  // catches that, but it still trips the debugger's first-chance exception
  // notification on every file FPImage can't read (SVG, and the XelImageFormats
  // formats: JB2/WebP/JXL/JP2/Lepton...). Returning nil lets the caller fall
  // through to the Xel decoder (stage 1b) or the main-thread widgetset decode
  // (stage 2, e.g. SVG's canvas rasteriser).
  if TLazIntfImage.FindReaderFromExtension(ext) = nil then
    Exit; // Result stays nil -> caller falls through to the next stage

  // Generic FPImage loader (reader chosen by file extension).
  Result := TLazIntfImage.Create(0, 0);
  try
    Desc.Init_BPP32_B8G8R8A8_BIO_TTB(0, 0);
    Result.DataDescription := Desc;
    Result.LoadFromFile(AFileName);
  except
    FreeAndNil(Result);             // unsupported/corrupt -> let caller fall back
  end;
end;

{$IFDEF USE_XELFORMATS}
// Thread-safe decode of the XelImageFormats formats. Each class exposes a
// ToIntfImage that decodes with pure-Pascal code into a memory TLazIntfImage and
// touches no widgetset, so this runs in a worker thread on every platform.
// SVG is intentionally NOT handled here: its rasteriser draws onto a bitmap
// canvas, so it must decode on the main thread - it falls through to the caller's
// Synchronize fallback. Returns nil for anything not handled here.
function XelDecodeToIntf(const AFileName: string;
  AMaxW, AMaxH: Integer): TLazIntfImage;
var
  ext: string;
  Str: TFileStream;
  Empty: TBytes;
begin
  Result := nil;
  ext := LowerCase(ExtractFileExt(AFileName));
  if not IsXelImageExt(ext) then
    Exit;

  Str := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    try
      if ext = '.webp' then
        Result := TWebPImage.ToIntfImage(Str)
      else if ext = '.jxl' then
        Result := TJxlImage.ToIntfImage(Str)
      else if (ext = '.jp2') or (ext = '.jpc') or (ext = '.j2k') then
        Result := TJp2Image.ToIntfImage(Str)
      else if ext = '.lep' then
        // Lepton is JPEG-backed - decode its embedded JPEG at a reduced DCT scale.
        Result := TLeptonImage.ToIntfImage(Str, AMaxW, AMaxH)
      else if (ext = '.jbig2') or (ext = '.jb2') then
      begin
        SetLength(Empty, 0);
        Result := TJBig2Image.ToIntfImage(Str, Empty);
      end;
    except
      FreeAndNil(Result);
    end;
  finally
    Str.Free;
  end;
end;
{$ENDIF}

// ============================== TThumbItem =================================

destructor TThumbItem.Destroy;
begin
  Bitmap.Free;
  inherited Destroy;
end;

// ============================== TThumbLoader ===============================

constructor TThumbLoader.Create(AOwner: TXelThumbs);
begin
  FOwner := AOwner;
  // We do NOT use FreeOnTerminate - the owner holds the references and frees
  // the threads itself in StopLoaders once they have finished.
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TThumbLoader.StoreResult;
var
  Item: TThumbItem;
  Bmp: TBitmap;
begin
  // Executed in the main thread (Synchronize). Here we create the visible
  // TBitmap from the finished, scaled TLazIntfImage.
  if FOwner = nil then Exit;
  FOwner.FLock.Enter;
  try
    if (FCurIndex < 0) or (FCurIndex >= FOwner.FItems.Count) then Exit;
    Item := TThumbItem(FOwner.FItems[FCurIndex]);
  finally
    FOwner.FLock.Leave;
  end;

  if FCurImage <> nil then
  begin
    Bmp := TBitmap.Create;
    try
      Bmp.LoadFromIntfImage(FCurImage);
      Item.Bitmap.Free;
      Item.Bitmap := Bmp;
      Item.State := tsDone;
    except
      Bmp.Free;
      Item.State := tsError;
    end;
  end
  else
    Item.State := tsError;

  FOwner.Invalidate;
end;

procedure TThumbLoader.DecodeOnMainThread;
var
  Bmp: TBitmap;
  Img: TLazIntfImage;
begin
  // Runs in the MAIN thread (Synchronize). Only here may we touch the widgetset:
  // TGraphic / XelImageFormats decoders, TBitmap.Handle, Canvas, etc. The result
  // is a pure-memory TLazIntfImage the worker can then scale off-thread.
  FDecodeResult := nil;
  Bmp := LoadGraphicAsBitmap(FDecodeFile);
  if Bmp = nil then Exit;
  try
    if (Bmp.Width = 0) or (Bmp.Height = 0) then Exit;
    Img := TLazIntfImage.Create(0, 0);
    try
      Img.LoadFromBitmap(Bmp.Handle, Bmp.MaskHandle); // main thread -> safe
      FDecodeResult := Img;
    except
      Img.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TThumbLoader.Execute;
var
  idx: Integer;
  Item: TThumbItem;
  fn: string;
  Src: TLazIntfImage;
begin
  while not Terminated do
  begin
    idx := FOwner.GetNextJob;
    if idx < 0 then
      Break;

    FOwner.FLock.Enter;
    try
      Item := TThumbItem(FOwner.FItems[idx]);
      fn := Item.FileName;
    finally
      FOwner.FLock.Leave;
    end;

    // 1) Fast path: decode with pure FPImage in this worker thread (no widgetset).
    //    JPEGs are decoded at a reduced DCT scale sized to the thumbnail frame.
    Src := nil;
    try
      Src := LoadIntfImageThreadSafe(fn, FOwner.FThumbWidth, FOwner.FThumbHeight);
    except
      FreeAndNil(Src);
    end;

    {$IFDEF USE_XELFORMATS}
    // 1b) XelImageFormats (WebP/JXL/JP2/JBIG2/Lepton) also decode in-thread via
    //     their pure-memory ToIntfImage - so these stay parallel on GTK2/Qt/Cocoa.
    if (Src = nil) and not Terminated then
    try
      Src := XelDecodeToIntf(fn, FOwner.FThumbWidth, FOwner.FThumbHeight);
    except
      FreeAndNil(Src);
    end;
    {$ENDIF}

    // 2) Fallback: formats that still need the widgetset to decode (e.g. ICO, or
    //    SVG's canvas rasteriser) are decoded on the main thread via Synchronize.
    if (Src = nil) and not Terminated then
    begin
      FDecodeFile := fn;
      FDecodeResult := nil;
      Synchronize(DecodeOnMainThread);
      Src := FDecodeResult;
      FDecodeResult := nil;
    end;

    if Terminated then
    begin
      FreeAndNil(Src);
      Break;
    end;

    // 3) Scale to the thumbnail size - pure memory, thread-safe. ResizeToThumb
    //    always frees Src.
    FCurImage := nil;
    if Src <> nil then
    try
      FCurImage := FOwner.ResizeToThumb(Src);
    except
      FreeAndNil(FCurImage);
    end;

    if Terminated then
    begin
      FreeAndNil(FCurImage);
      Break;
    end;

    FCurIndex := idx;
    Synchronize(StoreResult);
    FreeAndNil(FCurImage);
  end;

  // signal completion - always, regardless of Terminate
  InterlockedDecrement(FOwner.FActiveLoaders);
end;

// =============================== TXelThumbs ================================

constructor TXelThumbs.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems := TList.Create;
  FLoaders := TList.Create;
  FLock := TCriticalSection.Create;

  FThumbWidth := 128;
  FThumbHeight := 128;
  FMargin := 8;
  FShowCaption := True;
  FThreadCount := 4;
  FItemIndex := -1;
  FColumns := 1;

  Color := clWindow;
  DoubleBuffered := True;
  TabStop := True;
  ControlStyle := ControlStyle + [csClickEvents, csDoubleClicks];

  FCaptionHeight := Abs(Font.Height);
  if FCaptionHeight = 0 then FCaptionHeight := 14;
  FCaptionHeight := FCaptionHeight + 2 * CAPTION_PAD;

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Kind := sbVertical;
  FScrollBar.Parent := Self;
  FScrollBar.OnChange := ScrollBarChange;
  FScrollBar.Visible := False;

  SetInitialBounds(0, 0, 320, 240);
end;

destructor TXelThumbs.Destroy;
begin
  StopLoaders;
  ClearItems;
  FItems.Free;
  FLoaders.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TXelThumbs.ClearItems;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    TThumbItem(FItems[i]).Free;
  FItems.Clear;
  FItemIndex := -1;
end;

procedure TXelThumbs.StopLoaders;
var
  i: Integer;
begin
  // Signal the threads to stop working.
  FLock.Enter;
  try
    for i := 0 to FLoaders.Count - 1 do
      TThumbLoader(FLoaders[i]).Terminate;
  finally
    FLock.Leave;
  end;

  // Let the threads finish. Worker threads call Synchronize(StoreResult),
  // so the main thread MUST pump the Synchronize queue - otherwise deadlock.
  while FActiveLoaders > 0 do
    CheckSynchronize(10);

  // By now each thread's Execute has returned - WaitFor will not block.
  for i := 0 to FLoaders.Count - 1 do
  begin
    TThumbLoader(FLoaders[i]).WaitFor;
    TThumbLoader(FLoaders[i]).Free;
  end;
  FLoaders.Clear;
end;

procedure TXelThumbs.StartLoaders;
var
  i, n: Integer;
begin
  n := FThreadCount;
  if n < 1 then n := 1;
  if n > 20 then n := 20;
  if n > FItems.Count then n := FItems.Count;
  if n <= 0 then Exit;

  FActiveLoaders := n;
  for i := 1 to n do
    FLoaders.Add(TThumbLoader.Create(Self));
end;

function TXelThumbs.GetNextJob: Integer;
var
  i: Integer;
  Item: TThumbItem;
begin
  Result := -1;
  FLock.Enter;
  try
    for i := 0 to FItems.Count - 1 do
    begin
      Item := TThumbItem(FItems[i]);
      if Item.State = tsPending then
      begin
        Item.State := tsLoading;
        Result := i;
        Break;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TXelThumbs.ResizeToThumb(ASrc: TLazIntfImage): TLazIntfImage;
var
  scale: Double;
  nw, nh: Integer;
begin
  // ASrc is a pure-memory image (from FPImage or from the main-thread decode).
  // Everything here operates on memory only, so it is safe off the main thread.
  Result := nil;
  try
    if (ASrc.Width = 0) or (ASrc.Height = 0) then
      Exit;
    // target size preserving aspect ratio within the ThumbW x ThumbH frame
    scale := Min(FThumbWidth / ASrc.Width, FThumbHeight / ASrc.Height);
    if scale > 1 then scale := 1; // do not upscale beyond the original
    nw := Max(1, Round(ASrc.Width * scale));
    nh := Max(1, Round(ASrc.Height * scale));
    Result := BilinearResize(ASrc, nw, nh);
  finally
    ASrc.Free;
  end;
end;

procedure TXelThumbs.Reload;
var
  Info: TSearchRec;
  fn, ext: string;
  Item: TThumbItem;
begin
  StopLoaders;
  ClearItems;

  if (FDirectory <> '') and DirectoryExists(FDirectory) then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(FDirectory) + '*', faAnyFile, Info) = 0 then
    try
      repeat
        if (Info.Attr and faDirectory) <> 0 then
          Continue;
        ext := ExtractFileExt(Info.Name);
        if GetGraphicClassForFileExtension(ext) = nil then
          Continue; // registered graphic formats only
        fn := IncludeTrailingPathDelimiter(FDirectory) + Info.Name;
        Item := TThumbItem.Create;
        Item.FileName := fn;
        Item.DisplayName := Info.Name;
        Item.State := tsPending;
        FItems.Add(Item);
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
  end;

  RecalcLayout;
  Invalidate;
  StartLoaders;
end;

function TXelThumbs.CellWidth: Integer;
begin
  Result := FThumbWidth + FMargin;
end;

function TXelThumbs.CellHeight: Integer;
begin
  Result := FThumbHeight + FMargin;
  if FShowCaption then
    Inc(Result, FCaptionHeight);
end;

procedure TXelThumbs.RecalcLayout;
var
  i, col, row, avail: Integer;
  Item: TThumbItem;
  x, y: Integer;
begin
  avail := ClientWidth;
  if FScrollBar.Visible then
    Dec(avail, FScrollBar.Width);
  if avail < CellWidth then
    avail := CellWidth;

  FColumns := Max(1, (avail - FMargin) div CellWidth);

  for i := 0 to FItems.Count - 1 do
  begin
    Item := TThumbItem(FItems[i]);
    col := i mod FColumns;
    row := i div FColumns;
    x := FMargin + col * CellWidth;
    y := FMargin + row * CellHeight;
    Item.Bounds := Rect(x, y, x + FThumbWidth, y + FThumbHeight +
      IfThen(FShowCaption, FCaptionHeight, 0));
  end;

  if FItems.Count > 0 then
    FContentHeight := FMargin + ((FItems.Count - 1) div FColumns + 1) * CellHeight
  else
    FContentHeight := 0;

  UpdateScrollBar;
end;

function TXelThumbs.MaxScrollOffset: Integer;
begin
  Result := Max(0, FContentHeight - ClientHeight);
end;

procedure TXelThumbs.UpdateScrollBar;
var
  needBar: Boolean;
  maxOfs: Integer;
begin
  needBar := FContentHeight > ClientHeight;
  if needBar <> FScrollBar.Visible then
  begin
    FScrollBar.Visible := needBar;
    // changing the scrollbar visibility changes the working width -> recalculate once more
    RecalcLayout;
    Exit;
  end;

  if needBar then
  begin
    maxOfs := MaxScrollOffset;
    FScrollBar.SetBounds(ClientWidth - FScrollBar.Width, 0,
      FScrollBar.Width, ClientHeight);
    // The widgetset caps the draggable thumb at Max - PageSize + 1. To let the
    // thumb reach the real bottom offset (FContentHeight - ClientHeight) while
    // keeping a proportional thumb, Max must span the whole content range and
    // Position then IS the pixel scroll offset (0 .. maxOfs).
    FScrollBar.Min := 0;
    FScrollBar.PageSize := 0;                    // clear first so Max isn't clamped
    FScrollBar.Max := Max(1, FContentHeight - 1);
    FScrollBar.PageSize := Max(1, ClientHeight);
    FScrollBar.LargeChange := Max(1, ClientHeight - CellHeight);
    FScrollBar.SmallChange := Max(1, CellHeight div 2);
    if FScrollBar.Position > maxOfs then
      FScrollBar.Position := maxOfs;
  end;
end;

procedure TXelThumbs.ScrollBarChange(Sender: TObject);
begin
  Invalidate;
end;

procedure TXelThumbs.Paint;
var
  i, ofsY: Integer;
  Item: TThumbItem;
  r, thumbR: TRect;
  bw, bh, bx, by: Integer;
  cap: string;
  ts: TTextStyle;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);

  if FScrollBar.Visible then
    ofsY := FScrollBar.Position
  else
    ofsY := 0;

  FillChar(ts, SizeOf(ts), 0);
  ts.Alignment := taCenter;
  ts.Layout := tlCenter;
  ts.SingleLine := True;
  ts.EndEllipsis := True;

  for i := 0 to FItems.Count - 1 do
  begin
    Item := TThumbItem(FItems[i]);
    r := Item.Bounds;
    Types.OffsetRect(r, 0, -ofsY);
    if (r.Bottom < 0) or (r.Top > ClientHeight) then
      Continue; // outside the view

    thumbR := Rect(r.Left, r.Top, r.Left + FThumbWidth, r.Top + FThumbHeight);

    // selection
    if i = FItemIndex then
    begin
      Canvas.Brush.Color := clHighlight;
      Canvas.FillRect(Rect(r.Left - 3, r.Top - 3, r.Right + 3, r.Bottom + 3));
      Canvas.Brush.Color := Color;
    end;

    // thumbnail frame
    Canvas.Pen.Color := clSilver;
    Canvas.Brush.Color := clBtnFace;
    Canvas.Rectangle(thumbR);
    Canvas.Brush.Color := Color;

    if (Item.State = tsDone) and (Item.Bitmap <> nil) then
    begin
      bw := Item.Bitmap.Width;
      bh := Item.Bitmap.Height;
      bx := thumbR.Left + (FThumbWidth - bw) div 2;
      by := thumbR.Top + (FThumbHeight - bh) div 2;
      Canvas.Draw(bx, by, Item.Bitmap);
    end
    else
    begin
      Canvas.Font.Color := clGray;
      case Item.State of
        tsError: Canvas.TextOut(thumbR.Left + 6, thumbR.Top + 6, '!');
      else
        Canvas.TextOut(thumbR.Left + 6, thumbR.Top + 6, '...');
      end;
    end;

    // caption
    if FShowCaption then
    begin
      cap := Item.DisplayName;
      if i = FItemIndex then
        Canvas.Font.Color := clHighlightText
      else
        Canvas.Font.Color := clWindowText;
      Canvas.Brush.Style := bsClear;
      Canvas.TextRect(Rect(r.Left, thumbR.Bottom + CAPTION_PAD,
        r.Right, r.Bottom), r.Left, thumbR.Bottom + CAPTION_PAD, cap, ts);
      Canvas.Brush.Style := bsSolid;
    end;
  end;
end;

procedure TXelThumbs.Loaded;
begin
  inherited Loaded;
  if FDirectory <> '' then
    Reload
  else
    RecalcLayout;
end;

procedure TXelThumbs.Resize;
begin
  inherited Resize;
  RecalcLayout;
  Invalidate;
end;

function TXelThumbs.ItemAtPos(X, Y: Integer): Integer;
var
  i, ofsY: Integer;
  Item: TThumbItem;
  r: TRect;
begin
  Result := -1;
  if FScrollBar.Visible then ofsY := FScrollBar.Position else ofsY := 0;
  for i := 0 to FItems.Count - 1 do
  begin
    Item := TThumbItem(FItems[i]);
    r := Item.Bounds;
    Types.OffsetRect(r, 0, -ofsY);
    if PtInRect(r, Point(X, Y)) then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

procedure TXelThumbs.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  idx: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
  idx := ItemAtPos(X, Y);
  if idx >= 0 then
  begin
    SetItemIndex(idx);
    if Assigned(FOnItemClick) then
      FOnItemClick(Self, TThumbItem(FItems[idx]).FileName);
  end;
end;

procedure TXelThumbs.DblClick;
begin
  inherited DblClick;
  if (FItemIndex >= 0) and Assigned(FOnItemClick) then
    FOnItemClick(Self, TThumbItem(FItems[FItemIndex]).FileName);
end;

function TXelThumbs.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := True;
  if FScrollBar.Visible then
  begin
    FScrollBar.Position := EnsureRange(
      FScrollBar.Position - (WheelDelta div 120) * FScrollBar.SmallChange * 3,
      FScrollBar.Min, MaxScrollOffset);
  end
  else
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

// ---- setters / getters ----

procedure TXelThumbs.SetDirectory(const Value: string);
begin
  if FDirectory <> Value then
  begin
    FDirectory := Value;
    if not (csLoading in ComponentState) then
      Reload;
  end;
end;

procedure TXelThumbs.SetThumbWidth(Value: Integer);
begin
  if Value < 8 then Value := 8;
  if FThumbWidth <> Value then
  begin
    FThumbWidth := Value;
    if not (csLoading in ComponentState) then Reload;
  end;
end;

procedure TXelThumbs.SetThumbHeight(Value: Integer);
begin
  if Value < 8 then Value := 8;
  if FThumbHeight <> Value then
  begin
    FThumbHeight := Value;
    if not (csLoading in ComponentState) then Reload;
  end;
end;

procedure TXelThumbs.SetMargin(Value: Integer);
begin
  if Value < 0 then Value := 0;
  if FMargin <> Value then
  begin
    FMargin := Value;
    RecalcLayout;
    Invalidate;
  end;
end;

procedure TXelThumbs.SetShowCaption(Value: Boolean);
begin
  if FShowCaption <> Value then
  begin
    FShowCaption := Value;
    RecalcLayout;
    Invalidate;
  end;
end;

procedure TXelThumbs.SetThreadCount(Value: Integer);
begin
  if Value < 1 then Value := 1;
  if Value > 20 then Value := 20;
  FThreadCount := Value;
end;

procedure TXelThumbs.SetItemIndex(Value: Integer);
begin
  if (Value < -1) or (Value >= FItems.Count) then
    Value := -1;
  if FItemIndex <> Value then
  begin
    FItemIndex := Value;
    Invalidate;
    if (FItemIndex >= 0) and Assigned(FOnSelect) then
      FOnSelect(Self, TThumbItem(FItems[FItemIndex]).FileName);
  end;
end;

function TXelThumbs.ItemCount: Integer;
begin
  Result := FItems.Count;
end;

function TXelThumbs.FileNameByIndex(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < FItems.Count) then
    Result := TThumbItem(FItems[AIndex]).FileName
  else
    Result := '';
end;

// ============================== registration ===============================

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelThumbs]);
end;

end.
