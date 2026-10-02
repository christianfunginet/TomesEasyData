import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';

import '../../../../constants.dart';

class BagsPieChart extends StatefulWidget {
  final List<Corrida> corridas;
  const BagsPieChart({
    required this.corridas,
    super.key,
  });

  @override
  State<BagsPieChart> createState() => _BagsPieChartState();
}

class _BagsPieChartState extends State<BagsPieChart> {
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
              startDegreeOffset: 0,
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
  List<String> protocols = corridas.map((corrida) => corrida.nombreDeProtocolo).toList() ;
  protocols = protocols.toSet().toList(); // Eliminar duplicados
  Map<String, int> protocolCounts = {};
  for(var a=0; a<5; a++){
        protocolCounts[a.toString()] = corridas.where((corrida) => corrida.bolsas.length==a).length ;
  }
  List<PieChartSectionData> data = [];
  int i = 0;
  protocolCounts.forEach((protocol, count) {
    final isTouched = i == touchedIndex;
    final fontSize = isTouched ? 20.0 : 16.0;
    final radius = isTouched ? 45.0 : 40.0;
    data.add(
      PieChartSectionData(
        color: lineColors[int.parse(protocol)],
        value: count.toDouble(),
        showTitle: isTouched,
        radius: radius,
        title: "$protocol bolsas",
        titlePositionPercentageOffset: 1.0,
        badgeWidget: Text(
          "${(count/corridas.length*100).toStringAsFixed(1)} %",
          style: TextStyle(
         //   color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
          ),
        ),
      )
    );
    i++;
  });
  return data;
}

  