{$mode delphi}
unit jxl_vardct;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Variable-DCT (lossy) decoder for JPEG XL.
// Handles the VarDCT image mode: LF image, HF coefficients,
// quantization, chroma-from-luma, and multi-size IDCT.

interface

uses
  SysUtils, Math, jxl_types, jxl_bits, jxl_ans, jxl_modular;

type
  // Per-channel quantized coefficient blocks.
  TQBlocks = array[0..2] of array of Int32;

  // Frame parameters handed to the VarDCT decoder by the frame layer.

  TVarDCTFrameParams = record
    Width, Height: Integer;
    Flags:         UInt64;
    NumPasses:     Integer;
    XQMScale:      Integer;
    BQMScale:      Integer;
    XYBEncoded:    Boolean;
    // Restoration filters (gaborish runs before EPF, both in XYB space)
    Gab:           Boolean;
    GabX, GabY, GabB: Single;   // gaborish weight1 per channel
    EpfIters:      Integer;     // 0..3
  end;

  TVarDCTDecoder = class
  private
    FMetadata:     TJxlImageMetadata;
    FXYBEncoded:   Boolean;

    // --- Section-driven architecture (TOC-aware) ---
    FParams:        TVarDCTFrameParams;
    FGroupDim:      Integer;
    FXSizeGroups:   Integer;   // # of 256-px groups across
    FYSizeGroups:   Integer;
    FNumGroups:     Integer;
    FXSizeDCGroups: Integer;   // # of 2048-px LF (DC) groups across
    FYSizeDCGroups: Integer;
    FNumLFGroups:   Integer;
    // LFGlobal-derived global state
    FDCQuant:       array[0..2] of Single;  // DC dequant per channel
    FQGlobalScale:  Integer;
    FQuantDC:       Integer;
    // Block context map (entropy_coder.cc DecodeBlockCtxMap)
    FBlockNumDcCtxs: Integer;
    FBlockNumCtxs:   Integer;
    FBlockCtxMap:    TBytes;
    FQfThreshCount:  Integer;
    FQfThresh:       array of Cardinal;
    // Color-correlation DC (chroma_from_luma.cc DecodeDC)
    FColorFactor:   Integer;
    FBaseCorrX:     Single;
    FBaseCorrB:     Single;
    FYtoXDC:        Integer;
    FYtoBDC:        Integer;
    // Global modular tree + entropy code (shared by DC/AC-meta groups)
    FHasGlobalTree: Boolean;
    FGlobalTree:    TMATree;
    FGlobalAns:     TANSDecoder;
    // Dequantized DC image (1/8 resolution), plane order X=0, Y=1, B=2
    FDC:            array[0..2] of TFloat32Plane;
    FDCWidth:       Integer;
    FDCHeight:      Integer;
    // AC metadata (per 8x8 block; full DC-image dimensions)
    FAcsRaw:        array of Byte;     // raw AC strategy id (at top-left block)
    FAcsValid:      array of Boolean;  // block covered by some strategy
    FAcsOrigin:     array of Boolean;  // block is a strategy origin
    FRawQF:         array of Int32;    // raw quant field (1..256)
    FEpf:           array of Byte;     // EPF sharpness 0..7
    // CfL tile maps (per 64x64-pixel tile = per 8x8 blocks)
    FTileW, FTileH: Integer;
    FYtoXMap:       array of Int32;
    FYtoBMap:       array of Int32;
    // HFGlobal: AC histogram sets + entropy code
    FNumHFHistograms: Integer;
    FHFAns:           TANSDecoder;
    // Coefficient orders: kCoeffOrderLimit(6156) * 64 entries
    FCoeffOrders:     array of Cardinal;
    FUsedAcs:         Cardinal;   // bitmask of raw AC strategies seen
    // Reconstruction state
    FRecon:           array[0..2] of TFloat32Plane;  // full-res XYB
    FW8:              array[0..191] of Single;   // DCT8 dequant: [c*64+k]
    FW16:             array[0..767] of Single;   // DCT16: [c*256+k]
    FW32:             array[0..3071] of Single;  // DCT32: [c*1024+k]
    FWR16:            array[0..383] of Single;   // DCT8X16 table: [c*128+k]
    FWR32:            array[0..1535] of Single;  // DCT16X32 table: [c*512+k]
    FW64:             array[0..12287] of Single; // DCT64X64: [c*4096+k]
    FWR64:            array[0..6143] of Single;  // DCT32X64: [c*2048+k]
    FWID:             array[0..191] of Single;   // IDENTITY: [c*64+k]
    FWD22:            array[0..191] of Single;   // DCT2X2
    FWD48:            array[0..191] of Single;   // DCT4X8 / DCT8X4
    FWAFV:            array[0..191] of Single;   // AFV0..3
    FXDm, FBDm:       Single;                        // x/b qm multipliers

    procedure ComputeFrameDim;
    procedure DecodeBlockCtxMap(br: TBitReader);
    procedure DecodeCmapDC(br: TBitReader);
    procedure DecodeModularGlobalInfo(br: TBitReader);
    procedure DequantDCGroup(const dcImg: TModImage;
                             x0, y0, rectW, rectH: Integer; mul: Single);
    procedure DecodeAcMetadataGroup(idx, x0, y0, rectW, rectH: Integer;
                                    br: TBitReader);
    procedure DecodeCoeffOrdersAll(usedOrders: Cardinal; br: TBitReader);
    procedure ReconstructDCT8Block(absX, absY: Integer; acsRaw: Integer;
                                   const qb: TQBlocks);
    procedure BuildIdentityClassTables;
    procedure BuildAFVTable(const w48: array of Single);
    procedure ReconIdentityClass(c, px, py, acsRaw: Integer;
                                 const cf: array of Single);
    procedure ApplyGaborish;
    procedure ApplyEPF;
    function  MakeSectionReader(data: PByte; dataStart: NativeUInt;
                                const sizes: array of Cardinal;
                                idx: Integer): TBitReader;
    procedure DecodeLFGlobal(br: TBitReader);
    procedure DecodeLFGroupSection(idx: Integer; br: TBitReader);
    procedure DecodeHFGlobalSection(br: TBitReader);
    procedure DecodeACGroupSection(pass, group: Integer; br: TBitReader);
  public
    constructor Create(const md: TJxlImageMetadata);
    destructor  Destroy; override;

    // TOC-driven decode: the codestream buffer plus per-section sizes.
    //   dataStart = byte offset (in `data`) of the first section's payload.
    //   sizes[i]  = byte size of TOC section i.
    procedure DecodeSections(data: PByte; dataStart: NativeUInt;
                             const sizes: array of Cardinal;
                             const params: TVarDCTFrameParams;
                             var output: TJxlImageF);
  end;

implementation

// ---------------------------------------------------------------------------
constructor TVarDCTDecoder.Create(const md: TJxlImageMetadata);
begin
  inherited Create;
  FMetadata   := md;
  FXYBEncoded := md.XYBEncoded;
end;

destructor TVarDCTDecoder.Destroy;
begin
  FGlobalAns.Free;
  FHFAns.Free;
  inherited;
end;

// ===========================================================================
// TOC-driven section architecture
// ===========================================================================
const
  VDCT_GROUP_DIM      = 256;          // VarDCT AC group size (kGroupDim)
  VDCT_DC_GROUP_DIM   = 2048;         // LF (DC) group size = 8 * 256
  // FrameHeader flag bits (frame_header.h)
  VFLAG_NOISE         = 1;
  VFLAG_PATCHES       = 2;
  VFLAG_SPLINES       = 16;
  VFLAG_USE_DC_FRAME  = 32;

function CeilDiv(a, b: Integer): Integer; inline;
begin
  Result := (a + b - 1) div b;
end;

