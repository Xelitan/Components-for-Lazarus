unit XelFontConvert;

// XelFontManager — brings any accepted font format to a plain sfnt stream the
// operating system can load.
//
//   TTF   -> passed through, or rebuilt as CFF OpenType when asked
//   OTF   -> passed through
//   WOFF  -> tables inflated back into the original sfnt
//   WOFF2 -> Brotli decoded and detransformed back into the original sfnt
//   SVG   -> outlines parsed and built into a CFF OpenType font
//
// Author: www.xelitan.com
// License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  XelFontTypes;

{ Convert Src into a font the OS can register and write it to Dst.
  ASourceFormat may be xffUnknown, in which case the stream is sniffed.
  Returns the format actually written (xffTTF or xffOTF). }
function XelFontToSfnt(Src, Dst: TStream; AConvert: TXelFontConvert = xfcAuto;
  ASourceFormat: TXelFontFormat = xffUnknown): TXelFontFormat;

{ Same, file in / file out. }
function XelFontFileToSfnt(const ASrcFile, ADstFile: String;
  AConvert: TXelFontConvert = xfcAuto): TXelFontFormat;

{ True when XelFontToSfnt can handle the format at all. }
function XelFontFormatSupported(AFormat: TXelFontFormat): Boolean;

implementation

uses
  FontTypes, TTFParser, CFFBuilder, WOFFCodec, WOFF2Codec, SVGFontReader;

resourcestring
  SUnsupported   = 'Font format "%s" is not supported';
  SUnknownInput  = 'Cannot determine the font format of the input';
  SConvertFailed = 'Conversion from %s failed: %s';

function XelFontFormatSupported(AFormat: TXelFontFormat): Boolean;
begin
  Result := AFormat in [xffTTF, xffOTF, xffWOFF, xffWOFF2, xffSVG];
end;

{ Rebuild a glyf-based font as a CFF OpenType font. }
procedure TTFToOTF(Src, Dst: TStream);
var
  Parser  : TTTFParser;
  Builder : TCFFBuilder;
begin
  Parser := TTTFParser.Create(Src, False);
  try
    Parser.Parse;
    Builder := TCFFBuilder.Create(Parser);
    try
      Builder.BuildOTF(Dst);
    finally
      Builder.Free;
    end;
  finally
    Parser.Free;
  end;
end;

function XelFontToSfnt(Src, Dst: TStream; AConvert: TXelFontConvert;
  ASourceFormat: TXelFontFormat): TXelFontFormat;
var
  Fmt   : TXelFontFormat;
  Stage : TMemoryStream;
  Inner : TXelFontFormat;
begin
  Fmt := ASourceFormat;
  if Fmt = xffUnknown then Fmt := XelDetectFontFormat(Src);
  if Fmt = xffUnknown then
    raise EXelFontError.Create(SUnknownInput);
  if not XelFontFormatSupported(Fmt) then
    raise EXelFontError.CreateFmt(SUnsupported, [XelFontFormatNames[Fmt]]);

  try
    case Fmt of
      xffTTF:
        if AConvert = xfcOTF then
        begin
          TTFToOTF(Src, Dst);
          Result := xffOTF;
        end
        else
        begin
          Dst.CopyFrom(Src, 0);
          Result := xffTTF;
        end;

      xffOTF:
        begin
          { already CFF based — nothing left to convert }
          Dst.CopyFrom(Src, 0);
          Result := xffOTF;
        end;

      xffWOFF, xffWOFF2:
        begin
          Stage := TMemoryStream.Create;
          try
            if Fmt = xffWOFF then WOFFToOTF(Src, Stage)
                             else WOFF2ToOTF(Src, Stage);
            Stage.Position := 0;
            Inner := XelDetectFontFormat(Stage);

            if (AConvert = xfcOTF) and (Inner = xffTTF) then
            begin
              Stage.Position := 0;
              TTFToOTF(Stage, Dst);
              Result := xffOTF;
            end
            else
            begin
              Stage.Position := 0;
              Dst.CopyFrom(Stage, Stage.Size);
              if Inner = xffUnknown then Inner := xffTTF;
              Result := Inner;
            end;
          finally
            Stage.Free;
          end;
        end;

      xffSVG:
        begin
          { the SVG importer always produces a CFF OpenType font }
          SVGFontToOTF(Src, Dst);
          Result := xffOTF;
        end;
    else
      raise EXelFontError.CreateFmt(SUnsupported, [XelFontFormatNames[Fmt]]);
    end;
  except
    on E: EXelFontError do
      raise;
    on E: Exception do
      raise EXelFontError.CreateFmt(SConvertFailed,
        [XelFontFormatNames[Fmt], E.Message]);
  end;
end;

function XelFontFileToSfnt(const ASrcFile, ADstFile: String;
  AConvert: TXelFontConvert): TXelFontFormat;
var
  FIn, FOut: TFileStream;
begin
  FIn := TFileStream.Create(ASrcFile, fmOpenRead or fmShareDenyWrite);
  try
    FOut := TFileStream.Create(ADstFile, fmCreate);
    try
      Result := XelFontToSfnt(FIn, FOut, AConvert,
        XelDetectFontFormatFile(ASrcFile));
    finally
      FOut.Free;
    end;
  finally
    FIn.Free;
  end;
end;

end.
