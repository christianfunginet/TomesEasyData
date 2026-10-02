import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:tomesdashboard/screens/big_widget.dart';
import '../../../../constants.dart';

class ProtocolsVsCompWidget extends StatefulWidget {
  final List<Corrida> corridas;
  final bool showZoom;
  const ProtocolsVsCompWidget({
    required this.corridas,
    this.showZoom=true,
    super.key,
  });

  @override
  State<ProtocolsVsCompWidget> createState() => _ProtocolsVsCompWidgetState();
}

class _ProtocolsVsCompWidgetState extends State<ProtocolsVsCompWidget> {
    final double width = 7;
  double maxY=0;
  List<BarChartGroupData> rawBarGroups=[];
  List<BarChartGroupData> showingBarGroups=[];
  
  int touchedGroupIndex = -1;


  List<bool> showSerie=List.generate((200), (_)=>true);
  int touchedIndex=-1;
  Map<String,List<double>> series={};
  List<String> names=[];
 @override
  void initState() {
    super.initState();
    proccess();
  }
  @override
  void didUpdateWidget(covariant ProtocolsVsCompWidget oldWidget) {
    if(oldWidget.corridas!=widget.corridas){
      proccess();
      setState(() {
        
      });
    }
    super.didUpdateWidget(oldWidget);
  }
  
proccess(){
     List<CorridasDataSerie> usuarios=[];
    Map<String,dynamic> usuarioMap={};
    for(var corrida in widget.corridas){
      if(usuarioMap[corrida.nombreDeProtocolo ]==null){
        usuarioMap[corrida.nombreDeProtocolo]=corrida.nombreDeProtocolo;
        usuarios.add(
          CorridasDataSerie(
            name: corrida.nombreDeProtocolo,
            corridas: widget.corridas.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList(),
            longitud: widget.corridas.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList().length
          )
        );
      }
    }
    
   
    for (var user in usuarios) { 
      double plasmaPorUsuario=0.0;
      double plaquetasPorUsuario=0.0;
      double leucoPorUsuario=0.0;
      double rendimientoPorUsuario=0.0;
      int divisores=0;
      int bolsas=0;
      for(var corrida in user.corridas){
        for(var bolsa in corrida.bolsas){
          if(series[user.name]!=null){
            if(series[user.name]!.isNotEmpty){
            series[user.name]!.add( bolsa.volumenDePlaquetas.toDouble());   
            }
          }
          plaquetasPorUsuario += bolsa.volumenDePlaquetas;
          plasmaPorUsuario+= bolsa.volumenDePlasma;
          leucoPorUsuario+= bolsa.volumenDeLeucocitos;        
          rendimientoPorUsuario+= bolsa.indiceDeRendimientoDePlaquetas;
          if(bolsa.indiceDeRendimientoDePlaquetas!=0){
            divisores+= 1;  
          }
          bolsas++;
        }
      }
       List<double> values=[
        bolsas==0?0:plasmaPorUsuario/bolsas,
        bolsas==0?0:plaquetasPorUsuario/bolsas,
        bolsas==0?0:leucoPorUsuario/bolsas,
        divisores==0?0:rendimientoPorUsuario/(divisores)

      ];
     series[user.name]=values;   
      
      double n=values.reduce(max);
      if(n>maxY){
        maxY=n;

      }
      names.add(user.name);
    }
    List<BarChartGroupData> items = [];
    int ptr=0;
    series.forEach((name,list){
      final barGroup1 = makeGroupData(ptr, list[0], list[1],list[2],list[3]);
      items.add(barGroup1);
      ptr++;  
    });
  

    rawBarGroups = items;

    showingBarGroups = rawBarGroups;
 
}
  @override
  Widget build(BuildContext context) {

  double w=series.length<8?700:(100.0*series.length);
    return AspectRatio(
      aspectRatio: 1.9,
      child: Container(
        padding: EdgeInsets.all(defaultPadding),
          decoration: BoxDecoration(
          color: Theme.of(context).splashColor,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
        ),
        child:Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: [
                    if(widget.showZoom)...[
                    IconButton(onPressed: (){
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context)=> BigScreenWidget(widget: ProtocolsVsCompWidget(corridas:widget. corridas,showZoom: false,),))
                      );
                    }, icon: Icon(Icons.zoom_in)),
                    SizedBox(width: 12,)
                  ],
                    const Text(
                      'Protocols vs Components',
                      style: TextStyle(color: Colors.white, fontSize: 22),
                    ),
                  ],
                ),
                
              ],
            ),
            const SizedBox(
              height: 38,
            ),
            Expanded(
              
              child: SingleChildScrollView (
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                width:w,
                height: 300,    
                  child: BarChart(
                    BarChartData(
                      maxY: maxY*1.3,
                      
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          fitInsideVertically: true,
                          getTooltipColor: ((group) {
                            return Colors.grey;
                          }),
                          getTooltipItem: (a, b, c, d) {
                            List<String> cmp=["Plasma","Plaquetas","Leuco","Rendimineto"];
                            return BarTooltipItem(" ${names[b]}  ${cmp[d]} ${a.barRods[d].toY.toStringAsFixed(1)}"  , TextStyle( fontSize: 12));
                          },
                        ),
                        /*
                        touchCallback: (FlTouchEvent event, response) {
                          if (response == null || response.spot == null) {
                            setState(() {
                              touchedGroupIndex = -1;
                              showingBarGroups = List.of(rawBarGroups);
                            });
                            return;
                          }
                  
                          touchedGroupIndex = response.spot!.touchedBarGroupIndex;
                          setState(() {
                            if (!event.isInterestedForInteractions) {
                              touchedGroupIndex = -1;
                              showingBarGroups = List.of(rawBarGroups);
                              return;
                            }
                            showingBarGroups = List.of(rawBarGroups);
                            if (touchedGroupIndex != -1) {
                              var sum = 0.0;
                              for (final rod
                                  in showingBarGroups[touchedGroupIndex].barRods) {
                                sum += rod.toY;
                              }
                              final avg = sum /
                                  showingBarGroups[touchedGroupIndex]
                                      .barRods
                                      .length;
                  
                              showingBarGroups[touchedGroupIndex] =
                                  showingBarGroups[touchedGroupIndex].copyWith(
                                barRods: showingBarGroups[touchedGroupIndex]
                                    .barRods
                                    .map((rod) {
                                  return rod.copyWith(
                                    toY: avg,
                                    color: avgColor,
                  
                               //     label: makeLabel(avg, widget.avgColor, true),
                                  );
                                }).toList(),
                              );
                            }
                          });
                        },
                        */
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        rightTitles: const AxisTitles(
                          sideTitleAlignment: SideTitleAlignment.inside,
                          drawBelowEverything: true,
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: bottomTitles,
                            reservedSize: 80,
                          ),
                        ),
                        /*
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: 1,
                            getTitlesWidget: leftTitles,
                          ),
                        ),
                        */
                      ),
                      borderData: FlBorderData(
                        show: false,
                      ),
                      barGroups: showingBarGroups,
                      gridData: const FlGridData(
                        drawHorizontalLine: true,
                        drawVerticalLine: false,
                        show: true),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(
              height: 12,
            ),
          ],
        ),
      ),
       )   );
  }

 
  Widget bottomTitles(double value, TitleMeta meta) {
  //  final titles = <String>['Mn', 'Te', 'Wd', 'Tu', 'Fr', 'St', 'Su'];

    final Widget text = RotatedBox(
      quarterTurns: 3,
      child: SizedBox(
        child: Text(
          names[value.toInt()],
          style: const TextStyle(
            color: Color(0xff7589a2),
            fontWeight: FontWeight.bold,
            fontSize: 14,
            overflow: TextOverflow.ellipsis
          ),
        ),
      ),
    );

    return SideTitleWidget(
      meta: meta,
      space: 16, //margin top
      child: text,
    );
  }
  BarChartGroupData makeGroupData(int x, double y1, double y2, double y3, double y4) {
    return BarChartGroupData(
      barsSpace: 4,
      x: x,
      barRods: [
        BarChartRodData(
          toY: y1,
          color: colorDePlasma,
          width: width,
       //   label: makeLabel(y1, widget.leftBarColor, false),
        ),
        BarChartRodData(
          toY: y2,
          color: colorDePlaquetas,
          width: width,
       //   label: makeLabel(y1, widget.leftBarColor, false),
        ),
        BarChartRodData(
          toY: y3,
          color: colorDeLeuco,
          width: width,
      //    label: makeLabel(y2, widget.rightBarColor, false),
        ),
        BarChartRodData(
          toY: y4,
          color: colorDerendimiento,
          width: width,
      //    label: makeLabel(y2, widget.rightBarColor, false),
        ),
      ],
    );
  }

}