unit XelFontTypes;

// XelFontManager — shared types, format sniffing and sfnt `name` table reading.
// Author: www.xelitan.com
// License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  EXelFontError = class(Exception);

  { Font container formats XelFontManager accepts. }
  TXelFontFormat = (
    xffUnknown,
    xffTTF,     // sfnt, glyf outlines  ($00010000 / 'true')
    xffOTF,     // sfnt, CFF outlines   ('OTTO')
    xffTTC,     // TrueType collection  ('ttcf')  — not supported
    xffWOFF,    // 'wOFF'
    xffWOFF2,   // 'wOF2'
    xffSVG      // SVG 1.1 <font>
  );

  { What the manager does with a font before handing it to the OS.

    xfcAuto  — convert only what has to be converted: WOFF and WOFF2 are
               unwrapped to their sfnt payload, SVG fonts are built into a
               CFF OpenType font, TTF and OTF are passed through untouched.
               This is the fastest and the most faithful option — hinting and
               all the original tables survive.

    xfcOTF   — additionally push glyf-based fonts through the CFF builder so
               everything ends up as a CFF OpenType font.  Outlines are
               converted from quadratic to cubic and hinting is dropped. }
  TXelFontConvert = (xfcAuto, xfcOTF);

  { How the font is handed to the operating system.

    xfrAuto      — same as xfrTempFile.
    xfrTempFile  — write the sfnt to a temporary file and register that file
                   privately.  Works everywhere and the font shows up in the
                   process' own font enumeration (font pickers see it).
    xfrMemory    — register straight from memory where the platform supports
                   it (Windows).  Nothing touches the disk, but the font is
                   not enumerable — it can only be used by name. }
  TXelFontRegisterMode = (xfrAuto, xfrTempFile, xfrMemory);

  { Names read out of the sfnt `name` table. }
  TXelFontNames = record
    Family     : String;   // nameID 1
    SubFamily  : String;   // nameID 2  ('Regular', 'Bold Italic', ...)
    Full       : String;   // nameID 4
    PostScript : String;   // nameID 6
  end;

const
  XelFontManagerVersion = '1.0';

  XelFontFormatNames: array[TXelFontFormat] of String = (
    'unknown', 'TrueType', 'OpenType (CFF)', 'TrueType Collection',
    'WOFF', 'WOFF2', 'SVG font');

  { Extensions recognised for each format, ';' separated. }
  XelFontFormatExts: array[TXelFontFormat] of String = (
    '', '.ttf', '.otf', '.ttc', '.woff', '.woff2', '.svg');

{ Sniff a font's container format from its first bytes.  The stream position
  is restored before returning. }
function XelDetectFontFormat(AStream: TStream): TXelFontFormat;
function XelDetectFontFormatFile(const AFileName: String): TXelFontFormat;
function XelFontFormatByExt(const AFileName: String): TXelFontFormat;

{ Read the `name` table of an sfnt font (TTF or OTF).  AStream must be
  positioned at the start of the font.  The position is restored.
  Returns False when the font carries no usable name table. }
function XelReadSfntNames(AStream: TStream; out ANames: TXelFontNames): Boolean;

{ File dialog filter covering every accepted format. }
function XelFontFilterString: String;

implementation

{ ---------------------------------------------------------------------------
  Big-endian readers — local copies so this unit stays independent of the
  converter units in .\types
  --------------------------------------------------------------------------- }

function RdU16(S: TStream): Word;
var
  B: array[0..1] of Byte;
begin
  S.ReadBuffer(B, 2);
  Result := (Word(B[0]) shl 8) or B[1];
end;

function RdU32(S: TStream): LongWord;
var
  B: array[0..3] of Byte;
begin
  S.ReadBuffer(B, 4);
  Result := (LongWord(B[0]) shl 24) or (LongWord(B[1]) shl 16) or
            (LongWord(B[2]) shl 8) or B[3];
end;

{ ---------------------------------------------------------------------------
  Detection
  --------------------------------------------------------------------------- }

function XelDetectFontFormat(AStream: TStream): TXelFontFormat;
var
  Buf     : array[0..255] of Byte;
  N       : LongInt;
  SavePos : Int64;
  Tag     : LongWord;
  I       : Integer;
  S       : String;