function VUnpackSigned(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then Result := -((Int64(v) + 1) shr 1)
  else Result := Int64(v) shr 1;
end;

function CeilLog2NZ(n: Integer): Integer; inline;
begin
  Result := 0;
  while (1 shl Result) < n do Inc(Result);
end;

const
  // quant_weights.cc kDefaultQuantBias (x, y, b, global)
  kQuantBias: array[0..3] of Single = (
    1.0 - 0.05465007330715401, 1.0 - 0.07005449891748593,
    1.0 - 0.049935103337343655, 0.145);

const
  // quant_weights.cc default DCT16X16 bands (7) and DCT32X32 bands (8)
  kDCT8BandsF: array[0..17] of Single = (
    3150.0, 0.0, -0.4, -0.4, -0.4, -2.0,
    560.0,  0.0, -0.3, -0.3, -0.3, -0.3,
    512.0, -2.0, -1.0,  0.0, -1.0, -2.0);
  kDCT16BandsF: array[0..20] of Single = (
    8996.8725711814115328, -1.3000777393353804, -0.49424529824571225,
    -0.439093774457103443, -0.6350101832695744, -0.90177264050827612,
    -1.6162099239887414,
    3191.48366296844234752, -0.67424582104194355, -0.80745813428471001,
    -0.44925837484843441, -0.35865440981033403, -0.31322389111877305,
    -0.37615025315725483,
    1157.50408145487200256, -2.0531423165804414, -1.4,
    -0.50687130033378396, -0.42708730624733904, -1.4856834539296244,
    -4.9209142884401604);
  kDCT8X16BandsF: array[0..20] of Single = (
    7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5,
    1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2,
    506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6);
  kDCT16X32BandsF: array[0..23] of Single = (
    13844.97076442300573, -0.97113799999999995, -0.658, -0.42026,
    -0.22712, -0.2206, -0.226, -0.6,
    4798.964084220744293, -0.61125308982767057, -0.83770786552491361,
    -0.79014862079498627, -0.2692727459704829, -0.38272769465388551,
    -0.22924222653091453, -0.20719098826199578,
    1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5);
  kDCT64BandsF: array[0..23] of Single = (
    0.9 * 26629.073922049845, -1.025, -0.78, -0.65012,
    -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
    0.9 * 9311.3238710010046, -0.3041958212306401, -0.3633036457487539,
    -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
    -0.30180866526242109, -0.27321683125358037,
    0.9 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5);
  kDCT32X64BandsF: array[0..23] of Single = (
    0.65 * 23629.073922049845, -1.025, -0.78, -0.65012,
    -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
    0.65 * 8611.3238710010046, -0.3041958212306401, -0.3633036457487539,
    -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
    -0.30180866526242109, -0.27321683125358037,
    0.65 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5);
  kDCT32BandsF: array[0..23] of Single = (
    15718.40830982518931456, -1.025, -0.98, -0.9012, -0.4,
    -0.48819395464, -0.421064, -0.27,
    7305.7636810695983104, -0.8041958212306401, -0.7633036457487539,
    -0.55660379990111464, -0.49785304658857626, -0.43699592683512467,
    -0.40180866526242109, -0.27321683125358037,
    3803.53173721215041536, -3.060733579805728, -2.0413270132490346,
    -2.0235650159727417, -0.5495389509954993, -0.4, -0.4, -0.3);

// GetQuantWeights (quant_weights.cc) for a ROWS x COLS table; out = 1/weight,
// layout [c*rows*cols + y*cols + x]. bandsIn: numBands entries per channel.
procedure ComputeDQTable(rows, cols, numBands: Integer;
                         const bandsIn: array of Single;
                         var mat: array of Single);
var
  c, i, x, y, idx: Integer;
  bands: array[0..15] of Single;
  scale, dx, dy, dist, frac, w: Single;
begin
  for c := 0 to 2 do begin
    bands[0] := bandsIn[c * numBands];
    for i := 1 to numBands - 1 do
      if bandsIn[c * numBands + i] > 0 then
        bands[i] := bands[i-1] * (1.0 + bandsIn[c * numBands + i])
      else
        bands[i] := bands[i-1] / (1.0 - bandsIn[c * numBands + i]);
    scale := (numBands - 1) / (Sqrt(2.0) + 1e-6);
    for y := 0 to rows - 1 do
      for x := 0 to cols - 1 do begin
        dx := x * scale / (cols - 1);
        dy := y * scale / (rows - 1);
        dist := Sqrt(dx*dx + dy*dy);
        idx := Trunc(dist);
        if idx > numBands - 2 then idx := numBands - 2;
        frac := dist - idx;
        w := bands[idx] * Exp(Ln(bands[idx+1] / bands[idx]) * frac);
        mat[c*rows*cols + y*cols + x] := 1.0 / w;
      end;
  end;
end;

// quantizer.h AdjustQuantBias
function AdjustQBias(c: Integer; q: Integer): Single; inline;
begin
  if q = 0 then Result := 0.0
  else if q = 1 then Result := kQuantBias[c]
  else if q = -1 then Result := -kQuantBias[c]
  else Result := q - kQuantBias[3] / q;
end;

const
  // AC strategy covered blocks (ac_strategy.h, raw ids 0..26).
  // Names are ROWSxCOLS: DCT16X8 = 2 blocks tall, 1 wide.
  kAcsCbX: array[0..26] of Byte = (1,1,1,1, 2,4, 1,2, 1,4, 2,4, 1,1,
                                   1,1,1,1, 8, 4,8, 16, 8,16, 32, 16,32);
  kAcsCbY: array[0..26] of Byte = (1,1,1,1, 2,4, 2,1, 4,1, 4,2, 1,1,
                                   1,1,1,1, 8, 8,4, 16, 16,8, 32, 32,16);

function VFloorLog2(n: Cardinal): Integer; inline;
begin
  Result := 0;
  while n > 1 do begin n := n shr 1; Inc(Result); end;
end;

// CoeffOrderContext (coeff_order.cc): HybridUintConfig(0,0,0) token, capped at 7
function CoeffOrderCtx(val: Cardinal): Integer; inline;
begin
  if val = 0 then Result := 0
  else Result := 1 + VFloorLog2(val);
  if Result > 7 then Result := 7;   // kPermutationContexts - 1
end;

// DecodeLehmerCode (lehmer_code.h): Fenwick/order-statistics tree.
procedure DecodeLehmer(const code: array of Cardinal; n: Integer;
                       var perm: array of Cardinal);
var
  log2n, paddedN, i, j: Integer;
  temp: array of Cardinal;
  rank, bit, next, cand: Cardinal;
begin
  log2n   := CeilLog2NZ(n);
  paddedN := 1 shl log2n;
  SetLength(temp, paddedN);
  for i := 0 to paddedN - 1 do
    temp[i] := Cardinal(i + 1) and Cardinal(-(i + 1));   // lowest set bit of i+1
  for i := 0 to n - 1 do begin
    rank := code[i] + 1;
    bit  := Cardinal(paddedN);
    next := 0;
    for j := 0 to log2n do begin
      cand := next + bit;
      bit  := bit shr 1;
      if temp[cand - 1] < rank then begin
        next := cand;
        Dec(rank, temp[cand - 1]);
      end;
    end;
    perm[i] := next;
    Inc(next);
    while next <= Cardinal(paddedN) do begin
      Dec(temp[next - 1]);
      Inc(next, next and (not next + 1));
    end;
  end;
end;

// ComputeNaturalCoeffOrder (ac_strategy.cc CoeffOrderAndLut, is_lut=false).
// order[k] = coefficient position (in a cx*8 wide layout, cy<=cx normalized).
procedure ComputeNaturalOrder(rawStrat: Integer; var order: array of Cardinal);
var
  cx, cy, t, xs, xsm, xss, cur, i, j, x, y, vv, ip: Integer;
begin
  cx := kAcsCbX[rawStrat];
  cy := kAcsCbY[rawStrat];
  if cy > cx then begin t := cx; cx := cy; cy := t; end;
  xs  := cx div cy;
  xsm := xs - 1;
  xss := CeilLog2NZ(xs);
  cur := cx * cy;
  // First half (top-left triangle), zig-zag diagonals
  for i := 0 to cx * 8 - 1 do
    for j := 0 to i do begin
      x := j; y := i - j;
      if (i and 1) <> 0 then begin t := x; x := y; y := t; end;
      if (y and xsm) <> 0 then Continue;
      y := y shr xss;
      if (x < cx) and (y < cy) then
        vv := y * cx + x
      else begin
        vv := cur; Inc(cur);
      end;
      order[vv] := Cardinal(y * cx * 8 + x);
    end;
  // Second half
  for ip := cx * 8 - 1 downto 1 do begin
    i := ip - 1;
    for j := 0 to i do begin
      x := cx * 8 - 1 - (i - j);
      y := cx * 8 - 1 - j;
      if (i and 1) <> 0 then begin t := x; x := y; y := t; end;
      if (y and xsm) <> 0 then Continue;
      y := y shr xss;
      vv := cur; Inc(cur);
      order[vv] := Cardinal(y * cx * 8 + x);
    end;
  end;
end;

const
  // coeff_order.h: AC strategy -> order bucket
  kStrategyOrder: array[0..26] of Byte = (
    0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1,
    1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12);
  // coeff_order.h kCoeffOrderOffset (40 entries; multiplied by 64 on use)
  kCoeffOrderOffset: array[0..39] of Integer = (
    0,    1,    2,    3,    4,    5,    6,    10,   14,   18,
    34,   50,   66,   68,   70,   72,   76,   80,   84,   92,
    100,  108,  172,  236,  300,  332,  364,  396,  652,  908,
    1164, 1292, 1420, 1548, 2572, 3596, 4620, 5132, 5644, 6156);

  // ac_context.h clustering tables (index 0 unused)
  kCoeffFreqContext: array[0..63] of Word = (
    0, 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15,    15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23,    23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27,    27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30);
  kCoeffNumNonzeroContext: array[0..63] of Word = (
    0, 0,   31,  62,  62,  93,  93,  93,  93,  123, 123, 123, 123,
    152,   152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180,   180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206);

  // ac_context.h BlockCtxMap::kDefaultCtxMap (3 x kNumOrders = 39 entries)
  kDefaultBlockCtxMap: array[0..38] of Byte = (
    0, 1, 2, 2, 3,  3,  4,  5,  6,  6,  6,  6,  6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14);

// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.ComputeFrameDim;
begin
  FGroupDim      := VDCT_GROUP_DIM;
  FXSizeGroups   := CeilDiv(FParams.Width,  VDCT_GROUP_DIM);
  FYSizeGroups   := CeilDiv(FParams.Height, VDCT_GROUP_DIM);
  FNumGroups     := FXSizeGroups * FYSizeGroups;
  FXSizeDCGroups := CeilDiv(FParams.Width,  VDCT_DC_GROUP_DIM);
  FYSizeDCGroups := CeilDiv(FParams.Height, VDCT_DC_GROUP_DIM);
  FNumLFGroups   := FXSizeDCGroups * FYSizeDCGroups;
end;

// ---------------------------------------------------------------------------
// Build a fresh bit reader positioned at the start of TOC section `idx`.
// ---------------------------------------------------------------------------
function TVarDCTDecoder.MakeSectionReader(data: PByte; dataStart: NativeUInt;
                                          const sizes: array of Cardinal;
                                          idx: Integer): TBitReader;
var
  ofs: NativeUInt;
  i: Integer;
begin
  ofs := dataStart;
  for i := 0 to idx - 1 do
    Inc(ofs, sizes[i]);
  Result := TBitReader.Create(data + ofs, sizes[idx]);
end;

// ---------------------------------------------------------------------------
// LFGlobal section (dec_frame.cc ProcessLFGlobal, VarDCT path):
//   [patches] [splines] [noise]  (only if corresponding flag set)
//   DequantMatrices::DecodeDC
//   DecodeGlobalDCInfo: Quantizer + block context map + color-correlation DC
//   modular DecodeGlobalInfo (global MA tree)
// Only the deterministic opening (DequantMatrices DC + Quantizer) is parsed
// here; the entropy-coded remainder is not yet implemented.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeLFGlobal(br: TBitReader);
var
  dcAllDefault: Boolean;
  c: Integer;
begin
  if (FParams.Flags and VFLAG_PATCHES) <> 0 then
    raise EJxlError.Create('VarDCT: patches not yet supported');
  if (FParams.Flags and VFLAG_SPLINES) <> 0 then
    raise EJxlError.Create('VarDCT: splines not yet supported');
  if (FParams.Flags and VFLAG_NOISE) <> 0 then
    raise EJxlError.Create('VarDCT: noise not yet supported');

  // DequantMatrices::DecodeDC — all_default = ReadBits(1) (bit==1 -> default);
  // if not default, 3×F16 (scaled 1/128).
  dcAllDefault := br.ReadBit;
  if not dcAllDefault then
    for c := 0 to 2 do
      FDCQuant[c] := br.ReadF16 * (1.0 / 128.0)
  else
    for c := 0 to 2 do
      FDCQuant[c] := 1.0 / 128.0;   // default DC dequant placeholder

  // Quantizer::Decode (QuantizerParams, no AllDefault):
  //   global_scale: U32(BitsOffset(11,1),BitsOffset(11,2049),BitsOffset(12,4097),BitsOffset(16,8193))
  //   quant_dc:     U32(Val(16),BitsOffset(5,1),BitsOffset(8,1),BitsOffset(16,1))
  FQGlobalScale := Integer(br.ReadU32(1,11, 2049,11, 4097,12, 8193,16));
  FQuantDC      := Integer(br.ReadU32(16,0, 1,5, 1,8, 1,16));

  // Block context map, color-correlation DC, then the global modular tree/code.
  DecodeBlockCtxMap(br);
  DecodeCmapDC(br);
  DecodeModularGlobalInfo(br);

end;

// ---------------------------------------------------------------------------
// Block context map (entropy_coder.cc DecodeBlockCtxMap)
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeBlockCtxMap(br: TBitReader);
var
  isDefault: Boolean;
  j, n, i, nEntries: Integer;
  sub: TANSDecoder;
begin
  FBlockNumDcCtxs := 1;
  FBlockNumCtxs   := 1;
  FQfThreshCount  := 0;
  isDefault := br.ReadBit;
  if isDefault then begin
    // Default block context map (ac_context.h kDefaultCtxMap):
    // num_dc_ctxs=1, qf_thresholds empty, 15 distinct contexts.
    FBlockNumDcCtxs := 1;
    FBlockNumCtxs   := 15;
    SetLength(FBlockCtxMap, 39);
    for i := 0 to 38 do
      FBlockCtxMap[i] := kDefaultBlockCtxMap[i];
    Exit;
  end;

  // dc_thresholds[0..2]: ReadBits(4) entries each, UnpackSigned(kDCThresholdDist)
  for j := 0 to 2 do begin
    n := Integer(br.ReadBits(4));
    FBlockNumDcCtxs := FBlockNumDcCtxs * (n + 1);
    for i := 0 to n - 1 do
      VUnpackSigned(br.ReadU32(0,4, 16,8, 272,16, 65808,32));  // dc threshold (consumed)
  end;
  // qf_thresholds: ReadBits(4) entries, kQFThresholdDist + 1
  n := Integer(br.ReadBits(4));
  FQfThreshCount := n;
  SetLength(FQfThresh, n);
  for i := 0 to n - 1 do
    FQfThresh[i] := br.ReadU32(0,2, 4,3, 12,5, 44,8) + 1;

  nEntries := 3 * 13 * FBlockNumDcCtxs * (FQfThreshCount + 1);
  sub := TANSDecoder.Create;
  try
    FBlockCtxMap := sub.DecodeStandaloneContextMap(br, nEntries, FBlockNumCtxs);
  finally
    sub.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Color-correlation DC (chroma_from_luma.cc ColorCorrelation::DecodeDC)
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeCmapDC(br: TBitReader);
begin
  FColorFactor := 84;     // kDefaultColorFactor
  FBaseCorrX   := 0.0;
  // Default base B correlation is kYToBRatio (= 1.0) for XYB images;
  // ColorCorrelationMap::Create zeroes it for non-XYB.
  if FXYBEncoded then FBaseCorrB := 1.0 else FBaseCorrB := 0.0;
  FYtoXDC      := 0;
  FYtoBDC      := 0;
  if br.ReadBit then Exit;   // all default
  FColorFactor := Integer(br.ReadU32(84,0, 256,0, 2,8, 258,16));
  FBaseCorrX   := br.ReadF16;
  FBaseCorrB   := br.ReadF16;
  FYtoXDC      := Integer(br.ReadBits(8)) - 128;
  FYtoBDC      := Integer(br.ReadBits(8)) - 128;
end;

// ---------------------------------------------------------------------------
// Global modular info (dec_modular.cc DecodeGlobalInfo). For a VarDCT frame
// with no extra channels the global image has 0 channels, so only the tree
// (and its entropy code) are read.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeModularGlobalInfo(br: TBitReader);
var hasTree: Boolean; numLeaves: Integer;
begin
  FHasGlobalTree := False;
  hasTree := br.ReadBit;
  if hasTree then begin
    ReadMATree(br, FGlobalTree);
    numLeaves := (Length(FGlobalTree) + 1) div 2;
    if numLeaves < 1 then numLeaves := 1;
    FGlobalAns := TANSDecoder.Create;
    FGlobalAns.InitCode(br, numLeaves);
    FHasGlobalTree := True;
  end;
  // Global image has 0 channels (no color in VarDCT path, no extra channels) ->
  // ModularGenericDecompress would read nothing further.
  if Length(FMetadata.ExtraChannels) > 0 then
    raise EJxlError.Create('VarDCT: extra channels in global modular not yet supported');
end;

// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeLFGroupSection(idx: Integer; br: TBitReader);
var
  dcImg:   TModImage;
  dcTotW, dcTotH, gx, gy, rectW, rectH, c: Integer;
  extraPrec: Integer;
  mul: Single;
  mn, mx, v: Int64;
  k: Integer;
begin
  // dec_frame.cc ProcessDCGroup -> DecodeVarDCTDC: the DC (LF) image is a
  // 3-channel modular sub-image at 1/8 resolution, decoded with the global tree.
  if not (FParams.Flags and VFLAG_USE_DC_FRAME = 0) then begin
    Exit;
  end;

  dcTotW := CeilDiv(FParams.Width,  8);
  dcTotH := CeilDiv(FParams.Height, 8);
  gx := idx mod FXSizeDCGroups;
  gy := idx div FXSizeDCGroups;
  rectW := dcTotW - gx * 256; if rectW > 256 then rectW := 256;
  rectH := dcTotH - gy * 256; if rectH > 256 then rectH := 256;

  // extra_precision (2 bits), DC multiplier
  extraPrec := Integer(br.ReadBits(2));
  mul := 1.0 / (1 shl extraPrec);

  // 3 DC channels (no chroma subsampling assumed: 4:4:4)
  dcImg.NumChannels := 3;
  dcImg.NumMetaChannels := 0;
  SetLength(dcImg.Channels, 3);
  for c := 0 to 2 do
    InitModChannel(dcImg.Channels[c], rectW, rectH, 0, 0);

  // Decode using the global tree + global entropy code.
  // The modular "group" static property is the stream ID:
  // ModularStreamId::VarDCTDC(g).ID() = 1 + g  (dec_modular.h).
  ModularDecodeImage(br, dcImg, FGlobalTree, FGlobalAns, 1 + idx, True);

  // Report decoded DC stats for the first channel (validation signal).
  mn := High(Int64); mx := Low(Int64);
  for k := 0 to rectW * rectH - 1 do begin
    v := dcImg.Channels[0].Data[k];
    if v < mn then mn := v;
    if v > mx then mx := v;
  end;

  DequantDCGroup(dcImg, gx * 256, gy * 256, rectW, rectH, mul);

  // AC metadata follows the DC in the same LFGroup section.
  DecodeAcMetadataGroup(idx, gx * 256, gy * 256, rectW, rectH, br);
end;

// ---------------------------------------------------------------------------
// DecodeAcMetadata (dec_modular.cc): per-block AC strategy, raw quant field,
// EPF sharpness, and per-tile CfL factors — a 4-channel modular sub-image.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeAcMetadataGroup(idx, x0, y0, rectW, rectH: Integer;
                                               br: TBitReader);
