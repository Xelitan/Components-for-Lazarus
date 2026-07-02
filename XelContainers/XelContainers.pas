{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelContainers;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelPageControl, XelSidePages, XelAccordion, XelRibbon, XelDsgn, 
  LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelPageControl', @XelPageControl.Register);
  RegisterUnit('XelSidePages', @XelSidePages.Register);
  RegisterUnit('XelAccordion', @XelAccordion.Register);
  RegisterUnit('XelRibbon', @XelRibbon.Register);
  RegisterUnit('XelDsgn', @XelDsgn.Register);
end;

initialization
  RegisterPackage('XelContainers', @Register);
end.
