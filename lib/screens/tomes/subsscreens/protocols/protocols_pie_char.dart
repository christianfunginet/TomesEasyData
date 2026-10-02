import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';

import '../../../../constants.dart';

class ProtocolsPieChart extends StatefulWidget {
  final List<Corrida> corridas;
  const ProtocolsPieChart({
    required this.corridas,
    super.key,
  });

  @override
  State<ProtocolsPieChart> createState() => _ProtocolsPieChartState();
}

class _ProtocolsPieChartState extends State<ProtocolsPieChart> {
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
  List<String> protocols = corridas.map((corrida) => corrida.nombreDeProtocolo).toList() ;
  protocols = protocols.toSet().toList(); // Eliminar duplicados
  Map<String, int> protocolCounts = {};
  for(var corrida in corridas){
    for (var protocol in protocols) {
      if(corrida.nombreDeProtocolo == protocol){
        protocolCounts[protocol] = (protocolCounts[protocol] ?? 0) +1;
      }
    }
 
 
  }
  List<PieChartSectionData> data = [];
  int i = 0;
  protocolCounts.forEach((protocol, count) {
    final isTouched = i == touchedIndex;
    final fontSize = isTouched ? 20.0 : 16.0;
    final radius = isTouched ? 45.0 : 40.0;
    data.add(
      PieChartSectionData(
        color: lineColors[protocols.indexOf(protocol) % lineColors.length],
        value: count.toDouble(),
        showTitle: isTouched,
        radius: radius,
        title: protocol,
        titlePositionPercentageOffset: 1.0,
        badgeWidget: Text(
          count.toString(),
          style: TextStyle(
            color: Colors.white,
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

  