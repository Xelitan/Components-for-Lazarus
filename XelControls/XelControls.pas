{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelControls;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelToggleSwitch, XelRatingStars, XelImageButton, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelToggleSwitch', @XelToggleSwitch.Register);
  RegisterUnit('XelRatingStars', @XelRatingStars.Register);
  RegisterUnit('XelImageButton', @XelImageButton.Register);
end;

initialization
  RegisterPackage('XelControls', @Register);
end.
