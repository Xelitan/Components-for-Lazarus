{$mode delphi}
unit jxl_frame;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JXL Frame decoder: FrameHeader, TOC, and dispatch to
// modular or VarDCT sub-decoders.
//
// AllDefault convention (libjxl fields.cc ReadVisitor): value = (bit == 1).
//   bit=1 (ReadBit=True)  -> all-default, skip rest
//   bit=0 (ReadBit=False) -> explicit fields follow
// Implemented as:  allDefault := br.ReadBit;
// Every Bool field is likewise read as value=(bit==1) — no inversion.

interface

uses
  SysUtils, Math, jxl_types, jxl_bits, jxl_ans,
  jxl_modular, jxl_vardct, jxl_color;

// Flag bits in FrameHeader.Flags (from libjxl frame_header.h)
const
  kFlagNoise                 = 1;
  kFlagPatches               = 2;
  kFlagSplines               = 16;
  kFlagUseDcFrame            = 32;
  kFlagSkipAdaptiveDCSmoothing = 128;

type
  TBlendInfo = record
    Mode:       TJxlBlendMode;
    Alpha:      Integer;
    Clamp:      Boolean;
    Source:     Integer;
  end;

  TRestorationFilter = record
    Gab:            Boolean;
    GabX, GabY, GabXB: Single;   // weight1 for each channel
    EPF:            Integer;      // epf_iters 0..3
  end;

  TFrameHeader = record
    FrameType:      TJxlFrameType;
    Encoding:       Integer;    // 0 = VarDCT, 1 = Modular
    Flags:          UInt64;
    DoYCbCr:        Boolean;
    NumPasses:      Integer;
    XOffset, YOffset: Int64;
    Width, Height:  Integer;
    IsLast:         Boolean;
    DcLevel:        Integer;    // 0 = not a DC frame; 1..4 = pyramid level
    BlendInfo:      TBlendInfo;
    BlendInfoEC:    array of TBlendInfo;
    SaveAsRef:      Integer;
    Name:           AnsiString;
    RestorationFilter: TRestorationFilter;
    XQMScale:       Integer;    // VarDCT + XYB only (default 3)
    BQMScale:       Integer;    // VarDCT + XYB only (default 2)
    GroupSizeShift: Integer;    // Modular only (default 1)
    Extensions:     UInt64;
  end;

  TFrameDecoder = class
  private
    FMetadata:    TJxlImageMetadata;
    FHeader:      TFrameHeader;

    // TOC (Table of Contents): per-section sizes in bytes
    FTOCSizes:    array of Cardinal;
    FTOCPerms:    array of Integer;
    FNumSections: Integer;
    FSectionBase: NativeUInt;    // byte offset of the first section payload

    procedure SkipExtensions(br: TBitReader);
    procedure ReadPasses(br: TBitReader);
    procedure ReadBlendInfo(br: TBitReader; var bi: TBlendInfo;
                            ecCount: Integer; isPartial: Boolean);
    procedure ReadLoopFilter(br: TBitReader; isModular: Boolean);
    procedure ReadFrameHeader(br: TBitReader);
    procedure ReadTOC(br: TBitReader);
    procedure DecodeModularGroups(br: TBitReader; var modImg: TModImage;
                                  const gTree: TMATree; gAns: TANSDecoder);
    procedure DecodeVarDCT(br: TBitReader; var img: TJxlImageF);
    procedure DecodeModular(br: TBitReader; var img: TJxlImageF);
    procedure ApplyColorConversion(var img: TJxlImageF);
    procedure ApplyRestoration(var img: TJxlImageF);
  public
    constructor Create(const md: TJxlImageMetadata);
    destructor  Destroy; override;

    procedure Decode(br: TBitReader; var output: TJxlImageF);

    property Header: TFrameHeader read FHeader;
  end;

implementation

// ---------------------------------------------------------------------------
// SkipExtensions: reads the JXL extension U64 mask then skips
// any per-extension bit blobs.
// ---------------------------------------------------------------------------
procedure TFrameDecoder.SkipExtensions(br: TBitReader);
var
  mask:    UInt64;
  i:       Integer;
  extBits: UInt64;
  n:       Integer;
begin
  mask := br.ReadU64;
  if mask = 0 then Exit;
  for i := 0 to 63 do begin
    if (mask shr i) and 1 = 0 then Continue;
    extBits := br.ReadU64;
    // Guard against runaway on a misaligned/garbage U64
    if extBits > UInt64(br.BytesLeft) * 8 + 64 then
      raise EJxlError.CreateFmt(
        'Extension size %d exceeds remaining stream', [extBits]);
    // Skip extBits bits in chunks of up to 32
    while extBits >= 32 do begin
      br.ReadBits(32);
      Dec(extBits, 32);
    end;
    n := Integer(extBits);
    if n > 0 then br.ReadBits(n);
  end;
