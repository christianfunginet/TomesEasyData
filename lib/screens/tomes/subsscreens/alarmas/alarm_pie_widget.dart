import 'package:tomesdashboard/indices.dart';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/models/alarm.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alarmas/alarm_pie_chart.dart';

import '../../../../constants.dart';

class AlarmPieWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const AlarmPieWidget({
    super.key,
    required this.corridas,
  });

  @override
  Widget build(BuildContext context) {
   List<AlarmAlert> alarmas=[];
    List<DataSerie> series=[];
    
    var at=corridas.where((test) =>test.alarmas.isNotEmpty).toList();
    for(var corrida in at){
      alarmas+=(corrida.alarmas);
    }
    Map<String,dynamic>alarmasCont={};
    for (var element in alarmas) {
      if(alarmasCont[element.codigo]==null){
        alarmasCont[element.codigo]=alarmas.where((test)=>test.codigo==element.codigo).toList();
        series.add(
           DataSerie(name: element.codigo, longitud: alarmasCont[element.codigo].length, corridas: alarmas.where((test)=>test.codigo==element.codigo).toList()));
      }
    }

    series.sort(((a, b) => b.longitud.compareTo(a.longitud)));
    int total=alarmas.length;
    
    
    return Container(
      padding: EdgeInsets.all(defaultPadding),
      decoration: BoxDecoration(
      color: Theme.of(context).splashColor,
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Alarmas por Tipo",
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: defaultPadding,),
          SizedBox(
            width: double.infinity,
            child: AlarmPieChart(series: series,total: total,),
          ),
          SizedBox(height: defaultPadding,),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(defaultPadding),
                  decoration: BoxDecoration(
                     border: Border.all(color: Theme.of(context).primaryColor),
                   borderRadius: const BorderRadius.all(Radius.circular(10)),
                  ),
                  height: 60,
                  child: Center(child: Text("${(corridas.length/at.length).ceil().toStringAsFixed(0)}  Procedimientos/Alarma")),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }
}

