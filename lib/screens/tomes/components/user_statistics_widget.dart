import 'package:flutter/material.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';

class UserStatisticsWidget extends StatefulWidget {
  const UserStatisticsWidget({
    super.key,
    required this.listEquipment,
    required this.percent,
    required this.legend,
    required this.total,
    

  });

  final bool listEquipment;
  final double percent;
  final String legend;
  final int total;
  @override
  State<StatefulWidget> createState() => _UserStatisticsWidget();
}

class _UserStatisticsWidget extends State<UserStatisticsWidget> {
  int touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
    
    double radio= MediaQuery.of(context).size.width*0.050;
    return SizedBox(
      child: 
      Column(
                  children: [
                    const SizedBox(
                      height: 18,
                    ),
                    Text(widget.total.toString(),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                       
                      ),
                    ),
                    AspectRatio(
                      aspectRatio: 1.4,
                      child: Row(
                        children: <Widget>[
                          
                          Expanded(
                            child: AspectRatio(
                              aspectRatio: 1.4,
                              child: 
                                Stack(
                                  alignment: AlignmentGeometry.center,
                                  children: [
                                    CircularPercentIndicator(
                                  lineWidth: 34,
                                  radius: radio,
                                  percent: 1*((360-60)/360),
                                  startAngle: 210,
                                  progressColor: const Color.fromARGB(104, 158, 158, 158),
                                  animation: false,
                                  backgroundColor: Colors.transparent,
                                  addAutomaticKeepAlive: false,
                                     footer: Text(widget.legend),
                                   circularStrokeCap: CircularStrokeCap.round,
                                  ),
                               
                                    CircularPercentIndicator(
                                      lineWidth: 34,
                                      radius: radio,
                                      percent: widget.percent *((360-60)/360),
                                      startAngle: 210,
                                      animation: true,
                                      center: Text("${(widget.percent * 100).toStringAsFixed(1)} %",
                                      style:  TextStyle(
                                        fontSize: radio*0.25,
                                        fontWeight: FontWeight.bold,
                                      ),),
                                     footer: Text(widget.legend),
                                      animationDuration: 500,
                                      backgroundColor: Colors.transparent,
                                      addAutomaticKeepAlive: false,
                                      circularStrokeCap: CircularStrokeCap.round,
                                                                      ),
                                  ],
                                ),
                               ),
                              ),
                         
                          
                        ],
                      ),
                    ),
               
                
              ])
        
    );
  }
}