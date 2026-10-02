import 'package:flutter/material.dart';
import 'package:tomesdashboard/models/alarm.dart';
//Número de serie;Nombre abreviado;Nombre de protocolo;Hora de inicio del procesamiento;OPERADOR;UNIDAD;N.º de proceso;Número de cubeta;NUMERO LOTE;
//Contador de alarmas;Contador de alertas;Volumen de plasma;Volumen de plaquetas;
//Índice de rendimiento de plaquetas;
//Duración del proceso;
//Duración de la carga;
//Duración del procedimiento;
//CATALOGO;REF NLR;REF LR EXT;Volumen de leucocitos (ml)


//Donation ID;Serial Number;Alarms Count;Alerts Count;Bucket Number;
//Configuration Name;Catalogo;Leukocyte Volume (ml);Plasma Volume;Platelet Volume;Platelet Yield Index;
//Processing Start Time;
//Run Duration;ID_Operador;Lote;Counterbalance Bag(s);Barcode Scan Count


final List<String> columnaCodigoDeOperador=["OPERADOR".toLowerCase(),"Codigo de Operador".toLowerCase(),"ID_Operador".toLowerCase()];
final List<String> columnaNombreDeProtocolo=["Nombre de Protocolo".toLowerCase(),"Configuration Name".toLowerCase()];
final List<String> columnaCodigoDeDonacion=["UNIDAD".toLowerCase(),"Codigo de Donacion".toLowerCase(),"Donation ID".toLowerCase()];
final List<String> columnaNombreAbreviado=["Nombre abreviado".toLowerCase(),"Catalogo".toLowerCase()]; //TODO: Cambiar a "Short Name" cuando se pueda
final List<String> columnaNumeroDeSerie=["Número de serie".toLowerCase(),"Serial Number".toLowerCase()];
final List<String> columnaVolumenDeLeucocitos=["Volumen de leucocitos (ml)".toLowerCase(),"Leukocyte Volume (ml)".toLowerCase()];
final List<String> columnaVolumenDePlaquetas=["Volumen de plaquetas".toLowerCase(),"Platelet Volume".toLowerCase()];
final List<String> columnaVolumenDePlasma=["Volumen de plasma".toLowerCase(),"Plasma Volume".toLowerCase()];
final List<String> columnaIndiceDeRendimientoDePlaquetas=["Índice de rendimiento de plaquetas".toLowerCase(),"Platelet Yield Index".toLowerCase()];
final List<String> columnaHoraDeInicioDelProcesamiento=["Hora de inicio del procesamiento".toLowerCase(),"Processing Start Time".toLowerCase()];
final List<String> columnaHoraDeInicioDelProceso=["Hora de inicio del proceso".toLowerCase(),"Process Start Time".toLowerCase()];
final List<String> columnaContadorDeAlarmas=["Contador de alarmas".toLowerCase(),"Alarms Count".toLowerCase()];
final List<String> columnaContadorDeAlertas=["Contador de alertas".toLowerCase(),"Alerts Count".toLowerCase()];
final List<String> columnaDuracionDelProcedimineto=["Duración del procedimiento".toLowerCase(),"Run Duration".toLowerCase()];

//final List<String> columnaDuraciónDelProceso=["Duración del proceso".toLowerCase(),"Alerts Count".toLowerCase()];
//final List<String> columnaDuraciónDeLaCarga=["Duración de la carga".toLowerCase(),"Alerts Count".toLowerCase()];

class Corrida {
  Key key;
  String id;
  String codigoDeOperador;
  String nombreDeProtocolo;
  String codigoDeDonacion;
  String nombreAbreviado;
  String numeroDeSerie;
  List<AlarmAlert> alertas=[];
  List<AlarmAlert> alarmas=[];
  int duracionDelProcedimiento;  
  int volumenDeLeucocitos;
  int volumenDePlaquetas;
  int volumenDePlasma;
  int indiceDeRendimientoDePlaquetas;
  List<Bolsa> bolsas = [];
  int year;
  int month;
  int day; 
  String fecha; 
  Corrida({
    required this.key,
    required this.id,
    required this.codigoDeOperador,
    required this.nombreDeProtocolo,
    required this.codigoDeDonacion,
    required this.nombreAbreviado,
    required this.numeroDeSerie,
    required this.duracionDelProcedimiento,
    required this.volumenDeLeucocitos,
    required this.volumenDePlaquetas,
    required this.volumenDePlasma,
    required this.indiceDeRendimientoDePlaquetas,
    required this.bolsas,
    required this.year,
    required this.month,
    required this.day,
    required this.fecha,
    this.alarmas=const[],
    this.alertas=const[],
    
  });
}
class Bolsa {
  String codigoDeDonacion="";
  String nombreAbreviado=""; 
  String numeroDeSerie="";
  int volumenDeLeucocitos=0;
  int volumenDePlaquetas=0;
  int volumenDePlasma=0;
  int indiceDeRendimientoDePlaquetas=0;
  Bolsa({
     this.codigoDeDonacion="",
    this.nombreAbreviado="",
    this.numeroDeSerie="",
    this.volumenDeLeucocitos=0,
    this.volumenDePlaquetas=0, 
    this.volumenDePlasma=0,
    this.indiceDeRendimientoDePlaquetas=0,
  });
}

class DataSerie{
  final String name;
  final int longitud;
  final List<AlarmAlert> corridas;
  DataSerie({
    required this.name,
    required this.longitud,
    required this. corridas,

  });
}

class CorridasDataSerie{
  final String name;
  final int longitud;
  final List<Corrida> corridas;
  CorridasDataSerie({
    required this.name,
    required this.longitud,
    required this. corridas,

  });
}

String parseTime(String timeString) {
  // Split the time string into its components
  List<String> parts = timeString.split(' ');
  List<String> daysParts = parts[0].split('/');

  int ano=int.parse(daysParts[2]);
  int mes=int.parse(daysParts[1]);  
  int dia=int.parse(daysParts[0]);

  
  List<String> timeParts = parts[1].split(':');
  int hours = int.parse(timeParts[0]);
  int minutes = int.parse(timeParts[1]);
  if(timeParts.length<3){
    timeParts.add("0");
  }
  int seconds = int.parse(timeParts[2]);

  // Create a DateTime object with the parsed values
  DateTime dateTime = DateTime(ano, mes, dia, hours, minutes, seconds);

  // Format the DateTime object to a string in the desired format
  String formattedTime = dateTime.toString();

  return formattedTime;
} 