import 'package:flutter/material.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/protocols/protocols_pie_char.dart';

import '../../../../constants.dart';
import 'protocol_info_card.dart';

class ProtocolsDistributionWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const ProtocolsDistributionWidget({
    required this.corridas,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
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
  List<ProtocolInfoCard> protocolList = [];
  protocolCounts.forEach((protocol, count) {
    protocolList.add(
      ProtocolInfoCard(
        svgSrc: "assets/icons/Documents.svg",
        title: protocol,
        amountOfFiles: "${((count/corridas.length)*100).toStringAsFixed(1)}%",
        numOfFiles: count,
      )
    );
  });
  
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
            "Distribucion de Protocolos",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: defaultPadding),
          ProtocolsPieChart(corridas: corridas),
          ...protocolList,
          
        ],
      ),
    );
  }
}