var
  count, streamId, cw, chh: Integer;
  img: TModImage;
  ix, iy, x, y, num, tx, ty, k: Integer;
  sharpness, acsRaw, qf: Integer;
  cbx, cby, bx, by: Integer;
begin
  // count: number of (strategy, qf) pairs, raw bits before the modular stream
  count := Integer(br.ReadBits(CeilLog2NZ(rectW * rectH))) + 1;

  cw  := (rectW + 7) shr 3;   // CfL tiles in this rect
  chh := (rectH + 7) shr 3;

  img.NumChannels := 4;
  img.NumMetaChannels := 0;
  SetLength(img.Channels, 4);
  InitModChannel(img.Channels[0], cw, chh, 3, 3);     // ytox
  InitModChannel(img.Channels[1], cw, chh, 3, 3);     // ytob
  InitModChannel(img.Channels[2], count, 2, 0, 0);    // ACS + QF pairs
  InitModChannel(img.Channels[3], rectW, rectH, 0, 0);// EPF sharpness

  // Stream id: ModularStreamId::ACMetadata(g).ID = 1 + 2*num_dc_groups + g
  streamId := 1 + 2 * FNumLFGroups + idx;
  ModularDecodeImage(br, img, FGlobalTree, FGlobalAns, streamId, True);

  // CfL tile maps
  for ty := 0 to chh - 1 do
    for tx := 0 to cw - 1 do begin
      k := ((y0 shr 3) + ty) * FTileW + (x0 shr 3) + tx;
      FYtoXMap[k] := img.Channels[0].Data[ty * cw + tx];
      FYtoBMap[k] := img.Channels[1].Data[ty * cw + tx];
    end;

  // Walk blocks: EPF always; strategy+QF only at not-yet-covered positions.
  num := 0;
  for iy := 0 to rectH - 1 do begin
    y := y0 + iy;
    for ix := 0 to rectW - 1 do begin
      x := x0 + ix;
      sharpness := img.Channels[3].Data[iy * rectW + ix];
      if (sharpness < 0) or (sharpness > 7) then
        raise EJxlError.Create('VarDCT: corrupted sharpness field');
      FEpf[y * FDCWidth + x] := Byte(sharpness);
      if FAcsValid[y * FDCWidth + x] then Continue;
      if num >= count then
        raise EJxlError.Create('VarDCT: AC metadata count exceeded');
      acsRaw := img.Channels[2].Data[num];            // row 0
      if (acsRaw < 0) or (acsRaw > 26) then
        raise EJxlError.Create('VarDCT: invalid AC strategy');
      qf := img.Channels[2].Data[count + num];        // row 1
      if qf < 0 then qf := 0;
      if qf > 255 then qf := 255;                     // kQuantMax-1
      cbx := kAcsCbX[acsRaw]; cby := kAcsCbY[acsRaw];
      for by := 0 to cby - 1 do
        for bx := 0 to cbx - 1 do begin
          if (y + by >= FDCHeight) or (x + bx >= FDCWidth) then
            raise EJxlError.Create('VarDCT: AC strategy overflows image');
          FAcsValid[(y + by) * FDCWidth + x + bx] := True;
          FRawQF[(y + by) * FDCWidth + x + bx]    := 1 + qf;
        end;
      FAcsRaw[y * FDCWidth + x]    := Byte(acsRaw);
      FAcsOrigin[y * FDCWidth + x] := True;
      FUsedAcs := FUsedAcs or (Cardinal(1) shl acsRaw);
      Inc(num);
    end;
  end;

end;

// ---------------------------------------------------------------------------
// DequantDC (compressed_dc.cc, 4:4:4 path): modular channels are [Y, X, B];
// output planes are X=0, Y=1, B=2 with chroma-from-luma applied to X and B.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DequantDCGroup(const dcImg: TModImage;
                                        x0, y0, rectW, rectH: Integer;
                                        mul: Single);
