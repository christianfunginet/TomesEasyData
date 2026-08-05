import 'dart:convert';
import 'package:percent_indicator/circular_percent_indicator.dart';

import 'package:csv/csv.dart';
import 'package:csv/csv_settings_autodetection.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/constants.dart';
import 'package:file_picker/file_picker.dart';
//import 'package:material_charts/material_charts.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/my_files.dart';
import 'package:tomesdashboard/responsive.dart';
import 'package:tomesdashboard/screens/dashboard/components/chart_mensual.dart';
import 'package:tomesdashboard/screens/dashboard/components/value_info_widget.dart';
import 'package:tomesdashboard/screens/dashboard/components/componentes.dart';
import 'package:tomesdashboard/screens/dashboard/components/storage_details.dart';

class DashBoardPage extends StatefulWidget {
  final PlatformFile file;
  const DashBoardPage({super.key, required this.title, required this.file});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<DashBoardPage> createState() => _DashBoardPageState();
}

class _DashBoardPageState extends State<DashBoardPage> {



  int indexCodigoDeOperadorIndex = 0;
  int indexNombreDeProtocoloIndex = 0;
  int indexCodigoDeDonacionIndex = 0;
  int indexNombreAbreviadoIndex = 0;
  int indexNumeroDeSerieIndex = 0;
  int indexVolumenDeLeucocitosIndex = 0;
  int indexVolumenDePlaquetasIndex = 0;
  int indexVolumenDePlasmaIndex = 0;
  int indexIndiceDeRendimientoDePlaquetasIndex = 0;
  int indexHoraDeInicioDelProcesamientoIndex = 0;
  int indexHoraDeInicioDelProcesoIndex = 0;

  List<String> protocolos = [];
  List<String> operadores = [];
  List<String> donaciones = [];
  List<String> nombresAbreviados = [];
  List<String> numerosDeSerie = [];
  List<int> volumenesDeLeucocitos = [];
  List<int> volumenesDePlaquetas = [];
  List<int> volumenesDePlasma = [];
  List<int> indicesDeRendimientoDePlaquetas = [];
  List<DateTime> horasDeInicioDelProcesamiento = [];
  List<DateTime> horasDeInicioDelProceso = [];
  int leucocitosTotal = 0;
  int plaquetasTotal = 0;
  int plasmaTotal = 0;

  List<Corrida> corridas = [];
  List<Corrida> corridasToTrace = [];
  String selectedEquipo="Todos";

  // Define the initial viewport
  double minX = 0;
  double maxX = 20; // Show 20 data points initially
  final double viewportWidth = 20;
  List<String> searchAlarms = [];
  List<String> types = [];
  List<String> filtredSearchAlarms = [];
  List<List<dynamic>> values = [];
  List<String> timeLineSeries = [];
  bool isLoading = true;
  List<CartesianSeries> cartesianSeries = [];
  List<String> episodios = [];
  List<CartesianChartAnnotation> verticalRangeAnnotations = [];
  List<CartesianChartAnnotation> otherAnotation = [];
  int procedimientosTotal=0;
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  late ZoomPanBehavior zoom;
  List<String> machineData = [];
  bool isEpisodic = false;
  List<int> punteros = [];
  @override
  void initState() {
    super.initState();

    zoom = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableSelectionZooming: true,
      //enableMouseWheelZooming: true,
      enableDirectionalZooming: true,
      enableDoubleTapZooming: true,
      zoomMode: ZoomMode.xy,
      //maximumZoomLevel: 1.0
    );

    final fileBytes = widget.file.bytes;

    final i = fileBytes as List<int>;