end;

// ---------------------------------------------------------------------------
// ReadPasses: Passes nested bundle — NO AllDefault bit of its own.
// Reads num_passes and (if > 1) downsampling/shift tables.
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ReadPasses(br: TBitReader);
var
  numPasses, numDownsample: Cardinal;
  i: Integer;
begin
  // num_passes: U32(Val(1), Val(2), Val(3), BitsOffset(3,4)) — default 1
  numPasses := br.ReadU32(1,0, 2,0, 3,0, 4,3);
  if numPasses > MAX_NUM_PASSES then
    numPasses := MAX_NUM_PASSES;
  FHeader.NumPasses := Integer(numPasses);

  if numPasses = 1 then Exit;

  // num_downsample: U32(Val(0), Val(1), Val(2), BitsOffset(1,3)) — default 0
  numDownsample := br.ReadU32(0,0, 1,0, 2,0, 3,1);

  // shift[i] = Bits(2) for i = 0 .. num_passes-2
  for i := 0 to Integer(numPasses) - 2 do
    br.ReadBits(2);

  // downsample[i]: U32(Val(1), Val(2), Val(4), Val(8)) × num_downsample
  for i := 0 to Integer(numDownsample) - 1 do
    br.ReadU32(1,0, 2,0, 4,0, 8,0);

  // last_pass[i]: U32(Val(0), Val(1), Val(2), Bits(3)) × num_downsample
  for i := 0 to Integer(numDownsample) - 1 do
    br.ReadU32(0,0, 1,0, 2,0, 0,3);
end;

// ---------------------------------------------------------------------------
// ReadBlendInfo: BlendingInfo nested bundle — NO AllDefault bit.
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ReadBlendInfo(br: TBitReader; var bi: TBlendInfo;
                                      ecCount: Integer; isPartial: Boolean);
var bm: Cardinal;
begin
  // mode: U32(Val(0), Val(1), Val(2), BitsOffset(2,3))
  //   sel=0 -> 0 (Replace), sel=1 -> 1 (Add), sel=2 -> 2 (Blend),
  //   sel=3 -> 3+ReadBits(2) -> 3..6 (AlphaWeightedAdd=3, Mul=4)
  bm := br.ReadU32(0,0, 1,0, 2,0, 3,2);
  if bm > 4 then bm := 0;
  bi.Mode := TJxlBlendMode(bm);

  // alpha_channel: U32(Val(0), Val(1), Val(2), BitsOffset(3,3))
  // only if ecCount>0 AND mode is kBlend or kAlphaWeightedAdd
  bi.Alpha := 0;
  if (ecCount > 0) and (bi.Mode in [jbmBlend, jbmMulAdd]) then
    bi.Alpha := Integer(br.ReadU32(0,0, 1,0, 2,0, 3,3));

  // clamp: Bool(false) — 1 bit
  // only if (ecCount>0 AND kBlend/kAlphaWeightedAdd) OR kMul
  bi.Clamp := False;
  if ((ecCount > 0) and (bi.Mode in [jbmBlend, jbmMulAdd])) or
     (bi.Mode = jbmMul) then
    bi.Clamp := br.ReadBit;

  // source: U32(Val(0), Val(1), Val(2), Val(3))
  // only if mode != kReplace OR is partial frame
  bi.Source := 0;
  if (bi.Mode <> jbmReplace) or isPartial then
    bi.Source := Integer(br.ReadU32(0,0, 1,0, 2,0, 3,0));
end;

// ---------------------------------------------------------------------------
// ReadLoopFilter: LoopFilter nested bundle — HAS its own AllDefault bit.
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ReadLoopFilter(br: TBitReader; isModular: Boolean);
var
  allDefault:                         Boolean;
  gab, gabCustom:                     Boolean;
  epfIters:                           Integer;
  epfSharpCustom, epfWeightCustom,
  epfSigmaCustom:                     Boolean;
  i:                                  Integer;
