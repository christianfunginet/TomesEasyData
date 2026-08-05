import 'package:flutter/material.dart';
import 'package:tomesdashboard/indices.dart';

import '../../../constants.dart';
import 'chart.dart';
import 'storage_info_card.dart';

class StorageDetails extends StatelessWidget {
  final List<Corrida> corridas;
  const StorageDetails({
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
  List<StorageInfoCard> protocolList = [];
  protocolCounts.forEach((protocol, count) {
    protocolList.add(
      StorageInfoCard(
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
        color: secondaryColor,
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
          Chart(corridas: corridas),
          ...protocolList,
          
        ],
      ),
    );
  }
}