    final input = Stream.value(i);
    // file.openRead();
    var d = FirstOccurrenceSettingsDetector(eols: ['\r\n', '\n'], textDelimiters: ['"', "'"], fieldDelimiters: [',', ';', '\t']);
    input.transform(utf8.decoder).transform(CsvToListConverter(csvSettingsDetector: d, shouldParseNumbers: true)).toList().then((fields) {

      {
      var matches=fields[0].where((item)=>columnaCodigoDeOperador.contains(item.toLowerCase().toString())).toList();
      indexCodigoDeOperadorIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaNombreDeProtocolo.contains(item.toLowerCase().toString())).toList();
      indexNombreDeProtocoloIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaCodigoDeDonacion.contains(item.toLowerCase().toString())).toList();
      indexCodigoDeDonacionIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaNombreAbreviado.contains(item.toLowerCase().toString())).toList();
      indexNombreAbreviadoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaNumeroDeSerie.contains(item.toLowerCase().toString())).toList();
      indexNumeroDeSerieIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaVolumenDeLeucocitos.contains(item.toLowerCase().toString())).toList();
      indexVolumenDeLeucocitosIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaVolumenDePlaquetas.contains(item.toLowerCase().toString())).toList();
      indexVolumenDePlaquetasIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaVolumenDePlasma.contains(item.toLowerCase().toString())).toList();
      indexVolumenDePlasmaIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaIndiceDeRendimientoDePlaquetas.contains(item.toLowerCase().toString())).toList();
      indexIndiceDeRendimientoDePlaquetasIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      
      matches=fields[0].where((item)=>columnaHoraDeInicioDelProcesamiento.contains(item.toLowerCase().toString())).toList();
      indexHoraDeInicioDelProcesamientoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      //TODO: Cambiar a columnaHoraDeInicioDelProceso cuando se pueda
     // matches=fields[0].where((item)=>columnaHoraDeInicioDelProceso.contains(item.toString())).toList();
      
    //  indexHoraDeInicioDelProcesoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }

      String idInicial= fields[1][indexHoraDeInicioDelProcesamientoIndex].toString().trim().replaceAll("/","").replaceAll(":", "").replaceAll(" ", "").toString()
      +fields[1][indexNombreAbreviadoIndex].toString();//_${DateTime.parse(parseTime(fields[1][indexHoraDeInicioDelProcesoIndex].toString())).millisecondsSinceEpoch}";
