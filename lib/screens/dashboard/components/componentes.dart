import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/recent_file.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../../constants.dart';

class ComponenteResultCard extends StatelessWidget {
  final List<Corrida> corridas;
  const ComponenteResultCard({
    super.key,
    required this.corridas,
  });

  @override
  Widget build(BuildContext context) {
    int totalPlasmaVolume = 0;
    int totalLeucocyteVolume = 0;
    int totalPlateletVolume = 0;
    int rendimientoDePlaquetas = 0;
    int bolsasProcesadas=0;
    int plasmaMax=0;
    int plasmaMin=10000;
    int leucocyteMax=0;
    int leucocyteMin=10000;
    int plateletMax=0;
    int plateletMin=10000;
    int rendimientoMax=0;
    int rendimientoMin=10000;
    int promedio=0;
    for(var corrida in corridas){
      for(var bolsa in corrida.bolsas){
        totalPlasmaVolume += bolsa.volumenDePlasma;
        totalLeucocyteVolume += bolsa.volumenDeLeucocitos;
        totalPlateletVolume += bolsa.volumenDePlaquetas;
        if(bolsa.indiceDeRendimientoDePlaquetas!=0){
          promedio++;
        }
        rendimientoDePlaquetas += bolsa.indiceDeRendimientoDePlaquetas;
        if(bolsa.volumenDePlasma+bolsa.volumenDeLeucocitos+bolsa.volumenDePlaquetas>0){
          bolsasProcesadas++;
        }
        if(bolsa.volumenDePlasma>plasmaMax){
          plasmaMax=bolsa.volumenDePlasma;
        }
        if(bolsa.volumenDePlasma!=0 && bolsa.volumenDePlasma<plasmaMin){
          plasmaMin=bolsa.volumenDePlasma;
        }
        if(bolsa.volumenDeLeucocitos>leucocyteMax){
          leucocyteMax=bolsa.volumenDeLeucocitos;
        }
        if(bolsa.volumenDeLeucocitos!=0 && bolsa.volumenDeLeucocitos<leucocyteMin){
          leucocyteMin=bolsa.volumenDeLeucocitos;
        }
        if(bolsa.volumenDePlaquetas>plateletMax){
          plateletMax=bolsa.volumenDePlaquetas;
        }
        if(bolsa.volumenDePlaquetas!=0 &&   bolsa.volumenDePlaquetas<plateletMin){
          plateletMin=bolsa.volumenDePlaquetas;
        }
        if(bolsa.indiceDeRendimientoDePlaquetas>rendimientoMax){
          rendimientoMax=bolsa.indiceDeRendimientoDePlaquetas;
        }
        if(bolsa.indiceDeRendimientoDePlaquetas!=0 && bolsa.indiceDeRendimientoDePlaquetas<rendimientoMin){
          rendimientoMin=bolsa.indiceDeRendimientoDePlaquetas;
        }

      }
    }
    int avrPlasma=(totalPlasmaVolume/bolsasProcesadas).floor();
    int avrLeucocyte=(totalLeucocyteVolume/bolsasProcesadas).floor();
    int avrPlatelet=(totalPlateletVolume/bolsasProcesadas).floor();
    int avrRendimiento=(rendimientoDePlaquetas/promedio).floor();
    
    var demoComponenteResultCard = [
      RecentFile(
        icon: "assets/icons/menu_tran.svg",
        title: "Volumen de Plasma",
        max: plasmaMax.toString(),
        min: plasmaMin.toString(),
        avr: avrPlasma.toString(),
      ),
      RecentFile(
        icon: "assets/icons/menu_tran.svg",
        title: "Volumen de Leucocitos",
        max: leucocyteMax.toString(),
        min: leucocyteMin.toString(),
        avr: avrLeucocyte.toString(),
      ),
      RecentFile(
        icon: "assets/icons/menu_tran.svg",
        title: "Volumen de Plaquetas",
        max: plateletMax.toString(),
        min: plateletMin.toString(),
        avr: avrPlatelet.toString(),
      ),
      RecentFile(
        icon: "assets/icons/menu_tran.svg",
        title: "Indice de Rendimiento de Plaquetas",
        max: rendimientoMax.toString(),
        min: rendimientoMin.toString(),
        avr: avrRendimiento.toString(),
      ),
    ];
    
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
            "Volumenes de Componentes",
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(
            width: double.infinity,
            child: DataTable(
              columnSpacing: defaultPadding,
              // minWidth: 600,
              columns: [
                DataColumn(
                  label: Text("Componente"),
                ),
                DataColumn(
                  label: Text("Max"),
                ),
                DataColumn(
                  label: Text("Min"),
                ),
                DataColumn(
                  label: Text("AVR"),
                ),
              ],
              rows: List.generate(
                demoComponenteResultCard.length,
                (index) => recentFileDataRow(demoComponenteResultCard[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

DataRow recentFileDataRow(RecentFile fileInfo) {
  return DataRow(
    cells: [
      DataCell(
        Row(
          children: [
            SvgPicture.asset(
              fileInfo.icon!,
              height: 30,
              width: 30,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: defaultPadding),
              child: Text(fileInfo.title!),
            ),
          ],
        ),
      ),
      DataCell(Text(fileInfo.max!)),
      DataCell(Text(fileInfo.min!)),
      DataCell(Text(fileInfo.avr!)),
    ],
  );
}
