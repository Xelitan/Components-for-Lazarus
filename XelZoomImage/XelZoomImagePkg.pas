{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelZoomImagePkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelZoomImage, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelZoomImage', @XelZoomImage.Register);
end;

initialization
  RegisterPackage('XelZoomImagePkg', @Register);
end.
