{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelProgressBars;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelCircularProgress, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelCircularProgress', @XelCircularProgress.Register);
end;

initialization
  RegisterPackage('XelProgressBars', @Register);
end.
