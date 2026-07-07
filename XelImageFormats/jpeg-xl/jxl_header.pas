{$mode delphi}
unit jxl_header;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JPEG XL codestream header parsing — corrected against libjxl 0.11.2 source.
// Key principle: every Bundle (nested struct) starts with 1 bit AllDefault.
// libjxl read semantics (fields.cc ReadVisitor / VisitorBase::Bool):
//   value = (bit == 1).  So:
//   bit=1 -> all_default = TRUE  (skip the rest, use defaults)
//   bit=0 -> all_default = FALSE (explicit fields follow)
// This applies to EVERY Bool field too: on read it is always value=(bit==1),
// regardless of the encoder-side default. There is NO inversion on read.

interface

uses
  SysUtils, jxl_types, jxl_bits;

function AspectRatioXSize(ysize: Cardinal; ratio: Integer): Cardinal;
procedure ReadSizeHeader(br: TBitReader; var md: TJxlImageMetadata);
procedure ReadImageMetadata(br: TBitReader; var md: TJxlImageMetadata);

implementation

// ---------------------------------------------------------------------------
// Enum coder (fields.h VisitorBase::Enum): every enum is encoded with the
// single uniform distribution U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(6,18)).
//   sel=0 -> 0, sel=1 -> 1, sel=2 -> 2 + Bits(4), sel=3 -> 18 + Bits(6)
// ---------------------------------------------------------------------------
function ReadEnum(br: TBitReader): Cardinal; inline;
begin
  Result := br.ReadU32(0,0, 1,0, 2,4, 18,6);
end;

