import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/screens/tomes/components/visitor_growth_progress_bar.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/usuarios/users_distribution_pie_char.dart';

import '../../../../constants.dart';

class UsersDistributionWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const UsersDistributionWidget({
    required this.corridas,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
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
  
  List<Widget> protocolList = [];
  if(corridasPorUsuario.length>1){
    corridasPorUsuario.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
  int i=5;  
  for (var element in corridasPorUsuario) {
    protocolList.add(
      Padding(
        padding: const EdgeInsets.all(8.0),
        child: VisitorGrowthProgressBar(
          subTitle: "${((element.longitud/corridas.length)*100).toStringAsFixed(1)}%",
          title: element.name,
          color: lineColors[i],
        //  amountOfFiles: "${((count/corridas.length)*100).toStringAsFixed(1)}%",
          progress: element.longitud/corridas.length,
        ),
      )
    );
    i++;
  
}
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
            "Users vs Runs",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: defaultPadding),
          UsersDistributionPieChar(corridas: corridas),
          ...protocolList,
        ],
      ),
    );
  }
}