begin
  // AllDefault bit: 0 = all-default (our convention)
  allDefault := br.ReadBit;
  if allDefault then begin
    // Default values per JXL spec
    FHeader.RestorationFilter.Gab   := True;
    FHeader.RestorationFilter.GabX  := 1.1 * 0.104699568;  // gab_x_weight1
    FHeader.RestorationFilter.GabY  := 1.1 * 0.104699568;  // gab_y_weight1
    FHeader.RestorationFilter.GabXB := 1.1 * 0.104699568;  // gab_b_weight1
    FHeader.RestorationFilter.EPF   := 2;
    Exit;
  end;

  // gab: Bool(true, &gab) — on read, gab = (bit==1). No inversion.
  gab := br.ReadBit;
  FHeader.RestorationFilter.Gab   := gab;
  FHeader.RestorationFilter.GabX  := 1.1 * 0.104699568;
  FHeader.RestorationFilter.GabY  := 1.1 * 0.104699568;
  FHeader.RestorationFilter.GabXB := 1.1 * 0.104699568;

  if gab then begin
    // gab_custom: Bool(false, &gab_custom) — default=false, bit=value directly.
    gabCustom := br.ReadBit;
    if gabCustom then begin
      // 6 F16 weights: x_weight1, x_weight2, y_weight1, y_weight2, b_weight1, b_weight2
      FHeader.RestorationFilter.GabX  := br.ReadF16;  // gab_x_weight1
      br.ReadF16;                                        // gab_x_weight2 (discard)
      FHeader.RestorationFilter.GabY  := br.ReadF16;  // gab_y_weight1
      br.ReadF16;                                        // gab_y_weight2 (discard)
      FHeader.RestorationFilter.GabXB := br.ReadF16;  // gab_b_weight1
      br.ReadF16;                                        // gab_b_weight2 (discard)
    end;
  end;

  // epf_iters: Bits(2) — default 2
  epfIters := br.ReadBits(2);
  FHeader.RestorationFilter.EPF := epfIters;

  if epfIters > 0 then begin
    // EPF sharp LUT: only if NOT modular
    if not isModular then begin
      epfSharpCustom := br.ReadBit;  // Bool(false)
      if epfSharpCustom then begin
        for i := 0 to 7 do br.ReadF16;  // kEpfSharpEntries = 8 values
      end;
    end;

    // EPF channel weights
    epfWeightCustom := br.ReadBit;  // Bool(false)
    if epfWeightCustom then begin
      br.ReadF16;  // epf_channel_scale[0]
      br.ReadF16;  // epf_channel_scale[1]
      br.ReadF16;  // epf_channel_scale[2]
      br.ReadF16;  // epf_pass1_zeroflush
      br.ReadF16;  // epf_pass2_zeroflush
    end;

    // EPF sigma
    epfSigmaCustom := br.ReadBit;  // Bool(false)
    if epfSigmaCustom then begin
      if not isModular then br.ReadF16;  // epf_quant_mul
      br.ReadF16;  // epf_pass0_sigma_scale
      br.ReadF16;  // epf_pass2_sigma_scale
      br.ReadF16;  // epf_border_sad_mul
    end;

    // Modular-only sigma
    if isModular then
      br.ReadF16;  // epf_sigma_for_modular
  end;

  // LoopFilter extensions
  SkipExtensions(br);
end;

// ---------------------------------------------------------------------------
// ReadFrameHeader — correct AllDefault + full field structure
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ReadFrameHeader(br: TBitReader);
var
  allDefault:      Boolean;
  ftRaw:           Cardinal;
  isModular:       Boolean;
  ecCount:         Integer;
  isPartialFrame:  Boolean;
  canBeRef:        Boolean;
  ux0, uy0, xsz, ysz: Cardinal;
  nameLen:         Cardinal;
  i, j:            Integer;
