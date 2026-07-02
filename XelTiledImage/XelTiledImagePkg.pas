{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelTiledImagePkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelTiledImage, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelTiledImage', @XelTiledImage.Register);
end;

initialization
  RegisterPackage('XelTiledImagePkg', @Register);
end.
