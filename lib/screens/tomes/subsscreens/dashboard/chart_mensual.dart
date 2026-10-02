import 'package:fl_chart/fl_chart.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/screens/big_widget.dart';

import '../../../../constants.dart';

class MonthlyResultCard extends StatelessWidget {
  final List<Corrida> corridas;
  final bool showZoom;
  const MonthlyResultCard({
    super.key,
    this.showZoom=true,
    required this.corridas,
  });

  @override
  Widget build(BuildContext context) {
    List<List<double>> plasmaPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<double>> plaquetasPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<double>> leucoPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<double>> rendimientoPorMes=List.generate(5,(_)=> List.generate(12, (_)=>0));
    List<List<double>> divisores=List.generate(5,(_)=> List.generate(12, (_)=>0));
    
    int y=DateTime.now().year;

    for(var corrida in corridas){
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

    for(var year=0; year< rendimientoPorMes.length;year++){
      for(var month=0; month< rendimientoPorMes[year].length;month++){
        if(divisores[year][month]!=0){
        rendimientoPorMes[year][month]= (rendimientoPorMes[year][month]/divisores[year][month]);     
        }  
      }
    }


    List<List<List<double>>> series=[
      plaquetasPorMes,
      plasmaPorMes,
      leucoPorMes,
      rendimientoPorMes,
    ];

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
            children: [
              if(showZoom)...[
                    IconButton(onPressed: (){
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context)=> BigScreenWidget(widget: MonthlyResultCard(corridas: corridas,showZoom: false,),))
                      );
                    }, icon: Icon(Icons.zoom_in)),
                    SizedBox(width: 12,)
                  ],
              Text(
                "Volumenes por mes",
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: 
            
            UserWorksBarChartWidget(subTitle: "",title: "",values: series ,labels: ["Plaquetas","Plasma","Leuco","Rendimiento"],),
          ),
        ],
      ),
    );
  }
}



class UserWorksBarChartWidget extends StatefulWidget {

  final List<List<List<double>>> values;
  final List<String> labels;
  final String title;
  final String subTitle;
  const UserWorksBarChartWidget({super.key,required this.values,required this.title,required this.subTitle,required this.labels});

 
  @override
  State<StatefulWidget> createState() => UserWorksBarChartWidgetState();
}

class UserWorksBarChartWidgetState extends State<UserWorksBarChartWidget> {
  final Duration animDuration = const Duration(milliseconds: 250);
double max=0;
  int touchedIndex = -1;
  int selectedComponent=0;
  bool isPlaying = false;
 double maxY=0;

