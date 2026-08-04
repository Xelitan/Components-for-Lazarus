{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelFonts;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelFontTypes, XelFontConvert, XelFontInstall, XelFontManager, XelFontPreview,
  LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelFontManager', @XelFontManager.Register);
  RegisterUnit('XelFontPreview', @XelFontPreview.Register);
end;

initialization
  RegisterPackage('XelFonts', @Register);
end.