//      fields.removeAt(0);
      List<Bolsa> bolsas = List.generate(10,(_)=>Bolsa());
      int bolsaIndex=-1;      
      Corrida localCorrida=Corrida(
          year: 0,
            month: 0,
            day: 0,
            fecha: "",
            key: Key(idInicial.toString()), id: idInicial.toString(), codigoDeOperador: "", nombreDeProtocolo: "", codigoDeDonacion: "", nombreAbreviado: "", 
      numeroDeSerie: "", volumenDeLeucocitos: 0, volumenDePlaquetas: 0, volumenDePlasma: 0, indiceDeRendimientoDePlaquetas: 0, bolsas: []);
      int ptr=0;
      for (int fieldIndex = 1; fieldIndex < fields.length; fieldIndex++) {
        var element = fields[fieldIndex];
        String actualId= element[indexHoraDeInicioDelProcesamientoIndex].toString().trim().replaceAll("/","").replaceAll(":", "").replaceAll(" ", "")
        +element[indexNombreAbreviadoIndex].toString();
          if(actualId!=idInicial){
            if(bolsaIndex>3){
              for (var i = fieldIndex-(bolsaIndex+1); i < fieldIndex; i++) {
                print ("$fieldIndex  ${fields[i]}");
              }
            }
            corridas.add(localCorrida);
            localCorrida=Corrida(key: 
            
            Key(idInicial.toString()), 
            fecha: "",
            year: 0,
            month: 0,

            day: 0,
            id: idInicial.toString(), codigoDeOperador: "", nombreDeProtocolo: "", codigoDeDonacion: "", nombreAbreviado: "", 
            numeroDeSerie: "", volumenDeLeucocitos: 0, volumenDePlaquetas: 0, volumenDePlasma: 0, 
            indiceDeRendimientoDePlaquetas: 0, bolsas: List.generate(10,(_)=>Bolsa()));
            ptr++;

            bolsaIndex=0;
            idInicial=actualId;
          }else{
            bolsaIndex++;
          }
     //   if(element.length==len){
          if (!protocolos.contains(element[indexNombreDeProtocoloIndex].toString()) && element[indexNombreDeProtocoloIndex].toString().isNotEmpty) {
            protocolos.add(element[indexNombreDeProtocoloIndex].toString());
          }
          if (!operadores.contains(element[indexCodigoDeOperadorIndex].toString()) && element[indexCodigoDeOperadorIndex].toString().isNotEmpty) {
            operadores.add(element[indexCodigoDeOperadorIndex].toString());
          }
          if (!donaciones.contains(element[indexCodigoDeDonacionIndex].toString()) && element[indexCodigoDeDonacionIndex].toString().isNotEmpty) {
            donaciones.add(element[indexCodigoDeDonacionIndex].toString());
          }
          if (!nombresAbreviados.contains(element[indexNombreAbreviadoIndex].toString()) && element[indexNombreAbreviadoIndex].toString().isNotEmpty) {
            nombresAbreviados.add(element[indexNombreAbreviadoIndex].toString());
          }
          if (!numerosDeSerie.contains(element[indexNumeroDeSerieIndex].toString()) && element[indexNumeroDeSerieIndex].toString().isNotEmpty) {
            numerosDeSerie.add(element[indexNumeroDeSerieIndex].toString());
          }
          bolsas[bolsaIndex].volumenDeLeucocitos=int.tryParse(element[indexVolumenDeLeucocitosIndex].toString()) ?? 0;
          bolsas[bolsaIndex].volumenDePlaquetas=int.tryParse(element[indexVolumenDePlaquetasIndex].toString()) ?? 0;
          bolsas[bolsaIndex].volumenDePlasma=int.tryParse(element[indexVolumenDePlasmaIndex].toString()) ?? 0;
          bolsas[bolsaIndex].indiceDeRendimientoDePlaquetas=int.tryParse(element[indexIndiceDeRendimientoDePlaquetasIndex].toString()) ?? 0;
          bolsas[bolsaIndex].codigoDeDonacion=element[indexCodigoDeDonacionIndex].toString();
          bolsas[bolsaIndex].nombreAbreviado=element[indexNombreAbreviadoIndex].toString();
          bolsas[bolsaIndex].numeroDeSerie=element[indexNumeroDeSerieIndex].toString();


          volumenesDeLeucocitos.add(int.tryParse(element[indexVolumenDeLeucocitosIndex].toString()) ?? 0);
          volumenesDePlaquetas.add(int.tryParse(element[indexVolumenDePlaquetasIndex].toString()) ?? 0);
          volumenesDePlasma.add(int.tryParse(element[indexVolumenDePlasmaIndex].toString()) ?? 0);
          indicesDeRendimientoDePlaquetas.add(int.tryParse(element[indexIndiceDeRendimientoDePlaquetasIndex].toString()) ?? 0);
          var fecha=DateTime.parse( parseTime( element[indexHoraDeInicioDelProcesamientoIndex].toString()));
          localCorrida= Corrida(
                key: Key(idInicial.toString()),
                id: idInicial.toString(),
                year: fecha.year,
                month: fecha.month,
                day: fecha.day,
                fecha: fecha.toString(),
                codigoDeOperador: element[indexCodigoDeOperadorIndex].toString(),
                nombreDeProtocolo: element[indexNombreDeProtocoloIndex].toString(),
                codigoDeDonacion: element[indexCodigoDeDonacionIndex].toString(),
                nombreAbreviado: element[indexNombreAbreviadoIndex].toString(),
                numeroDeSerie: element[indexNumeroDeSerieIndex].toString(),
                volumenDeLeucocitos: element[indexVolumenDeLeucocitosIndex].toInt(),
                volumenDePlaquetas: element[indexVolumenDePlaquetasIndex].toInt(),
                volumenDePlasma: element[indexVolumenDePlasmaIndex].toInt(),
                indiceDeRendimientoDePlaquetas: element[indexIndiceDeRendimientoDePlaquetasIndex].toInt(),
                bolsas: bolsas,
              );
            
           
       
        
        
        
       // }
        
       
      }
      procedimientosTotal=ptr;
      setState(() {
        isLoading = false;
      });
    });
  }


  @override
  Widget build(BuildContext context) {
    procedimientosTotal=corridas.length;
    int corridasProductivas=corridas.where((element) => element.codigoDeDonacion.isNotEmpty).length;
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    leucocitosTotal=0;
    plaquetasTotal=0;
    plasmaTotal=0;
    for (var corrida in corridas) {
      for (var bolsa in corrida.bolsas) {
        leucocitosTotal += bolsa.volumenDeLeucocitos;
        plaquetasTotal += bolsa.volumenDePlaquetas;
        plasmaTotal += bolsa.volumenDePlasma;
      }
    }  
    
    if (selectedEquipo != "Todos") {
      corridasToTrace = corridas.where((element) => element.numeroDeSerie == selectedEquipo).toList();
    } else {
      corridasToTrace = corridas;
    }
    int leucocitosParcial=0;
    int plaquetasParcial=0;
    int plasmaParcial=0;
    int procedimientosParcial=corridasToTrace.length;
    for (var corrida in corridasToTrace) {
      for (var bolsa in corrida.bolsas) {
        leucocitosParcial += bolsa.volumenDeLeucocitos;
        plaquetasParcial += bolsa.volumenDePlaquetas;
        plasmaParcial += bolsa.volumenDePlasma;
      }
    }  
      

    if (isLoading) {
      return const Center(child: SizedBox(width: 200, height: 200, child: CircularProgressIndicator()));
    }
    
    List<SingleValueInfo> infoCards=[
      SingleValueInfo(
      title: "Operadores",
      numOfFiles: operadores.length,
      totalStorage: "",
      color: Colors.blue,
      percentage: 70,
      icon: Icons.person,
      unit: "Operadores",
      drawer: PopupMenuItem(
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
                            itemCount: operadores.length,
                            itemBuilder: (context, index) {
                              return ListTile(
                                title: Text(operadores[index]),
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
        drawer:  PopupMenuItem(
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
                                title: Text(protocolos[index]),
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
        title: "Donaciones",
        numOfFiles: donaciones.length,
        totalStorage: "",
        color: Colors.purple,
        percentage: donaciones.length>0 ? ((donaciones.length/4) / procedimientosTotal * 100).toInt() : 0,
        icon: Icons.bloodtype,
        unit: "Donaciones",
      ),
      SingleValueInfo(
        title: "Runs Totales",
        numOfFiles: procedimientosParcial,
        totalStorage: "${procedimientosParcial > 0 ? ((procedimientosParcial) / procedimientosTotal *100).toInt() : 0}%",
        color: Colors.orange,
        percentage: procedimientosParcial > 0 ? ((procedimientosParcial ) / procedimientosTotal * 100).toInt() : 0,
        icon: Icons.settings_backup_restore,
        unit: "Runs",
      ),
      

      SingleValueInfo(
        title: "Volumen de Plaquetas",
        numOfFiles: plaquetasParcial,
        totalStorage: "${plaquetasParcial > 0 ? ((plaquetasParcial ) / plaquetasTotal *100 ).toStringAsFixed(2) : 0}%",
        color: Colors.white60,
        percentage: plaquetasParcial > 0 ? ((plaquetasParcial ) / plaquetasTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
        title: "Volumen de plasma",
        numOfFiles: plasmaParcial,
        totalStorage: "${plasmaParcial > 0 ? ((plasmaParcial) / plasmaTotal *100).toStringAsFixed(2) : 0}%",
        color: const Color.fromARGB(255, 146, 175, 41),
        percentage: plasmaParcial > 0 ? ((plasmaParcial ) / plasmaTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
        title: "Volumen de Leucocitos",
        numOfFiles: leucocitosParcial,
        totalStorage: "${leucocitosParcial > 0 ? ((leucocitosParcial) / leucocitosTotal *100).toStringAsFixed(2) : 0}%",
        color: Colors.red,
        percentage: leucocitosParcial > 0 ? ((leucocitosParcial ) / leucocitosTotal * 100).toInt() : 0,
        icon: Icons.bubble_chart,
        unit: "ml",
      ),   
      SingleValueInfo(
      title: "Tasa de Productividad",
      numOfFiles: procedimientosTotal > 0 ? (corridasProductivas / procedimientosTotal * 100).toInt() : 0,
      totalStorage: "Runs",
      color: Colors.green,
      percentage: procedimientosTotal > 0 ? (corridasProductivas / procedimientosTotal * 100).toInt() : 0,
      icon: Icons.bar_chart,
      unit: "%",
    ),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.all(defaultPadding),
        child: Column(
          children: [
            //Header(),
            SizedBox(height: defaultPadding),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      ValueInfoWidget(actualSelection: selectedEquipo, infoValues: infoCards,equipos: ["Todos", ...numerosDeSerie], onEquipoChanged: (String equipo) {
                        setState(() {
                          selectedEquipo = equipo;
                        });
                      }),
                      SizedBox(height: defaultPadding),
                      MonthlyResultCard(corridas: corridasToTrace),
                      SizedBox(height: defaultPadding),
                      ComponenteResultCard(corridas: corridasToTrace),
                      if (Responsive.isMobile(context))
                        SizedBox(height: defaultPadding),
                      if (Responsive.isMobile(context)) StorageDetails(corridas: corridasToTrace),
                    ],
                  ),
                ),
                if (!Responsive.isMobile(context))
                  SizedBox(width: defaultPadding),
                // On Mobile means if the screen is less than 850 we don't want to show it
                if (!Responsive.isMobile(context))
                  Expanded(
                    flex: 2,
                    child: StorageDetails(corridas: corridasToTrace),
                  ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class Variable {
  String name;
  int max;
  int min;
  String reference;
  bool selected = false;
  bool isAnotation = false;

  Variable(this.name, this.max, this.min, this.reference, this.selected, this.isAnotation);
}

class VariableItem extends StatelessWidget {
  final Variable actor;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final bool disabled;
  final Color? color;
  const VariableItem({super.key, required this.actor, this.onTap, this.disabled = false, this.color, this.onClear});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2.0),
      child: Container(
        alignment: Alignment.centerLeft,
        height: 36,
        width: 280,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: BoxBorder.all(color: color ?? Colors.transparent),
        ),

        //decoration: BoxDecoration(color: disabled ? const Color.fromARGB(255, 116, 108, 108) : Colors.grey[200], borderRadius: BorderRadius.circular(10)),
        child: GestureDetector(
          onTap: () {
            if (!disabled) {
              if (actor.isAnotation) {
                if (!actor.selected) {
                  onTap?.call();
                } else {
                  showAdaptiveDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: SizedBox(
                          width: 280,
                          child: Text("These types of variables cannot be deleted individually because they are annotations. You can delete all the ones you have already selected by pressing 'CLEAR'.",
                            style: TextStyle(fontSize: 14),
                            maxLines: 4,
                          )
                          ),
                        actions: [
                          OutlinedButton(
                            onPressed: () {
                              if (onClear != null) {
                                onClear!.call();
                                Navigator.of(context).pop();
                              }
                            },
                            child: Text("CLEAR"),
                          ),
                          OutlinedButton(
                            onPressed: () {
                                Navigator.of(context).pop();
                            },
                            child: Text("CANCEL"),
                          ),
                        ],
                      );
                    },
                  );
                }
              } else {
                onTap?.call();
              }
            }
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(width: 6),
              Icon(Icons.circle, color: color ?? Colors.transparent, size: 12),
              SizedBox(width: 6),
              Tooltip(
                preferBelow: false,
                margin: EdgeInsets.only(right: 290),
                verticalOffset: -30,

                message: actor.name,
                child: Text(actor.name, style: const TextStyle(fontSize: 12, overflow: TextOverflow.ellipsis)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VisitorGrowthProgressBar extends StatelessWidget {
  const VisitorGrowthProgressBar({
    super.key,
    required this.title,
    required this.subTitle,
    required this.progress,
    required this.color,
  });

  final String title;
  final String subTitle;
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      spacing: 2,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(title), Text( subTitle)],
        ),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.grey[400],
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
      ],
    );
  }
}


enum StatStatus { ascending, descending }

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.iconPath,
    required this.title,
    required this.amount,
    required this.status,
    required this.percentageChange,
    required this.iconData,
  });

  final String iconPath;
  final String title;
  final String amount;
  final StatStatus status;
  final String percentageChange;
  final IconData iconData;

  @override
  Widget build(BuildContext context) {
    return BorderedContainer(
      width: 213,
      height: 113,
      padding: EdgeInsets.all(12),
      margin: EdgeInsets.only(left: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        spacing: 8,
        children: [
          Row(
            spacing: 8,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Icon(iconData ,
                size: 35,
              ),
              Text(title),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                amount,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),               
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                spacing: 8,
                children: [
                  Icon( 
                    status == StatStatus.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    size: 22,
                  ),
                  Text(
                    percentageChange,
                    style: TextStyle(
                      color:
                          status == StatStatus.ascending
                              ? Color(0xff19C964)
                              : Colors.red,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class BorderedContainer extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
  final double? borderRadius;

  const BorderedContainer({
    super.key,
    required this.child,
    this.borderColor,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.alignment,
    this.constraints,
    this.borderRadius,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: key,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      alignment: alignment,
      constraints: constraints,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: borderColor ?? Colors.grey.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(borderRadius ?? 12),
      ),
      child: child,
    );
  }
}

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