const
  kDCQuant: array[0..2] of Single = (1.0/4096.0, 1.0/512.0, 1.0/256.0);
var
  invQuantDC, mulDCx, mulDCy, mulDCb, cflX, cflB: Single;
  x, y: Integer;
  dcY, dcX, dcB: Single;
begin
  // inv_quant_dc = (kGlobalScaleDenom / global_scale) / quant_dc
  invQuantDC := (65536.0 / FQGlobalScale) / FQuantDC;
  mulDCx := invQuantDC * kDCQuant[0] * mul;
  mulDCy := invQuantDC * kDCQuant[1] * mul;
  mulDCb := invQuantDC * kDCQuant[2] * mul;
  cflX := FBaseCorrX + FYtoXDC / FColorFactor;
  cflB := FBaseCorrB + FYtoBDC / FColorFactor;

  for y := 0 to rectH - 1 do
    for x := 0 to rectW - 1 do begin
      // modular channel order: 0 = Y quants, 1 = X quants, 2 = B quants
      dcY := dcImg.Channels[0].Data[y * rectW + x] * mulDCy;
      dcX := dcImg.Channels[1].Data[y * rectW + x] * mulDCx + dcY * cflX;
      dcB := dcImg.Channels[2].Data[y * rectW + x] * mulDCb + dcY * cflB;
      PlaneSet(FDC[0], x0 + x, y0 + y, dcX);
      PlaneSet(FDC[1], x0 + x, y0 + y, dcY);
      PlaneSet(FDC[2], x0 + x, y0 + y, dcB);
    end;
end;

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// DecodeCoeffOrders (coeff_order.cc): one shared entropy code (8 contexts);
// per order-bucket with its bit set in usedOrders, 3 channel permutations
// composed with the natural zig-zag order.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeCoeffOrdersAll(usedOrders: Cardinal; br: TBitReader);
var
  pAns: TANSDecoder;
  computed, acsMask: Cardinal;
  o, ordIdx, c, llf, size, k, i, endv: Integer;
  usedFlag: Boolean;
  natural, perm, lehmer: array of Cardinal;
  last: Cardinal;
  base: Integer;
begin
  SetLength(FCoeffOrders, 6156 * 64);
  pAns := nil;
  if usedOrders <> 0 then begin
    pAns := TANSDecoder.Create;
    pAns.Init(br, 8);   // kPermutationContexts
  end;
  try
    acsMask := 0;
    for o := 0 to 26 do
      if (FUsedAcs and (Cardinal(1) shl o)) <> 0 then
        acsMask := acsMask or (Cardinal(1) shl kStrategyOrder[o]);

    computed := 0;
    for o := 0 to 26 do begin
      ordIdx := kStrategyOrder[o];
      if (computed and (Cardinal(1) shl ordIdx)) <> 0 then Continue;
      computed := computed or (Cardinal(1) shl ordIdx);
      llf  := kAcsCbX[o] * kAcsCbY[o];
      size := 64 * llf;
      usedFlag := (acsMask and (Cardinal(1) shl ordIdx)) <> 0;

      if (usedOrders and (Cardinal(1) shl ordIdx)) = 0 then begin
        if usedFlag then begin
          SetLength(natural, size);
          ComputeNaturalOrder(o, natural);
          for c := 0 to 2 do begin
            base := kCoeffOrderOffset[3 * ordIdx + c] * 64;
            for k := 0 to size - 1 do
              FCoeffOrders[base + k] := natural[k];
          end;
        end;
      end else begin
        SetLength(natural, size);
        ComputeNaturalOrder(o, natural);
        SetLength(perm, size);
        SetLength(lehmer, size);
        for c := 0 to 2 do begin
          // ReadPermutation(skip=llf, size)
          for i := 0 to size - 1 do lehmer[i] := 0;
          endv := Integer(pAns.Decode(CoeffOrderCtx(Cardinal(size)), br)) + llf;
          if endv > size then
            raise EJxlError.Create('VarDCT: invalid permutation size');
          last := 0;
          for i := llf to endv - 1 do begin
            lehmer[i] := pAns.Decode(CoeffOrderCtx(last), br);
            last := lehmer[i];
            if lehmer[i] >= Cardinal(size - i) then
              raise EJxlError.Create('VarDCT: invalid lehmer code');
          end;
          DecodeLehmer(lehmer, size, perm);
          base := kCoeffOrderOffset[3 * ordIdx + c] * 64;
          for k := 0 to size - 1 do
            FCoeffOrders[base + k] := natural[perm[k]];
        end;
      end;
    end;
    if (usedOrders <> 0) and not pAns.CheckFinalState then
      raise EJxlError.Create('VarDCT: coeff order ANS final state error');
  finally
    pAns.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Reconstruct one DCT8 block: dequant + CfL + LLF-from-DC + mean-preserving
// IDCT (dec_group.cc Dequant + DequantLane semantics).
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.ReconstructDCT8Block(absX, absY: Integer;
                                              acsRaw: Integer;
                                              const qb: TQBlocks);
const
  kScale2: array[0..1] of Single = (1.0, 1.108937353592731823);
  kScale4: array[0..3] of Single = (1.0, 1.025760096781116015,
                                    1.108937353592731823, 1.270559368765487251);
  kScale8: array[0..7] of Single = (
    1.0000000000000000, 1.0063534990068217, 1.0257600967811158,
    1.0593017296817173, 1.1089373535927318, 1.1777765381970435,
    1.2705593687654873, 1.3944898413647777);
var
  scaled, xfac, bfac, s, wgt: Single;
  coef: array[0..2] of array of Single;
  tile, c, k, u, v, px, py, x, y, sz: Integer;
  cbx, cby, R, CC, arrW, wstride: Integer;
  wide: Boolean;
  cosR, cosC: array of Single;          // [f*len + pos]
  cosCbX, cosCbY: array[0..7, 0..7] of Single;
  tmp: array of Single;                 // [v*CC + x]
  fv: Single;
  // storage index for frequency (v vertical, u horizontal)
  function KIdx(vv, uu: Integer): Integer; inline;
  begin
    if wide then Result := vv * arrW + uu
    else Result := uu * arrW + vv;
  end;
  function AxScale(cb, f: Integer): Single; inline;
  begin
    if cb = 2 then Result := kScale2[f]
    else if cb = 4 then Result := kScale4[f]
    else if cb = 8 then Result := kScale8[f]
    else Result := 1.0;
  end;
