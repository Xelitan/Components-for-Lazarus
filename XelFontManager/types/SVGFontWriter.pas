unit SVGFontWriter;

{$mode objfpc}{$H+}
{$WARN 5093 off}
interface
uses Classes, SysUtils, FontTypes, TTFParser;

// Author: www.xelitan.com
// License: MIT
//
// OTF/TTF -> SVG font converter.
//
// Produces an SVG 1.1 <font> element (inside <defs>) with:
//   <font-face>      metrics (units-per-em, ascent, descent)
//   <missing-glyph>  outline of glyph 0
//   <glyph>          one per cmap-mapped code point (unicode + advance + path)
//
// Outlines are emitted in the font's native coordinate system (Y up), which
// is exactly what SVG fonts expect, so no Y flip is applied.
//
// Supports both flavors of input:
//   * CFF-based OpenType (OTTO)  -> a full Type 2 charstring interpreter
//   * TrueType / glyf            -> reuses TTFParser (quadratic -> cubic)

procedure OTFToSVGFont(Src, Dst : TStream);

implementation

type
  TBytesArray = array of TBytes;
  TStrArr     = array of string;

// ================================================================
// Big-endian readers over a TBytes (bounds-checked, return 0 if OOB)
// ================================================================

function BU16(const D : TBytes; O : Integer) : Word;
begin
  if (O < 0) or (O + 1 >= Length(D)) then Exit(0);
  Result := (Word(D[O]) shl 8) or D[O + 1];
end;

function BS16(const D : TBytes; O : Integer) : SmallInt;
begin
  Result := SmallInt(BU16(D, O));
end;

function BU32(const D : TBytes; O : Integer) : LongWord;
begin
  if (O < 0) or (O + 3 >= Length(D)) then Exit(0);
  Result := (LongWord(D[O]) shl 24) or (LongWord(D[O + 1]) shl 16) or
            (LongWord(D[O + 2]) shl  8) or  LongWord(D[O + 3]);
end;

procedure WS(St : TStream; const S : string); inline;
begin
  if S <> '' then St.WriteBuffer(S[1], Length(S));
end;

function StreamToStr(St : TMemoryStream) : string;
begin
  SetLength(Result, St.Size);
  if St.Size > 0 then Move(St.Memory^, Result[1], St.Size);
end;

// Coordinate formatting: font coordinates are integral in practice; round.
function NS(V : Double) : string; inline;
begin
  Result := IntToStr(Round(V));
end;

// ================================================================
// sfnt table directory (works for any flavor: OTTO / 0x00010000 / 'true')
// ================================================================

type
  TTableRec = record Tag : LongWord; Data : TBytes; end;
  TTableArr = array of TTableRec;

function ReadTableDir(const Font : TBytes) : TTableArr;
var
  NumTables, I, EOfs : Integer;
  Off, Len : LongWord;
