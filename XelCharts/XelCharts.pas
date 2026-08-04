// This file was automatically created by Lazarus. Do not edit!
// This source is only used to compile and install the package.

unit XelCharts;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelChartTypes, XelChartBase, XelLineChart, XelBarChart, XelPieChart,
  XelSparkline, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelLineChart', @XelLineChart.Register);
  RegisterUnit('XelBarChart', @XelBarChart.Register);
  RegisterUnit('XelPieChart', @XelPieChart.Register);
  RegisterUnit('XelSparkline', @XelSparkline.Register);
end;

initialization
  RegisterPackage('XelCharts', @Register);
end.
