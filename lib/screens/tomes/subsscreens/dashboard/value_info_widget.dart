import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/my_files.dart';
import 'package:tomesdashboard/responsive.dart';
import 'package:flutter/material.dart';

import '../../../../constants.dart';
import 'value_info_card.dart';

class ValueInfoWidget extends StatelessWidget {
  final List<Corrida> corridas;
  final List<Corrida> corridasTotales;
   const ValueInfoWidget({
    super.key,
    required this.corridas,
    required this.corridasTotales,
    
  });

  @override
  Widget build(BuildContext context) {
    List<CorridasDataSerie> protocolos=[];
    Map<String,dynamic> protocolosMap={};

    List<CorridasDataSerie> usuario=[];
    Map<String,dynamic> usuarioMap={};
    int donacionesTotal=0;
    int donacionesParcial=0;

    int leucocitosTotal = 0;
    int plaquetasTotal = 0;
    int plasmaTotal = 0;
    
    int leucocitosParcial=0;
    int plaquetasParcial=0;
    int plasmaParcial=0;
    int corridasProductivasParcial=0;
    
    for(var corrida in corridasTotales){
      donacionesTotal=donacionesTotal+corrida.bolsas.length;
      
      for (var bolsa in corrida.bolsas) {
        leucocitosTotal += bolsa.volumenDeLeucocitos;
        plaquetasTotal += bolsa.volumenDePlaquetas;
        plasmaTotal += bolsa.volumenDePlasma;
      }
    }
    for(var corrida in corridas){
      if(corrida.bolsas.isNotEmpty){
        corridasProductivasParcial++;
      }
      donacionesParcial=donacionesParcial+corrida.bolsas.length;
      for (var bolsa in corrida.bolsas) {
        leucocitosParcial += bolsa.volumenDeLeucocitos;
        plaquetasParcial += bolsa.volumenDePlaquetas;
        plasmaParcial += bolsa.volumenDePlasma;
      }
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
      if(usuarioMap[corrida.codigoDeOperador ]==null){
        usuarioMap[corrida.codigoDeOperador]=corrida.codigoDeOperador;
        usuario.add(
          CorridasDataSerie(
            name: corrida.codigoDeOperador,
            corridas: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList(),
            longitud: corridas.where((test)=> test.codigoDeOperador==corrida.codigoDeOperador).toList().length
          )
        );
      }
    }
    
    if(protocolos.length>1){
      protocolos.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
    if(usuario.length>1){
      usuario.sort((a, b) => b.longitud.compareTo(a.longitud));
    }
    
    List<SingleValueInfo> infoValues=[
      SingleValueInfo(
        title: "Donaciones",
        numOfFiles: donacionesParcial,
        totalStorage: "",
        color: Colors.purple,
        percentage: corridasTotales.isNotEmpty ? ((donacionesParcial) / donacionesTotal * 100).toInt() : 0,
        icon: Icons.bloodtype,
        unit: "Donaciones",
      ),
      SingleValueInfo(
        title: "Runs Totales",
        numOfFiles: corridas.length,
        totalStorage: "${corridas.isNotEmpty ? ((corridas.length) / corridasTotales.length *100).toInt() : 0}%",
        color: Colors.orange,
        percentage: corridas.isNotEmpty  ? ((corridas.length ) / corridasTotales.length * 100).toInt() : 0,
        icon: Icons.settings_backup_restore,
        unit: "Runs",
      ),
      SingleValueInfo(
      title: "Operadores",
      numOfFiles: usuario.length,
      totalStorage: "",
      color: Colors.blue,
      percentage: 70,
      icon: Icons.person,
      unit: "Operadores",
      popMenu: PopupMenuItem(
                child: Text("Ver Operadores"),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: Text("Operadores"),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: usuario.length,
                            itemBuilder: (context, index) {
                              return ListTile(
                                title: Text(usuario[index].name),
                              );
                            },
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                            },
                            child: Text("Cerrar"),
                          ),
                        ],
                      );
                    },
                  );
                }),
      ),
      SingleValueInfo(
        title: "Protocolos",
        numOfFiles: protocolos.length,
        totalStorage: "",
        color: Colors.green,
        percentage: 70,
        icon: Icons.article_outlined,
        unit: "Protocolos",
        popMenu:  PopupMenuItem(
                child: Text("Ver Protocolos"),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: Text("Protocolos"),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: protocolos.length,
                            itemBuilder: (context, index) {
                              return ListTile(
                                title: Text(protocolos[index].name),
                              );
                            },
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                            },
                            child: Text("Cerrar"),
                          ),
                        ],
                      );
                    },
                  );
                }), 
                
            
          
        
      ),
      

      SingleValueInfo(
        title: "Volumen de Plaquetas",
        numOfFiles: plaquetasParcial,
        totalStorage: "${plaquetasParcial > 0 ? ((plaquetasParcial ) / plaquetasTotal *100 ).toStringAsFixed(2) : 0}%",
        color: colorDePlaquetas,
        percentage: plaquetasParcial > 0 ? ((plaquetasParcial ) / plaquetasTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
        title: "Volumen de plasma",
        numOfFiles: plasmaParcial,
        totalStorage: "${plasmaParcial > 0 ? ((plasmaParcial) / plasmaTotal *100).toStringAsFixed(2) : 0}%",
        color: colorDePlasma,
        percentage: plasmaParcial > 0 ? ((plasmaParcial ) / plasmaTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
        title: "Volumen de Leucocitos",
        numOfFiles: leucocitosParcial,
        totalStorage: "${leucocitosParcial > 0 ? ((leucocitosParcial) / leucocitosTotal *100).toStringAsFixed(2) : 0}%",
        color: colorDeLeuco,
        percentage: leucocitosParcial > 0 ? ((leucocitosParcial ) / leucocitosTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
      title: "Tasa de Productividad",
      numOfFiles: corridasProductivasParcial,
      totalStorage: "${(corridasProductivasParcial / corridas.length * 100).toStringAsFixed(1)}%",
      color: Colors.green,
      percentage: corridas.isNotEmpty ? (corridasProductivasParcial / corridas.length * 100).toInt() : 0,
      icon: Icons.bar_chart,
      unit: "Runs",
    ),
    ];
    
    final Size size = MediaQuery.of(context).size;
    return Column(
      children: [
        Responsive(
          mobile: ValueInfoCardGridView(infoValues: infoValues,
            crossAxisCount: size.width < 650 ? 2 : 4,
            childAspectRatio: size.width < 650 && size.width > 350 ? 1.3 : 1,
          ),
          tablet: ValueInfoCardGridView(infoValues: infoValues),
          desktop: ValueInfoCardGridView(
            infoValues: infoValues,
            childAspectRatio: size.width < 1400 ? 1.1 : 1.4,
          ),
        ),
      ],
    );
  }
}

class ValueInfoCardGridView extends StatelessWidget {
  final List<SingleValueInfo> infoValues;

  const ValueInfoCardGridView({
    super.key,
    this.crossAxisCount = 4,
    this.childAspectRatio = 1,
    required this.infoValues,
  });

  final int crossAxisCount;
  final double childAspectRatio;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: infoValues.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: defaultPadding,
        mainAxisSpacing: defaultPadding,
        childAspectRatio: childAspectRatio,
      ),
      itemBuilder: (context, index) => ValueInfoCard(info: infoValues[index]),
    );
  }
}
