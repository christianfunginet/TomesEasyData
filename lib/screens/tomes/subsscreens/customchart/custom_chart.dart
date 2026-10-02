import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import '../../../../constants.dart';

class CustomChartwidget extends StatefulWidget {
  final List<Corrida> corridas;
  const CustomChartwidget({
    required this.corridas,
    super.key,
  });

  @override
  State<CustomChartwidget> createState() => _CustomChartwidgetState();
}

class _CustomChartwidgetState extends State<CustomChartwidget> {
  List<bool> showSerie=List.generate((6), (_)=>true);
DateTime? selected;
  @override
  Widget build(BuildContext context) {

    List<CorridasDataSerie> protocolosOnDay=[];
    List<CorridasDataSerie> protocolos=[];
    Map<String,dynamic> protocolosMap={};
    
    List<CorridasDataSerie> usuarios=[];
    Map<String,dynamic> usuarioMap={};
    List<Corrida> s=[];
    
    if(selected!=null){
       s=widget.corridas.where((corrida)=> (corrida.day==selected!.day && corrida.month==selected!.month && corrida.year==selected!.year)  ).toList();
    }
   
    for(var corrida in s){
      if(protocolosMap[corrida.nombreDeProtocolo]==null){
        protocolosMap[corrida.nombreDeProtocolo]=corrida.nombreDeProtocolo;
        protocolos.add(
          CorridasDataSerie(
            name: corrida.nombreDeProtocolo,
            corridas: s.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList(),
            longitud: s.where((test)=> test.nombreDeProtocolo==corrida.nombreDeProtocolo).toList().length
          )
        );
      }
      if(usuarioMap[corrida.codigoDeOperador ]==null){
        usuarioMap[corrida.codigoDeOperador]=corrida.codigoDeOperador;
        usuarios.add(
          CorridasDataSerie(
            name: corrida.codigoDeOperador,
            corridas: s.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList(),
            longitud: s.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList().length
          )
        );
      }
    }
    


    
    

    if(protocolos.length>1){
   protocolos.sort((a, b) => b.longitud.compareTo(a.longitud));
   }
    if(usuarios.length>1){
    usuarios.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
    DateTime inicio=DateTime(widget.corridas.first.year, widget.corridas.first.month,widget.corridas.first.day);
    DateTime fin=DateTime(widget.corridas.last.year, widget.corridas.last.month,widget.corridas.last.day);
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
              Text(
                "Corridas",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              IconButton(
                icon: Icon(Icons.date_range) ,
                onPressed: ()async{
                var t=await 
                 showDialog(context: context, builder: (context){
                  return DatePickerDialog(firstDate: inicio, lastDate: fin);
                    });
                  if(t!=null){
                    setState(() {
                      
                    selected=t;
                    });
                    print(selected);
                  }
                }
                )
            ],
          ),
          if(selected!=null)
          SizedBox(
            width: double.infinity,
            child: DataTable(
              columnSpacing: defaultPadding,
              // minWidth: 600,
              columns: [
                DataColumn(
                  label: Text("Usuario"),
                ),
                DataColumn(
                  label: Text("Protocolo"),
                ),
                DataColumn(
                  label: Text("Bolsas"),
                ),
                DataColumn(
                  label: Text("Alertas"),
                ),
                DataColumn(
                  label: Text("Duracion"),
                ),
              ],
              rows: List.generate(
                s.length,
                (index) => recentFileDataRow(s[index],index),
              ),
            ),
          ),
          
        ],
      ),
    );
  }
}

DataRow recentFileDataRow(Corrida protocolos,int index) {
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
              child: Text(protocolos.codigoDeOperador ),
            ),
          ],
        ),
      ),
      DataCell(Text(protocolos.nombreDeProtocolo)),
      DataCell(Text(protocolos.bolsas.length.toString() ) ),
      DataCell(Text(protocolos.alarmas.length.toString() ) ),
      DataCell(Text(Duration(  milliseconds:protocolos.duracionDelProcedimiento).inMinutes.toString()) ) ,
    
     ],
  );
}