begin
  // ---- Initialize all fields to defaults first ----
  FHeader.FrameType    := jftRegular;
  FHeader.Encoding     := 0;           // VarDCT
  FHeader.Flags        := 0;
  FHeader.DoYCbCr      := False;
  FHeader.NumPasses    := 1;
  FHeader.XOffset      := 0;
  FHeader.YOffset      := 0;
  FHeader.Width        := Integer(FMetadata.XSize);
  FHeader.Height       := Integer(FMetadata.YSize);
  FHeader.IsLast       := True;
  FHeader.DcLevel      := 0;
  FHeader.BlendInfo.Mode   := jbmReplace;
  FHeader.BlendInfo.Alpha  := 0;
  FHeader.BlendInfo.Clamp  := False;
  FHeader.BlendInfo.Source := 0;
  SetLength(FHeader.BlendInfoEC, 0);
  FHeader.SaveAsRef    := 0;
  FHeader.Name         := '';
  FHeader.XQMScale     := 3;
  FHeader.BQMScale     := 2;
  FHeader.GroupSizeShift := 1;
  FHeader.Extensions   := 0;
  FHeader.RestorationFilter.Gab   := True;
  FHeader.RestorationFilter.GabX  := 1.1 * 0.104699568;
  FHeader.RestorationFilter.GabY  := 1.1 * 0.104699568;
  FHeader.RestorationFilter.GabXB := 1.1 * 0.104699568;
  FHeader.RestorationFilter.EPF   := 2;

  // ---- AllDefault preamble ----
  // bit=0 (ReadBit returns False) -> all-default; bit=1 -> explicit fields
  allDefault := br.ReadBit;
  if allDefault then Exit;  // all defaults already set above

  // ---- FrameType: U32(Val(0), Val(1), Val(2), Val(3)) ----
  ftRaw := br.ReadU32(0,0, 1,0, 2,0, 3,0);
  case ftRaw of
    0: FHeader.FrameType := jftRegular;
    1: FHeader.FrameType := jftLF;           // kDCFrame
    2: FHeader.FrameType := jftReferenceOnly;
  else FHeader.FrameType := jftSkipProgressive;
  end;

  // ---- is_modular: Bool(false) — bit=0→VarDCT, bit=1→Modular ----
  isModular := br.ReadBit;
  if isModular then FHeader.Encoding := 1 else FHeader.Encoding := 0;

  // ---- flags: U64 ----
  FHeader.Flags := br.ReadU64;

  // ---- Color transform ----
  // If XYB-encoded: color_transform = kXYB (no bits read)
  // If not XYB: read Bool(false) for kYCbCr alternate
  FHeader.DoYCbCr := False;
  if not FMetadata.XYBEncoded then begin
    FHeader.DoYCbCr := br.ReadBit;   // Bool(false): bit=0→None, bit=1→YCbCr
    // Chroma subsampling: 3 × Bits(2) = 6 bits
    // Conditional on YCbCr AND NOT kUseDcFrame flag
    if FHeader.DoYCbCr and ((FHeader.Flags and kFlagUseDcFrame) = 0) then begin
      br.ReadBits(2);  // channel_mode[0]
      br.ReadBits(2);  // channel_mode[1]
      br.ReadBits(2);  // channel_mode[2]
    end;
  end;

  // ---- Upsampling: conditional on NOT kUseDcFrame ----
  if (FHeader.Flags and kFlagUseDcFrame) = 0 then begin
    br.ReadU32(1,0, 2,0, 4,0, 8,0);  // upsampling factor (discard)
    ecCount := Length(FMetadata.ExtraChannels);
    if ecCount > 0 then
      for i := 0 to ecCount - 1 do
        br.ReadU32(1,0, 2,0, 4,0, 8,0);  // EC upsampling (discard)
  end;

  // ---- Modular group_size_shift: Bits(2, default=1) ----
  FHeader.GroupSizeShift := 1;
  if FHeader.Encoding = 1 {Modular} then
    FHeader.GroupSizeShift := br.ReadBits(2);

  // ---- VarDCT XYB quality scales: Bits(3) each ----
  FHeader.XQMScale := 3;
  FHeader.BQMScale := 2;
  if (FHeader.Encoding = 0 {VarDCT}) and FMetadata.XYBEncoded then begin
    FHeader.XQMScale := br.ReadBits(3);
    FHeader.BQMScale := br.ReadBits(3);
  end;

  // ---- Passes (nested bundle, no AllDefault bit): skip for kReferenceOnly ----
  FHeader.NumPasses := 1;
  if FHeader.FrameType <> jftReferenceOnly then
    ReadPasses(br);

  // ---- DC level: only for kDCFrame (jftLF) ----
  FHeader.DcLevel := 0;
  if FHeader.FrameType = jftLF then
    FHeader.DcLevel := Integer(br.ReadU32(1,0, 2,0, 3,0, 4,0));

  // ---- Custom size / origin: Bool(false) then optional crop fields ----
  // Conditional on frame_type != kDCFrame
  isPartialFrame := False;
  if FHeader.FrameType <> jftLF then begin
    if br.ReadBit then begin  // custom_size_or_origin Bool(false)
      // Size encoding: U32(Bits(8), BitsOffset(11,256), BitsOffset(14,2304), BitsOffset(30,18688))
      // Frame origin: only for kRegular and kSkipProgressive; packed-signed
      ux0 := 0; uy0 := 0;
      if (FHeader.FrameType = jftRegular) or
         (FHeader.FrameType = jftSkipProgressive) then begin
        ux0 := br.ReadU32(0,8, 256,11, 2304,14, 18688,30);  // packed-signed x0
        uy0 := br.ReadU32(0,8, 256,11, 2304,14, 18688,30);  // packed-signed y0
        // UnpackSigned: odd → negative, even → non-negative
        if (ux0 and 1) <> 0 then
          FHeader.XOffset := -Int64((ux0 + 1) shr 1)
        else
          FHeader.XOffset := Int64(ux0 shr 1);
        if (uy0 and 1) <> 0 then
          FHeader.YOffset := -Int64((uy0 + 1) shr 1)
        else
          FHeader.YOffset := Int64(uy0 shr 1);
      end;
      // Frame size
      xsz := br.ReadU32(0,8, 256,11, 2304,14, 18688,30);
      ysz := br.ReadU32(0,8, 256,11, 2304,14, 18688,30);
      FHeader.Width  := Integer(xsz);
      FHeader.Height := Integer(ysz);
      // Determine if partial
      if (FHeader.FrameType = jftRegular) or
         (FHeader.FrameType = jftSkipProgressive) then begin
        isPartialFrame :=
          (FHeader.XOffset > 0) or (FHeader.YOffset > 0) or
          (Int64(xsz) + FHeader.XOffset < Int64(FMetadata.XSize)) or
          (Int64(ysz) + FHeader.YOffset < Int64(FMetadata.YSize));
      end;
    end;
  end;

  // ---- Blending info + is_last ----
  // Only for kRegular and kSkipProgressive frames
  FHeader.IsLast := False;
  ecCount := Length(FMetadata.ExtraChannels);
  if (FHeader.FrameType = jftRegular) or
     (FHeader.FrameType = jftSkipProgressive) then begin
    ReadBlendInfo(br, FHeader.BlendInfo, ecCount, isPartialFrame);
    SetLength(FHeader.BlendInfoEC, ecCount);
    for i := 0 to ecCount - 1 do
      ReadBlendInfo(br, FHeader.BlendInfoEC[i], ecCount, isPartialFrame);
    // AnimationFrame: conditional on metadata.have_animation
    // TJxlImageMetadata has no have_animation → skip entirely
    // is_last Bool(true): on read, is_last = (bit==1). No inversion.
    FHeader.IsLast := br.ReadBit;
  end;

  // ---- save_as_reference: U32(Val(0), Val(1), Val(2), Val(3)) ----
  // Conditional on frame_type != kDCFrame AND NOT is_last
  FHeader.SaveAsRef := 0;
  if (FHeader.FrameType <> jftLF) and not FHeader.IsLast then
    FHeader.SaveAsRef := Integer(br.ReadU32(0,0, 1,0, 2,0, 3,0));

  // ---- save_before_color_transform: Bool(false) — conditional ----
  // CanBeReferenced = !is_last && frame_type!=kDCFrame && (duration=0||save_as_ref!=0)
  // Since we have no animation, duration=0 always, so:
  // CanBeReferenced = !is_last && frame_type!=kDCFrame
  canBeRef := (not FHeader.IsLast) and (FHeader.FrameType <> jftLF);
  if FHeader.FrameType <> jftLF then begin
    if canBeRef and
       (FHeader.BlendInfo.Mode = jbmReplace) and
       not isPartialFrame and
       ((FHeader.FrameType = jftRegular) or
        (FHeader.FrameType = jftSkipProgressive)) then
      br.ReadBit   // save_before_color_transform Bool(false) — discard
    else if FHeader.FrameType = jftReferenceOnly then
      br.ReadBit;  // save_before_color_transform Bool(true) — discard
  end;

  // ---- Name string ----
  // U32(Val(0), Bits(4), BitsOffset(5,16), BitsOffset(10,48)) for length
  nameLen := br.ReadU32(0,0, 0,4, 16,5, 48,10);
  if nameLen > UInt64(br.BytesLeft) then
    raise EJxlError.CreateFmt('Frame name length %d exceeds stream', [nameLen]);
  SetLength(FHeader.Name, nameLen);
  for j := 1 to Integer(nameLen) do
    FHeader.Name[j] := Chr(br.ReadBits(8));

  // ---- LoopFilter nested bundle (HAS its own AllDefault bit) ----
  ReadLoopFilter(br, isModular);

  // ---- FrameHeader extensions ----
  SkipExtensions(br);
