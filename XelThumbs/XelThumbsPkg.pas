{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelThumbsPkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelThumbs, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelThumbs', @XelThumbs.Register);
end;

initialization
  RegisterPackage('XelThumbsPkg', @Register);
end.
