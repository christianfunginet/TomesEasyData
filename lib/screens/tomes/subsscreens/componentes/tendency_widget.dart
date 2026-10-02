import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:tomesdashboard/screens/big_widget.dart';
import '../../../../constants.dart';

class TendencyWidget extends StatefulWidget {
  final List<Corrida> corridas;
  final bool showZoom;
  const TendencyWidget({
    required this.corridas,
    this.showZoom=true,
    super.key,
  });

  @override
  State<TendencyWidget> createState() => _TendencyWidgetState();
}

class _TendencyWidgetState extends State<TendencyWidget> {
  List<bool> showSerie=List.generate((6), (_)=>true);
  bool mediana=false;
  @override
  Widget build(BuildContext context) {

    bool  getUpDown(List<FlSpot> datosOriginales) {
      if (datosOriginales.isEmpty) false;

      double n = datosOriginales.length.toDouble();
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

      for (var spot in datosOriginales) {
        sumX += spot.x;
        sumY += spot.y;
        sumXY += spot.x * spot.y;
        sumX2 += spot.x * spot.x;
      }
      double pendiente = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
      return pendiente>0;
    }
    double  getPendiente(List<FlSpot> datosOriginales) {
      if (datosOriginales.isEmpty) false;

      double n = datosOriginales.length.toDouble();
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

      for (var spot in datosOriginales) {
        sumX += spot.x;
        sumY += spot.y;
        sumXY += spot.x * spot.y;
        sumX2 += spot.x * spot.x;
      }
      double pendiente = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
      return pendiente;
    }
    List<FlSpot> calcularLineaTendencia(List<FlSpot> data) {
      if (data.isEmpty) return [];
      var datosOriginales=data;
      if(mediana){
        datosOriginales.removeAt(datosOriginales.length-1);
        
        datosOriginales.removeAt(0);
      }
      double n = datosOriginales.length.toDouble();
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

      for (var spot in datosOriginales) {
        sumX += spot.x;
        sumY += spot.y;
        sumXY += spot.x * spot.y;
        sumX2 += spot.x * spot.x;
      }

      // Fórmula de la pendiente (m) y la intersección (b)
      double pendiente = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
      double interseccion = (sumY - pendiente * sumX) / n;

      // Generamos los puntos de la línea recta desde el inicio al fin
      double minX = datosOriginales.first.x;
      double maxX = datosOriginales.last.x;

      return [
        FlSpot(minX, (pendiente * minX) + interseccion),
        FlSpot(maxX, (pendiente * maxX) + interseccion),
      ];
    }
    List<List<int>> plasmaPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<int>> plaquetasPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<int>> leucoPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<int>> rendimientoPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<int>> divisores=List.generate(5,(_)=> List.generate(12, (_)=>0));
    
    int y=DateTime.now().year;
    List<FlSpot> seriePlaquetas=[];
    List<FlSpot> seriePlasma=[];
    List<FlSpot> serieLeuco=[];
    
    double ptr=0;
    
    for(var corrida in widget.corridas){
      
      for(var bolsa in corrida.bolsas){
        plaquetasPorMes[y-corrida.year][corrida.month-1]+= bolsa.volumenDePlaquetas;
        plasmaPorMes[y-corrida.year][corrida.month-1]+= bolsa.volumenDePlasma;
        leucoPorMes[y-corrida.year][corrida.month-1]+= bolsa.volumenDeLeucocitos;
        
        rendimientoPorMes[y-corrida.year][corrida.month-1]+= bolsa.indiceDeRendimientoDePlaquetas;
    
        if(bolsa.indiceDeRendimientoDePlaquetas!=0){
        divisores[y-corrida.year][corrida.month-1]=divisores[y-corrida.year][corrida.month-1]+ 1;  
        }
      }
      
        
    }

   
    ptr=widget.corridas.last.month.toDouble()-1.0;
    for(var year=4; year>= 0;year--){
      for(var month=0; month< plasmaPorMes[year].length;month++){
        if(plaquetasPorMes[year][month]+plasmaPorMes[year][month]+leucoPorMes[year][month]!=0){
          seriePlaquetas.add(FlSpot(ptr,plaquetasPorMes[year][month].toDouble()));
          seriePlasma.add(FlSpot(ptr,plasmaPorMes[year][month].toDouble()));
          serieLeuco.add(FlSpot(ptr,leucoPorMes[year][month].toDouble()));


          ptr=ptr+1.0;
        }
      }
    }


    

    const cutOffYValue = 5.0;
    
    List<LineChartBarData> values = [
    LineChartBarData(
      spots: seriePlaquetas,
      isCurved: true,
      barWidth: 2,
      color:colorDePlaquetas,
    
      belowBarData: BarAreaData(
        show: true,
        color: Colors.transparent,
        cutOffY: 0,
        applyCutOffY: true,
      ),
      aboveBarData: BarAreaData(
        show: true,
        color: Colors.transparent,
        cutOffY: cutOffYValue,
        applyCutOffY: true,
      ),
      dotData: const FlDotData(
        show: true,
      ),
    
    ),
    LineChartBarData(
          spots: seriePlasma,
          isCurved: true,
          barWidth: 2,
          color: colorDePlasma,
          belowBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          aboveBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          dotData: const FlDotData(
            show: true,
          ),
        ),
    LineChartBarData(
          spots: serieLeuco,
          isCurved: true,
          barWidth: 2,
          color: colorDeLeuco,
          belowBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          aboveBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          dotData: const FlDotData(
            show: true,
          ),
        ),
   
 ];

  List<LineChartBarData> tendencias=[
    LineChartBarData(
      spots: seriePlaquetas.length>1? calcularLineaTendencia( seriePlaquetas):seriePlaquetas,
      isCurved: true,
      barWidth: 1,
      color: getUpDown(seriePlaquetas)?Colors.green:Colors.red,
      belowBarData: BarAreaData(
        show: true,
        color: Colors.transparent,
        cutOffY: 0,
        applyCutOffY: true,
      ),
      aboveBarData: BarAreaData(
        show: true,
        color: Colors.transparent,
        cutOffY: cutOffYValue,
        applyCutOffY: true,
      ),
      dotData: const FlDotData(
        show: true,
      ),
    
    ),
    LineChartBarData(
          spots:seriePlasma.length>1? calcularLineaTendencia( seriePlasma):seriePlasma,
          isCurved: true,
          barWidth: 1,
          color: getUpDown(seriePlasma)?Colors.green:Colors.red,
      belowBarData: BarAreaData(
            show: true,
            color: const Color.fromARGB(0, 189, 153, 153),
            cutOffY: 0,
            applyCutOffY: true,
          ),
          aboveBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          dotData: const FlDotData(
            show: true,
          ),
        ),
    LineChartBarData(
          spots: serieLeuco.length>1? calcularLineaTendencia(serieLeuco):serieLeuco,
          isCurved: true,
          barWidth: 1,
          color: getUpDown(serieLeuco)?Colors.green:Colors.red,
          belowBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          aboveBarData: BarAreaData(
            show: true,
            color: Colors.transparent,
            cutOffY: 0,
            applyCutOffY: true,
          ),
          dotData: const FlDotData(
            show: true,
          ),
        ),
  
 ];
    int i=0;
    for (var element in values) {
      values[i]=element.copyWith(show:showSerie[i]);
      i++;
    }
    i=0;
    for (var element in tendencias) {
      tendencias[i]=element.copyWith(show:showSerie[i]);
      i++;
    }

    List<LineChartBarData> data=values+tendencias;
    return Container(
      padding: EdgeInsets.all(defaultPadding),
        decoration: BoxDecoration(
        color: Theme.of(context).splashColor,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        
          Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if(widget.showZoom)...[
                    IconButton(onPressed: (){
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context)=> BigScreenWidget(widget: TendencyWidget(corridas:widget. corridas,showZoom: false,),))
                      );
                    }, icon: Icon(Icons.zoom_in)),
                    SizedBox(width: 12,)
                  ],
                  Text(
                    "Productos",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  
                    if(values.first.spots .length>3)
                    GestureDetector(
                    onTap: (){
                      setState(() {
                        mediana=!mediana;
                        
                      });
                    },
                    child:  ChoiceChip  (
                      selectedColor:  Colors.blue.withAlpha(100),
                        
                      padding: EdgeInsetsGeometry.all(2),
                      label: Text("Mediana",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 10),), 
                        selected: mediana,),
                  ),
                ...values.map((serie){
                  
                  int index=values.indexWhere((test)=>serie==test);
                  return GestureDetector(
                    onTap: (){
                      setState(() {
                        showSerie[index]=!showSerie[index];
                        
                      });
                    },
                    child: ChoiceChip (
                      
                      selectedColor: serie.color!.withAlpha(100),
                      selected: showSerie[index],
                      label: Text(serieName(index),
                      
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 10),)),
                  );
                  
                }
                ),
                
                ],
                ),
              )
            ],
          ),
          SizedBox(height: defaultPadding),
          LineChartSample4(data: data)    
        ],
      ),
    );
  }
}