end;

// ---------------------------------------------------------------------------
// ReadTOC — Table of Contents
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ReadTOC(br: TBitReader);
var
  frameW, frameH: Integer;
  numGroups, numLFGroups, numPasses, groupDim: Integer;
  numSections, i: Integer;
  hasPerms: Boolean;
  dcFactor: Integer;
begin
  // For DC frames (kDCFrame / jftLF), actual pixel dimensions are
  // divided by 8^dc_level on each axis.
  frameW := FHeader.Width;
  frameH := FHeader.Height;
  if (FHeader.FrameType = jftLF) and (FHeader.DcLevel > 0) then begin
    dcFactor := 1 shl (3 * FHeader.DcLevel);  // 8^dc_level
    frameW   := (frameW + dcFactor - 1) div dcFactor;
    frameH   := (frameH + dcFactor - 1) div dcFactor;
  end;

  // Group dimension: 128 << group_size_shift (VarDCT always uses shift 1).
  if FHeader.Encoding = 0 then
    groupDim := kGroupDim
  else
    groupDim := 128 shl FHeader.GroupSizeShift;

  numGroups  := ((frameW + groupDim - 1) div groupDim) *
                ((frameH + groupDim - 1) div groupDim);
  numLFGroups:= ((frameW + groupDim * 8 - 1) div (groupDim * 8)) *
                ((frameH + groupDim * 8 - 1) div (groupDim * 8));
  numPasses  := FHeader.NumPasses;

  // Section count (toc.h NumTocEntries, encoding-independent):
  //   collapsed to 1 when num_groups == 1 and num_passes == 1; otherwise
  //   1 (LfGlobal) + numLFGroups (DC) + 1 (ACGlobal) + numGroups*numPasses.
  if (numGroups = 1) and (numPasses = 1) then
    numSections := 1
  else
    numSections := 2 + numLFGroups + numGroups * numPasses;

  FNumSections := numSections;
  SetLength(FTOCSizes, numSections);
  SetLength(FTOCPerms, numSections);
  for i := 0 to numSections - 1 do FTOCPerms[i] := i;

  // Permutation flag
  hasPerms := br.ReadBit;
  if hasPerms then begin
    // Lehmer-code permutation — simplified: just discard
    for i := 0 to numSections - 1 do
      FTOCPerms[i] := Integer(br.ReadU32(0,0, 0,5, 0,10, 0,16)) mod numSections;
  end;

  br.AlignToByte;

  // Section sizes: U32(Bits(10), BitsOffset(14,1024), BitsOffset(22,17408), BitsOffset(30,4211712))
  // Sizes are stored AS-IS (no +1/-1 convention). Confirmed by libjxl enc_toc.cc write path.
  for i := 0 to numSections - 1 do
    FTOCSizes[i] := br.ReadU32(0,10, 1024,14, 17408,22, 4211712,30);

  br.AlignToByte;
