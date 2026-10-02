import 'package:flutter/material.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/dashboard/bags_pie_chart.dart';

import '../../../../constants.dart';
import '../protocols/protocol_info_card.dart';

class RunsBagsWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const RunsBagsWidget({
    required this.corridas,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
  int unaBolsa=corridas.where((corrida) => corrida.bolsas.length==1).length ;
  int dosBolsa=corridas.where((corrida) => corrida.bolsas.length==2).length ;
  int tresBolsa=corridas.where((corrida) => corrida.bolsas.length==3).length ;
  int cuatroBolsa=corridas.where((corrida) => corrida.bolsas.length==4).length ;
  int ceroBolsa=corridas.where((corrida) => corrida.bolsas.isEmpty).length ;
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
  int total=ceroBolsa+unaBolsa+dosBolsa+tresBolsa+cuatroBolsa;
  List<ProtocolInfoCard> protocolList = [];
    protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: "Cuatro Bolsas",
        amountOfFiles: "${((cuatroBolsa/total)*100).toStringAsFixed(1)}%",
        numOfFiles: cuatroBolsa,
      )
    );
  protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: "Tres Bolsas",
        amountOfFiles: "${((tresBolsa/total)*100).toStringAsFixed(1)}%",
        numOfFiles: tresBolsa,
      )
    );
  protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: "Dos Bolsas",
        amountOfFiles: "${((dosBolsa/total)*100).toStringAsFixed(1)}%",
        numOfFiles: dosBolsa,
      )
    );
  protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: "Una Bolsas",
        amountOfFiles: "${((unaBolsa/total)*100).toStringAsFixed(1)}%",
        numOfFiles: unaBolsa,
      )
    );
  protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: "No productiva",
        amountOfFiles: "${((ceroBolsa/total)*100).toStringAsFixed(1)}%",
        numOfFiles: ceroBolsa,
      )
    );
  
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
            "Bolsas por corrida",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: defaultPadding),
          BagsPieChart(corridas: corridas),
          ...protocolList,
          
        ],
      ),
    );
  }
}
