{$mode delphi}
unit jxl_color;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Color-space transforms for JPEG XL:
//   XYB → linear sRGB → sRGB (gamma)
//   Linear sRGB → sRGB
//   Tone mapping helpers

interface

uses SysUtils, Math, jxl_types;

// XYB to linear sRGB (in-place, 3 planes)
procedure XYBToLinearSRGB(var X, Y, B: TFloat32Plane);

// Linear light → display-referred sRGB gamma (IEC 61966-2-1)
function  LinearToSRGB(v: Single): Single; inline;

// Display-referred sRGB → linear
function  SRGBToLinear(v: Single): Single; inline;

// PQ (SMPTE ST 2084) transfer function
function  LinearToPQ(v: Single): Single;
function  PQToLinear(v: Single): Single;

// HLG (Rec. ITU-R BT.2100)
function  LinearToHLG(v: Single): Single;
function  HLGToLinear(v: Single): Single;

// Convert a float32 sample in [0,1] to an 8-bit byte value (clamped)
function  FloatToByte(v: Single): Byte; inline;

// Convert a float32 sample in [0,1] to a 16-bit word (clamped, linear)
function  FloatToWord(v: Single): Word; inline;

// Convert integer modular sample to float in [0,1]
function  IntSampleToFloat(v: Int64; bitDepth: Integer): Single; inline;

// Apply the appropriate transfer function given the metadata
procedure ApplyTransferFunction(var plane: TFloat32Plane;
                                tf: TJxlTransferFunction; gamma: Double);

implementation

// ---------------------------------------------------------------------------
// XYB → linear sRGB
// The XYB color space in JXL:
//   X  = (0.5*(L' - M'))
//   Y  = (0.5*(L' + M'))  // actually luminance-like
//   B  = S'
// where L', M', S' are gamma-encoded LMS values.
//
// Inverse (linear sRGB):
//   L' = Y + X
//   M' = Y - X
//   S' = B
// Then apply the inverse LMS→XYZ matrix and XYZ→sRGB matrix.
// (Opsin inverse matrix from libjxl)
// ---------------------------------------------------------------------------
const
  // Opsin inverse matrix (from libjxl/enc_color_management.cc)
  // Maps XYB back to linear sRGB
  kM: array[0..8] of Double = (
    11.031566901960784, -9.866628423529412,  0.955989360392157,
    -3.254147380392157,  4.418770392156863, -0.096027450980392,
    -3.658284392156863,  2.712457058823529,  1.945860784313725
  );
  // Opsin bias constants (subtracted before matrix multiply in encoding,
  // added back during decoding)
  kOpsinBias: array[0..2] of Double = (
    0.00379307325527544933,
    0.00379307325527544933,
    0.00379307325527544933
  );

procedure XYBToLinearSRGB(var X, Y, B: TFloat32Plane);
var
  i, n: Integer;
  Lp, Mp, Sp: Double;
  L, M, S: Double;
begin
  n := X.Width * X.Height;
  for i := 0 to n - 1 do
  begin
    Lp := X.Data[i] + Y.Data[i];   // L' = X + Y
    Mp := Y.Data[i] - X.Data[i];   // M' = Y - X
    Sp := B.Data[i];                // S' = B

    // Add opsin bias then cube (inverse of the cube-root XYB encoding)
    L := Lp + kOpsinBias[0]; if L < 0 then L := 0;
    M := Mp + kOpsinBias[1]; if M < 0 then M := 0;
    S := Sp + kOpsinBias[2]; if S < 0 then S := 0;
    // Clamp before cubing to prevent overflow on malformed/incorrect input
    if L > 1e8 then L := 1e8;
    if M > 1e8 then M := 1e8;
    if S > 1e8 then S := 1e8;
    L := L * L * L;
    M := M * M * M;
    S := S * S * S;

    // Opsin inverse matrix: LMS -> linear sRGB
    // Use intermediate Double vars and clamp before narrowing to Single
    Lp := kM[0]*L + kM[1]*M + kM[2]*S;
    Mp := kM[3]*L + kM[4]*M + kM[5]*S;
    Sp := kM[6]*L + kM[7]*M + kM[8]*S;
    if Lp > 1e30 then Lp := 1e30 else if Lp < -1e30 then Lp := -1e30;
    if Mp > 1e30 then Mp := 1e30 else if Mp < -1e30 then Mp := -1e30;
    if Sp > 1e30 then Sp := 1e30 else if Sp < -1e30 then Sp := -1e30;
    X.Data[i] := Lp;
    Y.Data[i] := Mp;
    B.Data[i] := Sp;
  end;
