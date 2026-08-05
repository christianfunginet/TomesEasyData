import 'package:flutter/material.dart';

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

class Corrida {
  Key key;
  String id;
  String codigoDeOperador;
  String nombreDeProtocolo;
  String codigoDeDonacion;
  String nombreAbreviado;
  String numeroDeSerie;
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
    required this.volumenDeLeucocitos,
    required this.volumenDePlaquetas,
    required this.volumenDePlasma,
    required this.indiceDeRendimientoDePlaquetas,
    required this.bolsas,
    required this.year,
    required this.month,
    required this.day,
    required this.fecha,
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