import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:csv/csv.dart';
import 'package:csv/csv_settings_autodetection.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/constants.dart';
import 'package:file_picker/file_picker.dart';
//import 'package:material_charts/material_charts.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:tomesdashboard/indices.dart';
import 'package:tomesdashboard/models/alarm.dart';
import 'package:tomesdashboard/responsive.dart';
import 'package:tomesdashboard/screens/tomes/components/bordered_container.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alarmas/alarm_chart_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alarmas/alarm_pie_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alerts/alert_chart_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/alerts/alert_pie_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/customchart/custom_chart.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/dashboard/chart_mensual.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/dashboard/runs_bags.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/header/header.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/componentes/tendency_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/dashboard/value_info_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/componentes/componentes.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/protocols/protocols_distibution.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/protocols/protocols_vs_comp_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/usuarios/users_vs_comp_widget.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/usuarios/users_distibution.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/usuarios/users_table.dart';

class DashBoardPage extends StatefulWidget {
  final int option;
  final PlatformFile file;
  const DashBoardPage({super.key, required this.title, required this.file,required this.option});

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
  int indexNombreAbreviadoIndex = -1;
  int indexNumeroDeSerieIndex = -1;
  int indexVolumenDeLeucocitosIndex = 0;
  int indexVolumenDePlaquetasIndex = 0;
  int indexVolumenDePlasmaIndex = 0;
  int indexIndiceDeRendimientoDePlaquetasIndex = 0;
  int indexHoraDeInicioDelProcesamientoIndex = 0;
  int indexHoraDeInicioDelProcesoIndex = 0;
  int indexContadoDeAlarmas = 0;
  int indexContadoDeAlertas = 0;
  int indexDuracionDelProcedimineto = 0;

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
  bool isError = false;
  String errorMsg="";
  String alertMsg="";
  List<CartesianSeries> cartesianSeries = [];
  List<String> episodios = [];
  List<CartesianChartAnnotation> verticalRangeAnnotations = [];
  List<CartesianChartAnnotation> otherAnotation = [];
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
    
  
   input.transform(utf8.decoder).transform(CsvToListConverter(csvSettingsDetector: d, shouldParseNumbers: true)).toList()
    .onError<FormatException>((error, stackTrace) {
    // Specifically catch CSV formatting and parsing errors
      if (kDebugMode) {
        print('Format error during CSV conversion: $error');
      }
         setState(() {
      isError=true;
      errorMsg="$error\n\r$stackTrace";
    });
    return []; // Return a fallback empty list
    }).onError((error, stackTrace) {
      // Catch all other types of errors (e.g., File I/O or Network errors)
      if (kDebugMode) {
        print('General error: $error');
      }
      setState(() {
      isError=true;
      errorMsg="$error\n\r$stackTrace";
    });

      return [];
    })
    .then((fields)async  {

   try{
    errorMsg="";
    alertMsg="";
      var matches=fields[0].where((item)=>columnaCodigoDeOperador.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna CodigoDeOperador ";
      }else{
        indexCodigoDeOperadorIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaNombreDeProtocolo.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna NombreDeProtocolo ";
      }else{
        indexNombreDeProtocoloIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaCodigoDeDonacion.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna CodigoDeDonacion ";
      }else{
        indexCodigoDeDonacionIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      } 
      matches=fields[0].where((item)=>columnaNombreAbreviado.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        alertMsg="${errorMsg}Falta la columna NombreAbreviado ";
      }else{
        indexNombreAbreviadoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaNumeroDeSerie.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        alertMsg="${errorMsg}Falta la columna NumeroDeSerie ";
      }else{
        indexNumeroDeSerieIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaVolumenDeLeucocitos.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna VolumenDeLeucocitos ";
      }else{
        indexVolumenDeLeucocitosIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaVolumenDePlaquetas.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna VolumenDePlaqueta ";
      }else{
        indexVolumenDePlaquetasIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaVolumenDePlasma.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna VolumenDePlasma ";
      }else{
        indexVolumenDePlasmaIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaIndiceDeRendimientoDePlaquetas.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna IndiceDeRendimientoDePlaquetas ";
      }else{
        indexIndiceDeRendimientoDePlaquetasIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaHoraDeInicioDelProcesamiento.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna HoraDeInicioDelProcesamiento ";
      }else{
        indexHoraDeInicioDelProcesamientoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaContadorDeAlarmas.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna ContadorDeAlarmas ";
      }else{
        indexContadoDeAlarmas=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaContadorDeAlertas.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna ContadorDeAlertas ";
      }else{
        indexContadoDeAlertas=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      matches=fields[0].where((item)=>columnaDuracionDelProcedimineto.contains(item.toLowerCase().toString())).toList();
      if(matches.isEmpty){
        errorMsg="${errorMsg}Falta la columna DuracionDelProcedimineto ";
      }else{
        indexDuracionDelProcedimineto=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
      }
      //TODO: Cambiar a columnaHoraDeInicioDelProceso cuando se pueda
     // matches=fields[0].where((item)=>columnaHoraDeInicioDelProceso.contains(item.toString())).toList();
      
    //  indexHoraDeInicioDelProcesoIndex=fields[0].indexWhere((element) => element.toString().toLowerCase() == matches[0].toString().toLowerCase());
  
      if(errorMsg.isNotEmpty){
        setState(() {
          isError=true;
        });
        return;
      }
      if(alertMsg.isNotEmpty){
        showDialog(context: (context), builder: (context)=>
        AlertDialog.adaptive(
          title: Text("Atencion!!"),
          content: Text("Faltan las columnas $alertMsg",maxLines: 6,),
          )
        );
      }
      String s= indexNombreAbreviadoIndex !=-1 ? fields[1][indexNombreAbreviadoIndex].toString():"";
      String idInicial= fields[1][indexHoraDeInicioDelProcesamientoIndex].toString().trim().replaceAll("/","").replaceAll(":", "").replaceAll(" ", "").toString()+s;

      List<Bolsa> bolsas = [];
      int bolsaIndex=-1;      
      Corrida localCorrida=Corrida(
          year: 0,
            month: 0,
            day: 0,
            fecha: "",
            duracionDelProcedimiento: 0,
            key: Key(idInicial.toString()), id: idInicial.toString(), codigoDeOperador: "", nombreDeProtocolo: "", codigoDeDonacion: "", nombreAbreviado: "", 
      numeroDeSerie: "", volumenDeLeucocitos: 0, volumenDePlaquetas: 0, volumenDePlasma: 0, indiceDeRendimientoDePlaquetas: 0, bolsas: []);
      List<AlarmAlert> alertas = [];
      List<AlarmAlert> alarmas = [];
      for (int fieldIndex = 1; fieldIndex < fields.length; fieldIndex++) {
        var element = fields[fieldIndex];
        String s= indexNombreAbreviadoIndex !=-1 ? fields[fieldIndex][indexNombreAbreviadoIndex].toString():"";
        String actualId= fields[fieldIndex][indexHoraDeInicioDelProcesamientoIndex].toString().trim().replaceAll("/","").replaceAll(":", "").replaceAll(" ", "").toString()+s;
        if(actualId!=idInicial){
            if(bolsaIndex>3){
              for (var i = fieldIndex-(bolsaIndex+1); i < fieldIndex; i++) {
                if (kDebugMode) {
                  print ("$fieldIndex  ${fields[i]}");
                }
              }
            }
            corridas.add(localCorrida);
            alertas.clear();
            alarmas.clear();
            bolsas.clear();
           
           
            localCorrida=Corrida(key: 
            Key(idInicial.toString()), 
            fecha: "",
            year: 0,
            month: 0,
            duracionDelProcedimiento: 0,
            day: 0,
            id: idInicial.toString(), codigoDeOperador: "", nombreDeProtocolo: "", codigoDeDonacion: "", nombreAbreviado: "", 
            numeroDeSerie: "", volumenDeLeucocitos: 0, volumenDePlaquetas: 0, volumenDePlasma: 0, 
            indiceDeRendimientoDePlaquetas: 0, bolsas: List.generate(10,(_)=>Bolsa()));
            bolsaIndex=0;
            idInicial=actualId;
          }else{
            bolsaIndex++;
          }
     //   if(element.length==len){
          if (!protocolos.contains(element[indexNombreDeProtocoloIndex].toString()) && element[indexNombreDeProtocoloIndex].toString().isNotEmpty) {
            protocolos.add(element[indexNombreDeProtocoloIndex].toString());
          }
          if(element[indexCodigoDeOperadorIndex].toString().isEmpty){
            element[indexCodigoDeOperadorIndex]="No Especificado";
          }
          if (!operadores.contains(element[indexCodigoDeOperadorIndex].toString())) {
              operadores.add(element[indexCodigoDeOperadorIndex].toString());
            
          }
          if (!donaciones.contains(element[indexCodigoDeDonacionIndex].toString()) && element[indexCodigoDeDonacionIndex].toString().isNotEmpty) {
            donaciones.add(element[indexCodigoDeDonacionIndex].toString());
          }
          if(indexNombreAbreviadoIndex!=-1){
            if (!nombresAbreviados.contains(element[indexNombreAbreviadoIndex].toString()) && element[indexNombreAbreviadoIndex].toString().isNotEmpty) {
              nombresAbreviados.add(element[indexNombreAbreviadoIndex].toString());
            }
          }
          if(indexNumeroDeSerieIndex!=-1){
            if (!numerosDeSerie.contains(element[indexNumeroDeSerieIndex].toString()) && element[indexNumeroDeSerieIndex].toString().isNotEmpty) {
              numerosDeSerie.add(element[indexNumeroDeSerieIndex].toString());
            }
          }
          if(element[indexContadoDeAlarmas].toString()!="0"){
           List<AlarmAlert> newAlarm=fromString(element[indexContadoDeAlarmas].toString());
            for (var alarm in newAlarm) {
               alarmas.add(alarm);
            }
          }
          if(element[indexContadoDeAlertas].toString()!="0"){
            List<AlarmAlert> newAlert=fromString(element[indexContadoDeAlertas].toString());
            for (var alert in newAlert) {
               alertas.add(alert);
            }
          }
          if(element[indexCodigoDeDonacionIndex].toString().isNotEmpty){
          Bolsa b=Bolsa(
            volumenDeLeucocitos:int.tryParse(element[indexVolumenDeLeucocitosIndex].toString()) ?? 0,
            volumenDePlaquetas:int.tryParse(element[indexVolumenDePlaquetasIndex].toString()) ?? 0,
            volumenDePlasma:int.tryParse(element[indexVolumenDePlasmaIndex].toString()) ?? 0,
            indiceDeRendimientoDePlaquetas:int.tryParse(element[indexIndiceDeRendimientoDePlaquetasIndex].toString()) ?? 0,
            codigoDeDonacion:element[indexCodigoDeDonacionIndex].toString(),
            nombreAbreviado:indexNombreAbreviadoIndex!=-1? element[indexNombreAbreviadoIndex].toString():"",
            numeroDeSerie:indexNumeroDeSerieIndex!= -1 ? element[indexNumeroDeSerieIndex].toString():"",

          );
          bolsas.add(b);
          }
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
                alarmas: List.generate(alarmas.length,(int index) => alarmas[index]),
                alertas: List.generate(alertas.length,(int index) => alertas[index]),
                codigoDeOperador: element[indexCodigoDeOperadorIndex].toString().isNotEmpty
                  ? element[indexCodigoDeOperadorIndex].toString()
                  : "No especificado",
                nombreDeProtocolo: element[indexNombreDeProtocoloIndex].toString(),
                codigoDeDonacion: element[indexCodigoDeDonacionIndex].toString(),
                nombreAbreviado: indexNombreAbreviadoIndex!=-1? element[indexNombreAbreviadoIndex].toString():"",
                numeroDeSerie: indexNumeroDeSerieIndex!=-1 ?element[indexNumeroDeSerieIndex].toString():"",
                duracionDelProcedimiento: element[indexDuracionDelProcedimineto].toInt(),
                volumenDeLeucocitos: element[indexVolumenDeLeucocitosIndex].toInt(),
                volumenDePlaquetas: element[indexVolumenDePlaquetasIndex].toInt(),
                volumenDePlasma: element[indexVolumenDePlasmaIndex].toInt(),
                indiceDeRendimientoDePlaquetas: element[indexIndiceDeRendimientoDePlaquetasIndex].toInt(),
                bolsas: List.generate(bolsas.length,(int index)=> bolsas[index]),
              );
        }
      }catch(e,s){
          setState(() {
            isError=true;
            errorMsg="$e\n\r$s";
          });

        }
      setState(() {
        isLoading = false;
      });
    });
  
  }

  @override
  void didUpdateWidget(covariant DashBoardPage oldWidget) {
    if(oldWidget.option!=widget.option){
      setState(() {
        
      });
    }
    super.didUpdateWidget(oldWidget);
  }
  
  @override
  Widget build(BuildContext context) {
 
    if (isError) {
      return  Center(child: SizedBox(width: 400, height: 200, child: Text(errorMsg,maxLines: 30,)));
    }
    if (isLoading) {
      return const Center(child: SizedBox(width: 200, height: 200, child: CircularProgressIndicator()));
    }
 
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
   
    
    if (selectedEquipo != "Todos") {
      corridasToTrace = corridas.where((element) => element.numeroDeSerie == selectedEquipo).toList();
    } else {
      corridasToTrace = corridas;
    }
      

    
    return SafeArea(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.all(defaultPadding),
        child: Column(
          children: [
            Header(actualSelection: selectedEquipo,equipos: ["Todos", ...numerosDeSerie], onEquipoChanged: (String equipo) {
              setState(() {
                selectedEquipo = equipo;
              });
            }),
            SizedBox(height: defaultPadding),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(  // CUERPO PRENCIPAL
                    children: [
                      widget.option==0
                        ? ValueInfoWidget(corridas: corridasToTrace,corridasTotales: corridas,)
                        : widget.option==1 
                          ? TendencyWidget(corridas: corridasToTrace)
                          : widget.option==2
                            ? ProtocolsVsCompWidget(corridas: corridasToTrace) 
                            : widget.option==3
                              ? AlertChartWidget(corridas:corridasToTrace)
                              : widget.option==4
                              ? UsersChartwidget (corridas:corridasToTrace)
                              : CustomChartwidget(corridas:corridasToTrace), //1° ROW DEL CUERPO PRINCIPAL
                      SizedBox(height: defaultPadding),
                      widget.option==0
                        ? MonthlyResultCard(corridas: corridasToTrace)
                        : widget.option==1 
                          ? ComponenteResultCard(corridas: corridasToTrace)
                          : widget.option==2 
                            ? ComponenteResultCard(corridas: corridasToTrace)
                            : widget.option==3 
                              ? AlarmChartWidget (corridas: corridasToTrace)
                              :widget.option==4 
                              ? AlarmChartWidget (corridas: corridasToTrace)
                              : SizedBox(),  //2° ROW DEL CUERPO PRINCIPAL
                      if (Responsive.isMobile(context))
                        SizedBox(height: defaultPadding),
                      if (Responsive.isMobile(context)) 
                       lateralWidget(widget.option, corridasToTrace),
                    ],
                  ),
                ),
                if (!Responsive.isMobile(context))
                  SizedBox(width: defaultPadding),
                // On Mobile means if the screen is less than 850 we don't want to show it
                if (!Responsive.isMobile(context))
                  Expanded(
                    flex: 2,
                    child: lateralWidget(widget.option, corridasToTrace)
                 
                  ),                // COLUMNA LATERAL
              ],
            )
          ],
        ),
      ),
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
Widget lateralWidget(int option, List<Corrida> corridasToTrace){
  return option==0 //DASH
      ? RunsBagsWidget(corridas: corridasToTrace)
      : option==1 //Componentes
      ? ProtocolsDistributionWidget(corridas: corridasToTrace)
      : option==2 //Protocolos
      ? ProtocolsDistributionWidget(corridas: corridasToTrace)
      : option==3 //Alarmas
      ? Column(   
        children: [
          AlertPieWidget(corridas:corridasToTrace),
          SizedBox(height: defaultPadding),
          AlarmPieWidget(corridas:corridasToTrace),
        ],
      )
      :  option==4 //Users
      ? UsersDistributionWidget(corridas: corridasToTrace)
      : SizedBox()
    ; 
}