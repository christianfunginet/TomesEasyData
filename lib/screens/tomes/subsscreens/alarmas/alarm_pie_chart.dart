import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/alarm.dart';

import '../../../../constants.dart';

class AlarmPieChart extends StatefulWidget {
  final  List<DataSerie> series;
  final int total;
  const AlarmPieChart({
    required this.series,
    required this.total,
    
    super.key,
  });

  @override
  State<AlarmPieChart> createState() => _AlarmPieChartState();
}

class _AlarmPieChartState extends State<AlarmPieChart> {
  int touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
 List<DataSerie> seriesSorted=[];
  Map<String, List<AlarmAlert>>seriesMap={};
  for (var ser in widget.series) {
    for(var al in ser.corridas){
      if(seriesMap[al.descripcion]==null){
        seriesMap[al.descripcion]=[al];
      }else{
        seriesMap[al.descripcion]!.add(al) ;
      }  
    }
  }
  seriesMap.forEach((e,alarms){
    seriesSorted.add(
      DataSerie(
        name: e,
        longitud: alarms.length,
        corridas: alarms,
    ));
  });
 

    List<DataSerie> seriesToShow=seriesSorted;
     if(seriesToShow.length>1){
    seriesToShow.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
    
  
    

    return SizedBox(
      height: 200,
      child: Stack(
        children: [
          PieChart(
            PieChartData(
            borderData: FlBorderData(
              show: false,
            ),
    
              sectionsSpace: 0,
              centerSpaceRadius: 70,
              startDegreeOffset: -90,
              sections: paiChartSelectionData(seriesToShow, touchedIndex),
              pieTouchData: PieTouchData(
                touchCallback: (FlTouchEvent event, pieTouchResponse) {
                  setState(() {
                        if (!event.isInterestedForInteractions ||
                            pieTouchResponse == null ||
                            pieTouchResponse.touchedSection == null) {
                          touchedIndex = -1;
                          return;
                        }
                        touchedIndex = pieTouchResponse
                            .touchedSection!.touchedSectionIndex;
                      });
                // Handle touch events if needed
              }),
            ),
          ),
          Positioned.fill(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: defaultPadding),
                Text(
                  widget.total.toString(),
                  style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        height: 0.5,
                      ),
                ),
                Text(
                  "Alarmas",
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<PieChartSectionData> paiChartSelectionData(List<DataSerie> series,int touchedIndex) {
  List<PieChartSectionData> data = [];
  int i = 0;
  for (var protocol in series) {
    final isTouched = i == touchedIndex;
    final fontSize = isTouched ? 20.0 : 16.0;
    final radius = isTouched ? 45.0 : 40.0;
    data.add(
      PieChartSectionData(

        color: lineColors[series.indexOf(protocol) % lineColors.length],
        value: protocol.longitud.toDouble(),
        showTitle: isTouched,
        radius: radius,
        title: protocol.name.toString(),
        titlePositionPercentageOffset: 0.0,
        badgePositionPercentageOffset: 0.5,
        badgeWidget: Text(
          protocol.longitud.toString(),
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
          ),
        ),

      )
    );
    i++;
  }
  return data;
}

  