end;

// ---------------------------------------------------------------------------
function LinearToSRGB(v: Single): Single;
begin
  if IsNaN(v) or IsInfinite(v) then begin Result := 0; Exit; end;
  if v <= 0.0 then
    Result := v * 12.92
  else if v <= 0.0031308 then
    Result := v * 12.92
  else if v >= 1.0 then
    Result := 1.0
  else
    Result := 1.055 * Power(v, 1.0/2.4) - 0.055;
end;

function SRGBToLinear(v: Single): Single;
begin
  if v <= 0.04045 then
    Result := v / 12.92
  else
    Result := Power((v + 0.055) / 1.055, 2.4);
end;

// ---------------------------------------------------------------------------
// PQ transfer function (SMPTE ST 2084)
const
  kPQM1   = 0.1593017578125;
  kPQM2   = 78.84375;
  kPQC1   = 0.8359375;
  kPQC2   = 18.8515625;
  kPQC3   = 18.6875;

function LinearToPQ(v: Single): Single;
var Yp: Single;
begin
  if v <= 0 then begin Result := 0; Exit; end;
  Yp     := Power(v / 10000.0, kPQM1);
  Result := Power((kPQC1 + kPQC2*Yp) / (1.0 + kPQC3*Yp), kPQM2);
end;

function PQToLinear(v: Single): Single;
var Ep: Single;
begin
  if v <= 0 then begin Result := 0; Exit; end;
  Ep     := Power(v, 1.0/kPQM2);
  Result := 10000.0 * Power(Max(0.0, Ep - kPQC1) / (kPQC2 - kPQC3*Ep),
                             1.0/kPQM1);
end;

// ---------------------------------------------------------------------------
// HLG transfer function (ITU-R BT.2100)
const
  kHLGa = 0.17883277;
  kHLGb = 0.28466892;
  kHLGc = 0.55991073;

function LinearToHLG(v: Single): Single;
begin
  if v <= 1.0/12.0 then
    Result := Sqrt(3.0 * v)
  else
    Result := kHLGa * Ln(12.0*v - kHLGb) + kHLGc;
end;

function HLGToLinear(v: Single): Single;
begin
  if v <= 0.5 then
    Result := v * v / 3.0
  else
    Result := (Exp((v - kHLGc) / kHLGa) + kHLGb) / 12.0;
end;

// ---------------------------------------------------------------------------
function FloatToByte(v: Single): Byte;
begin
  if IsNaN(v) or IsInfinite(v) or (v <= 0.0) then begin Result := 0; Exit; end;
  if v >= 1.0 then begin Result := 255; Exit; end;
  Result := Byte(Round(v * 255.0));
end;

function FloatToWord(v: Single): Word;
begin
  if IsNaN(v) or IsInfinite(v) or (v <= 0.0) then begin Result := 0; Exit; end;
  if v >= 1.0 then begin Result := 65535; Exit; end;
  Result := Word(Round(v * 65535.0));
end;

function IntSampleToFloat(v: Int64; bitDepth: Integer): Single;
begin
  if bitDepth <= 0 then begin Result := 0; Exit; end;
  Result := v / ((Int64(1) shl bitDepth) - 1);
end;

// ---------------------------------------------------------------------------
procedure ApplyTransferFunction(var plane: TFloat32Plane;
                                tf: TJxlTransferFunction; gamma: Double);
var i, n: Integer; v: Single;
begin
  n := plane.Width * plane.Height;
  for i := 0 to n - 1 do begin
    v := plane.Data[i];
    case tf of
      jtfSRGB:   v := LinearToSRGB(v);
      jtf709:    begin  // Rec.709 gamma
                   if v < 0.018 then v := v * 4.5
                   else v := 1.099 * Power(v, 0.45) - 0.099;
                 end;
      jtfLinear: ;  // no-op
      jtfPQ:     v := LinearToPQ(v);
      jtfHLG:    v := LinearToHLG(v);
      jtfGamma:  if gamma > 0 then v := Power(Max(0.0, v), gamma);
    else ;
    end;
    plane.Data[i] := v;
  end;
end;

end.
