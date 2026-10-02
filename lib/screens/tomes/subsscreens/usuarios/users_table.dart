
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';

import 'package:flutter/material.dart';

import '../../../../constants.dart';

class UsersTableWidget extends StatelessWidget {
  final List<Corrida> corridas;
  const UsersTableWidget({
    super.key,
    required this.corridas,
  });

  @override
  Widget build(BuildContext context) {
    List<CorridasDataSerie> protocolos=[];
    List<CorridasDataSerie> protocolosPorUsuario=[];
    Map<String,dynamic> protocolosMap={};
    Map<String,dynamic> protocolosPorUsuarioMap={};
    for(var corrida in corridas){

      if(protocolosMap[corrida.nombreDeProtocolo]==null){
        protocolosMap[corrida.nombreDeProtocolo]=corrida.nombreDeProtocolo;
        protocolos.add(
          CorridasDataSerie(
            name: corrida.nombreDeProtocolo,
            corridas: corridas.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList(),
            longitud: corridas.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList().length
          )
        );
      }
      if(protocolosPorUsuarioMap[corrida.codigoDeOperador ]==null){
        protocolosPorUsuarioMap[corrida.codigoDeOperador]=corrida.codigoDeOperador;
        protocolosPorUsuario.add(
          CorridasDataSerie(
            name: corrida.codigoDeOperador,
            corridas: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList(),
            longitud: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList().length
          )
        );
      }
    }
    
    protocolos.sort((a, b) => b.longitud.compareTo(a.longitud));
    if(protocolosPorUsuario.length>1){
    protocolosPorUsuario.sort((a, b) => b.longitud.compareTo(a.longitud));
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
            "Protocols vs Users",
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(
            width: double.infinity,
            child: DataTable(
              columnSpacing: defaultPadding,
              // minWidth: 600,
              columns: [
                DataColumn(
                  label: Text("User"),
                ),
                DataColumn(
                  label: Text("Qty"),
                ),
                DataColumn(
                  label: Text("Alerts/Run"),
                ),
                DataColumn(
                  label: Text("Alarms/Run"),
                ),
              ],
              rows: List.generate(
                protocolosPorUsuario.length,
                (index) => usuariosData(protocolosPorUsuario[index],index),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

DataRow usuariosData(CorridasDataSerie protocolos,int index) {
  
 
    
    var wf=protocolos.corridas.where((test) =>test.alertas.isNotEmpty).toList();
    var at=wf.where((test) =>test.codigoDeOperador==protocolos.name).toList();

 
    var awf=protocolos.corridas.where((test) =>test.alarmas.isNotEmpty).toList();
    var aat=awf.where((test) =>test.codigoDeOperador==protocolos.name).toList();

  
    
  return DataRow(
    cells: [
      DataCell(
        Row(
          
          children: [
            Container(
              padding: EdgeInsets.all(defaultPadding * 0.5),
              height: 40,
              width: 40,
              decoration: BoxDecoration(
                color: lineColors[index+5].withAlpha(50),
                borderRadius: const BorderRadius.all(Radius.circular(10)),
              ),
              child: Center(
                child: Icon(
                  Icons.person,
                  color: lineColors[index+5],
                ),
              ),
            ),       
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: defaultPadding),
              child: Text(protocolos.name ),
            ),
          ],
        ),
      ),
      DataCell(Text(protocolos.longitud.toString())),
      DataCell(Text(protocolos.longitud!=0 ? (at.length/protocolos.longitud).toStringAsFixed(3) :0.toStringAsFixed(1)) ),
      DataCell(Text(protocolos.longitud!=0 ? (aat.length/protocolos.longitud).toStringAsFixed(3) :0.toStringAsFixed(1) ) ),
     ],
  );
}