// UnpackSigned: even -> v/2, odd -> -(v+1)/2 (JXL zig-zag)
function UnpackSigned(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then
    Result := -((Int64(v) + 1) shr 1)
  else
    Result := Int64(v) shr 1;
end;

// Customxy nested bundle: two packed-signed U32 values (x, y).
// U32(Bits(19), BitsOffset(19,524288), BitsOffset(20,1048576), BitsOffset(21,2097152))
procedure ReadCustomXY(br: TBitReader; out cx, cy: Double);
var ux, uy: Cardinal;
begin
  ux := br.ReadU32(0,19, 524288,19, 1048576,20, 2097152,21);
  cx := UnpackSigned(ux) / 1000000.0;   // stored in units of 1e-6
  uy := br.ReadU32(0,19, 524288,19, 1048576,20, 2097152,21);
  cy := UnpackSigned(uy) / 1000000.0;
end;

// ---------------------------------------------------------------------------
function AspectRatioXSize(ysize: Cardinal; ratio: Integer): Cardinal;
begin
  case ratio of
    1: Result := ysize;
    2: Result := (ysize * 12 + 9) div 10;   // 6:5  (w > h)
    3: Result := (ysize * 4  + 2) div 3;    // 4:3
    4: Result := (ysize * 3  + 1) div 2;    // 3:2
    5: Result := (ysize * 16 + 8) div 9;    // 16:9
    6: Result := (ysize * 5  + 3) div 4;    // 5:4
  else Result := ysize;
  end;
end;

// ---------------------------------------------------------------------------
// SizeHeader — headers.cc SizeHeader::VisitFields
//   Non-small: U32(BitsOffset(9,1), BitsOffset(13,1), BitsOffset(18,1), BitsOffset(30,1))
//   Small: 1-bit div8, ysize=(ytmp+1)*8, 3-bit ratio, optional xsize=(xtmp+1)*8
// NOTE: SizeHeader has NO AllDefault preamble in the JXL spec.
// ---------------------------------------------------------------------------
procedure ReadSizeHeader(br: TBitReader; var md: TJxlImageMetadata);
var
  small: Boolean;
  ytmp, xtmp, ratio: Cardinal;
begin
  small := br.ReadBit;
  if small then begin
    ytmp     := br.ReadBits(5);
    md.YSize := (ytmp + 1) * 8;
    ratio    := br.ReadBits(3);
    if ratio = 0 then begin
      xtmp     := br.ReadBits(5);
      md.XSize := (xtmp + 1) * 8;
    end else
      md.XSize := AspectRatioXSize(md.YSize, ratio);
  end else begin
    // BitsOffset(9,1)=sel0, BitsOffset(13,1)=sel1,
    // BitsOffset(18,1)=sel2, BitsOffset(30,1)=sel3
    md.YSize := br.ReadU32(1, 9,  1, 13,  1, 18,  1, 30);
    ratio    := br.ReadBits(3);
    if ratio = 0 then
      md.XSize := br.ReadU32(1, 9,  1, 13,  1, 18,  1, 30)
    else
      md.XSize := AspectRatioXSize(md.YSize, ratio);
  end;
end;

// ---------------------------------------------------------------------------
// PreviewHeader — different U32 from SizeHeader (headers.cc PreviewHeader::VisitFields)
// ---------------------------------------------------------------------------
procedure ReadPreviewHeader(br: TBitReader);
var
  div8: Boolean;
  ratio: Cardinal;
begin
  div8 := br.ReadBit;
  if div8 then
    br.ReadU32(16, 0,  32, 0,  1, 5,  33, 9)   // ysize_div8
  else
    br.ReadU32(1, 6,  65, 8,  321, 10,  1345, 12);   // ysize

  ratio := br.ReadBits(3);
  if ratio = 0 then begin
    if div8 then
      br.ReadU32(16, 0,  32, 0,  1, 5,  33, 9)
    else
      br.ReadU32(1, 6,  65, 8,  321, 10,  1345, 12);
  end;
end;

// ---------------------------------------------------------------------------
// AnimationHeader — headers.cc AnimationHeader::VisitFields
// ---------------------------------------------------------------------------
procedure ReadAnimationHeader(br: TBitReader);
begin
  br.ReadU32(100, 0,  1000, 0,  1, 10,  1, 30);   // tps_numerator
  br.ReadU32(1, 0,  1001, 0,  1, 8,  1, 10);       // tps_denominator
  br.ReadU32(0, 0,  1, 3,  1, 16,  0, 0);          // num_loops
  br.ReadBit;                                        // have_timecodes
end;

// ---------------------------------------------------------------------------
// BitDepth — image_metadata.cc BitDepth::VisitFields
// Has AllDefault preamble: bit 0 = all default (skip), bit 1 = fields follow.
// Defaults: floating_point_sample=false, bits_per_sample=8, exponent_bits=0
// ---------------------------------------------------------------------------
procedure ReadBitDepth(br: TBitReader; var md: TJxlImageMetadata);
var
  floatSample: Boolean;
  expMinus1: Cardinal;
begin
  // NOTE: BitDepth has NO AllDefault bit (image_metadata.cc BitDepth::VisitFields
  // begins directly with Bool(false, &floating_point_sample)).
  floatSample      := br.ReadBit;
  md.FloatSamples  := floatSample;
  if not floatSample then begin
    // U32(Val(8), Val(10), Val(12), BitsOffset(6,1))
    md.BitsPerSample := br.ReadU32(8, 0,  10, 0,  12, 0,  1, 6);
    md.ExponentBits  := 0;
  end else begin
    // U32(Val(32), Val(16), Val(24), BitsOffset(6,1))
    md.BitsPerSample := br.ReadU32(32, 0,  16, 0,  24, 0,  1, 6);
    // exponent_bits stored as (value-1) in 4 bits
    expMinus1       := br.ReadBits(4);
    md.ExponentBits := Integer(expMinus1) + 1;
  end;
end;

// ---------------------------------------------------------------------------
// ReadBitDepthEC — read BitDepth for an extra channel (same structure, diff target)
// ---------------------------------------------------------------------------
procedure ReadBitDepthEC(br: TBitReader; var ec: TJxlExtraChannelInfo);
var
  floatSample: Boolean;
  expMinus1: Cardinal;
begin
  // BitDepth has NO AllDefault bit.
  floatSample := br.ReadBit;
  if not floatSample then begin
    ec.BitsPerSample := br.ReadU32(8, 0,  10, 0,  12, 0,  1, 6);
    ec.ExponentBits  := 0;
  end else begin
    ec.BitsPerSample := br.ReadU32(32, 0,  16, 0,  24, 0,  1, 6);
    expMinus1        := br.ReadBits(4);
    ec.ExponentBits  := Integer(expMinus1) + 1;
  end;
end;

// ---------------------------------------------------------------------------
// ColorEncoding — color_encoding_internal.cc ColorEncoding::VisitFields
// Has AllDefault preamble.
// Defaults: want_icc=false, kRGB, D65, sRGB primaries, sRGB TF, relative intent
// ---------------------------------------------------------------------------
procedure ReadColorEncoding(br: TBitReader; var ce: TJxlColorEncoding);
var
  allDefault, hasPrimaries: Boolean;
  csRaw, wpRaw, primRaw, tfRaw, riRaw, gammaRaw: Cardinal;
  haveGamma: Boolean;
begin
  // Sensible defaults first
  ce.WantICC      := False;
  ce.ColorSpace   := jcsRGB;
  ce.WhitePoint   := jwpD65;
  ce.Primaries    := jpSRGB;
  ce.TransferFn   := jtfSRGB;
  ce.RenderIntent := jriRelative;
  ce.Gamma        := 0;

  // AllDefault preamble (bit==1 -> all default)
  allDefault := br.ReadBit;
  if allDefault then Exit;

  // want_icc Bool
  ce.WantICC := br.ReadBit;

  // colour_space Enum (default kRGB) — ALWAYS sent, even if want_icc.
  csRaw := ReadEnum(br);
  case csRaw of
    0: ce.ColorSpace := jcsRGB;
    1: ce.ColorSpace := jcsGray;
    2: ce.ColorSpace := jcsXYB;
  else ce.ColorSpace := jcsUnknown;
  end;

  // If want_icc, the remaining fields are NOT serialized (ICC blob follows
  // in the codestream and is read separately).
  if ce.WantICC then Exit;

  hasPrimaries := (ce.ColorSpace <> jcsGray) and (ce.ColorSpace <> jcsXYB);

  // White point — only if NOT implicit (implicit when color_space == kXYB)
  if ce.ColorSpace <> jcsXYB then begin
    wpRaw := ReadEnum(br);
    case wpRaw of
      1:  ce.WhitePoint := jwpD65;
      2:  ce.WhitePoint := jwpCustom;
      10: ce.WhitePoint := jwpE;
      11: ce.WhitePoint := jwpDCI;
    else  ce.WhitePoint := jwpD65;
    end;
    if ce.WhitePoint = jwpCustom then
      ReadCustomXY(br, ce.WhiteCustomX, ce.WhiteCustomY);
  end else
    ce.WhitePoint := jwpD65;

  // Primaries — only if HasPrimaries
  if hasPrimaries then begin
    primRaw := ReadEnum(br);
    case primRaw of
      1:  ce.Primaries := jpSRGB;
      2:  ce.Primaries := jpCustom;
      9:  ce.Primaries := jp2100;
      11: ce.Primaries := jpP3D65;
    else  ce.Primaries := jpSRGB;
    end;
    if ce.Primaries = jpCustom then begin
      ReadCustomXY(br, ce.PrimRX, ce.PrimRY);
      ReadCustomXY(br, ce.PrimGX, ce.PrimGY);
      ReadCustomXY(br, ce.PrimBX, ce.PrimBY);
    end;
  end;

  // CustomTransferFunction — implicit (linear) only for kXYB
  if ce.ColorSpace = jcsXYB then begin
    ce.TransferFn := jtfLinear;
  end else begin
    haveGamma := br.ReadBit;
    if haveGamma then begin
      gammaRaw     := br.ReadBits(24);  // gamma * 1e7
      ce.TransferFn := jtfGamma;
      if gammaRaw <> 0 then
        ce.Gamma := 1.0 / (gammaRaw / 10000000.0)   // stored exponent is 1/gamma
      else
        ce.Gamma := 0;
    end else begin
      tfRaw := ReadEnum(br);
      case tfRaw of
        1:  ce.TransferFn := jtf709;
        8:  ce.TransferFn := jtfLinear;
        13: ce.TransferFn := jtfSRGB;
        16: ce.TransferFn := jtfPQ;
        17: ce.TransferFn := jtfDCI;
        18: ce.TransferFn := jtfHLG;
      else  ce.TransferFn := jtfUnknown;
      end;
    end;
  end;

  // rendering_intent Enum (default kRelative)
  riRaw := ReadEnum(br);
  case riRaw of
    0: ce.RenderIntent := jriPerceptual;
    1: ce.RenderIntent := jriRelative;
    2: ce.RenderIntent := jriSaturation;
    3: ce.RenderIntent := jriAbsolute;
  else ce.RenderIntent := jriRelative;
  end;
end;

// ---------------------------------------------------------------------------
// ExtraChannelInfo — image_metadata.cc ExtraChannelInfo::VisitFields
// Has AllDefault preamble.
// Defaults: kAlpha, 8-bit uint, dim_shift=0, no name, not premultiplied
// ---------------------------------------------------------------------------
procedure ReadExtraChannelInfo(br: TBitReader; var ec: TJxlExtraChannelInfo);
var
  allDefault: Boolean;
  typeRaw, nameLen, i: Integer;
begin
  allDefault := br.ReadBit;
  if allDefault then begin
    ec.ChanType      := jectAlpha;
    ec.BitsPerSample := 8;
    ec.ExponentBits  := 0;
    ec.DimShift      := 0;
    ec.AlphaAssoc    := False;
    Exit;
  end;

  // type is an Enum (uniform enum coder)
  typeRaw := Integer(ReadEnum(br));
  case typeRaw of
    0: ec.ChanType := jectAlpha;
    1: ec.ChanType := jectDepth;
    2: ec.ChanType := jectSpotColor;
    3: ec.ChanType := jectSelection;
    4: ec.ChanType := jectBlack;
    5: ec.ChanType := jectCFA;
    6: ec.ChanType := jectThermal;
  else ec.ChanType := jectOptional;
  end;

  // nested BitDepth (with its own AllDefault)
  ReadBitDepthEC(br, ec);

  // dim_shift: U32(Val(0), Val(3), Val(4), BitsOffset(3,1))
  ec.DimShift := br.ReadU32(0, 0,  3, 0,  4, 0,  1, 3);

  // name: U32(Val(0), Bits(4), BitsOffset(5,16), BitsOffset(10,48)) + chars
  nameLen := br.ReadU32(0, 0,  0, 4,  16, 5,  48, 10);
  SetLength(ec.Name, nameLen);
  for i := 1 to nameLen do
    ec.Name[i] := Chr(br.ReadBits(8));

  // Conditional fields
  case ec.ChanType of
    jectAlpha:
      ec.AlphaAssoc := br.ReadBit;
    jectSpotColor: begin
      ec.SpotColor[0] := br.ReadF16;
      ec.SpotColor[1] := br.ReadF16;
      ec.SpotColor[2] := br.ReadF16;
      ec.SpotColor[3] := br.ReadF16;
    end;
    jectCFA: begin
      ec.CFARaw     := br.ReadBit;
      ec.CFAChannel := br.ReadU32(1, 0,  0, 2,  3, 4,  19, 8);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// ToneMapping — image_metadata.cc ToneMapping::VisitFields
// Has AllDefault preamble.
// Defaults: intensity_target=255, min_nits=0, relative_to_max=false, linear_below=0
// ---------------------------------------------------------------------------
procedure ReadToneMapping(br: TBitReader; var md: TJxlImageMetadata);
var allDefault: Boolean;
begin
  allDefault := br.ReadBit;
  if allDefault then begin
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
    Exit;
  end;
  md.IntensityTarget := br.ReadF16;
  md.MinNits         := br.ReadF16;
  md.RelativeToMax   := br.ReadBit;
  md.LinearBelow     := br.ReadF16;
end;

// ---------------------------------------------------------------------------
// ImageMetadata — image_metadata.cc ImageMetadata::VisitFields
// Has AllDefault preamble.
// Defaults: orientation=1, no extra channels, xyb_encoded=true,
//           sRGB color space, 8-bit, intensity_target=255
// ---------------------------------------------------------------------------
procedure ReadImageMetadata(br: TBitReader; var md: TJxlImageMetadata);
var
  allDefault: Boolean;
  extra_fields: Boolean;
  have_intrinsic_size, have_preview, have_animation: Boolean;
  numExtra, i: Integer;
  tmpMd: TJxlImageMetadata;
begin
  // AllDefault preamble for the entire ImageMetadata bundle
  allDefault := br.ReadBit;
  if allDefault then begin
    // Use all defaults:
    md.Orientation     := 1;
    md.IntrinsicXSize  := 0;
    md.IntrinsicYSize  := 0;
    md.FloatSamples    := False;
    md.BitsPerSample   := 8;
    md.ExponentBits    := 0;
    md.XYBEncoded      := True;   // JXL default is XYB=true
    SetLength(md.ExtraChannels, 0);
    md.ColorEncoding.WantICC    := False;
    md.ColorEncoding.ColorSpace := jcsRGB;
    md.ColorEncoding.WhitePoint := jwpD65;
    md.ColorEncoding.Primaries  := jpSRGB;
    md.ColorEncoding.TransferFn := jtfSRGB;
    md.ColorEncoding.RenderIntent := jriRelative;
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
    Exit;
  end;

  // extra_fields gates orientation + intrinsic_size + preview + animation
  // AND tone_mapping (at the end)
  extra_fields := br.ReadBit;

  if extra_fields then begin
    // orientation stored as (value-1) in 3 bits, then +1 on read
    md.Orientation := Integer(br.ReadBits(3)) + 1;

    have_intrinsic_size := br.ReadBit;
    if have_intrinsic_size then begin
      FillChar(tmpMd, SizeOf(tmpMd), 0);
      ReadSizeHeader(br, tmpMd);
      md.IntrinsicXSize := tmpMd.XSize;
      md.IntrinsicYSize := tmpMd.YSize;
    end else begin
      md.IntrinsicXSize := 0;
      md.IntrinsicYSize := 0;
    end;

    have_preview := br.ReadBit;
    if have_preview then
      ReadPreviewHeader(br);

    have_animation := br.ReadBit;
    if have_animation then
      ReadAnimationHeader(br);
  end else begin
    md.Orientation    := 1;
    md.IntrinsicXSize := 0;
    md.IntrinsicYSize := 0;
  end;

  // BitDepth (nested bundle with AllDefault)
  ReadBitDepth(br, md);

  // modular_16_bit_buffer_sufficient (Bool, default=true) — read and discard
  br.ReadBit;

  // num_extra_channels: U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(12,1))
  // Direct U32, NO separate hasExtras boolean
  numExtra := br.ReadU32(0, 0,  1, 0,  2, 4,  1, 12);
  SetLength(md.ExtraChannels, numExtra);
  for i := 0 to numExtra - 1 do
    ReadExtraChannelInfo(br, md.ExtraChannels[i]);

  // xyb_encoded (Bool, default=true)
  md.XYBEncoded := br.ReadBit;

  // ColorEncoding (nested bundle with AllDefault)
  ReadColorEncoding(br, md.ColorEncoding);

  // ToneMapping (nested bundle with AllDefault) — only when extra_fields=True
  if extra_fields then
    ReadToneMapping(br, md)
  else begin
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
  end;

  // Extensions (U64) — read and discard
  br.ReadU64;
end;

end.
