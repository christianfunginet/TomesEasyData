


import 'package:flutter/material.dart';

class AlarmAlert {
  final Key key;
  final String numero;
  final String fecha;
  final String hora;
  final String tipo;
  final String tipoDeAviso;
  
  final String momento;
  final String bucket;
  final String sellado;
  final String indice;
  final String codigo;
  final String descripcion;

  AlarmAlert({
    required this.key,
    required this.numero,
    required this.fecha,
    required this.hora,
    required this.tipo,
    required this.tipoDeAviso,
    required this.momento,
    required this.bucket,
    required this.sellado,
    required this.indice,
    required this.codigo,
    required this.descripcion,
  });


}


List<AlarmAlert> fromString(String rawData){
  List<AlarmAlert> ret=[];
  RegExp regex = RegExp(r'(\d{2}/\d{2}/\d{4})|(\d{2}:\d{2}:\d{2})|(\d+)|([A-Za-zÁ-Úá-úÑñ]+(?:\s[A-Za-zÁ-Úá-úÑñ]+)*)');

  // Extrae las coincidencias y les da el formato con corchetes []
    
    
    // Divide la cadena por espacios en blanco
    List<String> parts = rawData.trim().split(RegExp(r'\s+'));
    
    // Verifica que existan suficientes elementos para mapear los campos fijos
    
    //1 15/07/2026 17:02:15 6 Alarma 16 Posprocesamiento 2 No 31 1429 Sensor de la tapa exterior";
    List<String> arrayResultante = regex
      .allMatches(parts.sublist(1).join(' '))
      .map((match) => '${match.group(0)}')
      .toList();

    for(int i=0 ; i<arrayResultante.length;i=i+11){
     ret.add( AlarmAlert(
      key: Key(DateTime.now().millisecondsSinceEpoch.toString()),
      fecha: arrayResultante[0],
      hora: arrayResultante[1],
      numero: arrayResultante[2],
      tipoDeAviso: arrayResultante[3],
      tipo: arrayResultante[4],
      momento: arrayResultante[5],
      bucket: arrayResultante[6],
      sellado: arrayResultante[7],
      indice: arrayResultante[8],
      codigo: arrayResultante[9],
      descripcion: arrayResultante[10],
    ));}
  return ret;
  }

//1 15/07/2026 17:02:15 6 Alarma 16 Posprocesamiento 2 No 31 1429 Sensor de la tapa exterior