begin
  case acsRaw of
    0, 1, 2, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20: ;
  else Exit;
  end;
  cbx := kAcsCbX[acsRaw];
  cby := kAcsCbY[acsRaw];
  R   := cby * 8;          // pixel rows
  CC  := cbx * 8;          // pixel cols
  sz  := cbx * cby * 64;
  wide := cbx > cby;
  if CC >= R then arrW := CC else arrW := R;

  scaled := (65536.0 / FQGlobalScale) / FRawQF[absY * FDCWidth + absX];
  tile   := (absY div 8) * FTileW + (absX div 8);
  xfac   := FBaseCorrX + FYtoXMap[tile] / FColorFactor;
  bfac   := FBaseCorrB + FYtoBMap[tile] / FColorFactor;

  for c := 0 to 2 do SetLength(coef[c], sz);

  // Dequant + CfL (LLF positions get overwritten below).
  for k := 0 to sz - 1 do begin
    case acsRaw of
      0:      begin wgt := FW8[64 + k];    wstride := 64;   end;
      1:      begin wgt := FWID[64 + k];   wstride := 64;   end;
      2:      begin wgt := FWD22[64 + k];  wstride := 64;   end;
      12, 13: begin wgt := FWD48[64 + k];  wstride := 64;   end;
      14, 15, 16, 17: begin wgt := FWAFV[64 + k]; wstride := 64; end;
      4:      begin wgt := FW16[256 + k];  wstride := 256;  end;
      5:      begin wgt := FW32[1024 + k]; wstride := 1024; end;
      6, 7:   begin wgt := FWR16[128 + k]; wstride := 128;  end;
      10, 11: begin wgt := FWR32[512 + k]; wstride := 512;  end;
      18:     begin wgt := FW64[4096 + k]; wstride := 4096; end;
    else      begin wgt := FWR64[2048 + k]; wstride := 2048; end;
    end;
    coef[1][k] := AdjustQBias(1, qb[1][k]) * scaled * wgt;        // Y
    case acsRaw of
      0:    begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FW8[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FW8[2*wstride + k]
                                + bfac * coef[1][k]; end;
      4:    begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FW16[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FW16[2*wstride + k]
                                + bfac * coef[1][k]; end;
      5:    begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FW32[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FW32[2*wstride + k]
                                + bfac * coef[1][k]; end;
      1:    begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWID[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWID[2*wstride + k]
                                + bfac * coef[1][k]; end;
      2:    begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWD22[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWD22[2*wstride + k]
                                + bfac * coef[1][k]; end;
      12, 13: begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWD48[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWD48[2*wstride + k]
                                + bfac * coef[1][k]; end;
      14, 15, 16, 17:
            begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWAFV[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWAFV[2*wstride + k]
                                + bfac * coef[1][k]; end;
      6, 7: begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWR16[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWR16[2*wstride + k]
                                + bfac * coef[1][k]; end;
      10, 11: begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWR32[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWR32[2*wstride + k]
                                + bfac * coef[1][k]; end;
      18:   begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FW64[k]
                                + xfac * coef[1][k];
                  coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FW64[2*wstride + k]
                                + bfac * coef[1][k]; end;
    else  begin coef[0][k] := AdjustQBias(0, qb[0][k]) * scaled * FXDm * FWR64[k]
                                + xfac * coef[1][k];
                coef[2][k] := AdjustQBias(2, qb[2][k]) * scaled * FBDm * FWR64[2*wstride + k]
                                + bfac * coef[1][k]; end;
    end;
  end;

  // LLF from DC: cby x cbx mean-preserving forward DCT of the DC region,
  // scaled per axis by the resample factors, placed via the storage rule.
  for u := 0 to cbx - 1 do
    for x := 0 to cbx - 1 do begin
      s := Cos(Pi * u * (2*x + 1) / (2.0 * cbx));
      if u > 0 then s := s * Sqrt(2.0);
      cosCbX[u][x] := s;
    end;
  for v := 0 to cby - 1 do
    for y := 0 to cby - 1 do begin
      s := Cos(Pi * v * (2*y + 1) / (2.0 * cby));
      if v > 0 then s := s * Sqrt(2.0);
      cosCbY[v][y] := s;
    end;
  for c := 0 to 2 do
    for v := 0 to cby - 1 do
      for u := 0 to cbx - 1 do begin
        s := 0;
        for y := 0 to cby - 1 do
          for x := 0 to cbx - 1 do
            s := s + PlaneAt(FDC[c], absX + x, absY + y)
                   * cosCbY[v][y] * cosCbX[u][x];
        s := s / (cbx * cby);
        coef[c][KIdx(v, u)] := s * AxScale(cby, v) * AxScale(cbx, u);
      end;

  // Identity-class strategies use bespoke pixel kernels (dec_transforms-inl.h);
  // they consume the coefficient memory layout directly (no transpose).
  if acsRaw in [1, 2, 12, 13, 14, 15, 16, 17] then begin
    px := absX * 8; py := absY * 8;
    for c := 0 to 2 do
      ReconIdentityClass(c, px, py, acsRaw, coef[c]);
    Exit;
  end;

  // Mean-preserving separable IDCT (R rows x CC cols).
  SetLength(cosR, R * R);
  SetLength(cosC, CC * CC);
  SetLength(tmp, R * CC);
  for v := 0 to R - 1 do
    for y := 0 to R - 1 do begin
      s := Cos(Pi * v * (2*y + 1) / (2.0 * R));
      if v > 0 then s := s * Sqrt(2.0);
      cosR[v * R + y] := s;
    end;
  for u := 0 to CC - 1 do
    for x := 0 to CC - 1 do begin
      s := Cos(Pi * u * (2*x + 1) / (2.0 * CC));
      if u > 0 then s := s * Sqrt(2.0);
      cosC[u * CC + x] := s;
    end;

  px := absX * 8; py := absY * 8;
  for c := 0 to 2 do begin
    for v := 0 to R - 1 do
      for x := 0 to CC - 1 do begin
        s := 0;
        for u := 0 to CC - 1 do
          s := s + coef[c][KIdx(v, u)] * cosC[u * CC + x];
        tmp[v * CC + x] := s;
      end;
    for y := 0 to R - 1 do begin
      if py + y >= FParams.Height then Break;
      for x := 0 to CC - 1 do begin
        if px + x >= FParams.Width then Break;
        fv := 0;
        for v := 0 to R - 1 do
          fv := fv + tmp[v * CC + x] * cosR[v * R + y];
        PlaneSet(FRecon[c], px + x, py + y, fv);
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Identity-class dequant tables (quant_weights.cc GetQuantWeightsIdentity /
// GetQuantWeightsDCT2 / kQuantModeDCT4X8) with the library defaults.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.BuildIdentityClassTables;
const
  kIdW: array[0..2, 0..2] of Single = (
    (280.0, 3160.0, 3160.0), (60.0, 864.0, 864.0), (18.0, 200.0, 200.0));
  kD2W: array[0..2, 0..5] of Single = (
    (3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0),
    (960.0, 640.0, 320.0, 180.0, 140.0, 120.0),
    (640.0, 320.0, 128.0, 64.0, 32.0, 16.0));
  kD48BandsF: array[0..11] of Single = (
    2198.050556016380522, -0.96269623020744692, -0.76194253026666783,
    -0.6551140670773547,
    764.3655248643528689, -0.92630200888366945, -0.9675229603596517,
    -0.27845290869168118,
    527.107573587542228, -1.4594385811273854, -1.450082094097871593,
    -1.5843722511996204);
var
  c, x, y, k: Integer;
  w48: array[0..95] of Single;   // 3 x 4 x 8 (as 1/weight)
begin
  // IDENTITY: all = base; [1]=[8] = w1; [9] = w2  (stored as 1/weight)
  for c := 0 to 2 do begin
    for k := 0 to 63 do FWID[c*64 + k] := 1.0 / kIdW[c][0];
    FWID[c*64 + 1] := 1.0 / kIdW[c][1];
    FWID[c*64 + 8] := 1.0 / kIdW[c][1];
    FWID[c*64 + 9] := 1.0 / kIdW[c][2];
  end;

  // DCT2X2 (GetQuantWeightsDCT2 layout)
  for c := 0 to 2 do begin
    FWD22[c*64 + 0] := 1.0;                       // unused (LLF)
    FWD22[c*64 + 1] := 1.0 / kD2W[c][0];
    FWD22[c*64 + 8] := 1.0 / kD2W[c][0];
    FWD22[c*64 + 9] := 1.0 / kD2W[c][1];
    for y := 0 to 1 do
      for x := 0 to 1 do begin
        FWD22[c*64 + y*8 + x + 2]     := 1.0 / kD2W[c][2];
        FWD22[c*64 + (y+2)*8 + x]     := 1.0 / kD2W[c][2];
        FWD22[c*64 + (y+2)*8 + x + 2] := 1.0 / kD2W[c][3];
      end;
    for y := 0 to 3 do
      for x := 0 to 3 do begin
        FWD22[c*64 + y*8 + x + 4]     := 1.0 / kD2W[c][4];
        FWD22[c*64 + (y+4)*8 + x]     := 1.0 / kD2W[c][4];
        FWD22[c*64 + (y+4)*8 + x + 4] := 1.0 / kD2W[c][5];
      end;
  end;

  // DCT4X8: 4x8 GetQuantWeights, rows duplicated (y/2); multipliers = 1.0
  ComputeDQTable(4, 8, 4, kD48BandsF, w48);
  for c := 0 to 2 do
    for y := 0 to 7 do
      for x := 0 to 7 do
        FWD48[c*64 + y*8 + x] := w48[c*32 + (y div 2)*8 + x];

  BuildAFVTable(w48);
end;

// ---------------------------------------------------------------------------
// AFV dequant table (quant_weights.cc kQuantModeAFV, library defaults).
// w48 = 1/weight 4x8 table computed from the DCT4X8 bands.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.BuildAFVTable(const w48: array of Single);
const
  kAfvW: array[0..2, 0..8] of Single = (
    (3072.0, 3072.0, 256.0, 256.0, 256.0, 414.0, 0.0, 0.0, 0.0),
    (1024.0, 1024.0, 50.0, 50.0, 50.0, 58.0, 0.0, 0.0, 0.0),
    (384.0, 384.0, 12.0, 12.0, 12.0, 22.0, -0.25, -0.25, -0.25));
  kD44BandsF: array[0..11] of Single = (
    2200.0, 0.0, 0.0, 0.0,  392.0, 0.0, 0.0, 0.0,  112.0, -0.25, -0.25, -0.5);
  kFreqs: array[0..15] of Single = (
    0, 0, 0.8517778890324296, 5.37778436506804,
    0, 0, 4.734747904497923, 5.449245381693219,
    1.6598270267479331, 4, 7.275749096817861, 10.423227632456525,
    2.662932286148962, 7.630657783650829, 8.962388608184032, 12.97166202570235);
  kLo = 0.8517778890324296;
  kHi = 12.97166202570235 - kLo + 1e-6;
var
  w44: array[0..47] of Single;
  bands: array[0..3] of Single;
  c, i, x, y, idx: Integer;
  pos, frac, w: Single;
begin
  ComputeDQTable(4, 4, 4, kD44BandsF, w44);   // 1/weight
  for c := 0 to 2 do begin
    bands[0] := kAfvW[c][5];
    for i := 1 to 3 do
      if kAfvW[c][i + 5] > 0 then
        bands[i] := bands[i-1] * (1.0 + kAfvW[c][i + 5])
      else
        bands[i] := bands[i-1] / (1.0 - kAfvW[c][i + 5]);

    FWAFV[c*64 + 0] := 1.0;                       // unused (LLF)
    FWAFV[c*64 + 1*8 + 0] := 1.0 / kAfvW[c][0];   // (x=0,y=1)
    FWAFV[c*64 + 0*8 + 1] := 1.0 / kAfvW[c][1];   // (1,0)
    FWAFV[c*64 + 2*8 + 0] := 1.0 / kAfvW[c][2];   // (0,2)
    FWAFV[c*64 + 0*8 + 2] := 1.0 / kAfvW[c][3];   // (2,0)
    FWAFV[c*64 + 2*8 + 2] := 1.0 / kAfvW[c][4];   // (2,2)

    // AFV high-freq weights at (2x, 2y) for x,y<4, excluding the 2x2 corner.
    for y := 0 to 3 do
      for x := 0 to 3 do begin
        if (x < 2) and (y < 2) then Continue;
        pos  := (kFreqs[y*4 + x] - kLo) * 3.0 / kHi;
        idx  := Trunc(pos);
        if idx > 2 then idx := 2;
        frac := pos - idx;
        w := bands[idx] * Exp(Ln(bands[idx+1] / bands[idx]) * frac);
        FWAFV[c*64 + (2*y)*8 + 2*x] := 1.0 / w;
      end;

    // 4x8 weights in odd rows (except first position).
    for y := 0 to 3 do
      for x := 0 to 7 do begin
        if (x = 0) and (y = 0) then Continue;
        FWAFV[c*64 + (2*y + 1)*8 + x] := w48[c*32 + y*8 + x];
      end;
    // 4x4 weights in even rows / odd columns (except first position).
    for y := 0 to 3 do
      for x := 0 to 3 do begin
        if (x = 0) and (y = 0) then Continue;
        FWAFV[c*64 + (2*y)*8 + 2*x + 1] := w44[c*16 + y*4 + x];
      end;
  end;
end;

const
  // dec_transforms-inl.h k4x4AFVBasis: 16 basis vectors (j) x 16 pixels (i)
  kAFVBasis: array[0..255] of Single = (
    0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,
    0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,
    0.876902929799142, 0.2206518106944235, -0.10140050393753763,
    -0.1014005039375375, 0.2206518106944236, -0.10140050393753777,
    -0.10140050393753772, -0.10140050393753763, -0.10140050393753758,
    -0.10140050393753769, -0.1014005039375375, -0.10140050393753768,
    -0.10140050393753768, -0.10140050393753759, -0.10140050393753763,
    -0.10140050393753741,
    0.0, 0.0, 0.40670075830260755, 0.44444816619734445,
    0.0, 0.0, 0.19574399372042936, 0.2929100136981264,
    -0.40670075830260716, -0.19574399372042872, 0.0, 0.11379074460448091,
    -0.44444816619734384, -0.29291001369812636, -0.1137907446044814, 0.0,
    0.0, 0.0, -0.21255748058288748, 0.3085497062849767,
    0.0, 0.4706702258572536, -0.1621205195722993, 0.0,
    -0.21255748058287047, -0.16212051957228327, -0.47067022585725277,
    -0.1464291867126764, 0.3085497062849487, 0.0, -0.14642918671266536,
    0.4251149611657548,
    0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    -0.4105377591765233, 0.6235485373547691, -0.06435071657946274,
    -0.06435071657946266, 0.6235485373547694, -0.06435071657946284,
    -0.0643507165794628, -0.06435071657946274, -0.06435071657946272,
    -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
    -0.06435071657946277, -0.06435071657946273, -0.06435071657946274,
    -0.0643507165794626,
    0.0, 0.0, -0.4517556589999482, 0.15854503551840063,
    0.0, -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167,
    -0.45175565899994635, 0.007418226379244351, 0.1107416575309343,
    0.08298163094882051, 0.15854503551839705, 0.3935103426921022,
    0.0829816309488214, -0.45175565899994796,
    0.0, 0.0, -0.304684750724869, 0.5112616136591823,
    0.0, 0.0, -0.290480129728998, -0.06578701549142804,
    0.304684750724884, 0.2904801297290076, 0.0, -0.23889773523344604,
    -0.5112616136592012, 0.06578701549142545, 0.23889773523345467, 0.0,
    0.0, 0.0, 0.3017929516615495, 0.25792362796341184,
    0.0, 0.16272340142866204, 0.09520022653475037, 0.0,
    0.3017929516615503, 0.09520022653475055, -0.16272340142866173,
    -0.35312385449816297, 0.25792362796341295, 0.0, -0.3531238544981624,
    -0.6035859033230976,
    0.0, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0, -0.4082482904638628,
    -0.4082482904638635, 0.0, 0.0, -0.40824829046386296, 0.0,
    0.4082482904638634, 0.408248290463863, 0.0,
    0.0, 0.0, 0.1747866975480809, 0.0812611176717539,
    0.0, 0.0, -0.3675398009862027, -0.307882213957909,
    -0.17478669754808135, 0.3675398009862011, 0.0, 0.4826689115059883,
    -0.08126111767175039, 0.30788221395790305, -0.48266891150598584, 0.0,
    0.0, 0.0, -0.21105601049335784, 0.18567180916109802,
    0.0, 0.0, 0.49215859013738733, -0.38525013709251915,
    0.21105601049335806, -0.49215859013738905, 0.0, 0.17419412659916217,
    -0.18567180916109904, 0.3852501370925211, -0.1741941265991621, 0.0,
    0.0, 0.0, -0.14266084808807264, -0.3416446842253372,
    0.0, 0.7367497537172237, 0.24627107722075148, -0.08574019035519306,
    -0.14266084808807344, 0.24627107722075137, 0.14883399227113567,
    -0.04768680350229251, -0.3416446842253373, -0.08574019035519267,
    -0.047686803502292804, -0.14266084808807242,
    0.0, 0.0, -0.13813540350758585, 0.3302282550303788,
    0.0, 0.08755115000587084, -0.07946706605909573, -0.4613374887461511,
    -0.13813540350758294, -0.07946706605910261, 0.49724647109535086,
    0.12538059448563663, 0.3302282550303805, -0.4613374887461554,
    0.12538059448564315, -0.13813540350758452,
    0.0, 0.0, -0.17437602599651067, 0.0702790691196284,
    0.0, -0.2921026642334881, 0.3623817333531167, 0.0,
    -0.1743760259965108, 0.36238173335311646, 0.29210266423348785,
    -0.4326608024727445, 0.07027906911962818, 0.0, -0.4326608024727457,
    0.34875205199302267,
    0.0, 0.0, 0.11354987314994337, -0.07417504595810355,
    0.0, 0.19402893032594343, -0.435190496523228, 0.21918684838857466,
    0.11354987314994257, -0.4351904965232251, 0.5550443808910661,
    -0.25468277124066463, -0.07417504595810233, 0.2191868483885728,
    -0.25468277124066413, 0.1135498731499429);

// ---------------------------------------------------------------------------
// Identity-class pixel kernels (dec_transforms-inl.h TransformToPixels):
// IDENTITY, DCT2X2, DCT4X8, DCT8X4, AFV0..3 for one channel.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.ReconIdentityClass(c, px, py, acsRaw: Integer;
                                            const cf: array of Single);
var
  t, tt: array[0..63] of Single;
  sub: array[0..31] of Single;
  dcs: array[0..3] of Single;
  cos4: array[0..3, 0..3] of Single;
  cos8: array[0..7, 0..7] of Single;
  x2, y2, ix, iy, x, y, u, v, num, k: Integer;
  s, rsum, ctr: Single;

  procedure PSet(lx, ly: Integer; vv: Single);
  begin
    if (px + lx < FParams.Width) and (py + ly < FParams.Height) then
      PlaneSet(FRecon[c], px + lx, py + ly, vv);
  end;
  procedure IDCT2Top(SS: Integer);   // IDCT2TopBlock<SS> on t[]
  var yy, xx: Integer; c00, c01, c10, c11: Single;
  begin
    num := SS div 2;
    for yy := 0 to num - 1 do
      for xx := 0 to num - 1 do begin
        c00 := t[yy*8 + xx];
        c01 := t[yy*8 + num + xx];
        c10 := t[(yy+num)*8 + xx];
        c11 := t[(yy+num)*8 + num + xx];
        tt[yy*2*8 + xx*2]       := c00 + c01 + c10 + c11;
        tt[yy*2*8 + xx*2 + 1]   := c00 + c01 - c10 - c11;
        tt[(yy*2+1)*8 + xx*2]   := c00 - c01 + c10 - c11;
        tt[(yy*2+1)*8 + xx*2+1] := c00 - c01 - c10 + c11;
      end;
    for yy := 0 to SS - 1 do
      for xx := 0 to SS - 1 do
        t[yy*8 + xx] := tt[yy*8 + xx];
  end;
begin
  case acsRaw of
    1: begin   // IDENTITY (Hornuss)
      dcs[0] := cf[0] + cf[1] + cf[8] + cf[9];
      dcs[1] := cf[0] + cf[1] - cf[8] - cf[9];
      dcs[2] := cf[0] - cf[1] + cf[8] - cf[9];
      dcs[3] := cf[0] - cf[1] - cf[8] + cf[9];
      for y2 := 0 to 1 do
        for x2 := 0 to 1 do begin
          rsum := 0;
          for iy := 0 to 3 do
            for ix := 0 to 3 do
              if not ((ix = 0) and (iy = 0)) then
                rsum := rsum + cf[(y2 + iy*2)*8 + x2 + ix*2];
          ctr := dcs[y2*2 + x2] - rsum * (1.0/16.0);
          PSet(4*x2 + 1, 4*y2 + 1, ctr);
          for iy := 0 to 3 do
            for ix := 0 to 3 do
              if not ((ix = 1) and (iy = 1)) then
                PSet(x2*4 + ix, y2*4 + iy,
                     cf[(y2 + iy*2)*8 + x2 + ix*2] + ctr);
          PSet(x2*4, y2*4, cf[(y2 + 2)*8 + x2 + 2] + ctr);
        end;
    end;
    2: begin   // DCT2X2: recursive 2x2 upsampling cascade
      for k := 0 to 63 do t[k] := cf[k];
      IDCT2Top(2); IDCT2Top(4); IDCT2Top(8);
      for y := 0 to 7 do
        for x := 0 to 7 do
          PSet(x, y, t[y*8 + x]);
    end;
    14, 15, 16, 17: begin   // AFV0..3 (dec_transforms-inl.h AFVTransformToPixels)
      for u := 0 to 3 do
        for x := 0 to 3 do begin
          s := Cos(Pi * u * (2*x + 1) / 8.0);
          if u > 0 then s := s * Sqrt(2.0);
          cos4[u][x] := s;
        end;
      for u := 0 to 7 do
        for x := 0 to 7 do begin
          s := Cos(Pi * u * (2*x + 1) / 16.0);
          if u > 0 then s := s * Sqrt(2.0);
          cos8[u][x] := s;
        end;
      x2 := (acsRaw - 14) and 1;       // afv_x
      y2 := (acsRaw - 14) div 2;       // afv_y
      dcs[0] := (cf[0] + cf[8] + cf[1]) * 4.0;
      dcs[1] := cf[0] + cf[8] - cf[1];
      dcs[2] := cf[0] - cf[8];

      // 1. AFV 4x4 on the (afv_x, afv_y) corner from (even,even) coefficients,
      //    mirrored toward the corner.
      sub[0] := dcs[0];
      for iy := 0 to 3 do
        for ix := 0 to 3 do
          if not ((ix = 0) and (iy = 0)) then
            sub[iy*4 + ix] := cf[iy*2*8 + ix*2];
      for iy := 0 to 3 do
        for ix := 0 to 3 do begin
          // pixel value = sum_j sub[j] * basis[j][ (mirrored iy)*4 + mirrored ix ]
          u := iy; if y2 = 1 then u := 3 - iy;
          v := ix; if x2 = 1 then v := 3 - ix;
          s := 0;
          for k := 0 to 15 do
            s := s + sub[k] * kAFVBasis[k*16 + u*4 + v];
          PSet(x2*4 + ix, y2*4 + iy, s);
        end;

      // 2. DCT4x4 from (odd,even) coefficients in the horizontally adjacent
      //    4x4 quarter (same rows as the AFV corner).
      sub[0] := dcs[1];
      for iy := 0 to 3 do
        for ix := 0 to 3 do
          if not ((ix = 0) and (iy = 0)) then
            sub[iy*4 + ix] := cf[iy*2*8 + ix*2 + 1];
      // ComputeScaledIDCT<4,4>: square -> transposed storage k = u*4 + v
      for y := 0 to 3 do
        for x := 0 to 3 do begin
          s := 0;
          for v := 0 to 3 do
            for u := 0 to 3 do
              s := s + sub[u*4 + v] * cos4[v][y] * cos4[u][x];
          if x2 = 1 then PSet(x, y2*4 + y, s)
          else PSet(4 + x, y2*4 + y, s);
        end;

      // 3. DCT4x8 from odd rows, covering the other vertical half.
      sub[0] := dcs[2];
      for iy := 0 to 3 do
        for ix := 0 to 7 do
          if not ((ix = 0) and (iy = 0)) then
            sub[iy*8 + ix] := cf[(1 + iy*2)*8 + ix];
      for y := 0 to 3 do
        for x := 0 to 7 do begin
          s := 0;
          for v := 0 to 3 do
            for u := 0 to 7 do
              s := s + sub[v*8 + u] * cos4[v][y] * cos8[u][x];
          if y2 = 1 then PSet(x, y, s)
          else PSet(x, 4 + y, s);
        end;
    end;
    12, 13: begin   // DCT4X8 (two stacked) / DCT8X4 (two side-by-side)
      for u := 0 to 3 do
        for x := 0 to 3 do begin
          s := Cos(Pi * u * (2*x + 1) / 8.0);
          if u > 0 then s := s * Sqrt(2.0);
          cos4[u][x] := s;
        end;
      for u := 0 to 7 do
        for x := 0 to 7 do begin
          s := Cos(Pi * u * (2*x + 1) / 16.0);
          if u > 0 then s := s * Sqrt(2.0);
          cos8[u][x] := s;
        end;
      dcs[0] := cf[0] + cf[8];
      dcs[1] := cf[0] - cf[8];
      for y2 := 0 to 1 do begin   // y2 = half index
        sub[0] := dcs[y2];
        for iy := 0 to 3 do
          for ix := 0 to 7 do
            if not ((ix = 0) and (iy = 0)) then
              sub[iy*8 + ix] := cf[(y2 + iy*2)*8 + ix];
        if acsRaw = 12 then begin
          // ComputeScaledIDCT<4,8>: wide — sub[v*8+u], v vertical(4), u horiz(8)
          for y := 0 to 3 do
            for x := 0 to 7 do begin
              s := 0;
              for v := 0 to 3 do
                for u := 0 to 7 do
                  s := s + sub[v*8 + u] * cos4[v][y] * cos8[u][x];
              PSet(x, y2*4 + y, s);
            end;
        end else begin
          // ComputeScaledIDCT<8,4>: tall — sub[u*8+v], u horiz(4), v vert(8)
          for y := 0 to 7 do
            for x := 0 to 3 do begin
              s := 0;
              for u := 0 to 3 do
                for v := 0 to 7 do
                  s := s + sub[u*8 + v] * cos8[v][y] * cos4[u][x];
              PSet(y2*4 + x, y, s);
            end;
        end;
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Gaborish (normalized 3x3, weight2 = weight1 * default ratio) on FRecon.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.ApplyGaborish;
const
  kW2Ratio = 0.061248592 / 0.115169525;
var
  c, x, y, w, h: Integer;
  w1, w2, norm, acc: Single;
  src: array of Single;
  function S(xx, yy: Integer): Single; inline;
  begin
    if xx < 0 then xx := 0 else if xx >= w then xx := w - 1;
    if yy < 0 then yy := 0 else if yy >= h then yy := h - 1;
    Result := src[yy * w + xx];
  end;
begin
  if not FParams.Gab then Exit;
  w := FParams.Width; h := FParams.Height;
  SetLength(src, w * h);
  for c := 0 to 2 do begin
    case c of
      0: w1 := FParams.GabX;
      1: w1 := FParams.GabY;
    else w1 := FParams.GabB;
    end;
    w2   := w1 * kW2Ratio;
    norm := 1.0 / (1.0 + 4.0 * (w1 + w2));
    Move(FRecon[c].Data[0], src[0], w * h * SizeOf(Single));
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do begin
        acc := S(x, y)
             + w1 * (S(x-1, y) + S(x+1, y) + S(x, y-1) + S(x, y+1))
             + w2 * (S(x-1, y-1) + S(x+1, y-1) + S(x-1, y+1) + S(x+1, y+1));
        PlaneSet(FRecon[c], x, y, acc * norm);
      end;
  end;
end;

// ---------------------------------------------------------------------------
// Edge-preserving filter (render_pipeline/stage_epf.cc EPF1 + EPF2, defaults).
// Sigma per 8x8 block from epf.cc ComputeSigma. iters>=1: EPF1; >=2: EPF2.
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.ApplyEPF;
const
  kInvSigmaNum = -1.1715728752538099024;
  kMinSigma    = kInvSigmaNum / 0.3;
  kQuantMul    = 0.46;
  kPass2Scale  = 6.5;
  kBorderMul   = 0.6666666666666666;
  kChanScale: array[0..2] of Single = (40.0, 5.0, 3.5);
  kPlusDX: array[0..4] of Integer = (0, -1, 1, 0, 0);
  kPlusDY: array[0..4] of Integer = (0, 0, 0, -1, 1);
  kDirDX: array[0..3] of Integer = (0, -1, 1, 0);
  kDirDY: array[0..3] of Integer = (-1, 0, 0, 1);
var
  invSig: array of Single;            // per block: 1/sigma (negative)
  src: array[0..2] of array of Single;
  w, h, x, y, c, bx, by, d, p: Integer;
  sharp, sigma, sad, wt, wsum, sm: Single;
  acc: array[0..2] of Single;
  qscale: Single;
  function SP(c2, xx, yy: Integer): Single; inline;
  begin
    if xx < 0 then xx := 0 else if xx >= w then xx := w - 1;
    if yy < 0 then yy := 0 else if yy >= h then yy := h - 1;
    Result := src[c2][yy * w + xx];
  end;
  procedure SnapshotRecon;
  var cc: Integer;
  begin
    for cc := 0 to 2 do
      Move(FRecon[cc].Data[0], src[cc][0], w * h * SizeOf(Single));
  end;
begin
  if FParams.EpfIters <= 0 then Exit;
  w := FParams.Width; h := FParams.Height;
  for c := 0 to 2 do SetLength(src[c], w * h);

  // Per-block negative inverse sigma.
  qscale := FQGlobalScale / 65536.0;
  SetLength(invSig, FDCWidth * FDCHeight);
  for by := 0 to FDCHeight - 1 do
    for bx := 0 to FDCWidth - 1 do begin
      sharp := FEpf[by * FDCWidth + bx] / 7.0;     // default epf_sharp_lut
      sigma := kQuantMul / (qscale * FRawQF[by * FDCWidth + bx] * kInvSigmaNum)
               * sharp;
      if sigma > -1e-4 then sigma := -1e-4;
      invSig[by * FDCWidth + bx] := 1.0 / sigma;
    end;

  // --- EPF1: 4 neighbors, 3x3-plus SADs (iters >= 1) ---
  SnapshotRecon;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do begin
      bx := x div 8; by := y div 8;
      if invSig[by * FDCWidth + bx] < kMinSigma then Continue;
      sm := 1.65;
      if (x mod 8 = 0) or (x mod 8 = 7) or (y mod 8 = 0) or (y mod 8 = 7) then
        sm := sm * kBorderMul;
      sm := sm * invSig[by * FDCWidth + bx];

      wsum := 1.0;
      for c := 0 to 2 do acc[c] := src[c][y * w + x];
      for d := 0 to 3 do begin
        sad := 0;
        for c := 0 to 2 do begin
          sigma := 0;
          for p := 0 to 4 do
            sigma := sigma +
              Abs(SP(c, x + kDirDX[d] + kPlusDX[p], y + kDirDY[d] + kPlusDY[p])
                - SP(c, x + kPlusDX[p], y + kPlusDY[p]));
          sad := sad + sigma * kChanScale[c];
        end;
        wt := 1.0 + sad * sm;
        if wt < 0 then wt := 0;
        wsum := wsum + wt;
        for c := 0 to 2 do
          acc[c] := acc[c] + wt * SP(c, x + kDirDX[d], y + kDirDY[d]);
      end;
      for c := 0 to 2 do
        PlaneSet(FRecon[c], x, y, acc[c] / wsum);
    end;

  if FParams.EpfIters < 2 then Exit;

  // --- EPF2: 4 neighbors, single-pixel SADs, sigma scaled by 6.5 ---
  SnapshotRecon;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do begin
      bx := x div 8; by := y div 8;
      if invSig[by * FDCWidth + bx] < kMinSigma then Continue;
      sm := kPass2Scale * 1.65;
      if (x mod 8 = 0) or (x mod 8 = 7) or (y mod 8 = 0) or (y mod 8 = 7) then
        sm := sm * kBorderMul;
      sm := sm * invSig[by * FDCWidth + bx];

      wsum := 1.0;
      for c := 0 to 2 do acc[c] := src[c][y * w + x];
      for d := 0 to 3 do begin
        sad := 0;
        for c := 0 to 2 do
          sad := sad + Abs(SP(c, x + kDirDX[d], y + kDirDY[d])
                         - src[c][y * w + x]) * kChanScale[c];
        wt := 1.0 + sad * sm;
        if wt < 0 then wt := 0;
        wsum := wsum + wt;
        for c := 0 to 2 do
          acc[c] := acc[c] + wt * SP(c, x + kDirDX[d], y + kDirDY[d]);
      end;
      for c := 0 to 2 do
        PlaneSet(FRecon[c], x, y, acc[c] / wsum);
    end;
end;

procedure TVarDCTDecoder.DecodeHFGlobalSection(br: TBitReader);
const
  kNonZeroBuckets = 37;            // ac_context.h NonZeroContext buckets
  kZeroDensityContextCount = 458;  // ac_context.h
var
  allDefault: Boolean;
  numHistoBits, usedOrders, numACContexts, i: Integer;
begin
  // DequantMatrices::Decode (quant_weights.cc): per-table encodings.
  // all_default == Bits(1); only the default path is supported so far.
  allDefault := br.ReadBit;
  if not allDefault then
    raise EJxlError.Create('VarDCT: custom dequant matrices not yet supported');

  // num_histograms = 1 + ReadBits(CeilLog2(num_groups))
  numHistoBits := CeilLog2NZ(FNumGroups);
  FNumHFHistograms := 1 + Integer(br.ReadBits(numHistoBits));

  // Per pass: used_orders U32(Val($5F), Val($13), Val(0), Bits(13)),
  // then coefficient-order permutations for each used order (not yet impl.),
  // then the AC histograms.
  for i := 0 to FParams.NumPasses - 1 do begin
    usedOrders := Integer(br.ReadU32($5F,0, $13,0, 0,0, 0,13));
    DecodeCoeffOrdersAll(Cardinal(usedOrders), br);
    numACContexts := FNumHFHistograms * FBlockNumCtxs *
                     (kNonZeroBuckets + kZeroDensityContextCount);
    FHFAns := TANSDecoder.Create;
    FHFAns.InitCode(br, numACContexts);
  end;

end;

// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeACGroupSection(pass, group: Integer; br: TBitReader);
const
  kNonZeroBuckets = 37;
  kZeroDensityContextCount = 458;
var
  gx0, gy0, wBlk, hBlk: Integer;        // group origin/extent in blocks
  ctxOffset, selBits, sel: Integer;
  numCtxs, acCtxPerSet: Integer;
  nzRows: array[0..2] of array of Int32;  // per channel, wBlk*hBlk
  qblockC: TQBlocks;
  by, bx, ci, c, absX, absY, k: Integer;
  acsRaw, ord, covered, log2cov, size, bctx, predNz, nzeroCtx: Integer;
  nzeros, prev, ctx, ucoeff: Integer;
  orderBase: Integer;
  cOrderIdx: Integer;
  top, leftv: Integer;
  yy, xx: Integer;
const
  kChanOrder: array[0..2] of Integer = (1, 0, 2);   // Y, X, B
begin
  gx0  := (group mod FXSizeGroups) * 32;            // kGroupDimInBlocks
  gy0  := (group div FXSizeGroups) * 32;
  wBlk := FDCWidth  - gx0; if wBlk > 32 then wBlk := 32;
  hBlk := FDCHeight - gy0; if hBlk > 32 then hBlk := 32;

  numCtxs     := FBlockNumCtxs;
  acCtxPerSet := numCtxs * (kNonZeroBuckets + kZeroDensityContextCount);

  // Histogram-set selector is read BEFORE the ANS reader state (dec_group.cc
  // GetBlockFromBitstream::Init reads selector bits, then Create reads state).
  selBits := CeilLog2NZ(FNumHFHistograms);
  sel := 0;
  if selBits > 0 then sel := Integer(br.ReadBits(selBits));
  if sel >= FNumHFHistograms then
    raise EJxlError.Create('VarDCT: invalid histogram selector');
  ctxOffset := sel * acCtxPerSet;

  // Fresh ANS reader over the shared AC code for this section.
  FHFAns.BeginReader(br, 0);

  for c := 0 to 2 do begin
    SetLength(nzRows[c], wBlk * hBlk);
    for k := 0 to wBlk * hBlk - 1 do nzRows[c][k] := 0;
  end;

  for by := 0 to hBlk - 1 do begin
    for bx := 0 to wBlk - 1 do begin
      absX := gx0 + bx; absY := gy0 + by;
      if not FAcsOrigin[absY * FDCWidth + absX] then Continue;
      acsRaw  := FAcsRaw[absY * FDCWidth + absX];
      ord     := kStrategyOrder[acsRaw];
      covered := kAcsCbX[acsRaw] * kAcsCbY[acsRaw];
      log2cov := CeilLog2NZ(covered);
      size    := covered * 64;
      for c := 0 to 2 do begin
        SetLength(qblockC[c], size);
        for k := 0 to size - 1 do qblockC[c][k] := 0;
      end;

      for ci := 0 to 2 do begin
        c := kChanOrder[ci];
        // BlockCtxMap::Context(dc_idx=0, qf, ord, c):
        //   idx = (c<2 ? c^1 : 2)*13 + ord; *(qft+1)+qf_idx; *num_dc_ctxs+0
        if c < 2 then bctx := (c xor 1) * 13 + ord else bctx := 2 * 13 + ord;
        bctx := bctx * (FQfThreshCount + 1);
        for k := 0 to FQfThreshCount - 1 do
          if Cardinal(FRawQF[absY * FDCWidth + absX]) > FQfThresh[k] then
            Inc(bctx);
        bctx := bctx * FBlockNumDcCtxs;   // dc_idx = 0 (num_dc_ctxs = 1 here)
        bctx := FBlockCtxMap[bctx];

        // predicted nzeros from top/left rows
        if bx = 0 then begin
          if by = 0 then predNz := 32
          else predNz := nzRows[c][(by-1) * wBlk];
        end else if by = 0 then
          predNz := nzRows[c][bx - 1]
        else begin
          top   := nzRows[c][(by-1) * wBlk + bx];
          leftv := nzRows[c][by * wBlk + bx - 1];
          predNz := (top + leftv + 1) div 2;
        end;

        // NonZeroContext(nz, bctx) = (nz<8 ? nz : 4+nz/2) * num_ctxs + bctx
        if predNz < 8 then nzeroCtx := predNz else nzeroCtx := 4 + predNz div 2;
        nzeroCtx := ctxOffset + nzeroCtx * numCtxs + bctx;

        nzeros := Integer(FHFAns.Decode(nzeroCtx, br));
        if nzeros > size - covered then
          raise EJxlError.Create('VarDCT: invalid AC nzeros');
        for yy := 0 to kAcsCbY[acsRaw] - 1 do
          for xx := 0 to kAcsCbX[acsRaw] - 1 do
            nzRows[c][(by+yy) * wBlk + bx + xx] :=
              (nzeros + covered - 1) shr log2cov;

        // coefficients
        orderBase := kCoeffOrderOffset[3 * ord + c] * 64;
        if nzeros > size div 16 then prev := 0 else prev := 1;
        k := covered;
        while (k < size) and (nzeros <> 0) do begin
          ctx := ctxOffset + numCtxs * kNonZeroBuckets +
                 kZeroDensityContextCount * bctx +
                 (Integer(kCoeffNumNonzeroContext[(nzeros + covered - 1) shr log2cov]) +
                  Integer(kCoeffFreqContext[k shr log2cov])) * 2 + prev;
          ucoeff := Integer(FHFAns.Decode(ctx, br));
          cOrderIdx := Integer(FCoeffOrders[orderBase + k]);
          if (ucoeff and 1) <> 0 then
            qblockC[c][cOrderIdx] := qblockC[c][cOrderIdx] - Integer((Cardinal(ucoeff) + 1) shr 1)
          else
            qblockC[c][cOrderIdx] := qblockC[c][cOrderIdx] + (ucoeff shr 1);
          if ucoeff <> 0 then prev := 1 else prev := 0;
          Dec(nzeros, prev);
          Inc(k);
        end;
        if nzeros <> 0 then
          raise EJxlError.Create('VarDCT: AC nzeros mismatch at block end');
      end;
      case acsRaw of
        0, 1, 2, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20:
          ReconstructDCT8Block(absX, absY, acsRaw, qblockC);
      end;
    end;
  end;

  if not FHFAns.CheckFinalState then
    raise EJxlError.Create('VarDCT: AC group ANS final state error');
  if group = 0 then
end;

// ---------------------------------------------------------------------------
// Top-level TOC-driven dispatch. Section layout (toc.h):
//   0                         : LFGlobal
//   1 .. numLFGroups          : LFGroup[i]
//   numLFGroups+1             : HFGlobal
//   numLFGroups+2 + p*nG + g  : ACGroup[pass p, group g]
// ---------------------------------------------------------------------------
procedure TVarDCTDecoder.DecodeSections(data: PByte; dataStart: NativeUInt;
                                        const sizes: array of Cardinal;
                                        const params: TVarDCTFrameParams;
                                        var output: TJxlImageF);
var
  sec: TBitReader;
  i, p, g, baseAC, secIdx, x, y: Integer;
begin
  FParams     := params;
  FXYBEncoded := params.XYBEncoded;
  ComputeFrameDim;

  // Allocate the dequantized DC image (1/8 resolution).
  FDCWidth  := CeilDiv(FParams.Width,  8);
  FDCHeight := CeilDiv(FParams.Height, 8);
  for i := 0 to 2 do
    InitFloat32Plane(FDC[i], FDCWidth, FDCHeight);

  // AC metadata arrays (per block) and CfL tile maps (per 8x8 blocks).
  SetLength(FAcsRaw,    FDCWidth * FDCHeight);
  SetLength(FAcsValid,  FDCWidth * FDCHeight);
  SetLength(FAcsOrigin, FDCWidth * FDCHeight);
  SetLength(FRawQF,     FDCWidth * FDCHeight);
  SetLength(FEpf,       FDCWidth * FDCHeight);
  for i := 0 to FDCWidth * FDCHeight - 1 do begin
    FAcsRaw[i] := 0; FAcsValid[i] := False; FAcsOrigin[i] := False;
    FRawQF[i] := 1; FEpf[i] := 0;
  end;
  FTileW := CeilDiv(FDCWidth, 8);
  FTileH := CeilDiv(FDCHeight, 8);
  SetLength(FYtoXMap, FTileW * FTileH);
  SetLength(FYtoBMap, FTileW * FTileH);


  // --- LFGlobal (section 0) ---
  sec := MakeSectionReader(data, dataStart, sizes, 0);
  try
    DecodeLFGlobal(sec);
  finally
    sec.Free;
  end;

  // --- LFGroups (sections 1 .. numLFGroups) ---
  for i := 0 to FNumLFGroups - 1 do begin
    sec := MakeSectionReader(data, dataStart, sizes, 1 + i);
    try
      DecodeLFGroupSection(i, sec);
    finally
      sec.Free;
    end;
  end;

  // Prepare reconstruction: DC prefill + DCT8 dequant weights + QM multipliers.
  for i := 0 to 2 do
    InitFloat32Plane(FRecon[i], FParams.Width, FParams.Height);
  for i := 0 to 2 do
    for y := 0 to FParams.Height - 1 do
      for x := 0 to FParams.Width - 1 do
        PlaneSet(FRecon[i], x, y, PlaneAt(FDC[i], x div 8, y div 8));
  ComputeDQTable(8,  8,  6, kDCT8BandsF,    FW8);
  ComputeDQTable(16, 16, 7, kDCT16BandsF,   FW16);
  ComputeDQTable(32, 32, 8, kDCT32BandsF,   FW32);
  ComputeDQTable(8,  16, 7, kDCT8X16BandsF, FWR16);
  ComputeDQTable(16, 32, 8, kDCT16X32BandsF, FWR32);
  ComputeDQTable(64, 64, 8, kDCT64BandsF,   FW64);
  ComputeDQTable(32, 64, 8, kDCT32X64BandsF, FWR64);
  BuildIdentityClassTables;
  FXDm := Exp(Ln(1.0 / 1.25) * (FParams.XQMScale - 2));   // 1.25^(2-xqm)
  FBDm := Exp(Ln(1.0 / 1.25) * (FParams.BQMScale - 2));

  // --- HFGlobal (section numLFGroups+1) ---
  sec := MakeSectionReader(data, dataStart, sizes, FNumLFGroups + 1);
  try
    DecodeHFGlobalSection(sec);
  finally
    sec.Free;
  end;

  // --- ACGroups (one per pass per group) ---
  baseAC := FNumLFGroups + 2;
  for p := 0 to FParams.NumPasses - 1 do
    for g := 0 to FNumGroups - 1 do begin
      secIdx := baseAC + p * FNumGroups + g;
      if secIdx >= Length(sizes) then Continue;
      sec := MakeSectionReader(data, dataStart, sizes, secIdx);
      try
        DecodeACGroupSection(p, g, sec);
      finally
        sec.Free;
      end;
    end;

  // Restoration filters in libjxl order: gaborish, then EPF (both in XYB).
  ApplyGaborish;
  ApplyEPF;

  // Output the reconstructed image (DCT8 blocks fully reconstructed; other
  // strategies currently keep the DC fill).
  output.Width       := FParams.Width;
  output.Height      := FParams.Height;
  output.NumChannels := 3;
  for i := 0 to 2 do
    InitFloat32Plane(output.Planes[i], output.Width, output.Height);
  for i := 0 to 2 do
    for y := 0 to FParams.Height - 1 do
      for x := 0 to FParams.Width - 1 do
        PlaneSet(output.Planes[i], x, y, PlaneAt(FRecon[i], x, y));
end;

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

end.