end;

// ---------------------------------------------------------------------------
// Color conversion after decoding
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ApplyColorConversion(var img: TJxlImageF);
var c: Integer;
begin
  if FMetadata.XYBEncoded then begin
    // XYB → linear sRGB → display sRGB
    XYBToLinearSRGB(img.Planes[0], img.Planes[1], img.Planes[2]);
    for c := 0 to 2 do
      ApplyTransferFunction(img.Planes[c], jtfSRGB, 0);
  end else if FHeader.Encoding = 0 then begin
    // VarDCT non-XYB: samples are linear; apply the transfer function.
    for c := 0 to img.NumChannels - 1 do
      ApplyTransferFunction(img.Planes[c],
                            FMetadata.ColorEncoding.TransferFn,
                            FMetadata.ColorEncoding.Gamma);
  end;
  // Modular non-XYB integer samples are already display-referred: no-op.
end;

// ---------------------------------------------------------------------------
// Gaborish restoration filter (simplified 3×3 kernel)
// ---------------------------------------------------------------------------
procedure TFrameDecoder.ApplyRestoration(var img: TJxlImageF);
const
  kGabW2Ratio = 0.061248592 / 0.115169525;  // default weight2 / weight1
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
  if not FHeader.RestorationFilter.Gab then Exit;
  for c := 0 to img.NumChannels - 1 do begin
    w  := img.Planes[c].Width;
    h  := img.Planes[c].Height;
    w1 := FHeader.RestorationFilter.GabX;     // weight1 (per-channel)
    case c of
      1: w1 := FHeader.RestorationFilter.GabY;
      2: w1 := FHeader.RestorationFilter.GabXB;
    end;
    w2   := w1 * kGabW2Ratio;
    norm := 1.0 / (1.0 + 4.0 * (w1 + w2));
    // Work from a copy: gaborish is a true convolution, not in-place.
    SetLength(src, w * h);
    Move(img.Planes[c].Data[0], src[0], w * h * SizeOf(Single));
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do begin
        acc := S(x, y)
             + w1 * (S(x-1, y) + S(x+1, y) + S(x, y-1) + S(x, y+1))
             + w2 * (S(x-1, y-1) + S(x+1, y-1) + S(x-1, y+1) + S(x+1, y+1));
        PlaneSet(img.Planes[c], x, y, acc * norm);
      end;
  end;
