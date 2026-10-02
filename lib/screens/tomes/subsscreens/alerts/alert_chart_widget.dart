import 'package:fl_chart/fl_chart.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/alarm.dart';

import 'package:flutter/material.dart';

import '../../../../constants.dart';

class AlertChartWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const AlertChartWidget({
    super.key,
    required this.corridas,
  });

  @override
  Widget build(BuildContext context) {
    List<AlarmAlert> alertas=[];
    List<DataSerie> series=[];
    
    var at=corridas.where((test) =>test.alertas.isNotEmpty).toList();
    for(var corrida in at){
      alertas+=(corrida.alertas);
    }
    Map<String,dynamic>alertasCont={};
    for (var element in alertas) {
      if(alertasCont[element.codigo]==null){
        alertasCont[element.codigo]=alertas.where((test)=>test.codigo==element.codigo).toList();
        series.add(
           DataSerie(name: element.codigo, longitud: alertasCont[element.codigo].length, corridas: alertas.where((test)=>test.codigo==element.codigo).toList()));
      }
    }
    if(series.length>1){
      series.sort(((a, b) => b.longitud.compareTo(a.longitud)));
    }
    
    return Container(
      padding: EdgeInsets.all(defaultPadding),
        decoration: BoxDecoration(
        color: Theme.of(context).splashColor,
        borderRadius: const BorderRadius.all(Radius.circular(10)),),
      child:            SizedBox(
            width: double.infinity,
            height: 350,
            child: 
              BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceEvenly,
                  maxY: series.first.longitud*1.3, // Límite máximo del eje Y
        
                  // Configuración de la interacción al tocar las barras
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (group) => Colors.blueGrey,
                      tooltipHorizontalAlignment: FLHorizontalAlignment.center,
                      tooltipMargin: 8,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                       String desc=series[groupIndex].corridas.first.descripcion;
                        return BarTooltipItem(

                          '(${rod.toY.round()}) $desc',
                           const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                    ),
                  ),
        
                  // Títulos e información de los ejes
                  titlesData: FlTitlesData(
                    show: true,
                    topTitles: const AxisTitles(
                      sideTitleAlignment: SideTitleAlignment.inside,
                      axisNameWidget: Text("Alertas por Codigo"),
                      sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 35,
                        getTitlesWidget: (value, meta) {
                          // Muestra solo valores de 20 en 20 para limpieza visual
                          if (value % 20 == 0) {
                            return Text(
                              value.toInt().toString(),
                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        reservedSize: 30,
                        showTitles: true,
                        getTitlesWidget: (double value, TitleMeta meta) {
                          return  RotatedBox(
                            quarterTurns: 3,
                            child: Text(series[value.toInt()].name , style: TextStyle(color: Colors.grey, fontSize: 12)));
                        },
                      ),
                    ),
                  ),
        
                  // Desactivar bordes genéricos del gráfico
                  borderData: FlBorderData(show: false),
        
                  // Cuadrícula horizontal de fondo sutil
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: Colors.grey.withAlpha(25),
                      strokeWidth: 1,
                    ),
                  ),
        
                  // Lista de grupos de barras
                  barGroups: 
                  series.map((serie)=>_construirGrupoDeBarras(
                    series.indexWhere((test)=>test==serie)
                    , serie.longitud.toDouble())).toList()
                  ,
                ),
              ),
      ),
          );
  }

  // Método auxiliar para estructurar y dar estilo a las barras individuales
  BarChartGroupData _construirGrupoDeBarras(int x, double y) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: Colors.yellow,
          width: 18,
          borderRadius: BorderRadius.circular(4),
          // Sombra de fondo gris para dar contexto del límite máximo
          
        ),
      ],
    );
  }
}