begin
  Result := xffUnknown;
  if AStream = nil then Exit;

  FillChar(Buf, SizeOf(Buf), 0);
  SavePos := AStream.Position;
  try
    N := AStream.Read(Buf, SizeOf(Buf));
  finally
    AStream.Position := SavePos;
  end;
  if N < 4 then Exit;

  Tag := (LongWord(Buf[0]) shl 24) or (LongWord(Buf[1]) shl 16) or
         (LongWord(Buf[2]) shl 8) or Buf[3];

  case Tag of
    $00010000 : Exit(xffTTF);
    $74727565 : Exit(xffTTF);    // 'true'
    $74797031 : Exit(xffTTF);    // 'typ1' — rare, treated as sfnt
    $4F54544F : Exit(xffOTF);    // 'OTTO'
    $74746366 : Exit(xffTTC);    // 'ttcf'
    $774F4646 : Exit(xffWOFF);   // 'wOFF'
    $774F4632 : Exit(xffWOFF2);  // 'wOF2'
  end;

  { SVG: look for a '<' near the start and an 'svg' or 'font' tag in the
    first block.  UTF-8 BOM and leading whitespace are tolerated. }
  SetLength(S, N);
  for I := 0 to N - 1 do S[I + 1] := AnsiChar(Buf[I]);
  S := LowerCase(S);
  if (Pos('<svg', S) > 0) or (Pos('<?xml', S) > 0) or (Pos('<font', S) > 0) then
    Result := xffSVG;
end;

function XelFontFormatByExt(const AFileName: String): TXelFontFormat;
var
  Ext: String;
  F  : TXelFontFormat;
begin
  Result := xffUnknown;
  Ext := LowerCase(ExtractFileExt(AFileName));
  if Ext = '' then Exit;
  for F := Low(TXelFontFormat) to High(TXelFontFormat) do
    if XelFontFormatExts[F] = Ext then Exit(F);
end;

function XelDetectFontFormatFile(const AFileName: String): TXelFontFormat;
var
  FS: TFileStream;
begin
  Result := xffUnknown;
  if not FileExists(AFileName) then Exit;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Result := XelDetectFontFormat(FS);
  finally
    FS.Free;
  end;
  if Result = xffUnknown then Result := XelFontFormatByExt(AFileName);
end;

{ ---------------------------------------------------------------------------
  name table
  --------------------------------------------------------------------------- }

type
  TNameRec = record
    PlatformID : Word;
    EncodingID : Word;
    LanguageID : Word;
    NameID     : Word;
    Len        : Word;
    Ofs        : Word;
  end;

{ Score a name record so the best available encoding wins:
  Windows/Unicode English first, then any Windows record, then Mac Roman. }
function ScoreOf(const R: TNameRec): Integer;
begin
  Result := 0;
  case R.PlatformID of
    3: begin                                  // Windows
         Result := 100;
         if R.LanguageID = $0409 then Inc(Result, 20);   // en-US
         if R.EncodingID in [1, 10] then Inc(Result, 5); // UCS-2 / UCS-4
       end;
    0: Result := 80;                          // Unicode
    1: begin                                  // Macintosh
         Result := 50;
         if R.LanguageID = 0 then Inc(Result, 10);
       end;
  end;
end;

function DecodeName(const ARaw: TBytes; const R: TNameRec): String;
var
  I  : Integer;
  W  : Word;
  U  : UnicodeString;
begin
  Result := '';
  if Length(ARaw) = 0 then Exit;

  if (R.PlatformID = 1) then
  begin
    { Mac Roman — ASCII range is all we need for font names }
    SetLength(Result, Length(ARaw));
    for I := 0 to High(ARaw) do Result[I + 1] := AnsiChar(ARaw[I]);
    Exit;
  end;

  { everything else is UTF-16BE }
  SetLength(U, Length(ARaw) div 2);
  for I := 0 to Length(U) - 1 do
  begin
    W := (Word(ARaw[I * 2]) shl 8) or ARaw[I * 2 + 1];
    U[I + 1] := WideChar(W);
  end;
  Result := UTF8Encode(U);