end;

// ---------------------------------------------------------------------------
// VarDCT dispatch
// ---------------------------------------------------------------------------
procedure TFrameDecoder.DecodeVarDCT(br: TBitReader; var img: TJxlImageF);
var
  dec:       TVarDCTDecoder;
  params:    TVarDCTFrameParams;
  dataStart: NativeUInt;
begin
  // After ReadTOC the reader is byte-aligned at the first section payload.
  dataStart := br.BitsRead div 8;

  params.Width      := FHeader.Width;
  params.Height     := FHeader.Height;
  params.Flags      := FHeader.Flags;
  params.NumPasses  := FHeader.NumPasses;
  params.XQMScale   := FHeader.XQMScale;
  params.BQMScale   := FHeader.BQMScale;
  params.XYBEncoded := FMetadata.XYBEncoded;
  params.Gab        := FHeader.RestorationFilter.Gab;
  params.GabX       := FHeader.RestorationFilter.GabX;
  params.GabY       := FHeader.RestorationFilter.GabY;
  params.GabB       := FHeader.RestorationFilter.GabXB;
  params.EpfIters   := FHeader.RestorationFilter.EPF;

  dec := TVarDCTDecoder.Create(FMetadata);
  try
    dec.DecodeSections(br.Data, dataStart, FTOCSizes, params, img);
  finally
    dec.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Modular dispatch
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Multi-group modular frame: LfGlobal global stream (large channels skipped),
// then per-group rect streams; transforms undone on the reassembled image.
// Section layout: 0=LfGlobal, 1..numDC=DC groups (empty for shift-0 channels),
// numDC+1=ACGlobal (empty for modular), numDC+2+g = group g.
// ---------------------------------------------------------------------------
procedure TFrameDecoder.DecodeModularGroups(br: TBitReader; var modImg: TModImage;
                                            const gTree: TMATree;
                                            gAns: TANSDecoder);
var
  groupDim, xg, yg, numGroups, numDC, g, c, i: Integer;
  gx, gy, x0, y0, rw, rh, x, y, streamId: Integer;
  transforms: TModTransformList;
  sub: TModImage;
  sec: TBitReader;
  ofs: NativeUInt;
  total: Integer;
begin
  groupDim := 128 shl FHeader.GroupSizeShift;
  xg := (FHeader.Width + groupDim - 1) div groupDim;
  yg := (FHeader.Height + groupDim - 1) div groupDim;
  numGroups := xg * yg;
  numDC := ((FHeader.Width + groupDim*8 - 1) div (groupDim*8)) *
           ((FHeader.Height + groupDim*8 - 1) div (groupDim*8));
  total := modImg.NumChannels;

  // LfGlobal global stream: header + transforms; big channels are skipped.
  ModularDecodeImageOpts(br, modImg, gTree, gAns, 0, False, groupDim,
                         transforms);
  for i := 0 to High(transforms) do
    if transforms[i].Id <> 0 then
      raise EJxlError.Create(
        'Modular multi-group: only RCT transforms supported');

  // Per-group rect streams (sections numDC+2+g), positioned via the TOC.
  for g := 0 to numGroups - 1 do begin
    gx := g mod xg; gy := g div xg;
    x0 := gx * groupDim; y0 := gy * groupDim;
    rw := FHeader.Width - x0;  if rw > groupDim then rw := groupDim;
    rh := FHeader.Height - y0; if rh > groupDim then rh := groupDim;

    // Section reader at TOC offset of section (numDC + 2 + g).
    ofs := 0;
    for i := 0 to numDC + 2 + g - 1 do
      Inc(ofs, FTOCSizes[i]);
    // FTOCSizes[0] starts right after the TOC in the codestream:
    sec := TBitReader.Create(br.Data + FSectionBase + ofs,
                             FTOCSizes[numDC + 2 + g]);
    try
      sub.NumChannels := total;
      sub.NumMetaChannels := 0;
      sub.BitDepth := modImg.BitDepth;
      SetLength(sub.Channels, total);
      for c := 0 to total - 1 do
        InitModChannel(sub.Channels[c], rw, rh, 0, 0);
      // stream id = 1 + 3*numDC + kNumQuantTables(17) + g
      streamId := 1 + 3 * numDC + 17 + g;
      ModularDecodeImage(sec, sub, gTree, gAns, streamId, False);
      // Copy the rect back into the full image.
      for c := 0 to total - 1 do
        for y := 0 to rh - 1 do
          for x := 0 to rw - 1 do
            modImg.Channels[c].Data[(y0 + y) * FHeader.Width + x0 + x] :=
              sub.Channels[c].Data[y * rw + x];
    finally
      sec.Free;
    end;
  end;

  // Undo the global transforms on the assembled image.
  ApplyInverseTransformList(modImg, transforms);
