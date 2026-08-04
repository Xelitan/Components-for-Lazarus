program fontconv;

{$mode objfpc}{$H+}
uses
  Classes, SysUtils,
  FontTypes, TTFParser, CFFBuilder, WOFFCodec, WOFF2Codec, SVGFontWriter, SVGFontReader;

// Author: www.xelitan.com
// License: MIT
//
// Font format converter — conversion is inferred from file extensions.
// Usage:
//   fontconv <input.ttf>   <output.otf>
//   fontconv <input.otf>   <output.woff>
//   fontconv <input.otf>   <output.woff2>
//   fontconv <input.woff>  <output.otf>
//   fontconv <input.woff>  <output.woff2>
//   fontconv <input.woff2> <output.woff>
//   fontconv <input.woff2> <output.otf>

// ----------------------------------------------------------------
// TTF -> OTF
// ----------------------------------------------------------------
procedure ConvertTTFToOTF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
  Parser    : TTTFParser;
  Builder   : TCFFBuilder;
begin
  WriteLn('TTF -> OTF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  try
    Parser := TTTFParser.Create(SrcStream, False);
    try
      Write('  Parsing TrueType font... ');
      Parser.Parse;
      WriteLn(Format('done (%d glyphs, %d upm)',
                     [Parser.NumGlyphs, Parser.UnitsPerEm]));

      Builder := TCFFBuilder.Create(Parser);
      try
        DstStream := TFileStream.Create(DstFile, fmCreate);
        try
          Write('  Building CFF-based OpenType... ');
          Builder.BuildOTF(DstStream);
          WriteLn(Format('done (%d bytes)', [DstStream.Size]));
        finally
          DstStream.Free;
        end;
      finally
        Builder.Free;
      end;
    finally
      Parser.Free;
    end;
  finally
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// OTF/TTF -> WOFF
// ----------------------------------------------------------------
procedure ConvertOTFToWOFF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('OTF -> WOFF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Compressing tables... ');
    OTFToWOFF(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// WOFF -> OTF/TTF
// ----------------------------------------------------------------
procedure ConvertWOFFToOTF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('WOFF -> OTF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Decompressing tables... ');
    WOFFToOTF(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// OTF/TTF -> WOFF2
// ----------------------------------------------------------------
procedure ConvertOTFToWOFF2(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('OTF -> WOFF2: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Encoding WOFF2... ');
    OTFToWOFF2(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// WOFF -> WOFF2
// ----------------------------------------------------------------
procedure ConvertWOFFToWOFF2(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('WOFF -> WOFF2: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Re-encoding as WOFF2... ');
    WOFFToWOFF2(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// WOFF2 -> WOFF
// ----------------------------------------------------------------
procedure ConvertWOFF2ToWOFF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('WOFF2 -> WOFF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Decoding WOFF2... ');
    WOFF2ToWOFF(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// WOFF2 -> OTF
// ----------------------------------------------------------------
procedure ConvertWOFF2ToOTF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('WOFF2 -> OTF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Decoding WOFF2... ');
    WOFF2ToOTF(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// OTF/TTF -> SVG font
// ----------------------------------------------------------------
procedure ConvertOTFToSVG(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('OTF -> SVG: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Extracting outlines... ');
    OTFToSVGFont(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// SVG font -> OTF
// ----------------------------------------------------------------
procedure ConvertSVGToOTF(const SrcFile, DstFile : string);
var
  SrcStream : TFileStream;
  DstStream : TFileStream;
begin
  WriteLn('SVG -> OTF: ', SrcFile, ' -> ', DstFile);
  SrcStream := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  DstStream := TFileStream.Create(DstFile, fmCreate);
  try
    Write('  Building CFF OpenType... ');
    SVGFontToOTF(SrcStream, DstStream);
    WriteLn(Format('done (%d -> %d bytes)', [SrcStream.Size, DstStream.Size]));
  finally
    DstStream.Free;
    SrcStream.Free;
  end;
end;

// ----------------------------------------------------------------
// Main
// ----------------------------------------------------------------
procedure PrintUsage;
begin
  WriteLn('Usage:');
  WriteLn('  fontconv <input.ttf>   <output.otf>');
  WriteLn('  fontconv <input.otf>   <output.woff>');
  WriteLn('  fontconv <input.otf>   <output.woff2>');
  WriteLn('  fontconv <input.woff>  <output.otf>');
  WriteLn('  fontconv <input.woff>  <output.woff2>');
  WriteLn('  fontconv <input.woff2> <output.woff>');
  WriteLn('  fontconv <input.woff2> <output.otf>');
  WriteLn('  fontconv <input.otf>   <output.svg>');
  WriteLn('  fontconv <input.ttf>   <output.svg>');
  WriteLn('  fontconv <input.svg>   <output.otf>');
end;

var
  Src, Dst, SrcExt, DstExt : string;
begin
  if ParamCount < 2 then begin PrintUsage; Halt(1); end;

  Src := ParamStr(1);
  Dst := ParamStr(2);

  if not FileExists(Src) then
  begin
    WriteLn('Error: input file not found: ', Src);
    Halt(1);
  end;

  SrcExt := LowerCase(ExtractFileExt(Src));
  DstExt := LowerCase(ExtractFileExt(Dst));

  try
    if      (SrcExt = '.ttf')   and (DstExt = '.otf')   then ConvertTTFToOTF    (Src, Dst)
    else if (SrcExt = '.otf')   and (DstExt = '.woff')  then ConvertOTFToWOFF   (Src, Dst)
    else if (SrcExt = '.otf')   and (DstExt = '.woff2') then ConvertOTFToWOFF2  (Src, Dst)
    else if (SrcExt = '.woff')  and (DstExt = '.otf')   then ConvertWOFFToOTF   (Src, Dst)
    else if (SrcExt = '.woff')  and (DstExt = '.woff2') then ConvertWOFFToWOFF2 (Src, Dst)
    else if (SrcExt = '.woff2') and (DstExt = '.woff')  then ConvertWOFF2ToWOFF (Src, Dst)
    else if (SrcExt = '.woff2') and (DstExt = '.otf')   then ConvertWOFF2ToOTF  (Src, Dst)
    else if (SrcExt = '.otf')   and (DstExt = '.svg')   then ConvertOTFToSVG    (Src, Dst)
    else if (SrcExt = '.ttf')   and (DstExt = '.svg')   then ConvertOTFToSVG    (Src, Dst)
    else if (SrcExt = '.svg')   and (DstExt = '.otf')   then ConvertSVGToOTF    (Src, Dst)
    else
    begin
      WriteLn('Error: no conversion available for ', SrcExt, ' -> ', DstExt);
      PrintUsage;
      Halt(1);
    end;
  except
    on E : Exception do
    begin
      WriteLn('Error: ', E.Message);
      Halt(1);
    end;
  end;

  WriteLn('Conversion complete.');
end.