  @override
  Widget build(BuildContext context) {
 
  return AspectRatio(
      aspectRatio: 1.9,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.values.length,
              reverse: true,
              itemBuilder: (context,index){
              var y=DateTime.now().year;
             return SizedBox(
              width: 300,
              height: 200,
               child: Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 8),
                 child: Stack(
                  children: <Widget>[
                     
                     BarChart(
                       mainBarData(index,),
                       
                     ),
           
                     Chip(label: 
                     Text(
                      (y -index).toString(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                     ),
                    
                    ),
                    
                   ],
                 ),
               ),
             );
             }),
          ),
          Positioned(
                  top: 0,
                  right: 0,
                  child:Container(
                    decoration: BoxDecoration(
                        color: Theme.of(context).splashColor,
        
                     borderRadius: BorderRadius.all(Radius.circular(12.0))),
                    child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    padding: EdgeInsets.only(right: 12,left: 12),
                                    icon: const Icon(Icons.arrow_drop_down_circle, color: Colors.blueAccent),
                                    iconSize: 22,
                                    dropdownColor: Colors.blueGrey,
                                    
                                    borderRadius: BorderRadius.circular(12.0), 
                                    // 5. Menu borders
                                
                        
                                    value: widget.labels[ selectedComponent],
                                    onChanged: (String? newValue) {
                                      setState(() {
                                       selectedComponent=widget.labels.indexWhere((test)=> test==newValue );
                      
                                      });
                                    },
                                    items: widget.labels.map<DropdownMenuItem<String>>((String value) {
                                      return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value,style: TextStyle(fontSize: 12),),
                                      );
                                    }).toList(),
                                  ),
                    ),
                  ),),
        ],
      ),
    );
  }

  BarChartGroupData makeGroupData(
    int x,
    double y, {
    bool isTouched = false,
    Color? barColor,
    double width = 22,
    List<int> showTooltips = const [],
    double maxY=20,
    
  }) {
    barColor ??= Colors.white;
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          
          toY: y,//isTouched ? y + 1 : y,
          color: isTouched ? Colors.green : barColor,
          width: width,
          borderSide: isTouched
              ? BorderSide(color: Colors.grey)
              : const BorderSide(color: Colors.white, width: 0),
          backDrawRodData: BackgroundBarChartRodData(
            show: true,
            toY: maxY,
            color:  (Colors.grey),
          ),
        ),
      ],
      showingTooltipIndicators: showTooltips,
    );
  }

  List<BarChartGroupData> showingGroups(int index) => List.generate(
      12,
      (i) => makeGroupData(i, widget.values[selectedComponent][index][i].toDouble(), isTouched: i == touchedIndex,barColor: lineColors[selectedComponent] ,maxY: maxY  ));
     

  BarChartData mainBarData(int index) {
  maxY=widget.values[selectedComponent][index].reduce((a,b)=> a>b?a:b)*1.3;
  if(maxY==0){
      maxY=20;
  }   
    return BarChartData(
      barTouchData: BarTouchData(
        enabled: true,
        allowTouchBarBackDraw: true,
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => Colors.blueGrey,
          tooltipHorizontalAlignment: FLHorizontalAlignment.right,
          tooltipMargin: -10,
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            String weekDay = switch (group.x) {
              0 => 'Enero',
              1 => 'Febrero',
              2 => 'Marzo',
              3 => 'Abril',
              4 => 'Mayo',
              5 => 'Junio',
              6 => 'Julio',
              7 => 'Agosto',
              8 => 'Septiembre',
              9 => 'Octubre',
              10 => 'Noviembre',
              11 => 'Diciembre',
              
              _ => throw Error(),
            };
            return BarTooltipItem(
              '$weekDay\n',
              const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
              children: <TextSpan>[
                TextSpan(
                  text: ((rod.toY).toStringAsFixed(2)).toString(),// - 1).toStringAsFixed(2)).toString(),
                  style: const TextStyle(
                    color: Colors.white, //widget.touchedBarColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            );
          },
        ),
        touchCallback: (FlTouchEvent event, barTouchResponse) {
          setState(() {
            if (!event.isInterestedForInteractions ||
                barTouchResponse == null ||
                barTouchResponse.spot == null) {
              touchedIndex = -1;
              return;
            }
            touchedIndex = barTouchResponse.spot!.touchedBarGroupIndex;
          });
        },
      ),
      titlesData: FlTitlesData(
        show: true,
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        topTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: getTitles,
            reservedSize: 38,
          ),
        ),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(
            showTitles: false,
          ),
        ),
      ),
      borderData: FlBorderData(
        show: false,
      ),
      barGroups: showingGroups(index),
      gridData: const FlGridData(show: false),
    );
  }

  Widget getTitles(double value, TitleMeta meta) {
    const style = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.bold,
      fontSize: 14,
    );
    String text = switch (value.toInt()) {
      0 => 'E',
      1 => 'F',
      2 => 'M',
      3 => 'A',
      4 => 'M',
      5 => 'J',
      6 => 'J',
      7 => 'A',
      8 => 'S',
      9 => 'O',
      10 => 'N',
      11 => 'D',
      _ => '',
    };
    return SideTitleWidget(
      meta: meta,
      space: 16,
      child: Text(text, style: style),
    );
  }

  
}