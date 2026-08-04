# XelCharts usage
```
const Months : array[0..11] of String =
  ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

  Revenue : array[0..11] of Double =
    (412, 388, 455, 501, 478, 533, 590, 612, 587, 640, 705, 748);
  Cost    : array[0..11] of Double =
    (301, 295, 322, 340, 351, 366, 388, 401, 396, 410, 447, 470);
  Support : array[0..11] of Double =
    ( 61,  58,  70,  66,  74,  81,  77,  90,  84,  95, 101,  98);
var i: Integer;
    C: TXelLineChart;
    C2: TXelBarChart;
    C3: TXelPieChart;
    S: TXelChartSeries;
    Sp: TXelSparkline;
begin
  //Line chart
  C := XelLineChart1;
  C.Theme  := ctLight;
  C.Title  := 'Monthly revenue and cost';
  C.Footer := 'thousands of EUR';

  for i := 0 to 11 do C.Categories.Add(Months[i]);
  C.AddSeries('Revenue', Revenue).Style := ssLinePoints;
  C.AddSeries('Cost', Cost).Style := ssLinePoints;
  C.AddSeries('Support', Support).Style := ssLinePoints;
  C.AxisY.LabelFormat := '%.0f';
  C.AxisX.TickCount   := 12;
  C.MarkLast := True;

  //Bar chart
  C2 := XelBarChart1;
  C2.Layout := blStacked;
  C2.Title := 'Cost breakdown, stacked';
  for i := 0 to 11 do C2.Categories.Add(Months[i]);

  C2.AddSeries('Revenue', Revenue);
  C2.AddSeries('Cost', Cost);
  C2.AddSeries('Support', Support);
  C2.AxisY.LabelFormat := '%.0f';

  //Pie chart
  C3 := XelPieChart1;
  C3.Donut := 55;
  C3.Title := 'Traffic by source, donut';

  S := C3.Series.Add;
  S.Add(4210, 'Organic');
  S.Add(2870, 'Direct');
  S.Add(1640, 'Referral');
  S.Add( 980, 'Social');
  S.Add( 410, 'Email');
  S.Add(  95, 'Affiliate');
  S.Add(  40, 'Print');
  C3.Labels       := plNamePercent;
  C3.ExplodeIndex := 0;
  C3.Explode      := 10;

  //Spark line
  Sp := XelSparkline1;
  Sp.SetData(Revenue);
```