class LineChartSample4 extends StatelessWidget {
  final List<LineChartBarData> data;
  LineChartSample4({
    super.key,
    required this.data,
    Color? mainLineColor,
    Color? belowLineColor,
    Color? aboveLineColor,
  })  : mainLineColor =
            mainLineColor ?? Colors.yellowAccent.withValues(alpha: 1),
        belowLineColor =
            belowLineColor ?? Colors.pinkAccent.withValues(alpha: 1),
        aboveLineColor = aboveLineColor ??
            Colors.purple.withValues(alpha: 0.7);

  final Color mainLineColor;
  final Color belowLineColor;
  final Color aboveLineColor;

  Widget bottomTitleWidgets(double value, TitleMeta meta) {
    int toSwitch=value.toInt();
    if(value>11){
      toSwitch=value.toInt()% 12;
    }
    String text = switch (toSwitch) {
      0 => 'Jan',
      1 => 'Feb',
      2 => 'Mar',
      3 => 'Apr',
      4 => 'May',
      5 => 'Jun',
      6 => 'Jul',
      7 => 'Aug',
      8 => 'Sep',
      9 => 'Oct',
      10 => 'Nov',
      11 => 'Dec',
      _ => '',
    };

    return SideTitleWidget(
      meta: meta,
      space: 4,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: mainLineColor,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget leftTitleWidgets(double value, TitleMeta meta,BuildContext context) {
    var style = TextStyle(
      color: Theme.of(context).primaryColor,
      fontSize: 12,
    );
    return SideTitleWidget(
      meta: meta,
      child: Text(' $value ', style: style),
    );
  }

  @override
  Widget build(BuildContext context) {
    var dt=data.where((test) =>test.show==true);
   final allSpots = dt.expand((bar) => bar .spots).toList();
  
  final dynamicMinY = allSpots.isEmpty ? 0.0 : allSpots.map((s) => s.y).reduce(min);
  final dynamicMaxY = allSpots.isEmpty ? 10.0 : allSpots.map((s) => s.y).reduce(max);
  double  getPendiente(List<FlSpot> datosOriginales) {
      if (datosOriginales.isEmpty) false;

      double n = datosOriginales.length.toDouble();
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

      for (var spot in datosOriginales) {
        sumX += spot.x;
        sumY += spot.y;
        sumXY += spot.x * spot.y;
        sumX2 += spot.x * spot.x;
      }
      double pendiente = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
      return pendiente;
    }
    
    return Padding(
      padding: const EdgeInsets.only(
        left: 12,
        right: 28,
        top: 22,
        bottom: 12,
      ),
      child: SizedBox(
        width:MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height/2,
        
        child: LineChart(
          transformationConfig: FlTransformationConfig(),
          LineChartData(
          minY: dynamicMinY * 0.9,
          maxY: dynamicMaxY * 1.1,  
          gridData: FlGridData(
            show: true, // Muestra la cuadrícula de fondo
            drawVerticalLine: false, // Desactiva las líneas verticales si solo quieres las horizontales
            drawHorizontalLine: true, // Activa las líneas horizontales
            
            // 1. Controla la separación entre las líneas horizontales
            // Un valor de 2 significa que dibujará una línea cada 2 unidades en el eje Y (ej: 0, 2, 4, 6...)
            horizontalInterval: dynamicMaxY/5, 
        
            
        
            
            // 3. Opcional: Si quieres elegir de forma manual exacta qué líneas mostrar
            
          ),
            
          lineTouchData: LineTouchData(
                enabled: true, // Cambiado de false a true
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (LineBarSpot touchedSpot) => Colors.blueGrey..withAlpha(200), // Color de fondo del cuadro
                  tooltipBorderRadius: BorderRadius.all(Radius.circular(4)),
                  getTooltipItems: (List<LineBarSpot> touchedSpots) {
                    return touchedSpots.map((LineBarSpot touchedSpot) {
                      String labelSerie= serieName(touchedSpot.barIndex);
                          
                      return LineTooltipItem(
                        touchedSpot.barIndex<3
                        ? '$labelSerie: ${touchedSpot.y.toStringAsFixed(1)}' // Texto que se mostrará (puedes personalizarlo)
                        : '$labelSerie: ${(getPendiente( data[touchedSpot.barIndex].spots)) .toStringAsFixed(1)} ml/mes', // Texto que se mostrará (puedes personalizarlo)
                        
                        const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
         
            lineBarsData: data,
          //  minY: 0,
           
            titlesData: FlTitlesData(
              show: true,
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              bottomTitles: AxisTitles(
                axisNameWidget: Text(
                  'Months',
                  style: TextStyle(
                    fontSize: 10,
                    color: mainLineColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 18,
                  interval: 1,
                  getTitlesWidget: bottomTitleWidgets,
                ),
                
              ),
              leftTitles: AxisTitles(
                axisNameSize: 20,
                axisNameWidget:  Text(
                  'Value',
                  style: TextStyle(
                  //  color: Theme.of(context).primaryColor ,
                  ),
                ),
                
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 60,
                  interval: (dynamicMaxY/5),      // <--- IMPORTANTE: Debe coincidir con el intervalo de la grilla
          getTitlesWidget: (double value, TitleMeta meta) {
            // Aquí puedes dar formato a los números (ej. agregar '$' o '%')
            return SideTitleWidget(
              meta: meta,
              space: 10,
              child: Text(
                value.toStringAsFixed(0), // Muestra 0, 1, 2, 3... sin decimales
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            );
          },
                ),
                
              ),
            ),
            
            borderData: FlBorderData(
              show: false,
              border: Border.all(
                color: Theme.of(context).primaryColor,
              ),
            ),
            
          ),
        ),
      ),
    );
  }
}

String serieName(int value){
                       String labelSerie;
                          switch (value) {
                            case 0:
                              labelSerie = 'Paquetas';
                              break;
                            case 1:
                              labelSerie = 'Plasma';
                              break;
                            case 2:
                              labelSerie = 'Leuco';
                              break;
                            case 3:
                              labelSerie = 'Tendencia Plaquetas';
                              break;
                            case 4:
                              labelSerie = 'Tendencia Plasma';
                              break;
                            case 5:
                              labelSerie = 'Tendencia Leuco';
                              break;
                            default:
                              labelSerie = 'Serie unknow';
                          }

 return labelSerie;
}