begin
  NumTables := BU16(Font, 4);
  SetLength(Result, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    EOfs := 12 + I * 16;
    Result[I].Tag := BU32(Font, EOfs);
    Off := BU32(Font, EOfs + 8);
    Len := BU32(Font, EOfs + 12);
    SetLength(Result[I].Data, Len);
    if (Len > 0) and (Off + Len <= LongWord(Length(Font))) then
      Move(Font[Off], Result[I].Data[0], Len);
  end;
end;

function GetTable(const Tabs : TTableArr; Tag : LongWord) : TBytes;
var I : Integer;
begin
  for I := 0 to High(Tabs) do
    if Tabs[I].Tag = Tag then Exit(Tabs[I].Data);
  Result := nil;
end;

// ================================================================
// name table: extract a usable font family / PostScript name
// ================================================================

function SanitizeName(const S : string) : string;
var I : Integer; C : Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_') then
      Result := Result + C;
  end;
end;

function ExtractFontName(const NameData : TBytes) : string;
var
  Count, StrOfs, J, Base : Integer;
  Plat, NID, SLen, SOfs, K : Integer;
  Raw, Decoded, BestPS, BestFam : string;
begin
  BestPS := ''; BestFam := '';
  if Length(NameData) >= 6 then
  begin
    Count  := BU16(NameData, 2);
    StrOfs := BU16(NameData, 4);
    for J := 0 to Count - 1 do
    begin
      Base := 6 + J * 12;
      Plat := BU16(NameData, Base);
      NID  := BU16(NameData, Base + 6);
      SLen := BU16(NameData, Base + 8);
      SOfs := BU16(NameData, Base + 10);
      if ((NID = 1) or (NID = 6)) and (SLen > 0) then
      begin
        SetLength(Raw, SLen);
        if StrOfs + SOfs + SLen <= Length(NameData) then
        begin
          Move(NameData[StrOfs + SOfs], Raw[1], SLen);
          if Plat = 3 then
          begin
            // UTF-16BE: take the low byte of each unit (ASCII subset)
            Decoded := '';
            K := 2;
            while K <= SLen do begin Decoded := Decoded + Raw[K]; Inc(K, 2); end;
          end
          else
            Decoded := Raw;  // Mac/other: treat as ASCII
          Decoded := SanitizeName(Decoded);
          if (NID = 6) and (BestPS = '')  then BestPS  := Decoded;
          if (NID = 1) and (BestFam = '') then BestFam := Decoded;
        end;
      end;
    end;
  end;
  if      BestPS  <> '' then Result := BestPS
  else if BestFam <> '' then Result := BestFam
  else                       Result := 'ConvertedFont';
end;

// ================================================================
// cmap parser -> sorted (codepoint -> glyph id) pairs
// ================================================================

type
  TCmapPair = record CP : LongWord; GID : Word; end;
  TCmapArr  = array of TCmapPair;

procedure CmapAppend(var Arr : TCmapArr; var Count : Integer; CP : LongWord; GID : Word);
begin
  if (GID = 0) or (CP > $10FFFF) then Exit;
  if Count >= Length(Arr) then SetLength(Arr, (Count + 1) * 2);
  Arr[Count].CP := CP; Arr[Count].GID := GID; Inc(Count);
end;

function ParseCmap(const C : TBytes) : TCmapArr;
var
  NumSub, I, Base, Rank, BestRank, BestOfs : Integer;
  Plat, Enc : Integer;
  Fmt : Integer;
  Count : Integer;

  // format 4 locals
  SegX2, SegCount, S : Integer;
  EndO, StartO, DeltaO, RangeO : Integer;
  EndC, StartC, RO, GidOfs : Integer;
  Delta, G, CP : Integer;

  // format 6/0 locals
  First, ECount, Idx : Integer;

  // format 12 locals
  NGroups, GOfs, Gi : Integer;
  SC, EC, SG, Cc : LongWord;
begin
  Count := 0;
  SetLength(Result, 0);
  if Length(C) < 4 then Exit;

  NumSub := BU16(C, 2);
  BestRank := -1; BestOfs := -1;
  for I := 0 to NumSub - 1 do
  begin
    Base := 4 + I * 8;
    Plat := BU16(C, Base);
    Enc  := BU16(C, Base + 2);
    // Prefer full-unicode, then BMP unicode, then symbol/mac
    Rank := 0;
    if      (Plat = 3) and (Enc = 10) then Rank := 6
    else if (Plat = 0) and (Enc >= 4) then Rank := 5
    else if (Plat = 3) and (Enc = 1)  then Rank := 4
    else if (Plat = 0)                then Rank := 3
    else if (Plat = 3) and (Enc = 0)  then Rank := 2
    else                                   Rank := 1;
    if Rank > BestRank then
    begin
      BestRank := Rank;
      BestOfs  := Integer(BU32(C, Base + 4));
    end;
  end;
  if BestOfs < 0 then Exit;

  Fmt := BU16(C, BestOfs);
  case Fmt of
    0:
      for CP := 0 to 255 do
        CmapAppend(Result, Count, LongWord(CP), C[BestOfs + 6 + CP]);

    4:
      begin
        SegX2    := BU16(C, BestOfs + 6);
        SegCount := SegX2 div 2;
        EndO     := BestOfs + 14;
        StartO   := EndO + SegX2 + 2;
        DeltaO   := StartO + SegX2;
        RangeO   := DeltaO + SegX2;
        for S := 0 to SegCount - 1 do
        begin
          EndC   := BU16(C, EndO   + 2 * S);
          StartC := BU16(C, StartO + 2 * S);
          Delta  := BS16(C, DeltaO + 2 * S);
          RO     := BU16(C, RangeO + 2 * S);
          if StartC > EndC then Continue;
          for CP := StartC to EndC do
          begin
            if CP = $FFFF then Continue;
            if RO = 0 then
              G := (CP + Delta) and $FFFF
            else
            begin
              GidOfs := RangeO + 2 * S + RO + 2 * (CP - StartC);
              G := BU16(C, GidOfs);
              if G <> 0 then G := (G + Delta) and $FFFF;
            end;
            CmapAppend(Result, Count, LongWord(CP), Word(G));
          end;
        end;
      end;

    6:
      begin
        First  := BU16(C, BestOfs + 6);
        ECount := BU16(C, BestOfs + 8);
        for Idx := 0 to ECount - 1 do
          CmapAppend(Result, Count, LongWord(First + Idx),
                     BU16(C, BestOfs + 10 + 2 * Idx));
      end;

    12:
      begin
        NGroups := Integer(BU32(C, BestOfs + 12));
        GOfs := BestOfs + 16;
        for Gi := 0 to NGroups - 1 do
        begin
          SC := BU32(C, GOfs);
          EC := BU32(C, GOfs + 4);
          SG := BU32(C, GOfs + 8);
          Inc(GOfs, 12);
          if EC > SC + 65535 then EC := SC + 65535;  // sanity clamp
          Cc := SC;
          while Cc <= EC do
          begin
            CmapAppend(Result, Count, Cc, Word((SG + (Cc - SC)) and $FFFF));
            Inc(Cc);
          end;
        end;
      end;
  end;

  SetLength(Result, Count);
end;

// ================================================================
// CFF DICT parsing
// ================================================================

type
  TDictEntry = record Op : Integer; Args : array of Double; end;
  TDictArr   = array of TDictEntry;

function ReadCFFIndex(const C : TBytes; var Pos : Integer) : TBytesArray;
var
  Count, OffSize, I, K : Integer;
  Offs : array of LongWord;
  Off  : LongWord;
  DataBase : Integer;
begin
  SetLength(Result, 0);
  if Pos + 2 > Length(C) then Exit;
  Count := (Integer(C[Pos]) shl 8) or C[Pos + 1];
  Inc(Pos, 2);
  if Count = 0 then Exit;
  OffSize := C[Pos]; Inc(Pos);
  SetLength(Offs, Count + 1);
  for I := 0 to Count do
  begin
    Off := 0;
    for K := 0 to OffSize - 1 do
      Off := (Off shl 8) or C[Pos + I * OffSize + K];
    Offs[I] := Off;
  end;
  Inc(Pos, (Count + 1) * OffSize);
  DataBase := Pos - 1;  // INDEX offsets are 1-based
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    SetLength(Result[I], Offs[I + 1] - Offs[I]);
    if Offs[I + 1] > Offs[I] then
      Move(C[DataBase + Offs[I]], Result[I][0], Offs[I + 1] - Offs[I]);
  end;
  Pos := DataBase + Integer(Offs[Count]);
end;

function ParseCFFDict(const D : TBytes) : TDictArr;
var
  I, N, Cnt : Integer;
  Args : array of Double;
  B, B2 : Byte;
  V : Double;
  IsInt : LongInt;
  Sb : string;
  Nib, K : Integer;
  FS : TFormatSettings;

  procedure PushArg(X : Double);
  begin
    if N >= Length(Args) then SetLength(Args, N + 8);
    Args[N] := X; Inc(N);
  end;

  procedure EmitOp(Op : Integer);
  var J : Integer;
  begin
    Cnt := Length(Result);
    SetLength(Result, Cnt + 1);
    Result[Cnt].Op := Op;
    SetLength(Result[Cnt].Args, N);
    for J := 0 to N - 1 do Result[Cnt].Args[J] := Args[J];
    N := 0;
  end;

begin
  SetLength(Result, 0);
  SetLength(Args, 8);
  N := 0;
  I := 0;
  while I < Length(D) do
  begin
    B := D[I];
    if B >= 32 then
    begin
      if B <= 246 then begin PushArg(Integer(B) - 139); Inc(I); end
      else if B <= 250 then
        begin PushArg((Integer(B) - 247) * 256 + D[I + 1] + 108); Inc(I, 2); end
      else if B <= 254 then
        begin PushArg(-(Integer(B) - 251) * 256 - D[I + 1] - 108); Inc(I, 2); end
      else { 255 } begin
        IsInt := LongInt((LongWord(D[I+1]) shl 24) or (LongWord(D[I+2]) shl 16) or
                         (LongWord(D[I+3]) shl 8) or D[I+4]);
        PushArg(IsInt / 65536.0); Inc(I, 5);
      end;
    end
    else if B = 28 then
      begin PushArg(SmallInt((Word(D[I+1]) shl 8) or D[I+2])); Inc(I, 3); end
    else if B = 29 then
      begin
        PushArg(LongInt((LongWord(D[I+1]) shl 24) or (LongWord(D[I+2]) shl 16) or
                        (LongWord(D[I+3]) shl 8) or D[I+4])); Inc(I, 5);
      end
    else if B = 30 then
    begin
      // Real number: packed BCD nibbles, terminated by nibble 0xF
      Inc(I);
      Sb := '';
      while I < Length(D) do
      begin
        for K := 0 to 1 do
        begin
          if K = 0 then Nib := D[I] shr 4 else Nib := D[I] and $0F;
          case Nib of
            0..9: Sb := Sb + Chr(Ord('0') + Nib);
            $A:  Sb := Sb + '.';
            $B:  Sb := Sb + 'E';
            $C:  Sb := Sb + 'E-';
            $E:  Sb := Sb + '-';
            $F:  ; // end marker handled below
          end;
        end;
        if (D[I] and $0F) = $F then begin Inc(I); Break; end;
        Inc(I);
      end;
      V := 0;
      if Sb <> '' then
      begin
        FS.DecimalSeparator := '.';
        FS.ThousandSeparator := #0;
        try V := StrToFloat(Sb, FS); except V := 0; end;
      end;
      PushArg(V);
    end
    else
    begin
      // Operator
      if B = 12 then begin B2 := D[I + 1]; Inc(I, 2); EmitOp(1200 + B2); end
      else begin Inc(I); EmitOp(B); end;
    end;
  end;
end;

function FindDict(const Dict : TDictArr; Op : Integer; out E : TDictEntry) : Boolean;
var I : Integer;
begin
  for I := High(Dict) downto 0 do
    if Dict[I].Op = Op then begin E := Dict[I]; Exit(True); end;
  Result := False;
end;

function DictInt(const Dict : TDictArr; Op, ArgIdx, Default : Integer) : Integer;
var E : TDictEntry;
begin
  if FindDict(Dict, Op, E) and (ArgIdx < Length(E.Args)) then
    Result := Round(E.Args[ArgIdx])
  else
    Result := Default;
end;

// ================================================================
// Type 2 charstring interpreter -> SVG path 'd'
// ================================================================

function SubrBias(N : Integer) : Integer;
begin
  if      N < 1240  then Result := 107
  else if N < 33900 then Result := 1131
  else                   Result := 32768;
end;

function RunCharString(const CharStr : TBytes;
                       const LocalSubrs, GlobalSubrs : TBytesArray) : string;
var
  PB    : TMemoryStream;
  St    : array[0..63] of Double;
  SP    : Integer;
  CX, CY: Double;
  NStems: Integer;
  HaveWidth, Open, Done : Boolean;
  LBias, GBias : Integer;

  procedure ClearStack; inline; begin SP := 0; end;
  procedure Push(V : Double); inline; begin if SP < 64 then begin St[SP] := V; Inc(SP); end; end;
  procedure RemoveBottom;
  var K : Integer;
  begin
    if SP > 0 then
    begin
      for K := 1 to SP - 1 do St[K - 1] := St[K];
      Dec(SP);
    end;
  end;

  procedure DoMove(NX, NY : Double);
  begin
    if Open then WS(PB, 'Z ');
    WS(PB, 'M' + NS(NX) + ' ' + NS(NY) + ' ');
    CX := NX; CY := NY; Open := True;
  end;
  procedure DoLine(NX, NY : Double);
  begin
    WS(PB, 'L' + NS(NX) + ' ' + NS(NY) + ' ');
    CX := NX; CY := NY;
  end;
  procedure DoCurve(X1, Y1, X2, Y2, X3, Y3 : Double);
  begin
    WS(PB, 'C' + NS(X1) + ' ' + NS(Y1) + ' ' + NS(X2) + ' ' + NS(Y2) + ' '
               + NS(X3) + ' ' + NS(Y3) + ' ');
    CX := X3; CY := Y3;
  end;

  procedure Exec(const Code : TBytes);
  var
    I, J, N, B2, Idx, Rem : Integer;
    B : Byte;
    X1, Y1, X2, Y2, X3, Y3, X4, Y4, X5, Y5, X6, Y6 : Double;
    D1, D2, D6, SX, SY, DSumX, DSumY : Double;
    Horiz : Boolean;
  begin
    I := 0;
    while (I < Length(Code)) and (not Done) do
    begin
      B := Code[I];
      if B >= 32 then
      begin
        if B <= 246 then begin Push(Integer(B) - 139); Inc(I); end
        else if B <= 250 then begin Push((Integer(B)-247)*256 + Code[I+1] + 108); Inc(I,2); end
        else if B <= 254 then begin Push(-(Integer(B)-251)*256 - Code[I+1] - 108); Inc(I,2); end
        else begin
          Push(LongInt((LongWord(Code[I+1]) shl 24) or (LongWord(Code[I+2]) shl 16) or
                       (LongWord(Code[I+3]) shl 8) or Code[I+4]) / 65536.0);
          Inc(I, 5);
        end;
        Continue;
      end;
      if B = 28 then
      begin
        Push(SmallInt((Word(Code[I+1]) shl 8) or Code[I+2])); Inc(I, 3); Continue;
      end;

      // Operator
      Inc(I);
      case B of
        1, 3, 18, 23:  // hstem vstem hstemhm vstemhm
          begin
            if (not HaveWidth) and ((SP and 1) = 1) then RemoveBottom;
            NStems := NStems + (SP div 2);
            HaveWidth := True; ClearStack;
          end;

        19, 20:  // hintmask cntrmask
          begin
            if (not HaveWidth) and ((SP and 1) = 1) then RemoveBottom;
            NStems := NStems + (SP div 2);
            HaveWidth := True; ClearStack;
            Inc(I, (NStems + 7) div 8);  // skip mask bytes
          end;

        21:  // rmoveto
          begin
            if (not HaveWidth) and (SP > 2) then RemoveBottom;
            HaveWidth := True;
            DoMove(CX + St[0], CY + St[1]); ClearStack;
          end;
        22:  // hmoveto
          begin
            if (not HaveWidth) and (SP > 1) then RemoveBottom;
            HaveWidth := True;
            DoMove(CX + St[0], CY); ClearStack;
          end;
        4:   // vmoveto
          begin
            if (not HaveWidth) and (SP > 1) then RemoveBottom;
            HaveWidth := True;
            DoMove(CX, CY + St[0]); ClearStack;
          end;

        5:   // rlineto
          begin
            J := 0;
            while J + 1 <= SP - 1 do
            begin DoLine(CX + St[J], CY + St[J+1]); Inc(J, 2); end;
            ClearStack;
          end;
        6, 7:  // hlineto / vlineto
          begin
            Horiz := (B = 6);
            J := 0;
            while J < SP do
            begin
              if Horiz then DoLine(CX + St[J], CY) else DoLine(CX, CY + St[J]);
              Horiz := not Horiz; Inc(J);
            end;
            ClearStack;
          end;

        8:   // rrcurveto
          begin
            J := 0;
            while J + 5 <= SP - 1 do
            begin
              X1 := CX + St[J];   Y1 := CY + St[J+1];
              X2 := X1 + St[J+2]; Y2 := Y1 + St[J+3];
              X3 := X2 + St[J+4]; Y3 := Y2 + St[J+5];
              DoCurve(X1, Y1, X2, Y2, X3, Y3); Inc(J, 6);
            end;
            ClearStack;
          end;
        24:  // rcurveline
          begin
            N := (SP - 2) div 6; J := 0;
            while N > 0 do
            begin
              X1 := CX + St[J];   Y1 := CY + St[J+1];
              X2 := X1 + St[J+2]; Y2 := Y1 + St[J+3];
              X3 := X2 + St[J+4]; Y3 := Y2 + St[J+5];
              DoCurve(X1, Y1, X2, Y2, X3, Y3); Inc(J, 6); Dec(N);
            end;
            if J + 1 <= SP - 1 then DoLine(CX + St[J], CY + St[J+1]);
            ClearStack;
          end;
        25:  // rlinecurve
          begin
            N := (SP - 6) div 2; J := 0;
            while N > 0 do
            begin DoLine(CX + St[J], CY + St[J+1]); Inc(J, 2); Dec(N); end;
            if J + 5 <= SP - 1 then
            begin
              X1 := CX + St[J];   Y1 := CY + St[J+1];
              X2 := X1 + St[J+2]; Y2 := Y1 + St[J+3];
              X3 := X2 + St[J+4]; Y3 := Y2 + St[J+5];
              DoCurve(X1, Y1, X2, Y2, X3, Y3);
            end;
            ClearStack;
          end;
        26:  // vvcurveto
          begin
            J := 0; D1 := 0;
            if (SP and 1) = 1 then begin D1 := St[0]; J := 1; end;
            while J + 3 <= SP - 1 do
            begin
              X1 := CX + D1;      Y1 := CY + St[J];
              X2 := X1 + St[J+1]; Y2 := Y1 + St[J+2];
              X3 := X2;           Y3 := Y2 + St[J+3];
              DoCurve(X1, Y1, X2, Y2, X3, Y3); D1 := 0; Inc(J, 4);
            end;
            ClearStack;
          end;
        27:  // hhcurveto
          begin
            J := 0; D1 := 0;
            if (SP and 1) = 1 then begin D1 := St[0]; J := 1; end;
            while J + 3 <= SP - 1 do
            begin
              X1 := CX + St[J];   Y1 := CY + D1;
              X2 := X1 + St[J+1]; Y2 := Y1 + St[J+2];
              X3 := X2 + St[J+3]; Y3 := Y2;
              DoCurve(X1, Y1, X2, Y2, X3, Y3); D1 := 0; Inc(J, 4);
            end;
            ClearStack;
          end;
        30, 31:  // vhcurveto / hvcurveto
          begin
            Horiz := (B = 31);
            J := 0;
            while (SP - J) >= 4 do
            begin
              Rem := SP - J;
              if Horiz then
              begin
                X1 := CX + St[J];   Y1 := CY;
                X2 := X1 + St[J+1]; Y2 := Y1 + St[J+2];
                Y3 := Y2 + St[J+3];
                if Rem = 5 then X3 := X2 + St[J+4] else X3 := X2;
              end
              else
              begin
                X1 := CX;           Y1 := CY + St[J];
                X2 := X1 + St[J+1]; Y2 := Y1 + St[J+2];
                X3 := X2 + St[J+3];
                if Rem = 5 then Y3 := Y2 + St[J+4] else Y3 := Y2;
              end;
              DoCurve(X1, Y1, X2, Y2, X3, Y3);
              Horiz := not Horiz; Inc(J, 4);
            end;
            ClearStack;
          end;

        10:  // callsubr
          begin
            if SP > 0 then
            begin
              Idx := Round(St[SP-1]) + LBias; Dec(SP);
              if (Idx >= 0) and (Idx < Length(LocalSubrs)) then Exec(LocalSubrs[Idx]);
            end;
          end;
        29:  // callgsubr
          begin
            if SP > 0 then
            begin
              Idx := Round(St[SP-1]) + GBias; Dec(SP);
              if (Idx >= 0) and (Idx < Length(GlobalSubrs)) then Exec(GlobalSubrs[Idx]);
            end;
          end;
        11:  // return
          Exit;

        14:  // endchar
          begin
            if (not HaveWidth) and (SP > 0) and (SP <> 4) then RemoveBottom;
            HaveWidth := True;
            if Open then WS(PB, 'Z ');
            Done := True; Exit;
          end;

        12:  // escape
          begin
            B2 := Code[I];          // escape operand (I already advanced past the 12)
            Inc(I);
            case B2 of
              34:  // hflex
                begin
                  D2 := St[2];
                  X1 := CX + St[0]; Y1 := CY;
                  X2 := X1 + St[1]; Y2 := Y1 + D2;
                  X3 := X2 + St[3]; Y3 := Y2;
                  DoCurve(X1, Y1, X2, Y2, X3, Y3);
                  X4 := CX + St[4]; Y4 := CY;
                  X5 := X4 + St[5]; Y5 := CY - D2;
                  X6 := X5 + St[6]; Y6 := CY - D2;
                  DoCurve(X4, Y4, X5, Y5, X6, Y6);
                  ClearStack;
                end;
              35:  // flex
                begin
                  X1 := CX + St[0]; Y1 := CY + St[1];
                  X2 := X1 + St[2]; Y2 := Y1 + St[3];
                  X3 := X2 + St[4]; Y3 := Y2 + St[5];
                  DoCurve(X1, Y1, X2, Y2, X3, Y3);
                  X4 := CX + St[6]; Y4 := CY + St[7];
                  X5 := X4 + St[8]; Y5 := Y4 + St[9];
                  X6 := X5 + St[10];Y6 := Y5 + St[11];
                  DoCurve(X4, Y4, X5, Y5, X6, Y6);
                  ClearStack;
                end;
              36:  // hflex1
                begin
                  SY := CY;
                  X1 := CX + St[0]; Y1 := CY + St[1];
                  X2 := X1 + St[2]; Y2 := Y1 + St[3];
                  X3 := X2 + St[4]; Y3 := Y2;
                  DoCurve(X1, Y1, X2, Y2, X3, Y3);
                  X4 := CX + St[5]; Y4 := CY;
                  X5 := X4 + St[6]; Y5 := CY + St[7];
                  X6 := X5 + St[8]; Y6 := SY;
                  DoCurve(X4, Y4, X5, Y5, X6, Y6);
                  ClearStack;
                end;
              37:  // flex1
                begin
                  SX := CX; SY := CY;
                  DSumX := St[0] + St[2] + St[4] + St[6] + St[8];
                  DSumY := St[1] + St[3] + St[5] + St[7] + St[9];
                  X1 := CX + St[0]; Y1 := CY + St[1];
                  X2 := X1 + St[2]; Y2 := Y1 + St[3];
                  X3 := X2 + St[4]; Y3 := Y2 + St[5];
                  DoCurve(X1, Y1, X2, Y2, X3, Y3);
                  X4 := CX + St[6]; Y4 := CY + St[7];
                  X5 := X4 + St[8]; Y5 := Y4 + St[9];
                  D6 := St[10];
                  if Abs(DSumX) > Abs(DSumY) then
                  begin X6 := X5 + D6; Y6 := SY; end
                  else
                  begin X6 := SX; Y6 := Y5 + D6; end;
                  DoCurve(X4, Y4, X5, Y5, X6, Y6);
                  ClearStack;
                end;
            else
              ClearStack;  // dotsection / unsupported: ignore operands
            end;
          end;
      else
        ClearStack;  // unknown operator: drop operands defensively
      end;
    end;
  end;

begin
  PB := TMemoryStream.Create;
  try
    SP := 0; CX := 0; CY := 0; NStems := 0;
    HaveWidth := False; Open := False; Done := False;
    LBias := SubrBias(Length(LocalSubrs));
    GBias := SubrBias(Length(GlobalSubrs));
    Exec(CharStr);
    if Open and (not Done) then WS(PB, 'Z ');
    Result := Trim(StreamToStr(PB));
  finally
    PB.Free;
  end;
end;

// ================================================================
// CFF outline extraction (handles non-CID and CID fonts)
// ================================================================

procedure ParseCFFOutlines(const Cff : TBytes; out Paths : TStrArr);
var
  Pos, I, G : Integer;
  HdrSize : Integer;
  NameIdx, TopIdx, StrIdx, GlobalSubrs, CharStrings : TBytesArray;
  TopDict, PrivDict : TDictArr;
  CSOff, PrivOff, PrivSize, SubrsRel : Integer;
  LocalSubrs : TBytesArray;

  // CID
  IsCID : Boolean;
  E : TDictEntry;
  FDArrayOff, FDSelectOff : Integer;
  FDArrayIdx : TBytesArray;
  FDLocal : array of TBytesArray;     // local subrs per font dict
  GlyphFD : array of Integer;         // fd index per glyph
  NumGlyphs : Integer;

  procedure LoadLocalSubrs(const FontDict : TDictArr; out LS : TBytesArray);
  var PD : TDictArr; PO, PS, SR, P2 : Integer; PE : TDictEntry;
  begin
    SetLength(LS, 0);
    if FindDict(FontDict, 18, PE) and (Length(PE.Args) >= 2) then
    begin
      PS := Round(PE.Args[0]); PO := Round(PE.Args[1]);
      if (PO > 0) and (PO + PS <= Length(Cff)) then
      begin
        PD := ParseCFFDict(Copy(Cff, PO, PS));
        if FindDict(PD, 19, PE) and (Length(PE.Args) >= 1) then
        begin
          SR := Round(PE.Args[0]);
          P2 := PO + SR;
          if (P2 > 0) and (P2 < Length(Cff)) then LS := ReadCFFIndex(Cff, P2);
        end;
      end;
    end;
  end;

  procedure ParseFDSelect;
  var Fmt, NRanges, R, First, Next, FD, Gi : Integer;
  begin
    SetLength(GlyphFD, NumGlyphs);
    for Gi := 0 to NumGlyphs - 1 do GlyphFD[Gi] := 0;
    if (FDSelectOff <= 0) or (FDSelectOff >= Length(Cff)) then Exit;
    Fmt := Cff[FDSelectOff];
    if Fmt = 0 then
    begin
      for Gi := 0 to NumGlyphs - 1 do
        if FDSelectOff + 1 + Gi < Length(Cff) then
          GlyphFD[Gi] := Cff[FDSelectOff + 1 + Gi];
    end
    else if Fmt = 3 then
    begin
      NRanges := BU16(Cff, FDSelectOff + 1);
      for R := 0 to NRanges - 1 do
      begin
        First := BU16(Cff, FDSelectOff + 3 + R * 3);
        FD    := Cff[FDSelectOff + 3 + R * 3 + 2];
        Next  := BU16(Cff, FDSelectOff + 3 + (R + 1) * 3);
        for Gi := First to Next - 1 do
          if (Gi >= 0) and (Gi < NumGlyphs) then GlyphFD[Gi] := FD;
      end;
    end;
  end;

begin
  SetLength(Paths, 0);
  if Length(Cff) < 4 then Exit;

  HdrSize := Cff[2];
  Pos := HdrSize;
  NameIdx     := ReadCFFIndex(Cff, Pos);
  TopIdx      := ReadCFFIndex(Cff, Pos);
  StrIdx      := ReadCFFIndex(Cff, Pos);
  GlobalSubrs := ReadCFFIndex(Cff, Pos);
  if Length(TopIdx) = 0 then Exit;

  TopDict := ParseCFFDict(TopIdx[0]);

  CSOff := DictInt(TopDict, 17, 0, 0);  // CharStrings
  if CSOff <= 0 then Exit;
  Pos := CSOff;
  CharStrings := ReadCFFIndex(Cff, Pos);
  NumGlyphs := Length(CharStrings);

  IsCID := FindDict(TopDict, 1230, E);  // ROS operator => CIDFont

  if not IsCID then
  begin
    // Single Private DICT / Local Subrs
    SetLength(FDLocal, 1);
    LoadLocalSubrs(TopDict, LocalSubrs);
    FDLocal[0] := LocalSubrs;
    SetLength(GlyphFD, NumGlyphs);
    for I := 0 to NumGlyphs - 1 do GlyphFD[I] := 0;
  end
  else
  begin
    FDArrayOff  := DictInt(TopDict, 1236, 0, 0);  // FDArray
    FDSelectOff := DictInt(TopDict, 1237, 0, 0);  // FDSelect
    if FDArrayOff > 0 then
    begin
      Pos := FDArrayOff;
      FDArrayIdx := ReadCFFIndex(Cff, Pos);
    end;
    SetLength(FDLocal, Length(FDArrayIdx));
    for I := 0 to High(FDArrayIdx) do
      LoadLocalSubrs(ParseCFFDict(FDArrayIdx[I]), FDLocal[I]);
    if Length(FDLocal) = 0 then SetLength(FDLocal, 1);
    ParseFDSelect;
  end;

  SetLength(Paths, NumGlyphs);
  for G := 0 to NumGlyphs - 1 do
  begin
    I := 0;
    if (G < Length(GlyphFD)) then I := GlyphFD[G];
    if (I < 0) or (I >= Length(FDLocal)) then I := 0;
    Paths[G] := RunCharString(CharStrings[G], FDLocal[I], GlobalSubrs);
  end;

  // touch unused locals to avoid hints
  if (Length(NameIdx) < 0) or (Length(StrIdx) < 0) then ;
  PrivDict := nil; PrivOff := 0; PrivSize := 0; SubrsRel := 0;
  if (PrivOff <> 0) or (PrivSize <> 0) or (SubrsRel <> 0) or (Length(PrivDict) < 0) then ;
end;

// ================================================================
// glyf outline -> SVG path (from TTFParser cubic contours)
// ================================================================

function ContourPath(const GD : TGlyphData) : string;
var
  PB : TMemoryStream;
  CI, PI, L : Integer;
  C  : TCubicContour;
begin
  PB := TMemoryStream.Create;
  try
    if not (GD.IsEmpty) then
      for CI := 0 to High(GD.Contours) do
      begin
        C := GD.Contours[CI];
        L := Length(C);
        if L = 0 then Continue;
        WS(PB, 'M' + NS(C[0].X) + ' ' + NS(C[0].Y) + ' ');
        PI := 1;
        while PI < L do
        begin
          if C[PI].OnCurve then
          begin
            WS(PB, 'L' + NS(C[PI].X) + ' ' + NS(C[PI].Y) + ' ');
            Inc(PI);
          end
          else if (PI + 2 < L) and (not C[PI].OnCurve) and
                  (not C[PI+1].OnCurve) and C[PI+2].OnCurve then
          begin
            WS(PB, 'C' + NS(C[PI].X)   + ' ' + NS(C[PI].Y)   + ' '
                       + NS(C[PI+1].X) + ' ' + NS(C[PI+1].Y) + ' '
                       + NS(C[PI+2].X) + ' ' + NS(C[PI+2].Y) + ' ');
            Inc(PI, 3);
          end
          else
            Inc(PI);
        end;
        WS(PB, 'Z ');
      end;
    Result := Trim(StreamToStr(PB));
  finally
    PB.Free;
  end;
end;

// ================================================================
// unicode attribute value (XML-safe)
// ================================================================

// True if CP is a legal XML 1.0 character (others cannot appear, even as a
// numeric character reference, so such code points are skipped entirely).
function IsXmlChar(CP : LongWord) : Boolean;
begin
  Result := (CP = $09) or (CP = $0A) or (CP = $0D) or
            ((CP >= $20) and (CP <= $D7FF)) or
            ((CP >= $E000) and (CP <= $FFFD)) or
            ((CP >= $10000) and (CP <= $10FFFF));
end;

function UnicodeAttr(CP : LongWord) : string;
begin
  if (CP >= $20) and (CP <= $7E) and
     (CP <> Ord('&')) and (CP <> Ord('<')) and (CP <> Ord('>')) and
     (CP <> Ord('"')) and (CP <> Ord('''')) then
    Result := Chr(CP)
  else
    Result := '&#x' + IntToHex(CP, 1) + ';';
end;

// ================================================================
// Main entry point
// ================================================================

procedure OTFToSVGFont(Src, Dst : TStream);
var
  Data : TBytes;
  Sig  : LongWord;
  Tabs : TTableArr;
  Head, Hhea, Maxp, Hmtx, Cmap, Name, Cff, Glyf : TBytes;

  UnitsPerEm, NumHMetrics, NumGlyphs : Integer;
  Ascent, Descent : Integer;
  FontName : string;
  Adv : array of Integer;
  Paths : TStrArr;
  Pairs : TCmapArr;

  I, GID, DefaultAdv, Last : Integer;
  Parser : TTTFParser;
  MemFont : TMemoryStream;
begin
  Src.Position := 0;
  SetLength(Data, Src.Size);
  if Src.Size > 0 then Src.ReadBuffer(Data[0], Src.Size);
  if Length(Data) < 12 then
    raise Exception.Create('OTFToSVGFont: file too small');

  Sig := BU32(Data, 0);
  Tabs := ReadTableDir(Data);

  Head := GetTable(Tabs, TAG_HEAD);
  Hhea := GetTable(Tabs, TAG_HHEA);
  Maxp := GetTable(Tabs, TAG_MAXP);
  Hmtx := GetTable(Tabs, TAG_HMTX);
  Cmap := GetTable(Tabs, TAG_CMAP);
  Name := GetTable(Tabs, TAG_NAME);
  Cff  := GetTable(Tabs, TAG_CFF);
  Glyf := GetTable(Tabs, TAG_GLYF);

  if Length(Head) < 54 then raise Exception.Create('OTFToSVGFont: head table missing');

  UnitsPerEm := BU16(Head, 18);
  if UnitsPerEm = 0 then UnitsPerEm := 1000;

  if Length(Hhea) >= 36 then
  begin
    Ascent      := BS16(Hhea, 4);
    Descent     := BS16(Hhea, 6);
    NumHMetrics := BU16(Hhea, 34);
  end
  else
  begin
    Ascent := BS16(Head, 42); Descent := BS16(Head, 38);  // yMax / yMin fallback
    NumHMetrics := 0;
  end;

  NumGlyphs := BU16(Maxp, 4);
  FontName  := ExtractFontName(Name);
  Pairs     := ParseCmap(Cmap);

  // Advance widths from hmtx
  SetLength(Adv, NumGlyphs);
  Last := UnitsPerEm;
  for I := 0 to NumGlyphs - 1 do
  begin
    if I < NumHMetrics then begin Adv[I] := BU16(Hmtx, I * 4); Last := Adv[I]; end
    else Adv[I] := Last;
  end;

  // Outlines
  if Length(Cff) > 0 then
    ParseCFFOutlines(Cff, Paths)
  else if Length(Glyf) > 0 then
  begin
    if (Sig <> SFNT_TRUE) and (Sig <> SFNT_TRUE2) then
      raise Exception.Create('OTFToSVGFont: glyf font has unexpected sfnt signature');
    MemFont := TMemoryStream.Create;
    try
      MemFont.WriteBuffer(Data[0], Length(Data));
      MemFont.Position := 0;
      Parser := TTTFParser.Create(MemFont, False);
      try
        Parser.Parse;
        SetLength(Paths, Parser.NumGlyphs);
        for I := 0 to Parser.NumGlyphs - 1 do
          Paths[I] := ContourPath(Parser.Glyphs[I]);
      finally
        Parser.Free;
      end;
    finally
      MemFont.Free;
    end;
  end
  else
    raise Exception.Create('OTFToSVGFont: font has neither CFF nor glyf table');

  if Length(Paths) < NumGlyphs then SetLength(Paths, NumGlyphs);

  if NumGlyphs > 0 then DefaultAdv := Adv[0] else DefaultAdv := UnitsPerEm;

  // ---- Emit SVG ----
  WS(Dst, '<?xml version="1.0" standalone="no"?>' + LineEnding);
  WS(Dst, '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" ' +
          '"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">' + LineEnding);
  WS(Dst, '<svg xmlns="http://www.w3.org/2000/svg">' + LineEnding);
  WS(Dst, '<defs>' + LineEnding);
  WS(Dst, Format('<font id="%s" horiz-adv-x="%d">', [FontName, DefaultAdv]) + LineEnding);
  WS(Dst, Format('<font-face font-family="%s" units-per-em="%d" ascent="%d" descent="%d" />',
                 [FontName, UnitsPerEm, Ascent, Descent]) + LineEnding);

  // missing-glyph from GID 0
  if NumGlyphs > 0 then
  begin
    if Paths[0] <> '' then
      WS(Dst, Format('<missing-glyph horiz-adv-x="%d" d="%s" />', [Adv[0], Paths[0]]) + LineEnding)
    else
      WS(Dst, Format('<missing-glyph horiz-adv-x="%d" />', [Adv[0]]) + LineEnding);
  end;

  for I := 0 to High(Pairs) do
  begin
    GID := Pairs[I].GID;
    if (GID <= 0) or (GID >= NumGlyphs) then Continue;
    if not IsXmlChar(Pairs[I].CP) then Continue;
    if Paths[GID] <> '' then
      WS(Dst, Format('<glyph unicode="%s" horiz-adv-x="%d" d="%s" />',
                     [UnicodeAttr(Pairs[I].CP), Adv[GID], Paths[GID]]) + LineEnding)
    else
      WS(Dst, Format('<glyph unicode="%s" horiz-adv-x="%d" />',
                     [UnicodeAttr(Pairs[I].CP), Adv[GID]]) + LineEnding);
  end;

  WS(Dst, '</font>' + LineEnding);
  WS(Dst, '</defs>' + LineEnding);
  WS(Dst, '</svg>' + LineEnding);
end;

end.
