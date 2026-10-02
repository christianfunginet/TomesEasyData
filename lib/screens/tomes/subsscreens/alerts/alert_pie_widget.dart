import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/alarm.dart';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alerts/alert_pie_chart.dart';

import '../../../../constants.dart';

class AlertPieWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const AlertPieWidget({
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
    int total=alertas.length;

    
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
            "Alertas por Tipo",
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: defaultPadding,),
          SizedBox(
            width: double.infinity,
            child: AlertPieChart(series: series,total: total,),
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
                   // color: primaryColor.withAlpha(25),
                    border: Border.all(color: Theme.of(context).primaryColor),
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                  ),
                  height: 60,
                  child: Center(child: Text("${(corridas.length/at.length).ceil().toStringAsFixed(0)}  Procedimientos/Alerta")),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }
}

DataRow recentFileDataRow(DataSerie fileInfo) {
  return DataRow(
    onHover: (value) {
     
    },
    cells: [
      DataCell(Tooltip(
        message: fileInfo.corridas.first.descripcion,
        child: Text(fileInfo.name))),
      DataCell(Text(fileInfo.longitud.toString())),
    ],
  );
}