end;

function XelReadSfntNames(AStream: TStream; out ANames: TXelFontNames): Boolean;
var
  Base       : Int64;
  Tag        : LongWord;
  NumTables  : Word;
  I, J       : Integer;
  TblTag     : LongWord;
  TblOfs     : LongWord;
  TblLen     : LongWord;
  NameOfs    : LongWord;
  Count      : Word;
  StrOfs     : Word;
  Recs       : array of TNameRec;
  Best       : array[0..6] of Integer;   // best record index per nameID 0..6
  BestScore  : array[0..6] of Integer;
  Sc         : Integer;
  Raw        : TBytes;
  R          : TNameRec;

  function TakeName(AID: Integer): String;
  begin
    Result := '';
    if Best[AID] < 0 then Exit;
    R := Recs[Best[AID]];
    if R.Len = 0 then Exit;
    AStream.Position := Base + NameOfs + StrOfs + R.Ofs;
    SetLength(Raw, R.Len);
    if AStream.Read(Raw[0], R.Len) <> R.Len then Exit;
    Result := DecodeName(Raw, R);
  end;

begin
  Result := False;
  ANames.Family     := '';
  ANames.SubFamily  := '';
  ANames.Full       := '';
  ANames.PostScript := '';

  Base := AStream.Position;
  try
    try
      Tag := RdU32(AStream);
      if (Tag <> $00010000) and (Tag <> $74727565) and
         (Tag <> $74797031) and (Tag <> $4F54544F) then Exit;

      NumTables := RdU16(AStream);
      AStream.Seek(6, soCurrent);          // searchRange, entrySelector, rangeShift

      NameOfs := 0;
      TblLen  := 0;
      for I := 0 to NumTables - 1 do
      begin
        TblTag := RdU32(AStream);
        RdU32(AStream);                    // checksum
        TblOfs := RdU32(AStream);
        TblLen := RdU32(AStream);
        if TblTag = $6E616D65 then         // 'name'
        begin
          NameOfs := TblOfs;
          Break;
        end;
      end;
      if NameOfs = 0 then Exit;

      AStream.Position := Base + NameOfs;
      RdU16(AStream);                      // format
      Count  := RdU16(AStream);
      StrOfs := RdU16(AStream);
      if Count = 0 then Exit;

      SetLength(Recs, Count);
      for I := 0 to Count - 1 do
      begin
        Recs[I].PlatformID := RdU16(AStream);
        Recs[I].EncodingID := RdU16(AStream);
        Recs[I].LanguageID := RdU16(AStream);
        Recs[I].NameID     := RdU16(AStream);
        Recs[I].Len        := RdU16(AStream);
        Recs[I].Ofs        := RdU16(AStream);
      end;

      for J := 0 to High(Best) do
      begin
        Best[J]      := -1;
        BestScore[J] := -1;
      end;

      for I := 0 to Count - 1 do
        if Recs[I].NameID <= High(Best) then
        begin
          Sc := ScoreOf(Recs[I]);
          if Sc > BestScore[Recs[I].NameID] then
          begin
            BestScore[Recs[I].NameID] := Sc;
            Best[Recs[I].NameID]      := I;
          end;
        end;

      ANames.Family     := TakeName(1);
      ANames.SubFamily  := TakeName(2);
      ANames.Full       := TakeName(4);
      ANames.PostScript := TakeName(6);

      Result := ANames.Family <> '';
    except
      Result := False;
    end;
  finally
    AStream.Position := Base;
  end;
end;

function XelFontFilterString: String;
begin
  Result :=
    'All fonts (*.ttf;*.otf;*.woff;*.woff2;*.svg)|*.ttf;*.otf;*.woff;*.woff2;*.svg|' +
    'TrueType (*.ttf)|*.ttf|' +
    'OpenType (*.otf)|*.otf|' +
    'WOFF (*.woff)|*.woff|' +
    'WOFF2 (*.woff2)|*.woff2|' +
    'SVG fonts (*.svg)|*.svg|' +
    'All files (*.*)|*.*';
end;

end.