end;

procedure TFrameDecoder.DecodeModular(br: TBitReader; var img: TJxlImageF);
var
  modImg: TModImage;
  c, x, y, bd, total: Integer;
  v: Single;
  hasTree: Boolean;
  gTree: TMATree;
  gAns: TANSDecoder;
  numLeaves: Integer;
begin
  bd := FMetadata.BitsPerSample;
  if bd <= 0 then bd := 8;
  total := 3 + Length(FMetadata.ExtraChannels);

  // LfGlobal for a modular frame (dec_frame.cc ProcessLFGlobal):
  // [patches/splines/noise: none] + DequantMatrices::DecodeDC + global info.
  if not br.ReadBit then
    raise EJxlError.Create('Modular frame: custom DC dequant not supported');

  // DecodeGlobalInfo: optional global tree + entropy code.
  gAns := nil;
  SetLength(gTree, 0);
  hasTree := br.ReadBit;
  if hasTree then begin
    ReadMATree(br, gTree);
    numLeaves := (Length(gTree) + 1) div 2;
    if numLeaves < 1 then numLeaves := 1;
    gAns := TANSDecoder.Create;
    gAns.InitCode(br, numLeaves);
  end;

  try
    modImg.NumChannels := total;
    modImg.NumMetaChannels := 0;
    modImg.BitDepth := bd;
    SetLength(modImg.Channels, total);
    for c := 0 to total - 1 do
      InitModChannel(modImg.Channels[c], FHeader.Width, FHeader.Height, 0, 0);

    if FNumSections <= 1 then
      // Collapsed TOC: everything is in this one stream.
      ModularDecodeImage(br, modImg, gTree, gAns, 0, True)
    else
      DecodeModularGroups(br, modImg, gTree, gAns);
  finally
    gAns.Free;
  end;

  img.Width       := FHeader.Width;
  img.Height      := FHeader.Height;
  img.NumChannels := 3;
  for c := 0 to 2 do
    InitFloat32Plane(img.Planes[c], img.Width, img.Height);

  for c := 0 to Min(2, modImg.NumChannels - 1) do
    for y := 0 to FHeader.Height - 1 do
      for x := 0 to FHeader.Width - 1 do begin
        v := IntSampleToFloat(ModChannelAt(modImg.Channels[c], x, y), bd);
        PlaneSet(img.Planes[c], x, y, v);
      end;
end;

// ---------------------------------------------------------------------------
// Main decode entry point
// ---------------------------------------------------------------------------
procedure TFrameDecoder.Decode(br: TBitReader; var output: TJxlImageF);
var
  i: Integer;
  totalSkip: Int64;
  maxFrames: Integer;
begin
  maxFrames := 100;
  repeat
    Dec(maxFrames);
    if maxFrames < 0 then
      raise EJxlError.Create('Too many frames');

    ReadFrameHeader(br);
    // NOTE: libjxl does NOT align between ReadFrameHeader and ReadTOC.
    // The TOC reader itself aligns to byte boundary after the permutation flag
    // and again after all section sizes. No extra alignment here.
    ReadTOC(br);
    FSectionBase := br.BitsRead div 8;

    // DC frames (kDCFrame / jftLF) provide low-frequency reference data
    // for VarDCT. We skip their payload for now and read the next frame.
    if FHeader.FrameType = jftLF then begin
      totalSkip := 0;
      for i := 0 to FNumSections - 1 do
        Inc(totalSkip, Int64(FTOCSizes[i]));
      br.SkipBytes(NativeUInt(totalSkip));
      Continue;
    end;

    if FHeader.Encoding = 0 then begin
      DecodeVarDCT(br, output);
    end else begin
      DecodeModular(br, output);
    end;

    // VarDCT applies gaborish + EPF internally (correct order, in XYB space);
    // the frame-level gaborish remains only for the modular path.
    if FHeader.Encoding <> 0 then
      ApplyRestoration(output);
    ApplyColorConversion(output);
  until FHeader.IsLast;
end;

// ---------------------------------------------------------------------------
constructor TFrameDecoder.Create(const md: TJxlImageMetadata);
begin
  inherited Create;
  FMetadata    := md;
  FNumSections := 0;
end;

destructor TFrameDecoder.Destroy;
begin
  SetLength(FTOCSizes, 0);
  SetLength(FTOCPerms, 0);
  inherited;
end;

end.
