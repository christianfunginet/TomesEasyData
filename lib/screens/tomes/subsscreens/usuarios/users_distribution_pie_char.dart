import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import '../../../../constants.dart';

class UsersDistributionPieChar extends StatefulWidget {
  final List<Corrida> corridas;
  const UsersDistributionPieChar({
    required this.corridas,
    super.key,
  });

  @override
  State<UsersDistributionPieChar> createState() => _UsersDistributionPieCharState();
}

class _UsersDistributionPieCharState extends State<UsersDistributionPieChar> {
  int touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
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
              sections: paiChartSelectionData(widget.corridas, touchedIndex),
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
                  widget.corridas.length.toString(),
                  style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        height: 0.5,
                      ),
                ),
                Text(
                  "Runs",
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

List<PieChartSectionData> paiChartSelectionData(List<Corrida> corridas,int touchedIndex) {
  List<CorridasDataSerie> corridasPorUsuario=[];
  Map<String, dynamic> userCount = {};
   for(var corrida in corridas){
      if(userCount[corrida.codigoDeOperador]==null){
        userCount[corrida.codigoDeOperador]=corrida.codigoDeOperador;
    
        corridasPorUsuario.add(
          CorridasDataSerie(
            name: corrida.codigoDeOperador,
            corridas: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList(),
            longitud: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList().length
          )
        );
    }
  }
    if(corridasPorUsuario.length>1){
    corridasPorUsuario.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
  List<PieChartSectionData> data = [];
  int i = 0;
  for(var corrida in corridasPorUsuario) {
      final isTouched = i == touchedIndex;
      final fontSize = isTouched ? 20.0 : 16.0;
      final radius = isTouched ? 45.0 : 40.0;
    
    data.add(
      
      PieChartSectionData(

        color: lineColors[i+5],
        value: corrida.longitud.toDouble(),
        showTitle: isTouched,
        radius: radius,
        title: corrida.name,
        titlePositionPercentageOffset: 1.0,
        badgeWidget: Text(
          corrida.longitud.toString(),
          style: TextStyle(
          //  color: Colors.white,
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

  