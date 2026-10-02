import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'dlog_alarm_catalog.dart';

/// Decoder experimental del formato propietario .dlog.
///
/// Pipeline confirmado:
///
///   DLOG
///     -> cabecera propietaria
///     -> GZIP
///     -> descompresión
///     -> XOR 0xA5
///     -> payload binario
///     -> registros 0x022E
///     -> campos
///     -> CSV
///
/// Esta versión:
///   1. Detecta automáticamente GZIP.
///   2. Descomprime.
///   3. Aplica XOR 0xA5.
///   4. Encuentra TODOS los 0x022E.
///   5. Analiza cada registro independientemente.
///   6. Valida campos mediante IDs conocidos.
///   7. Intenta reconstruir timestamp en relación con el comienzo
///      temporal del DLOG.
///   8. Genera CSV largo y CSV de procedimiento.
///
/// Dependencia:
///
///   archive: ^3.6.1
///
/// Ejemplo:
///
///   final result = DlogDecoder.decodeBytes(bytes, sourcePath: fileName);
///   final outputs = result.buildOutputs();
///   print(result.summary);
class DlogDecoder {
  static const String decoderVersion = 'V81_OPTIA_GEN2_V69_RESTORED';
  static const int xorKey = 0xA5;

  static const int marker022eLo = 0x2E;
  static const int marker022eHi = 0x02;

  // Optia: record marker after GZIP + XOR A5.
  static const List<int> optiaMarker = [0x5A, 0x01, 0x00, 0x02];
  static const List<int> optiaSafetyMarker = [0x5A, 0x01, 0x00, 0x01];

  // Optia eBox Gen2 also uses a second stream family.  The last byte is
  // still the node: 01 = Safety, 02 = Control.
  static const List<int> optiaGen2ControlMarker2 = [0x5A, 0x02, 0x00, 0x02];
  static const List<int> optiaGen2SafetyMarker2 = [0x5A, 0x02, 0x00, 0x01];




  /// Entrada unificada usada por GraphicPage.
  ///
  /// - .dlog: ejecuta el decoder.
  /// - .csv: usa el CSV directamente, sin GZIP/XOR.
  static DlogInputResult decodeInput(
    Uint8List input, {
    required String fileName,
    String? sourcePath,
    DlogOutputOptions options = const DlogOutputOptions(),
  }) {
    final lower = fileName.trim().toLowerCase();

    if (lower.endsWith('.csv')) {
      if (input.isEmpty) {
        return DlogInputResult.failure('El archivo CSV esta vacio.');
      }

      final sourceName = fileName.replaceAll('\\', '/').split('/').last;
      final dot = sourceName.lastIndexOf('.');
      final baseName =
          dot > 0 ? sourceName.substring(0, dot) : sourceName;
      final csvText = utf8.decode(input, allowMalformed: true);

      final outputs = DlogOutputBundle(
        baseName: baseName,
        recordsCsv: null,
        fieldsCsv: null,
        procedureCsv: options.procedureCsv ? csvText : null,
        nativeCsv: options.nativeCsv ? csvText : null,
        alarms: options.alarms ? const <DlogAlarm>[] : null,
        alarmsCsv: options.alarmsCsv ? '' : null,
        summaryText: options.summary
            ? 'CSV ya decodificado: ${input.length} bytes. '
              'No se aplico decoder DLOG.'
            : null,
      );

      return DlogInputResult(
        ok: true,
        isCsv: true,
        outputs: outputs,
        decodeResult: null,
        diagnostics: <String>[
          'Entrada CSV detectada.',
          'Se omite GZIP/XOR/parser DLOG.',
          'CSV original: ${input.length} bytes.',
        ],
      );
    }

    if (!lower.endsWith('.dlog')) {
      return DlogInputResult.failure(
        'Formato no soportado: $fileName. Se esperaba .dlog o .csv.',
      );
    }

    final decoded = decodeBytes(
      input,
      sourcePath: sourcePath ?? fileName,
      options: options,
    );

    if (!decoded.ok) {
      return DlogInputResult(
        ok: false,
        isCsv: false,
        outputs: null,
        decodeResult: decoded,
        diagnostics: decoded.diagnostics,
      );
    }

    return DlogInputResult(
      ok: true,
      isCsv: false,
      outputs: decoded.buildOutputs(options: options),
      decodeResult: decoded,
      diagnostics: decoded.diagnostics,
    );
  }

  /// V51: decodifica el DLOG y genera directamente SOLO las salidas pedidas.
  /// Todas las salidas están desactivadas por defecto.
  static DlogDecodeResult decodeBytes(
    Uint8List input, {
    String? sourcePath,
    DlogOutputOptions options = const DlogOutputOptions(),
  }) {
    final core = _decodeCore(input, sourcePath: sourcePath);
    if (!core.ok) return core;
    return _attachDirectOutputs(core, options);
  }

  /// Fast path para pantallas que solo necesitan alarmas.
  ///
  /// En Optia/Reveos evita decodificar DATA, procedure CSV y demás campos:
  /// descomprime, aplica XOR y recorre únicamente TRACE. En Trima conserva
  /// temporalmente el parser completo hasta tener una regla de alarma nativa
  /// equivalente y segura.
  static List<DlogAlarm> extractAlarmsBytes(
    Uint8List input, {
    String? sourcePath,
  }) {
    if (input.isEmpty) return const <DlogAlarm>[];

    final gzipOffset = _findGzip(input);
    if (gzipOffset < 0) return const <DlogAlarm>[];

    final decompressed = _gunzip(input, gzipOffset);
    if (decompressed == null) return const <DlogAlarm>[];
    final payload = _xor(decompressed, xorKey);

    final sourceName = sourcePath == null
        ? ''
        : sourcePath.replaceAll('\\', '/').split('/').last.toUpperCase();
    final forceTrima = sourceName.startsWith('1T');
    final forceOptia = sourceName.startsWith('1P');
    final forceReveos = sourceName.startsWith('1W');

    // OPTIA: solamente TRACE 03 55. No se decodifican MAIN/SAFETY/DATA.
    final optiaStarts = forceOptia ? const <int>[] : _findOptiaRecordStarts(payload, optiaMarker);
    if (forceOptia || (!forceTrima && !forceReveos && optiaStarts.isNotEmpty)) {
      final base = _optiaStartDateTime(input, sourcePath);
      final traces = _decodeOptiaTraceRecords(payload, 0, base);
      return _raisedAlarmsFromTrace(DlogDecodeResult(
        ok: true,
        sourcePath: sourcePath,
        gzipOffset: gzipOffset,
        decompressedSize: decompressed.length,
        payloadSize: payload.length,
        records: traces,
        diagnostics: const <String>[],
        timestampInfo: _TimestampInfo(
          mode: base == null ? TimestampMode.none : TimestampMode.optiaSecondsNanoseconds,
          dlogStart: base,
          diagnostics: const <String>[],
        ),
        originalHeader: const <String>[],
        machine: DlogMachine.optia,
      ));
    }

    // REVEOS: solamente diccionario EVENT + TRACE. Se omiten todos los DATA.
    if (forceReveos || (!forceTrima && _looksLikeReveos(payload))) {
      final base = _reveosStartDateTime(input);
      final events = _reveosEventDictionary(payload);
      final traces = _readReveosTraces(payload, events, base, 0);
      return _raisedAlarmsFromTrace(DlogDecodeResult(
        ok: true,
        sourcePath: sourcePath,
        gzipOffset: gzipOffset,
        decompressedSize: decompressed.length,
        payloadSize: payload.length,
        records: traces,
        diagnostics: const <String>[],
        timestampInfo: _TimestampInfo(
          mode: base == null ? TimestampMode.none : TimestampMode.reveosSecondsNanoseconds,
          dlogStart: base,
          diagnostics: const <String>[],
        ),
        originalHeader: const <String>[],
        machine: DlogMachine.reveos,
      ));
    }

    // TRIMA: fallback seguro. No cambia el comportamiento actual.
    final result = _decodeCore(input, sourcePath: sourcePath);
    return result.ok ? _alarmsFromFields(result) : const <DlogAlarm>[];
  }

  /// Dashboard fast API.
  ///
  /// Important for Trima: alarm extraction and CriticalOutput extraction used
  /// to call _decodeCore independently, decoding the same DLOG twice. This
  /// method decodes Trima only once and derives both collections from the same
  /// DlogDecodeResult. Optia/Reveos keep their TRACE-only alarm fast path.
  static DlogDashboardExtraction extractDashboardBytes(
    Uint8List input, {
    String? sourcePath,
  }) {
    if (input.isEmpty) return const DlogDashboardExtraction();

    final sourceName = sourcePath == null
        ? ''
        : sourcePath.replaceAll('\\', '/').split('/').last.toUpperCase();

    // Trima needs DATA fields for AlarmEnumCurrent/AlarmCurrent (or legacy
    // Alarm) and TRACE for CriticalOutput. Decode the file once and reuse it.
    if (sourceName.startsWith('1T')) {
      final result = _decodeCore(input, sourcePath: sourcePath);
      if (!result.ok || result.machine != DlogMachine.trima) {
        return const DlogDashboardExtraction();
      }
      return DlogDashboardExtraction(
        alarms: _alarmsFromFields(result),
        criticalFaultEvents: criticalFaultEvents(result),
      );
    }

    // Optia/Reveos already have a much cheaper TRACE-only path and do not
    // expose Trima CriticalOutput events.
    return DlogDashboardExtraction(
      alarms: extractAlarmsBytes(input, sourcePath: sourcePath),
      criticalFaultEvents: const <DlogCriticalEvent>[],
    );
  }

  /// Fast convenience API for the alarm dashboard. Critical events are
  /// currently defined only for Trima, so other machine families return
  /// an empty list without doing extra work.
  static List<DlogCriticalEvent> extractCriticalFaultEventsBytes(
    Uint8List input, {
    String? sourcePath,
  }) {
    final sourceName = sourcePath == null
        ? ''
        : sourcePath.replaceAll('\\', '/').split('/').last.toUpperCase();
    if (!sourceName.startsWith('1T')) return const <DlogCriticalEvent>[];

    final result = _decodeCore(input, sourcePath: sourcePath);
    if (!result.ok || result.machine != DlogMachine.trima) {
      return const <DlogCriticalEvent>[];
    }
    return criticalFaultEvents(result);
  }

  static DlogDecodeResult _attachDirectOutputs(
    DlogDecodeResult result,
    DlogOutputOptions options,
  ) {
    Uint8List? enc(String Function() producer) =>
        Uint8List.fromList(utf8.encode(producer()));

    final procedureBytes = options.procedureCsv
        ? enc(() => procedureCsv(result.records, originalHeader: result.originalHeader))
        : null;

    Uint8List? nativeBytes;
    if (options.nativeCsv) {
      final original = result.originalBytes;
      if (original != null) {
        nativeBytes = enc(() => switch (result.machine) {
          DlogMachine.trima => trimaFullCsv(result, original),
          DlogMachine.optia => optiaFullCsv(result, original),
          DlogMachine.reveos => reveosFullCsv(result, original),
          DlogMachine.unknown => procedureCsv(result.records, originalHeader: result.originalHeader),
        });
      }
    }

    List<DlogAlarm>? found;
    if (options.alarms || options.alarmsCsv) found = alarms(result);

    Uint8List? alarmBytes;
    if (options.alarmsCsv) {
      final b = StringBuffer();
      b.writeln('timestamp,dateMillisecondsSinceEpoch,filePath,machine,alarmId,alarmKey,alarmCode,alarmName,rawAlarmName,catalogKnown,category,statusLine,messageType,dlogText,occursDuring,detection,possibleCauses,suggestedActions,state,active,node,source,recordIndex');
      for (final a in found ?? const <DlogAlarm>[]) {
        b.writeln(<String>[
          a.timestampString,
          a.dateMillisecondsSinceEpoch?.toString() ?? '',
          a.sourcePath,
          a.machine,
          a.alarmId,
          a.alarmKey,
          a.alarmCode,
          a.alarmName,
          a.rawAlarmName,
          a.catalogKnown ? '1' : '0',
          a.category,
          a.statusLine,
          a.messageType,
          a.dlogText,
          a.occursDuring,
          a.detection,
          a.possibleCauses,
          a.suggestedActions,
          a.state,
          a.active ? '1' : '0',
          a.node,
          a.source,
          a.recordIndex.toString(),
        ].map(_csv).join(','));
      }
      alarmBytes = Uint8List.fromList(utf8.encode(b.toString()));
    }

    return result.copyWithOutputs(
      recordsCsvBytes: options.recordsCsv ? enc(() => recordsCsv(result.records)) : null,
      fieldsCsvBytes: options.fieldsCsv ? enc(() => fieldsCsv(result.records)) : null,
      procedureCsvBytes: procedureBytes,
      nativeCsvBytes: nativeBytes,
      alarms: options.alarms ? found : null,
      alarmsCsvBytes: alarmBytes,
      summaryText: options.summary ? summary(result) : null,
    );
  }

  /// Núcleo multiplataforma: decodifica bytes en memoria.
  ///
  /// En Web use FilePicker con `withData: true` y pase `bytes` + `fileName`.
  /// En plataformas nativas puede leer el archivo con dart:io desde una capa
  /// externa y llamar a este mismo método.
  /// Decodifica bytes de un DLOG.
  static DlogDecodeResult _decodeCore(
    Uint8List input, {
    String? sourcePath,
  }) {
    final diagnostics = <String>[];

    if (input.isEmpty) {
      return DlogDecodeResult.failure(
        diagnostics: ['El archivo está vacío.'],
      );
    }

    diagnostics.add(
      'DLOG original: ${input.length} bytes',
    );

    // ------------------------------------------------------------
    // 1. Buscar GZIP
    // ------------------------------------------------------------

    final gzipOffset = _findGzip(input);

    if (gzipOffset < 0) {
      return DlogDecodeResult.failure(
        diagnostics: [
          ...diagnostics,
          'No se encontró cabecera GZIP 1F 8B.',
        ],
      );
    }

    diagnostics.add(
      'GZIP encontrado en offset $gzipOffset.',
    );

    // ------------------------------------------------------------
    // 2. GZIP
    // ------------------------------------------------------------

    final decompressed = _gunzip(
      input,
      gzipOffset,
    );

    if (decompressed == null) {
      return DlogDecodeResult.failure(
        diagnostics: [
          ...diagnostics,
          'No se pudo descomprimir el GZIP.',
        ],
      );
    }

    diagnostics.add(
      'GZIP descomprimido: ${decompressed.length} bytes.',
    );

    // ------------------------------------------------------------
    // 3. XOR 0xA5
    // ------------------------------------------------------------

    final payload = _xor(
      decompressed,
      xorKey,
    );

    diagnostics.add(
      'XOR 0x${xorKey.toRadixString(16).padLeft(2, '0')} aplicado.',
    );

    // ------------------------------------------------------------
    // 4. Detectar familia del equipo
    // ------------------------------------------------------------
    // Regla primaria por nombre de archivo:
    //   1T... -> Trima
    //   1P... -> Optia
    //   1W... -> Reveos
    // Si el nombre no sigue la convención, se conserva la detección
    // binaria anterior como fallback.
    final sourceName = sourcePath == null
        ? ''
        : sourcePath.replaceAll('\\', '/').split('/').last.toUpperCase();
    final forceTrima = sourceName.startsWith('1T');
    final forceOptia = sourceName.startsWith('1P');
    final forceReveos = sourceName.startsWith('1W');

    if (forceTrima) {
      diagnostics.add('Equipo identificado por nombre 1T: Trima.');
    } else if (forceOptia) {
      diagnostics.add('Equipo identificado por nombre 1P: Optia.');
    } else if (forceReveos) {
      diagnostics.add('Equipo identificado por nombre 1W: Reveos.');
    }

    if (forceReveos ||
        (!forceTrima && !forceOptia && _looksLikeReveos(payload))) {
      return _decodeReveosPayload(
        payload: payload, input: input, sourcePath: sourcePath,
        gzipOffset: gzipOffset, decompressedSize: decompressed.length,
        diagnostics: diagnostics,
      );
    }

    final optiaStarts = _findOptiaRecordStarts(payload, optiaMarker);
    if (forceOptia ||
        (!forceTrima && !forceReveos && optiaStarts.isNotEmpty)) {
      return _decodeOptiaPayload(
        payload: payload,
        input: input,
        sourcePath: sourcePath,
        gzipOffset: gzipOffset,
        decompressedSize: decompressed.length,
        starts: optiaStarts,
        diagnostics: diagnostics,
      );
    }

    diagnostics.add('Equipo detectado: Trima (0x022E).');

    // ------------------------------------------------------------
    // 5. Trima DATA nativo: envelope 04 55
    // ------------------------------------------------------------
    // Layout confirmado contra el CSV oficial:
    //   04 55 [seconds:u32 LE] [nanoseconds:u32 LE]
    //   [family:u16] 5A 00 00 02 [fieldCount:u16 LE]
    //   repeated: [size:u16 LE] [fieldId:u16 LE] [value:size]
    //   FE 55
    //
    // Importante: DATA no es solamente la familia 0x022E. En este log
    // también aparecen 0x020E, 0x022F y familias EOR.
    final records = _readTrimaDataEnvelopes(payload);
    diagnostics.add('Trima DATA 04 55 válidos: ${records.length}');
    // Preserve the native 04 55 envelope clock. _applyTimestamps() is a
    // generic 0x022E routine and can reinterpret elapsedMs from DATA fields.
    final trimaEnvelopeElapsed = <int, int?>{
      for (final r in records) r.offset: r.elapsedMs,
    };

    if (records.isEmpty) {
      return DlogDecodeResult.failure(
        diagnostics: [...diagnostics, 'No se encontraron registros DATA Trima 04 55 válidos.'],
      );
    }

    // ------------------------------------------------------------
    // 6. Timestamp
    // ------------------------------------------------------------

    final timestampInfo = _buildTimestampModel(
      records: records,
      sourcePath: sourcePath,
    );

    diagnostics.addAll(
      timestampInfo.diagnostics,
    );

    _applyTimestamps(
      records,
      timestampInfo,
    );

    // Restore the native Trima envelope seconds/nanoseconds after the generic
    // timestamp model. EVENT/TRACE use the same DLOG-header clock base.
    for (final r in records) {
      r.elapsedMs = trimaEnvelopeElapsed[r.offset];
    }

    // ------------------------------------------------------------
    // 7. Clasificación
    // ------------------------------------------------------------

    _classifyRecords(records);
    // Todos los registros construidos arriba son envelopes DATA 04 55 válidos.
    for (final r in records) { r.classification = DlogRecordClass.procedure; }

    // Trima native EVENT/TRACE records live outside 0x022E.
    // Preserve DATA parsing and add the native 01 55 + 02/03 55 rows.
    final trimaEvents = _trimaEventDictionary(payload);
    // EVENT/TRACE seconds+nanoseconds are relative to the actual DLOG start
    // stored in the proprietary header. DATA AbsTime remains based on the
    // calendar date/midnight model and must not use this clock base.
    final trimaTraceBase = _trimaStartFromHeader(input) ?? timestampInfo.dlogStart;
    if (trimaTraceBase != null) {
      diagnostics.add('Trima EVENT/TRACE start: ${trimaTraceBase.toIso8601String()}');
    }
    if (trimaTraceBase != null) {
      for (final r in records) {
        if (r.elapsedMs != null) {
          r.timestamp = trimaTraceBase.add(Duration(milliseconds: r.elapsedMs!));
        }
      }
    }
    final trimaExtra = <Dlog022eRecord>[
      ..._readTrimaEvents(payload, trimaEvents, trimaTraceBase, records.length),
      ..._readTrimaTraces(payload, trimaEvents, trimaTraceBase, records.length + 100000),
    ];
    records.addAll(trimaExtra);
    records.sort((a,b) => a.offset.compareTo(b.offset));
    diagnostics.add('Trima EVENT válidos: ${trimaExtra.where((r) => r.traceMessage == null).length}');
    diagnostics.add('Trima TRACE válidos: ${trimaExtra.where((r) => r.traceMessage != null).length}');

    // ------------------------------------------------------------
    // 8. Estadísticas
    // ------------------------------------------------------------

    final procedureCount = records
        .where(
          (r) => r.classification == DlogRecordClass.procedure,
        )
        .length;

    final mixedCount = records
        .where(
          (r) => r.classification == DlogRecordClass.mixed,
        )
        .length;

    final traceCount = records
        .where(
          (r) => r.classification == DlogRecordClass.trace,
        )
        .length;

    final unknownCount = records
        .where(
          (r) => r.classification == DlogRecordClass.unknown,
        )
        .length;

    final totalFields = records.fold<int>(
      0,
      (sum, r) => sum + r.fields.length,
    );

    diagnostics.add(
      'Procedure: $procedureCount',
    );

    diagnostics.add(
      'Mixed: $mixedCount',
    );

    diagnostics.add(
      'Trace: $traceCount',
    );

    diagnostics.add(
      'Unknown: $unknownCount',
    );

    diagnostics.add(
      'Campos decodificados: $totalFields',
    );

    // ------------------------------------------------------------
    // 9. Mostrar algunos registros
    // ------------------------------------------------------------

    for (final record in records
        .where(
          (r) => r.classification == DlogRecordClass.procedure,
        )
        .take(5)) {
      diagnostics.add(
        _recordPreview(record),
      );
    }

    return DlogDecodeResult(
      ok: true,
      sourcePath: sourcePath,
      gzipOffset: gzipOffset,
      decompressedSize: decompressed.length,
      payloadSize: payload.length,
      records: records,
      diagnostics: diagnostics,
      timestampInfo: timestampInfo,
      originalHeader: csvColumns,
      machine: DlogMachine.trima,
      machineInfo: _extractMachineInfo(input, payload, DlogMachine.trima, gzipOffset),
      originalBytes: input,
    );
  }


  // ============================================================
  // TRIMA EVENT / TRACE (native columns without header)
  // ============================================================

  static DateTime? _trimaStartFromHeader(Uint8List input) {
    // Trima stores its start clock immediately before the ASCII node name.
    // Observed native layout:
    //   day month year:u16LE hour minute second weekday 00 "CONTROL"
    // Example: 05 05 EA 07 06 2D 1B 07 00 CONTROL
    //          -> 2026-05-05 06:45:27
    final gzip = _findGzip(input);
    final limit = gzip > 0 ? gzip : math.min(input.length, 2048);
    const control = [0x43,0x4F,0x4E,0x54,0x52,0x4F,0x4C];
    for (var p = 9; p + control.length <= limit; p++) {
      var ok = true;
      for (var i=0;i<control.length;i++) {
        if (input[p+i] != control[i]) { ok=false; break; }
      }
      if (!ok || input[p-1] != 0) continue;
      final day=input[p-9], month=input[p-8];
      final year=input[p-7] | (input[p-6] << 8);
      final hour=input[p-5], minute=input[p-4], second=input[p-3];
      if (year < 2000 || year > 2200 || month < 1 || month > 12 ||
          day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) continue;
      try { return DateTime(year,month,day,hour,minute,second); } catch (_) {}
    }
    return null;
  }

  static Map<int,String> _trimaEventDictionary(Uint8List d) {
    final out=<int,String>{};
    for(var p=0;p+18<d.length;p++) {
      if(d[p]!=0x01 || d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if(ns>=1000000000) continue;
      if(d[p+12]!=0x5A || d[p+13]!=0 || d[p+14]!=0 || (d[p+15]!=1 && d[p+15]!=2)) continue;
      final len=_u16(d,p+16); if(len<=0 || len>128 || p+18+len>d.length) continue;
      final b=d.sublist(p+18,p+18+len);
      if(!b.every((x)=>x>=32 && x<=126)) continue;
      out[_u16(d,p+10)]=ascii(b);
    }
    return out;
  }

  static List<Dlog022eRecord> _readTrimaEvents(Uint8List d, Map<int,String> names, DateTime? base, int startIndex) {
    final out=<Dlog022eRecord>[]; var ix=startIndex;
    for(var p=0;p+18<d.length;p++) {
      if(d[p]!=0x01 || d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if(ns>=1000000000) continue;
      if(d[p+12]!=0x5A || d[p+13]!=0 || d[p+14]!=0 || (d[p+15]!=1 && d[p+15]!=2)) continue;
      final len=_u16(d,p+16); if(len<=0 || len>128 || p+18+len>d.length) continue;
      final b=d.sublist(p+18,p+18+len);
      if(!b.every((x)=>x>=32 && x<=126)) continue;
      final name=ascii(b);
      final r=Dlog022eRecord(index:ix++,offset:p,length:18+len,raw:Uint8List(0),fields:const [],asciiRatio:1,traceMarkers:0,printableText:name);
      r.classification=DlogRecordClass.trace;
      r.traceCategory=name; r.traceNode=name; r.traceMessage=null;
      if(base!=null) r.timestamp=base.add(Duration(seconds:_u32(d,p+2),microseconds:ns~/1000));
      out.add(r);
    }
    return out;
  }

  static List<Dlog022eRecord> _readTrimaTraces(Uint8List d, Map<int,String> names, DateTime? base, int startIndex) {
    final out=<Dlog022eRecord>[];
    var ix=startIndex;

    // ----------------------------------------------------------
    // Legacy Trima TRACE: 02 55
    // ----------------------------------------------------------
    // Layout confirmed against the native Trima CSV:
    // 02 55 sec:u32 ns:u32 eventId:u16 context:u32
    // 5A 00 00 node
    // formatLen:u16 fileNameLen:u16 sourceLine:u16
    // format[formatLen] fileName[fileNameLen] args...
    //
    // Unlike 03 55, arguments are not tagged. Their types are
    // described by the printf-style format string itself.
    for(var p=0;p+26<d.length;p++) {
      if(d[p]!=0x02 || d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if(ns>=1000000000) continue;
      if(d[p+16]!=0x5A || d[p+17]!=0 || d[p+18]!=0 || (d[p+19]!=1 && d[p+19]!=2)) continue;
      final formatLen=_u16(d,p+20);
      final fileLen=_u16(d,p+22);
      if(formatLen<=0 || formatLen>4096 || fileLen>256) continue;
      final formatStart=p+26;
      final fileStart=formatStart+formatLen;
      final argsStart=fileStart+fileLen;
      if(argsStart>d.length) continue;
      final fb=d.sublist(formatStart,fileStart);
      final file=d.sublist(fileStart,argsStart);
      if(!fb.every((x)=>x==9 || x==10 || x==13 || (x>=32 && x<=126))) continue;
      if(!file.every((x)=>x>=32 && x<=126)) continue;

      final format=ascii(fb);
      final rendered=_renderTrimaLegacyPrintf(d,argsStart,format);
      if(rendered==null) continue;
      var msg=rendered.$1.replaceAll('\r','').replaceAll('\n','');
      // Native Trima CSV sanitizes commas in TRACE verbose so they do not
      // become CSV separators. Quotes are also removed from ordinary TRACE
      // strings. The large TRIMA_PARAMETERS_PPL ConfigBlocks payload is the
      // observed exception: its JSON quotes are preserved by the native CSV.
      msg=msg.replaceAll(',', ' ');
      if (!msg.contains('ConfigBlocks::initializeConfigBlocks using Block:   TRIMA_PARAMETERS_PPL')) {
        msg=msg.replaceAll('"', '');
      }
      msg=msg.replaceFirst(RegExp(r'\s+$'),'');
      final id=_u16(d,p+10);
      final r=Dlog022eRecord(index:ix++,offset:p,length:rendered.$2-p,raw:Uint8List(0),fields:const [],asciiRatio:0,traceMarkers:1,printableText:msg);
      r.classification=DlogRecordClass.trace;
      r.traceCategory=id==0?'CriticalOutput':(names[id]??'');
      r.traceNode=d[p+19]==1?'Node:SAFETY':'Node:CONTROL';
      r.traceMessage='  ${msg.replaceFirst(RegExp(r'^\s+'),'')}';
      if(base!=null) r.timestamp=base.add(Duration(seconds:_u32(d,p+2),microseconds:ns~/1000));
      out.add(r);
    }

    // ----------------------------------------------------------
    // Tokenized Trima TRACE: 03 55
    // ----------------------------------------------------------
    final starts=<int>[];
    for(var p=0;p+24<d.length;p++) {
      if(d[p]!=0x03 || d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if(ns>=1000000000) continue;
      if(d[p+16]!=0x5A || d[p+17]!=0 || d[p+18]!=0 || (d[p+19]!=1 && d[p+19]!=2)) continue;
      final fl=_u16(d,p+20); if(fl>256 || p+24+fl+5>d.length) continue;
      final fb=d.sublist(p+24,p+24+fl);
      if(!fb.every((x)=>x>=32 && x<=126)) continue;
      starts.add(p);
    }
    for(var n=0;n<starts.length;n++) {
      final p=starts[n];
      final hardLimit=n+1<starts.length?starts[n+1]:d.length;
      final ns=_u32(d,p+6), id=_u16(d,p+10), fl=_u16(d,p+20);
      final tag=p+24+fl;
      var q=tag;
      int? numericFormat;
      bool numericHexPrefix=false;
      int? fixedPrecision;
      if(q+5<hardLimit &&
          (((d[q]==0x10 || d[q]==0x20) && d[q+1]==0x40 && d[q+2]==0x05) ||
           ((d[q]==0x00 || d[q]==0x10) && d[q+1]==0x11))) {
        if(d[q]==0x10 || d[q]==0x20) numericFormat=d[q];
        // Trima TRACE headers xx 11 PP aa bb encode the default
        // floating-point precision in PP. This is why the same message
        // family may appear behind 00/10 11 03 with different trailing
        // bytes while still rendering all float tokens with 3 decimals.
        // Observed native headers also use PP=02 and PP=07.
        if(d[q+1]==0x11 && d[q+2]<=9) {
          fixedPrecision=d[q+2];
        }
        q+=5;
      }
      final sb=StringBuffer();
      while(q<hardLimit) {
        if(q+1<hardLimit && d[q]==0xFE && d[q+1]==0x55) { q+=2; break; }
        final t=d[q++];
        if(t==7) {
          if(q+2>hardLimit) break; final l=_u16(d,q); q+=2; if(q+l>hardLimit) break;
          sb.write(utf8.decode(d.sublist(q,q+l),allowMalformed:true)); q+=l;
        } else if(t==1) {
          if(q>=hardLimit) break; sb.writeCharCode(d[q++]);
        } else if(t==3 || t==4 || t==5 || t==6) {
          if(q+4>hardLimit) break;
          final bd=ByteData.sublistView(d,q,q+4); final si=bd.getInt32(0,Endian.little), ui=bd.getUint32(0,Endian.little); q+=4;
          if(numericFormat==0x20) {
            final hx=ui.toRadixString(16);
            sb.write(numericHexPrefix ? '0x$hx' : hx);
          } else if(t==4 || t==6) {
            // Trima token 04/06 are unsigned 32-bit values.  In particular
            // CRC values above 0x7fffffff must not become negative.
            sb.write(ui);
          } else {
            sb.write(si);
          }
        } else if(t==8) {
          if(q+4>hardLimit) break;
          final raw=ByteData.sublistView(d,q,q+4).getFloat32(0,Endian.little); q+=4;
          // The native Trima logger first renders float32 with about seven
          // significant decimal digits, then applies the requested fixed
          // precision.  This reproduces e.g. 170.973617... -> 170.97360 and
          // 2025.303955... -> 2025.30400.
          sb.write(raw.toStringAsFixed(fixedPrecision ?? 5));
        } else if(t==9) {
          if(q+8>hardLimit) break; final v=ByteData.sublistView(d,q,q+8).getFloat64(0,Endian.little); q+=8; sb.write(v.toStringAsFixed(fixedPrecision ?? 5));
        } else if(t==10) {
          if(q>=hardLimit) break; sb.write(d[q++]!=0?'true':'false');
        } else if(t==0x64) {
          if(q+2>hardLimit) break;
          numericFormat=d[q];
          // 64 20 11 is a Trima formatter variant that emits the 0x prefix.
          // 64 20 40 selects hexadecimal digits only (no prefix).
          numericHexPrefix=(numericFormat==0x20 && d[q+1]==0x11);
          q+=2;
        } else if(t==0x65) {
          if(q>=hardLimit) break; fixedPrecision=d[q++];
        } else {
          break;
        }
      }
      var msg=sb.toString().replaceAll('\r','').replaceAll('\n','');
      // Trima's native CSV writer sanitizes TRACE payload punctuation rather
      // than CSV-quoting ordinary verbose fields.
      msg=msg.replaceAll(',', ' ');
      if (!msg.contains('ConfigBlocks::initializeConfigBlocks using Block:   TRIMA_PARAMETERS_PPL')) {
        msg=msg.replaceAll('"', '');
      }
      msg=msg.replaceFirst(RegExp(r'\s+$'),'');
      final r=Dlog022eRecord(index:ix++,offset:p,length:q-p,raw:Uint8List(0),fields:const [],asciiRatio:0,traceMarkers:1,printableText:msg);
      r.classification=DlogRecordClass.trace;
      r.traceCategory=id==0?'CriticalOutput':(names[id]??'');
      r.traceNode=d[p+19]==1?'Node:SAFETY':'Node:CONTROL';
      r.traceMessage='  ${msg.replaceFirst(RegExp(r'^\s+'),'')}';
      if(base!=null) r.timestamp=base.add(Duration(seconds:_u32(d,p+2),microseconds:ns~/1000));
      out.add(r);
    }
    return out;
  }

  static String _trimaDecimalToFixed(String value, int precision) {
    var s=value.trim();
    var neg=false;
    if(s.startsWith('-')) { neg=true; s=s.substring(1); }
    var exp=0;
    final ei=s.toLowerCase().indexOf('e');
    if(ei>=0) { exp=int.tryParse(s.substring(ei+1))??0; s=s.substring(0,ei); }
    final dot=s.indexOf('.');
    var digits=s.replaceAll('.', '');
    var decimalPos=(dot>=0?dot:s.length)+exp;
    while(decimalPos<0) { digits='0$digits'; decimalPos++; }
    while(decimalPos>digits.length) digits+='0';
    if(digits.isEmpty) digits='0';
    final target=decimalPos+precision;
    if(target<digits.length) {
      final rd=target>=0 ? int.parse(digits[target]) : int.parse(digits[0]);
      var kept=target>0 ? digits.substring(0,target) : '0';
      var n=BigInt.parse(kept.isEmpty?'0':kept);
      if(rd>=5) n+=BigInt.one;
      kept=n.toString();
      final oldTarget=target;
      if(oldTarget>0 && kept.length<oldTarget) kept=kept.padLeft(oldTarget,'0');
      digits=kept;
      if(oldTarget>0 && kept.length>oldTarget) decimalPos++;
    } else {
      digits=digits.padRight(target,'0');
    }
    if(decimalPos<=0) {
      var frac=('0' * (-decimalPos)) + digits;
      frac=frac.padRight(precision,'0');
      if(frac.length>precision) frac=frac.substring(0,precision);
      var out=precision>0?'0.$frac':'0';
      if(neg && frac.replaceAll('0','').isNotEmpty) out='-$out';
      return out;
    }
    if(digits.length<decimalPos) digits=digits.padRight(decimalPos,'0');
    final a=digits.substring(0,decimalPos);
    var frac=digits.substring(decimalPos).padRight(precision,'0');
    if(frac.length>precision) frac=frac.substring(0,precision);
    var out=precision>0?'$a.$frac':a;
    final nz=(a+frac).replaceAll('0','').isNotEmpty;
    if(neg && nz) out='-$out';
    return out;
  }

  static (String,int)? _renderTrimaLegacyPrintf(Uint8List d, int argsStart, String format) {
    final b=StringBuffer();
    var q=argsStart;
    var i=0;
    while(i<format.length) {
      if(format.codeUnitAt(i)!=0x25) { b.writeCharCode(format.codeUnitAt(i++)); continue; }
      if(i+1<format.length && format.codeUnitAt(i+1)==0x25) { b.write('%'); i+=2; continue; }
      final begin=i++;
      while(i<format.length && '-+ #0'.contains(format[i])) i++;
      while(i<format.length && RegExp(r'[0-9]').hasMatch(format[i])) i++;
      int? precision;
      if(i<format.length && format[i]=='.') {
        i++; final ps=i; while(i<format.length && RegExp(r'[0-9]').hasMatch(format[i])) i++;
        if(i>ps) precision=int.tryParse(format.substring(ps,i));
      }
      // Preserve the printf length modifier. Trima legacy 02 55 stores
      // %lf arguments as an IEEE-754 little-endian 64-bit double, while
      // plain %f arguments are stored as 32-bit floats.
      String lengthModifier='';
      while(i<format.length && 'hlL'.contains(format[i])) {
        lengthModifier += format[i++];
      }
      if(i>=format.length) { b.write(format.substring(begin)); break; }
      final type=format[i++];
      if(type=='d' || type=='i') {
        if(q+4>d.length) return null; b.write(ByteData.sublistView(d,q,q+4).getInt32(0,Endian.little)); q+=4;
      } else if(type=='u') {
        if(q+4>d.length) return null; b.write(ByteData.sublistView(d,q,q+4).getUint32(0,Endian.little)); q+=4;
      } else if(type=='x' || type=='X') {
        if(q+4>d.length) return null; var x=ByteData.sublistView(d,q,q+4).getUint32(0,Endian.little).toRadixString(16); q+=4; if(type=='X') x=x.toUpperCase(); b.write(x);
      } else if(type=='f' || type=='F' || type=='e' || type=='E' || type=='g' || type=='G') {
        final bool isDouble = lengthModifier.contains('l') || lengthModifier.contains('L');
        if(q+(isDouble?8:4)>d.length) return null;
        final double v;
        if(isDouble) {
          v=ByteData.sublistView(d,q,q+8).getFloat64(0,Endian.little); q+=8;
        } else {
          v=ByteData.sublistView(d,q,q+4).getFloat32(0,Endian.little); q+=4;
        }
        // Trima legacy has two different floating renderers. Plain %f is a
        // float32 printf-like value, but %lf is stored as float64 and the
        // native logger renders it with 15 significant digits. In observed
        // records the written precision in %.Nlf is not used as decimal
        // precision (e.g. %.2lf -> 195.314257523434).
        if (isDouble) {
          b.write(v.toString());
        } else if (precision != null) {
          b.write(v.toStringAsFixed(precision));
        } else {
          var fv=v.toStringAsFixed(2);
          fv=fv.replaceFirst(RegExp(r'0+$'),'').replaceFirst(RegExp(r'\.$'),'');
          b.write(fv);
        }
      } else if(type=='s') {
        if(q+2>d.length) return null; final l=_u16(d,q); q+=2; if(l<0 || l>4096 || q+l>d.length) return null;
        b.write(utf8.decode(d.sublist(q,q+l),allowMalformed:true)); q+=l;
      } else if(type=='c') {
        if(q+4>d.length) return null; b.writeCharCode(_u32(d,q)&0xff); q+=4;
      } else {
        b.write(format.substring(begin,i));
      }
    }
    return (b.toString(),q);
  }

  // ============================================================
  // OPTIA
  // ============================================================

  static const List<String> optiaCsvColumns = [
    'index',
    'timestamp','DispState','SubState','Alarms','Pwr_24V','Pwr_S24V','Pwr_24I',
    'S_PumpPW','S_PumpPWCmd','Pump1Cmd','Pump1Curr','S_Pump1Curr',
    'Pump2Cmd','Pump2Curr','S_Pump2Curr','Pump3Cmd','Pump3Curr','S_Pump3Curr',
    'Pump4Cmd','Pump4Curr','S_Pump4Curr','Pump5Cmd','Pump5Curr','S_Pump5Curr',
    'Valve1Cmd','Valve1State','S_Valve1State','Valve2Cmd','Valve2State','S_Valve2State',
    'Valve3Cmd','Valve3State','S_Valve3State','CassetteCmd','CassetteState','S_CassState',
    'DoorLockCmd','DoorState','S_DoorState','Pwr_64V','Pwr_S64V','Pwr_64I',
    'S_CentPWCmd','CentCmd','CentCurr','AIM_CentCurr','Pressure1','Pressure2','Pressure3','Pressure4',
    'LvlSensor1Fluid','LvlSensor1AGC','LvlSensor2Fluid','LvlSensor2AGC',
    'ReturnAirDetector','ReturnAirAccum','AirCirc','FluidDetector1','FluidDetector2','LeakDetector',
    'RBCDetectorGreenDrive','RBCDetectorGreenReflectance','RBCDetectorRedDrive','RBCDetectorRedReflectance',
    'Pwr_5V','Pwr_12V','Pwr_m12V',
  ];

  static const String optiaDescriptionRow = ",disposable set state,procedure sub-state,active alarm list,+ 24 volt supply (volts),+ 24 volt switched supply (volts),+ 24 volt current (milliamps),safety pump power -1=Dis;0=Off;1=On,safety pump power cmd -1=Dis;0=Off;1=On,pump 1 command (RPM),pump 1 current (RPM),safety pump 1 current (RPM),pump 2 command (RPM),pump 2 current (RPM),safety pump 2 current (RPM),pump 3 command (RPM),pump 3 current (RPM),safety pump 3 current (RPM),pump 4 command (RPM),pump 4 current (RPM),safety pump 4 current (RPM),pump 5 command (RPM),pump 5 current (RPM),safety pump 5 current (RPM),valve 1 command,valve 1 state,safety valve 1 state,valve 2 command,valve 2 state,safety valve 2 state,valve 3 command,valve 3 state,safety valve 3 state,cassette command,cassette state,safety cassette state,door lock command,door state,safety door state,+ 64 volt supply (volts),+ 64 volt switched supply (volts),+ 64 volt current (milliamps),safety cent power cmd -1=Dis;0=Off;1=On,commanded centrifuge speed (RPM),current centrifuge speed (RPM),AIM current centrifuge speed (RPM),pressure sensor 1 (mmHg),pressure sensor 2 (mmHg),pressure sensor 3 (mmHg),pressure sensor 4 (mmHg),level sensor 1 fluid present,level sensor 1 AGC (volts),level sensor 2 fluid present,level sensor 2 AGC (volts),return line air detector state,accumulated return air (ml),estimated air circulation (ml),fluid detector 1 fluid present,fluid detector 2 fluid present,leak detector (volts),RBC detector green drive,RBC detector green reflectance,RBC detector red drive,RBC detector red reflectance,+ 5 volt supply (volts),+ 12 volt supply (volts),- 12 volt supply (volts)";

  static final Map<int, DlogFieldDefinition> optiaFieldDefinitions = {
    0x8F: DlogFieldDefinition(id:0x8F,name:'DispState',typeCode:2,format:'%s'),
    0x90: DlogFieldDefinition(id:0x90,name:'SubState',typeCode:2,format:'%s'),
    0x91: DlogFieldDefinition(id:0x91,name:'Alarms',typeCode:2,format:'%s'),
    0x92: DlogFieldDefinition(id:0x92,name:'Pwr_5V',typeCode:5,format:'%.2lf'),
    0x93: DlogFieldDefinition(id:0x93,name:'Pwr_12V',typeCode:5,format:'%.2lf'),
    0x94: DlogFieldDefinition(id:0x94,name:'Pwr_m12V',typeCode:5,format:'%.2lf'),
    0x95: DlogFieldDefinition(id:0x95,name:'Pwr_24V',typeCode:5,format:'%.2lf'),
    0x96: DlogFieldDefinition(id:0x96,name:'Pwr_S24V',typeCode:5,format:'%.2lf'),
    0x97: DlogFieldDefinition(id:0x97,name:'Pwr_64V',typeCode:5,format:'%.2lf'),
    0x98: DlogFieldDefinition(id:0x98,name:'Pwr_S64V',typeCode:5,format:'%.2lf'),
    0x99: DlogFieldDefinition(id:0x99,name:'Pwr_24I',typeCode:5,format:'%.1lf'),
    0x9A: DlogFieldDefinition(id:0x9A,name:'Pwr_64I',typeCode:5,format:'%.1lf'),
    0x9C: DlogFieldDefinition(id:0x9C,name:'Pump1Cmd',typeCode:5,format:'%.1lf'),
    0x9D: DlogFieldDefinition(id:0x9D,name:'Pump1Curr',typeCode:5,format:'%.1lf'),
    0xA0: DlogFieldDefinition(id:0xA0,name:'Pump2Cmd',typeCode:5,format:'%.1lf'),
    0xA1: DlogFieldDefinition(id:0xA1,name:'Pump2Curr',typeCode:5,format:'%.1lf'),
    0xA4: DlogFieldDefinition(id:0xA4,name:'Pump3Cmd',typeCode:5,format:'%.1lf'),
    0xA5: DlogFieldDefinition(id:0xA5,name:'Pump3Curr',typeCode:5,format:'%.1lf'),
    0xA8: DlogFieldDefinition(id:0xA8,name:'Pump4Cmd',typeCode:5,format:'%.1lf'),
    0xA9: DlogFieldDefinition(id:0xA9,name:'Pump4Curr',typeCode:5,format:'%.1lf'),
    0xAC: DlogFieldDefinition(id:0xAC,name:'Pump5Cmd',typeCode:5,format:'%.1lf'),
    0xAD: DlogFieldDefinition(id:0xAD,name:'Pump5Curr',typeCode:5,format:'%.1lf'),
    0xB0: DlogFieldDefinition(id:0xB0,name:'CentCmd',typeCode:5,format:'%.1lf'),
    0xB1: DlogFieldDefinition(id:0xB1,name:'CentCurr',typeCode:5,format:'%.1lf'),
    0xB2: DlogFieldDefinition(id:0xB2,name:'AIM_CentCurr',typeCode:5,format:'%.1lf'),
    0xB3: DlogFieldDefinition(id:0xB3,name:'Valve1Cmd',typeCode:2,format:'%s'),
    0xB4: DlogFieldDefinition(id:0xB4,name:'Valve1State',typeCode:2,format:'%s'),
    0xB5: DlogFieldDefinition(id:0xB5,name:'Valve2Cmd',typeCode:2,format:'%s'),
    0xB6: DlogFieldDefinition(id:0xB6,name:'Valve2State',typeCode:2,format:'%s'),
    0xB7: DlogFieldDefinition(id:0xB7,name:'Valve3Cmd',typeCode:2,format:'%s'),
    0xB8: DlogFieldDefinition(id:0xB8,name:'Valve3State',typeCode:2,format:'%s'),
    0xB9: DlogFieldDefinition(id:0xB9,name:'DoorLockCmd',typeCode:2,format:'%s'),
    0xBA: DlogFieldDefinition(id:0xBA,name:'DoorState',typeCode:2,format:'%s'),
    0xBB: DlogFieldDefinition(id:0xBB,name:'CassetteCmd',typeCode:2,format:'%s'),
    0xBC: DlogFieldDefinition(id:0xBC,name:'CassetteState',typeCode:2,format:'%s'),
    0xBD: DlogFieldDefinition(id:0xBD,name:'Pressure1',typeCode:5,format:'%.1lf'),
    0xBE: DlogFieldDefinition(id:0xBE,name:'Pressure2',typeCode:5,format:'%.1lf'),
    0xBF: DlogFieldDefinition(id:0xBF,name:'Pressure3',typeCode:5,format:'%.1lf'),
    0xC0: DlogFieldDefinition(id:0xC0,name:'Pressure4',typeCode:5,format:'%.1lf'),
    0xC1: DlogFieldDefinition(id:0xC1,name:'LvlSensor1Fluid',typeCode:2,format:'%s'),
    0xC2: DlogFieldDefinition(id:0xC2,name:'LvlSensor1AGC',typeCode:5,format:'%.1lf'),
    0xC3: DlogFieldDefinition(id:0xC3,name:'LvlSensor2Fluid',typeCode:2,format:'%s'),
    0xC4: DlogFieldDefinition(id:0xC4,name:'LvlSensor2AGC',typeCode:5,format:'%.1lf'),
    0xC5: DlogFieldDefinition(id:0xC5,name:'FluidDetector1',typeCode:2,format:'%s'),
    0xC6: DlogFieldDefinition(id:0xC6,name:'FluidDetector2',typeCode:2,format:'%s'),
    0xC7: DlogFieldDefinition(id:0xC7,name:'LeakDetector',typeCode:5,format:'%.2lf'),
    0xC8: DlogFieldDefinition(id:0xC8,name:'RBCDetectorGreenDrive',typeCode:2,format:'%d'),
    0xC9: DlogFieldDefinition(id:0xC9,name:'RBCDetectorGreenReflectance',typeCode:2,format:'%d'),
    0xCA: DlogFieldDefinition(id:0xCA,name:'RBCDetectorRedDrive',typeCode:2,format:'%d'),
    0xCB: DlogFieldDefinition(id:0xCB,name:'RBCDetectorRedReflectance',typeCode:2,format:'%d'),
    0xD5: DlogFieldDefinition(id:0xD5,name:'ReturnAirDetector',typeCode:2,format:'%s'),
    0xD6: DlogFieldDefinition(id:0xD6,name:'ReturnAirAccum',typeCode:5,format:'%.3lf'),
    0xD7: DlogFieldDefinition(id:0xD7,name:'AirCirc',typeCode:5,format:'%.3lf'),
  };

  static final Map<int, DlogFieldDefinition> optiaSafetyFieldDefinitions = {
    0x8F: DlogFieldDefinition(id:0x8F,name:'S_CassState',typeCode:2,format:'%s'),
    0x90: DlogFieldDefinition(id:0x90,name:'S_DoorState',typeCode:2,format:'%s'),
    0x92: DlogFieldDefinition(id:0x92,name:'S_Valve1State',typeCode:2,format:'%s'),
    0x93: DlogFieldDefinition(id:0x93,name:'S_Valve2State',typeCode:2,format:'%s'),
    0x94: DlogFieldDefinition(id:0x94,name:'S_Valve3State',typeCode:2,format:'%s'),
    0x97: DlogFieldDefinition(id:0x97,name:'S_CentPWCmd',typeCode:2,format:'%d'),
    0x9A: DlogFieldDefinition(id:0x9A,name:'S_PumpPW',typeCode:2,format:'%d'),
    0x9B: DlogFieldDefinition(id:0x9B,name:'S_PumpPWCmd',typeCode:2,format:'%d'),
    0x9C: DlogFieldDefinition(id:0x9C,name:'S_Pump1Curr',typeCode:5,format:'%.1lf'),
    0x9F: DlogFieldDefinition(id:0x9F,name:'S_Pump2Curr',typeCode:5,format:'%.1lf'),
    0xA2: DlogFieldDefinition(id:0xA2,name:'S_Pump3Curr',typeCode:5,format:'%.1lf'),
    0xA5: DlogFieldDefinition(id:0xA5,name:'S_Pump4Curr',typeCode:5,format:'%.1lf'),
    0xA8: DlogFieldDefinition(id:0xA8,name:'S_Pump5Curr',typeCode:5,format:'%.1lf'),
  };

  static const List<String> reveosCsvColumns = [
    'index',
    'timestamp',
    'ConfigName',
    'SequenceState',
    'SequenceTime',
    'TimeRemaining',
    'Alarms',
    'Language',
    'ServiceMode',
    'LidState',
    'LidLockCmd',
    'LidLockState',
    'LidLockPower',
    'CentrifugeRPMCmd',
    'CentrifugeRamp',
    'CentrifugeRPM',
    'CentrifugePower',
    'CentrifugeBusPower',
    'LineSensorCalBk1',
    'BucketSensorCalBk1',
    'LineSensor1Gain1',
    'LineSensor1Gain2',
    'LineSensor1LedAdjust1',
    'LineSensor1LedAdjust2',
    'Bucket1SensorGain',
    'Bucket1SensorLedAdjust',
    'Bucket1RotorInterfaceFault',
    'Bucket1SensorFault',
    'Bucket1BucketSensor',
    'Bucket1TempSensor',
    'Bucket1PressureSensor',
    'Bucket1LatchSensor',
    'Bucket1LineBlueTransmit',
    'Bucket1LineBlueReflect',
    'Bucket1LineRedTransmit',
    'Bucket1LineRedReflect',
    'Bucket1PlasmaValveRfEnable',
    'Bucket1PlasmaValveSealComplete',
    'PlasmaValveRfSelectCmdBk1',
    'Bucket1PlateletValveRfEnable',
    'Bucket1PlateletValveSealComplete',
    'PlateletValveRfSelectCmdBk1',
    'Bucket1LeukopackValveRfEnable',
    'Bucket1LeukopackValveSealComplete',
    'LeukopackValveRfSelectCmdBk1',
    'LineSensorCalBk2',
    'BucketSensorCalBk2',
    'LineSensor2Gain1',
    'LineSensor2Gain2',
    'LineSensor2LedAdjust1',
    'LineSensor2LedAdjust2',
    'Bucket2SensorGain',
    'Bucket2SensorLedAdjust',
    'Bucket2RotorInterfaceFault',
    'Bucket2SensorFault',
    'Bucket2BucketSensor',
    'Bucket2TempSensor',
    'Bucket2PressureSensor',
    'Bucket2LatchSensor',
    'Bucket2LineBlueTransmit',
    'Bucket2LineBlueReflect',
    'Bucket2LineRedTransmit',
    'Bucket2LineRedReflect',
    'Bucket2PlasmaValveRfEnable',
    'Bucket2PlasmaValveSealComplete',
    'PlasmaValveRfSelectCmdBk2',
    'Bucket2PlateletValveRfEnable',
    'Bucket2PlateletValveSealComplete',
    'PlateletValveRfSelectCmdBk2',
    'Bucket2LeukopackValveRfEnable',
    'Bucket2LeukopackValveSealComplete',
    'LeukopackValveRfSelectCmdBk2',
    'LineSensorCalBk3',
    'BucketSensorCalBk3',
    'LineSensor3Gain1',
    'LineSensor3Gain2',
    'LineSensor3LedAdjust1',
    'LineSensor3LedAdjust2',
    'Bucket3SensorGain',
    'Bucket3SensorLedAdjust',
    'Bucket3RotorInterfaceFault',
    'Bucket3SensorFault',
    'Bucket3BucketSensor',
    'Bucket3TempSensor',
    'Bucket3PressureSensor',
    'Bucket3LatchSensor',
    'Bucket3LineBlueTransmit',
    'Bucket3LineBlueReflect',
    'Bucket3LineRedTransmit',
    'Bucket3LineRedReflect',
    'Bucket3PlasmaValveRfEnable',
    'Bucket3PlasmaValveSealComplete',
    'PlasmaValveRfSelectCmdBk3',
    'Bucket3PlateletValveRfEnable',
    'Bucket3PlateletValveSealComplete',
    'PlateletValveRfSelectCmdBk3',
    'Bucket3LeukopackValveRfEnable',
    'Bucket3LeukopackValveSealComplete',
    'LeukopackValveRfSelectCmdBk3',
    'LineSensorCalBk4',
    'BucketSensorCalBk4',
    'LineSensor4Gain1',
    'LineSensor4Gain2',
    'LineSensor4LedAdjust1',
    'LineSensor4LedAdjust2',
    'Bucket4SensorGain',
    'Bucket4SensorLedAdjust',
    'Bucket4RotorInterfaceFault',
    'Bucket4SensorFault',
    'Bucket4BucketSensor',
    'Bucket4TempSensor',
    'Bucket4PressureSensor',
    'Bucket4LatchSensor',
    'Bucket4LineBlueTransmit',
    'Bucket4LineBlueReflect',
    'Bucket4LineRedTransmit',
    'Bucket4LineRedReflect',
    'Bucket4PlasmaValveRfEnable',
    'Bucket4PlasmaValveSealComplete',
    'PlasmaValveRfSelectCmdBk4',
    'Bucket4PlateletValveRfEnable',
    'Bucket4PlateletValveSealComplete',
    'PlateletValveRfSelectCmdBk4',
    'Bucket4LeukopackValveRfEnable',
    'Bucket4LeukopackValveSealComplete',
    'LeukopackValveRfSelectCmdBk4',
    'Bucket1PlasmaValveState',
    'Bucket2PlasmaValveState',
    'Bucket3PlasmaValveState',
    'Bucket4PlasmaValveState',
    'Bucket1PlateletValveState',
    'Bucket2PlateletValveState',
    'Bucket3PlateletValveState',
    'Bucket4PlateletValveState',
    'Bucket1LeukopackValveState',
    'Bucket2LeukopackValveState',
    'Bucket3LeukopackValveState',
    'Bucket4LeukopackValveState',
    'HydFlowCmd',
    'HydFlowRampCmd',
    'PistonFlowRate',
    'ActualRotorFlowRate',
    'HydPressureLimit',
    'HydAbsPressure',
    'HydPressureSensor',
    'HydRotorVolume',
    'HydEncoderCounts',
    'RodValve1Cmd',
    'HeadValve2Cmd',
    'HydLimitSwitchState',
    '5VReference',
    'ReferenceGroundVoltage',
    'VibrationForce',
    'VibrationSensor',
    'VibrationDisplacementSensor',
    'LeakDetector',
    'SafetyCentrifugePowerCmd',
    'SafetyCentrifugePowerStatus',
    'SafetyCentrifugeSpeed',
    'SafetyLidStatus',
    'SafetyLidLockStatus',
    'SafetyLockPowerCmd',
    'SafetyLidLockPowerStatus',
    'SafetyStopSwitch',
    'SafetyFault',
    'CentrifugeHours',
    'ProcedureNumber',
    'ProcedureHours',
    'TempBasin',
    'TempBearings',
    'TempH2O',
    'RotorBoardTemperature',
    'LineSensorCalCmdBk1',
    'BucketSensorCalCmdBk1',
    'BucketSensorGainCmdBk1',
    'LineSensorGainCmdBk1',
    'PlasmaValveCmdBk1',
    'PlateletValveCmdBk1',
    'LeukopackValveCmdBk1',
    'LineSensorCalCmdBk2',
    'BucketSensorCalCmdBk2',
    'BucketSensorGainCmdBk2',
    'LineSensorGainCmdBk2',
    'PlasmaValveCmdBk2',
    'PlateletValveCmdBk2',
    'LeukopackValveCmdBk2',
    'LineSensorCalCmdBk3',
    'BucketSensorCalCmdBk3',
    'BucketSensorGainCmdBk3',
    'LineSensorGainCmdBk3',
    'PlasmaValveCmdBk3',
    'PlateletValveCmdBk3',
    'LeukopackValveCmdBk3',
    'LineSensorCalCmdBk4',
    'BucketSensorCalCmdBk4',
    'BucketSensorGainCmdBk4',
    'LineSensorGainCmdBk4',
    'PlasmaValveCmdBk4',
    'PlateletValveCmdBk4',
    'LeukopackValveCmdBk4',
    'HydPurgeCmd',
    'HydSysResetCmd',
    'LidCmd',
    'LidPwrCmd',
    'Bucket1Status',
    'Bucket2Status',
    'Bucket3Status',
    'Bucket4Status',
  ];

  static const Map<int, String> reveosExportFields = {
    0x006D: 'SequenceState',
    0x006E: 'SequenceTime',
    0x006F: 'TimeRemaining',
    0x045E: 'Alarms',
    0x045F: 'LidState',
    0x0460: 'LidLockCmd',
    0x0461: 'LidLockState',
    0x0462: 'LidLockPower',
    0x0463: 'CentrifugeRPMCmd',
    0x0464: 'CentrifugeRamp',
    0x0465: 'CentrifugeRPM',
    0x0466: 'CentrifugePower',
    0x0467: 'CentrifugeBusPower',
    0x0468: 'LineSensorCalBk1',
    0x0469: 'BucketSensorCalBk1',
    0x046A: 'LineSensor1Gain1',
    0x046B: 'LineSensor1Gain2',
    0x046C: 'LineSensor1LedAdjust1',
    0x046D: 'LineSensor1LedAdjust2',
    0x046E: 'Bucket1SensorGain',
    0x046F: 'Bucket1SensorLedAdjust',
    0x0470: 'Bucket1BucketSensor',
    0x0471: 'Bucket1TempSensor',
    0x0472: 'Bucket1PressureSensor',
    0x0473: 'Bucket1LineBlueTransmit',
    0x0474: 'Bucket1LineBlueReflect',
    0x0475: 'Bucket1LineRedTransmit',
    0x0476: 'Bucket1LineRedReflect',
    0x0477: 'LineSensorCalBk2',
    0x0478: 'BucketSensorCalBk2',
    0x0479: 'LineSensor2Gain1',
    0x047A: 'LineSensor2Gain2',
    0x047B: 'LineSensor2LedAdjust1',
    0x047C: 'LineSensor2LedAdjust2',
    0x047D: 'Bucket2SensorGain',
    0x047E: 'Bucket2SensorLedAdjust',
    0x047F: 'Bucket2BucketSensor',
    0x0480: 'Bucket2TempSensor',
    0x0481: 'Bucket2PressureSensor',
    0x0482: 'Bucket2LineBlueTransmit',
    0x0483: 'Bucket2LineBlueReflect',
    0x0484: 'Bucket2LineRedTransmit',
    0x0485: 'Bucket2LineRedReflect',
    0x0486: 'LineSensorCalBk3',
    0x0487: 'BucketSensorCalBk3',
    0x0488: 'LineSensor3Gain1',
    0x0489: 'LineSensor3Gain2',
    0x048A: 'LineSensor3LedAdjust1',
    0x048B: 'LineSensor3LedAdjust2',
    0x048C: 'Bucket3SensorGain',
    0x048D: 'Bucket3SensorLedAdjust',
    0x048E: 'Bucket3BucketSensor',
    0x048F: 'Bucket3TempSensor',
    0x0490: 'Bucket3PressureSensor',
    0x0491: 'Bucket3LineBlueTransmit',
    0x0492: 'Bucket3LineBlueReflect',
    0x0493: 'Bucket3LineRedTransmit',
    0x0494: 'Bucket3LineRedReflect',
    0x0495: 'LineSensorCalBk4',
    0x0496: 'BucketSensorCalBk4',
    0x0497: 'LineSensor4Gain1',
    0x0498: 'LineSensor4Gain2',
    0x0499: 'LineSensor4LedAdjust1',
    0x049A: 'LineSensor4LedAdjust2',
    0x049B: 'Bucket4SensorGain',
    0x049C: 'Bucket4SensorLedAdjust',
    0x049D: 'Bucket4BucketSensor',
    0x049E: 'Bucket4TempSensor',
    0x049F: 'Bucket4PressureSensor',
    0x04A0: 'Bucket4LineBlueTransmit',
    0x04A1: 'Bucket4LineBlueReflect',
    0x04A2: 'Bucket4LineRedTransmit',
    0x04A3: 'Bucket4LineRedReflect',
    0x04A4: 'Bucket1PlasmaValveRfEnable',
    0x04A5: 'Bucket2PlasmaValveRfEnable',
    0x04A6: 'Bucket3PlasmaValveRfEnable',
    0x04A7: 'Bucket4PlasmaValveRfEnable',
    0x04A8: 'Bucket1PlateletValveRfEnable',
    0x04A9: 'Bucket2PlateletValveRfEnable',
    0x04AA: 'Bucket3PlateletValveRfEnable',
    0x04AB: 'Bucket4PlateletValveRfEnable',
    0x04AC: 'Bucket1LeukopackValveRfEnable',
    0x04AD: 'Bucket2LeukopackValveRfEnable',
    0x04AE: 'Bucket3LeukopackValveRfEnable',
    0x04AF: 'Bucket4LeukopackValveRfEnable',
    0x04D0: 'Bucket1PlasmaValveState',
    0x04D1: 'Bucket2PlasmaValveState',
    0x04D2: 'Bucket3PlasmaValveState',
    0x04D3: 'Bucket4PlasmaValveState',
    0x04D4: 'Bucket1PlateletValveState',
    0x04D5: 'Bucket2PlateletValveState',
    0x04D6: 'Bucket3PlateletValveState',
    0x04D7: 'Bucket4PlateletValveState',
    0x04D8: 'Bucket1LeukopackValveState',
    0x04D9: 'Bucket2LeukopackValveState',
    0x04DA: 'Bucket3LeukopackValveState',
    0x04DB: 'Bucket4LeukopackValveState',
    0x04DC: 'Bucket1LatchSensor',
    0x04DD: 'Bucket2LatchSensor',
    0x04DE: 'Bucket3LatchSensor',
    0x04DF: 'Bucket4LatchSensor',
    0x04E0: 'HydFlowCmd',
    0x04E1: 'HydFlowRampCmd',
    0x04E2: 'PistonFlowRate',
    0x04E3: 'ActualRotorFlowRate',
    0x04E4: 'HydPressureLimit',
    0x04E5: 'HydAbsPressure',
    0x04E6: 'HydPressureSensor',
    0x04E7: 'HydEncoderCounts',
    0x04E8: 'HydRotorVolume',
    0x04EE: 'RodValve1Cmd',
    0x04F0: 'HeadValve2Cmd',
    0x04F2: 'HydLimitSwitchState',
    0x04F3: '5VReference',
    0x04F4: 'ReferenceGroundVoltage',
    0x04F5: 'VibrationForce',
    0x04F6: 'VibrationSensor',
    0x04F7: 'VibrationDisplacementSensor',
    0x04F8: 'LeakDetector',
    0x04F9: 'SafetyCentrifugePowerCmd',
    0x04FA: 'SafetyCentrifugePowerStatus',
    0x04FB: 'SafetyCentrifugeSpeed',
    0x04FF: 'SafetyLidStatus',
    0x0500: 'SafetyLidLockStatus',
    0x0501: 'SafetyLockPowerCmd',
    0x0502: 'SafetyLidLockPowerStatus',
    0x0503: 'SafetyStopSwitch',
    0x0504: 'SafetyFault',
    0x0505: 'CentrifugeHours',
    0x0506: 'ProcedureNumber',
    0x0507: 'ProcedureHours',
    0x050E: 'TempBasin',
    0x050F: 'TempBearings',
    0x0510: 'TempH2O',
    0x0511: 'RotorBoardTemperature',
    0x0513: 'LineSensorCalCmdBk1',
    0x0514: 'BucketSensorGainCmdBk1',
    0x0515: 'BucketSensorCalCmdBk1',
    0x0516: 'LineSensorGainCmdBk1',
    0x0517: 'LineSensorCalCmdBk2',
    0x0518: 'BucketSensorGainCmdBk2',
    0x0519: 'BucketSensorCalCmdBk2',
    0x051A: 'LineSensorGainCmdBk2',
    0x051B: 'LineSensorCalCmdBk3',
    0x051C: 'BucketSensorGainCmdBk3',
    0x051D: 'BucketSensorCalCmdBk3',
    0x051E: 'LineSensorGainCmdBk3',
    0x051F: 'LineSensorCalCmdBk4',
    0x0520: 'BucketSensorGainCmdBk4',
    0x0521: 'BucketSensorCalCmdBk4',
    0x0522: 'LineSensorGainCmdBk4',
    0x0523: 'PlasmaValveCmdBk1',
    0x0524: 'PlasmaValveCmdBk2',
    0x0525: 'PlasmaValveCmdBk3',
    0x0526: 'PlasmaValveCmdBk4',
    0x0527: 'PlateletValveCmdBk1',
    0x0528: 'PlateletValveCmdBk2',
    0x0529: 'PlateletValveCmdBk3',
    0x052A: 'PlateletValveCmdBk4',
    0x052B: 'LeukopackValveCmdBk1',
    0x052C: 'LeukopackValveCmdBk2',
    0x052D: 'LeukopackValveCmdBk3',
    0x052E: 'LeukopackValveCmdBk4',
    0x052F: 'PlasmaValveRfSelectCmdBk1',
    0x0530: 'PlasmaValveRfSelectCmdBk2',
    0x0531: 'PlasmaValveRfSelectCmdBk3',
    0x0532: 'PlasmaValveRfSelectCmdBk4',
    0x0533: 'PlateletValveRfSelectCmdBk1',
    0x0534: 'PlateletValveRfSelectCmdBk2',
    0x0535: 'PlateletValveRfSelectCmdBk3',
    0x0536: 'PlateletValveRfSelectCmdBk4',
    0x0537: 'LeukopackValveRfSelectCmdBk1',
    0x0538: 'LeukopackValveRfSelectCmdBk2',
    0x0539: 'LeukopackValveRfSelectCmdBk3',
    0x053A: 'LeukopackValveRfSelectCmdBk4',
    0x0561: 'HydPurgeCmd',
    0x0563: 'HydSysResetCmd',
    0x0567: 'LidCmd',
    0x0568: 'LidPwrCmd',
    0x056E: 'Bucket1Status',
    0x056F: 'Bucket2Status',
    0x0570: 'Bucket3Status',
    0x0571: 'Bucket4Status',
    0x0572: 'Bucket1PlasmaValveSealComplete',
    0x0573: 'Bucket2PlasmaValveSealComplete',
    0x0574: 'Bucket3PlasmaValveSealComplete',
    0x0575: 'Bucket4PlasmaValveSealComplete',
    0x0576: 'Bucket1PlateletValveSealComplete',
    0x0577: 'Bucket2PlateletValveSealComplete',
    0x0578: 'Bucket3PlateletValveSealComplete',
    0x0579: 'Bucket4PlateletValveSealComplete',
    0x057A: 'Bucket1LeukopackValveSealComplete',
    0x057B: 'Bucket2LeukopackValveSealComplete',
    0x057C: 'Bucket3LeukopackValveSealComplete',
    0x057D: 'Bucket4LeukopackValveSealComplete',
    0x057F: 'ConfigName',
    0x0586: 'Language',
    0x0587: 'ServiceMode',
  };

  static bool _looksLikeReveos(Uint8List d) {
    const families = <List<int>>[
      [0x6C,0,0,0,0,0],[0x5A,4,0,0,0,0],[0x12,5,0,0,0,0],
      [0x6D,5,0,0,0,0],[0x7E,5,0,0,0,0],
    ];
    var hits = 0;
    for (var p=0; p+18<d.length && hits<3; p++) {
      if (d[p]!=0x04 || d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if (ns>=1000000000) continue;
      for (final f in families) {
        var ok=true; for(var i=0;i<6;i++) if(d[p+10+i]!=f[i]) {ok=false;break;}
        if(ok) { hits++; break; }
      }
    }
    return hits>=2;
  }

  static DlogDecodeResult _decodeReveosPayload({
    required Uint8List payload, required Uint8List input, required String? sourcePath,
    required int gzipOffset, required int decompressedSize, required List<String> diagnostics,
  }) {
    diagnostics.add('Equipo detectado: Reveos.');
    final base=_reveosStartDateTime(input);
    if(base!=null) diagnostics.add('Inicio temporal Reveos: $base');
    final events=_reveosEventDictionary(payload);
    diagnostics.add('Definiciones EVENT Reveos: ${events.length}');
    final records=<Dlog022eRecord>[];
    var idx=0, rawData=0, skipped=0;
    final reveosFirstOnlySeen = <int>{};
    const reveosFirstOnlyIds = <int>{0x046D,0x047C,0x048B,0x049A};
    for(var p=0;p+18<payload.length;p++) {
      if(payload[p]!=0x04 || payload[p+1]!=0x55) continue;
      final parsed=_readReveosData(payload,p); if(parsed==null) continue;
      rawData++; p=parsed.end-1;
      final fields=<DlogField>[];
      // El exportador nativo de Reveos tiene un comportamiento peculiar cuando
      // el GZIP termina sin trailer y el ultimo DATA llega exactamente al EOF:
      // conserva los campos hasta el primer double (HydAbsPressure), marca EOF
      // y construye ese double con el descriptor de fin de registro. Reproducir
      // esta semantica evita inventar los campos posteriores de un log truncado.
      final truncatedFinalData = parsed.end == payload.length &&
          !_reveosHasCompleteGzipTrailer(input, gzipOffset, decompressedSize);
      for(final e in parsed.fields.entries) {
        final name=reveosExportFields[e.key]; if(name==null) continue;
        if (reveosFirstOnlyIds.contains(e.key) && !reveosFirstOnlySeen.add(e.key)) continue;
        if (truncatedFinalData && e.key == 0x04E5) {
          final synthetic = _reveosEofDouble(parsed.ns, e.key, 5);
          fields.add(DlogField(relativeOffset:0,id:e.key,name:name,typeCode:5,length:e.value.length,value:synthetic,formattedValue:_formatReveosEofDouble(synthetic),rawHex:_hex(e.value),trailer:0));
          break;
        }
        final val=_decodeReveosFieldValue(e.key, e.value);
        fields.add(DlogField(relativeOffset:0,id:e.key,name:name,typeCode:0,length:e.value.length,value:val,formattedValue:_formatReveosFieldValue(e.key, val),rawHex:_hex(e.value),trailer:0));
      }
      if(fields.isEmpty) { skipped++; continue; }
      // Reveos conserva registros DATA distintos aunque al truncar a milisegundos
      // tengan el mismo timestamp. El CSV oficial contiene 40 timestamps ms
      // duplicados en este DLOG, por lo que NO deben fusionarse.
      final ms=parsed.sec*1000 + parsed.ns~/1000000;
      final r=Dlog022eRecord(index:idx++,offset:parsed.start,length:parsed.end-parsed.start,raw:Uint8List(0),fields:<DlogField>[],asciiRatio:0,traceMarkers:0,printableText:'');
      r.classification=DlogRecordClass.procedure;
      if(base!=null) r.timestamp=base.add(Duration(milliseconds:ms));
      r.fields.addAll(fields);
      records.add(r);
    }
    // EVENT rows: category + category.
    final eventRows=_readReveosEvents(payload,events,base,idx);
    records.addAll(eventRows);
    idx += eventRows.length;
    // TRACE rows: category + Node: + verbose.
    final traces=_readReveosTraces(payload,events,base,idx); records.addAll(traces);
    records.sort((a,b)=>a.offset.compareTo(b.offset));
    for(var i=0;i<records.length;i++) records[i].indexOverride=i;
    diagnostics.add('Reveos DATA binarios: $rawData');
    diagnostics.add('Reveos DATA sin campos exportables: $skipped');
    final dataCsv = rawData - skipped;
    diagnostics.add('Reveos DATA CSV: $dataCsv');
    diagnostics.add('Reveos EVENT válidos: ${eventRows.length}');
    diagnostics.add('Reveos TRACE válidos: ${traces.length}');
    diagnostics.add('Reveos TOTAL CSV: ${dataCsv + eventRows.length + traces.length}');
    return DlogDecodeResult(ok:records.isNotEmpty,sourcePath:sourcePath,gzipOffset:gzipOffset,decompressedSize:decompressedSize,payloadSize:payload.length,records:records,diagnostics:diagnostics,timestampInfo:_TimestampInfo(mode:base==null?TimestampMode.none:TimestampMode.reveosSecondsNanoseconds,dlogStart:base,diagnostics:const []),originalHeader:reveosCsvColumns,machine:DlogMachine.reveos,machineInfo:_extractMachineInfo(input,payload,DlogMachine.reveos,gzipOffset),originalBytes:input);
  }

  static bool _reveosHasCompleteGzipTrailer(Uint8List input, int gzipOffset, int decompressedSize) {
    if (gzipOffset < 0 || input.length - gzipOffset < 18) return false;
    // RFC 1952: ISIZE son los ultimos 4 bytes del miembro GZIP, little-endian.
    // En los DLOG Reveos truncados esos bytes no contienen el tamano descomprimido.
    final n = input.length;
    final isize = input[n-4] | (input[n-3] << 8) | (input[n-2] << 16) | (input[n-1] << 24);
    return (isize & 0xFFFFFFFF) == (decompressedSize & 0xFFFFFFFF);
  }

  static double _reveosEofDouble(int ns, int fieldId, int typeCode) {
    // Representacion observada en el exportador nativo al faltar EOF_RECORD:
    // [nanoseconds:u32 BE][fieldId:u16 BE][type:u16 BE], interpretada como double BE.
    final bd = ByteData(8);
    bd.setUint32(0, ns, Endian.big);
    bd.setUint16(4, fieldId, Endian.big);
    bd.setUint16(6, typeCode, Endian.big);
    return bd.getFloat64(0, Endian.big);
  }

  static String _formatReveosEofDouble(double v) {
    // El CSV nativo usa E mayuscula para este valor de EOF corrupto/sintetico.
    return v.toString().replaceAll('e', 'E');
  }

  static _ReveosData? _readReveosData(Uint8List d,int p) {
    if(p+18>d.length || d[p]!=4 || d[p+1]!=0x55) return null;
    final ns=_u32(d,p+6); if(ns>=1000000000) return null;
    final fam=d.sublist(p+10,p+16);
    const fs=<String>{'108,0,0,0,0,0','90,4,0,0,0,0','18,5,0,0,0,0','109,5,0,0,0,0','126,5,0,0,0,0'};
    if(!fs.contains(fam.join(','))) return null;
    final count=_u16(d,p+16); if(count>2000) return null;
    var q=p+18; final m=<int,Uint8List>{};
    for(var i=0;i<count;i++) { if(q+4>d.length)return null; final len=_u16(d,q), id=_u16(d,q+2); q+=4; if(len>65535||q+len>d.length)return null; m[id]=Uint8List.fromList(d.sublist(q,q+len)); q+=len; }
    return _ReveosData(p,q,_u32(d,p+2),ns,m);
  }

  static Object? _decodeReveosValue(Uint8List r) {
    if(r.isEmpty) return '';
    var printable=true; for(final b in r) if(b!=0 && (b<32||b>126)) {printable=false;break;}
    if(printable && r.any((b)=>b>=32&&b<=126)) return utf8.decode(r,allowMalformed:true);
    final bd=ByteData.sublistView(r);
    if(r.length==8) { final v=bd.getFloat64(0,Endian.little); if(v.isFinite)return v; }
    if(r.length==4) { final f=bd.getFloat32(0,Endian.little); final u=bd.getUint32(0,Endian.little); if(f.isFinite && (f==0 || f.abs()>=1e-20) && f.abs()<1e12) return f; return u; }
    if(r.length==2)return bd.getUint16(0,Endian.little); if(r.length==1)return r[0];
    return _hex(r);
  }
  // Reveos no puede decodificarse sólo por longitud: varios int32 positivos
  // forman bytes ASCII imprimibles (p.ej. 120 = 78 00 00 00), y el parser
  // genérico anterior los confundía con texto. Estos IDs tienen tipo conocido.
  static const Set<int> _reveosSignedInt32 = <int>{
    0x006E,0x006F,0x0467,
    0x04E0,0x04E1,0x04E2,0x04E3,0x04E4,0x04E7,0x0504,
  };

  static const Set<int> _reveosFloat32 = <int>{
    0x0463,0x0464,0x0465,0x0466,0x04E8,0x04F5,0x04F6,0x04F7,0x04FB,
    0x050E,0x050F,0x0510,0x0511,
  };

  static const Set<int> _reveosFloat64 = <int>{
    0x04E5,0x04E6,0x04F3,0x04F4,
  };

  static Object? _decodeReveosFieldValue(int id, Uint8List r) {
    if (r.isEmpty) return '';
    // SequenceState is a fixed 50-byte char buffer. The native Reveos CSV
    // preserves an all-NUL initial buffer instead of rendering it as hex.
    if (id == 0x006D && r.every((b) => b == 0)) {
      return String.fromCharCodes(r);
    }
    final bd=ByteData.sublistView(r);
    if (_reveosSignedInt32.contains(id) && r.length==4) {
      return bd.getInt32(0,Endian.little);
    }
    if (_reveosFloat32.contains(id) && r.length==4) {
      return bd.getFloat32(0,Endian.little);
    }
    if (_reveosFloat64.contains(id) && r.length==8) {
      return bd.getFloat64(0,Endian.little);
    }
    return _decodeReveosValue(r);
  }

  static String _stripNumericZeros(String s) {
    if (s.contains('e') || s.contains('E')) return s;
    if (!s.contains('.')) return s;
    while (s.endsWith('0')) s=s.substring(0,s.length-1);
    if (s.endsWith('.')) s=s.substring(0,s.length-1);
    if (s=='-0') return '0';
    return s;
  }

  static const Set<int> _reveosOffWhenZero = <int>{
    // Calibration state fields are exported by Reveos as Off/On, not 0/1.
    0x0468,0x0469,0x0477,0x0478,0x0486,0x0487,0x0495,0x0496,
    0x0513,0x0515,0x0517,0x0519,0x051B,0x051D,0x051F,0x0521,
  };

  static String _formatReveosScientific7(double v) {
    // El logger Reveos usa 7 cifras significativas para estos float32 y,
    // para magnitudes menores que 1e-4, notación científica con E mayúscula
    // y exponente de al menos dos dígitos (por ejemplo 7.875002E-05).
    var s = v.toStringAsExponential(6);
    final parts = s.split('e');
    var mantissa = _stripNumericZeros(parts[0]);
    final exp = int.parse(parts[1]);
    final sign = exp < 0 ? '-' : '+';
    final digits = exp.abs().toString().padLeft(2, '0');
    return '${mantissa}E$sign$digits';
  }

  static String _formatReveosFieldValue(int id, Object? v) {
    if(v==null)return '';
    if (_reveosOffWhenZero.contains(id)) {
      if ((v is num && v == 0) || v.toString() == '0') return 'Off';
      if ((v is num && v == 1) || v.toString() == '1') return 'On';
    }
    if (id == 0x0504 && v is num) {
      return '0X${v.toInt().toRadixString(16).toUpperCase()}';
    }
    if ({0x0514,0x0516,0x0518,0x051A,0x051C,0x051E,0x0520,0x0522}.contains(id) && v.toString() == 'Off') {
      return '0';
    }
    if (id == 0x006E && v is num) return v.toDouble().toStringAsFixed(3);
    if(v is double) {
      return v.toString();
    }
    return v.toString();
  }

  static String _formatReveosValue(Object? v) { if(v==null)return ''; return v.toString(); }

  static DateTime? _reveosStartDateTime(Uint8List input) {
    // Reveos guarda el inicio del DLOG en la cabecera binaria inmediatamente
    // antes del texto "control":
    //   [day:u8][month:u8][year:u16 LE][hour:u8][minute:u8][second:u8][weekday:u8]
    // Ejemplo real:
    //   03 0C E9 07 0D 0C 03 07 -> 2025-12-03 13:12:03
    // No dependemos del CSV ni del nombre del archivo.
    const control = <int>[0x63,0x6F,0x6E,0x74,0x72,0x6F,0x6C];
    for (var p = 8; p + control.length <= input.length; p++) {
      var match = true;
      for (var i = 0; i < control.length; i++) {
        if (input[p + i] != control[i]) { match = false; break; }
      }
      if (!match) continue;
      // En la cabecera real hay un byte NUL entre los 8 bytes de fecha/hora
      // y la palabra "control":
      // 03 0C E9 07 0D 0C 03 07 00 63 6F 6E 74 72 6F 6C
      //                                ^^
      // Por eso el bloque temporal comienza 9 bytes antes de "control".
      final q = p - 9;
      if (q < 0 || input[q + 8] != 0x00) continue;
      final day = input[q];
      final month = input[q + 1];
      final year = input[q + 2] | (input[q + 3] << 8);
      final hour = input[q + 4];
      final minute = input[q + 5];
      final second = input[q + 6];
      if (year >= 2000 && year <= 2200 && month >= 1 && month <= 12 &&
          day >= 1 && day <= 31 && hour <= 23 && minute <= 59 && second <= 59) {
        return DateTime(year, month, day, hour, minute, second);
      }
    }
    return null;
  }

  static Map<int,String> _reveosEventDictionary(Uint8List d) {
    final out=<int,String>{};
    for(var p=0;p+20<d.length;p++) { if(d[p]!=1||d[p+1]!=0x55)continue; final ns=_u32(d,p+6); if(ns>=1000000000)continue; final id=_u16(d,p+10); final len=_u16(d,p+16); if(len<=0||len>128||p+18+len>d.length)continue; final b=d.sublist(p+18,p+18+len); if(b.every((x)=>x>=32&&x<=126)) out[id]=ascii(b); }
    return out;
  }

  static List<Dlog022eRecord> _readReveosEvents(Uint8List d,Map<int,String> names,DateTime? base,int startIndex) {
    final out=<Dlog022eRecord>[]; var ix=startIndex;
    for(var p=0;p+20<d.length;p++) { if(d[p]!=1||d[p+1]!=0x55)continue; final ns=_u32(d,p+6); if(ns>=1000000000)continue; final id=_u16(d,p+10), len=_u16(d,p+16); if(len<=0||len>128||p+18+len>d.length)continue; final b=d.sublist(p+18,p+18+len); if(!b.every((x)=>x>=32&&x<=126))continue; final name=ascii(b); final r=Dlog022eRecord(index:ix++,offset:p,length:18+len,raw:Uint8List(0),fields:const [],asciiRatio:1,traceMarkers:0,printableText:name); r.classification=DlogRecordClass.trace; r.traceCategory=name; r.traceNode=name; r.traceMessage=null; if(base!=null)r.timestamp=base.add(Duration(seconds:_u32(d,p+2),microseconds:ns~/1000)); out.add(r); } return out;
  }

  static List<Dlog022eRecord> _readReveosTraces(Uint8List d,Map<int,String> names,DateTime? base,int startIndex) {
    final starts=<int>[];
    for(var p=0;p+30<d.length;p++) {
      if(d[p]!=3||d[p+1]!=0x55) continue;
      final ns=_u32(d,p+6); if(ns>=1000000000) continue;
      final fl=_u16(d,p+20); if(fl>256||p+24+fl+5>d.length) continue;
      final fb=d.sublist(p+24,p+24+fl);
      if(!fb.every((x)=>x>=32&&x<=126)) continue;
      final tag=p+24+fl;
      if(!((d[tag]==0x10||d[tag]==0x20)&&d[tag+1]==0x40&&d[tag+2]==0x05)) continue;
      starts.add(p);
    }
    final out=<Dlog022eRecord>[]; var ix=startIndex;
    for(var n=0;n<starts.length;n++) {
      final p=starts[n], limit=n+1<starts.length?starts[n+1]:d.length;
      final ns=_u32(d,p+6), id=_u16(d,p+10), fl=_u16(d,p+20), tag=p+24+fl;
      var q=tag+5;
      final sb=StringBuffer();
      // Keep TRACE token boundaries as well as the rendered text. Reveos uses
      // those boundaries for DATALOG_RESERVED key/value formatting.
      final traceTokens=<String>[];
      int? fixedPrecision;
      int? numericFormat = d[tag]; // TRACE tag: 0x10=decimal, 0x20=hex; 0x64 may change it
      while(q<limit) {
        if(q+1<limit&&d[q]==0xFE&&d[q+1]==0x55) break;
        final t=d[q++];
        if(t==7) {
          if(q+2>limit)break; final l=_u16(d,q); q+=2; if(q+l>limit)break;
          // Reveos preserves quote characters carried by string tokens.
          // They are part of the native verbose payload (e.g. FileName="...").
          final s=utf8.decode(d.sublist(q,q+l),allowMalformed:true);
          sb.write(s); traceTokens.add(s);
          q+=l;
        } else if(t==1) {
          if(q>=limit)break; final s=String.fromCharCode(d[q++]); sb.write(s); traceTokens.add(s);
        } else if(t==5||t==3||t==4||t==6) {
          if(q+4>limit)break;
          final bd=ByteData.sublistView(d,q,q+4);
          final signed=bd.getInt32(0,Endian.little);
          final unsigned=bd.getUint32(0,Endian.little);
          q+=4;
          final String rendered;
          if(numericFormat==0x20) {
            // TRACE tag 0x20 or 0x64 0x20 0x40: hexadecimal presentation.
            rendered=unsigned.toRadixString(16);
          } else if(t==6) {
            // Reveos token 0x06 is an unsigned 32-bit decimal value.
            rendered=unsigned.toString();
          } else {
            // Tokens 0x03/0x04/0x05 use signed decimal presentation.
            rendered=signed.toString();
          }
          sb.write(rendered); traceTokens.add(rendered);
          // 0x64 changes the numeric presentation mode and remains active
          // until another 0x64 changes it. Reveos uses one modifier for
          // several following numeric arguments (e.g. board/hardware/FPGA).
        } else if(t==8) {
          if(q+4>limit)break; final v=ByteData.sublistView(d,q,q+4).getFloat32(0,Endian.little); q+=4;
          final s=v.toStringAsFixed(fixedPrecision ?? 5); sb.write(s); traceTokens.add(s); fixedPrecision=null;
        } else if(t==9) {
          if(q+8>limit)break; final v=ByteData.sublistView(d,q,q+8).getFloat64(0,Endian.little); q+=8;
          final s=v.toStringAsFixed(fixedPrecision ?? 5); sb.write(s); traceTokens.add(s); fixedPrecision=null;
        } else if(t==10) {
          if(q>=limit)break; final s=d[q++]!=0?'true':'false'; sb.write(s); traceTokens.add(s);
        } else if(t==0x64) {
          // Reveos numeric presentation modifier: 64 <mode> 40.
          // 0x10 requests decimal; 0x20 requests hexadecimal for the next
          // numeric argument. Preserve the state until that argument arrives.
          if(q+2>limit)break;
          numericFormat=d[q];
          q+=2;
        } else if(t==0x65) {
          // Precision modifier applies to the next float/double token.
          if(q>=limit)break; fixedPrecision=d[q++];
        } else break;
      }
      // Native Reveos CSV TRACE formatting. The exporter always emits exactly
      // two leading spaces. Inside verbose text it removes quotes/control CR/LF
      // and converts commas to spaces (avoids CSV delimiter collisions).
      String cleanTracePart(String s) => s
          .replaceAll('"','')
          .replaceAll('\r','')
          .replaceAll('\n','')
          .replaceAll(',', ' ');

      String traceText;
      if(traceTokens.length>=2 && traceTokens[0]=='DATALOG_RESERVED') {
        // Structured records are token based, not concatenated text:
        // DATALOG_RESERVED, EVENT, KEY, VALUE, KEY, VALUE ...
        // -> EVENT {KEY} VALUE {KEY} VALUE ... {END}
        final eventName=cleanTracePart(traceTokens[1]);
        final b=StringBuffer(eventName);
        // OPERATOR_RESPONSE is not a pure KEY/VALUE sequence. The token
        // ')' is a standalone structural key, so stepping by two from token 2
        // shifts every following pair. Native layout:
        // BUTTON_ID,0, RESPONSE_STATE,none, (,1, ),
        // EVENT_ID,1, NODE_ID,0, MODULE_LEVEL,1, ALARM_ID,111.
        if(eventName=='OPERATOR_RESPONSE') {
          var i=2;
          while(i<traceTokens.length) {
            final key=cleanTracePart(traceTokens[i]);
            if(key==')') {
              b.write(' {)}');
              i++;
              continue;
            }
            if(key=='EVENT_ID') {
              b.write(' ');
              // From EVENT_ID onward Reveos emits compact KEYVALUE pairs.
              while(i<traceTokens.length) {
                final compactKey=cleanTracePart(traceTokens[i]);
                if(i+1>=traceTokens.length) break;
                final compactValue=cleanTracePart(traceTokens[i+1]);
                b.write(compactKey);
                b.write(compactValue);
                i+=2;
              }
              break;
            }
            final value=i+1<traceTokens.length?cleanTracePart(traceTokens[i+1]):'';
            b.write(' {$key} ');
            b.write(value);
            i+=2;
          }
        } else {
          for(var i=2;i<traceTokens.length;i+=2) {
            final key=cleanTracePart(traceTokens[i]);
            final value=i+1<traceTokens.length?cleanTracePart(traceTokens[i+1]):'';
            b.write(' {$key} ');
            b.write(value);
          }
        }
        b.write(' {END}');
        traceText=b.toString();
      } else {
        traceText=cleanTracePart(sb.toString());
      }
      // The fixed prefix supplies the only leading whitespace; trailing
      // whitespace is not written by the native exporter.
      traceText=traceText.replaceFirst(RegExp(r'^\s+'), '');
      traceText=traceText.replaceFirst(RegExp(r'\s+$'), '');

      final msg='  $traceText';
      final r=Dlog022eRecord(index:ix++,offset:p,length:limit-p,raw:Uint8List(0),fields:const [],asciiRatio:0,traceMarkers:1,printableText:msg);
      r.classification=DlogRecordClass.trace; r.traceCategory=id==0?'CriticalOutput':(names[id]??''); r.traceNode='Node:'; r.traceMessage=msg;
      if(base!=null)r.timestamp=base.add(Duration(seconds:_u32(d,p+2),microseconds:ns~/1000)); out.add(r);
    }
    return out;
  }

  /// Optia records do not have a fixed first uint16.  The two bytes before
  /// 5A 01/02 00 02 / 5A 01/02 00 01 vary by record/source.  V61 incorrectly
  /// hard-coded them as 8E 00, which only matched a definition record.
  static List<int> _findOptiaRecordStarts(Uint8List data, List<int> signature) {
    final out = <int>[];
    if (signature.isEmpty || data.length < signature.length + 2) return out;
    for (var i = 2; i <= data.length - signature.length; i++) {
      var ok = true;
      for (var j = 0; j < signature.length; j++) {
        if (data[i + j] != signature[j]) { ok = false; break; }
      }
      if (ok) out.add(i - 2);
    }
    return out;
  }

  /// Lightweight Optia image index. This does NOT reconstruct pixels.
  /// A real stored image is identified by binary chunk records beginning
  /// `IM 01 00`, not by TRACE/config strings mentioning images.
  ///
  /// Offsets refer to the decoded (gunzip + XOR) payload and are diagnostic;
  /// UI code should use imageId to lazily locate/reconstruct the image from
  /// originalBytes only when the IMAGES tab/image is opened.
  static List<DlogImageRef> _indexOptiaImages(Uint8List payload) {
    final chunksById = <int, List<DlogImageChunkRef>>{};
    final dimensions = <int, (int, int)>{};

    for (var i = 0; i + 12 <= payload.length; i++) {
      if (payload[i] != 0x49 || payload[i + 1] != 0x4D ||
          payload[i + 2] != 0x01 || payload[i + 3] != 0x00) continue;

      final imageId = _u32(payload, i + 4);
      final chunkIndex = _u32(payload, i + 8);
      if (imageId <= 0 || chunkIndex < 0 || chunkIndex > 100000) continue;

      // First chunk carries height/width before its pixel data.
      if (chunkIndex == 0 && i + 20 <= payload.length) {
        final height = _u32(payload, i + 12);
        final width = _u32(payload, i + 16);
        if (width > 0 && width <= 8192 && height > 0 && height <= 8192) {
          dimensions[imageId] = (width, height);
        }
      }

      (chunksById[imageId] ??= <DlogImageChunkRef>[]).add(
        DlogImageChunkRef(index: chunkIndex, payloadOffset: i),
      );
    }

    final out = <DlogImageRef>[];
    for (final entry in chunksById.entries) {
      final chunks = entry.value..sort((a, b) => a.index.compareTo(b.index));
      if (chunks.isEmpty || chunks.first.index != 0) continue;
      // Require a contiguous chunk sequence. This rejects accidental "IM" text.
      var contiguous = true;
      for (var n = 0; n < chunks.length; n++) {
        if (chunks[n].index != n) { contiguous = false; break; }
      }
      if (!contiguous) continue;
      final dim = dimensions[entry.key];
      out.add(DlogImageRef(
        imageId: entry.key,
        width: dim?.$1,
        height: dim?.$2,
        chunkCount: chunks.length,
        chunks: List.unmodifiable(chunks),
      ));
    }
    out.sort((a, b) => a.chunks.first.payloadOffset.compareTo(b.chunks.first.payloadOffset));
    return List.unmodifiable(out);
  }


  /// Optia Gen2 APC image chunks.
  ///
  /// Gen2 stores them as:
  ///   FE 55 <sec:u32> <ns:u32>
  ///   F0 55 <recordLength:u32>
  ///   49 4D 01 00 <imageId:u32> <chunkIndex:u32> ...
  ///
  /// As with the official Gen1 exporter, every stored binary image chunk is
  /// represented by one native CSV/event row. Pixel reconstruction remains
  /// lazy; this method only creates the lightweight event row.
  static List<Dlog022eRecord> _decodeOptiaGen2ImageRows(
      Uint8List data, int startIndex, DateTime? base) {
    final out = <Dlog022eRecord>[];
    var ix = startIndex;

    for (var p = 0; p + 12 <= data.length; p++) {
      if (data[p] != 0x49 ||
          data[p + 1] != 0x4D ||
          data[p + 2] != 0x01 ||
          data[p + 3] != 0x00) {
        continue;
      }

      final imageId = _u32(data, p + 4);
      final chunk = _u32(data, p + 8);

      // Reject accidental "IM" byte sequences.
      if (imageId <= 0 || chunk < 0 || chunk > 100000) continue;

      // In Gen2 the IM record is normally:
      // FE55 timestamp + F055 length + IM0100...
      // Keep a bounded backwards search so the parser is tolerant of
      // additional record metadata.
      var eventStart = -1;
      for (var q = p - 1; q >= math.max(0, p - 4096); q--) {
        if (q + 10 > data.length ||
            data[q] != 0xFE ||
            data[q + 1] != 0x55) {
          continue;
        }
        final sec = _u32(data, q + 2);
        final ns = _u32(data, q + 6);
        if (sec <= 86400 * 7 && ns < 1000000000) {
          eventStart = q;
          break;
        }
      }
      if (eventStart < 0) continue;

      final r = Dlog022eRecord(
        index: ix++,
        offset: eventStart,
        length: 12,
        raw: Uint8List(0),
        fields: const [],
        asciiRatio: 0,
        traceMarkers: 0,
        printableText: '',
      );
      r.classification = DlogRecordClass.trace;
      r.optiaExtraColumn =
          'Binary Record Observed_APC Image_1_${imageId}_$chunk';

      if (base != null) {
        r.timestamp = base.add(Duration(
          seconds: _u32(data, eventStart + 2),
          microseconds: _u32(data, eventStart + 6) ~/ 1000,
        ));
      }
      out.add(r);
    }
    return out;
  }

  static DlogDecodeResult _decodeOptiaPayload({
    required Uint8List payload,
    required Uint8List input,
    required String? sourcePath,
    required int gzipOffset,
    required int decompressedSize,
    required List<int> starts,
    required List<String> diagnostics,
  }) {
    diagnostics.add('Equipo detectado: Optia.');
    final imageRefs = _indexOptiaImages(payload);
    diagnostics.add('Optia imágenes binarias indexadas: ${imageRefs.length}');
    diagnostics.add('Optia hasImages: ${imageRefs.isNotEmpty}');
    diagnostics.add('Registros Optia candidatos: ${starts.length}');

    final base = _optiaStartDateTime(input, sourcePath);
    if (base != null) {
      diagnostics.add('Inicio temporal Optia: ${base.toIso8601String()}');
    } else {
      diagnostics.add('Optia: no se pudo determinar la hora inicial; timestamp quedará vacío.');
    }

    final records = <Dlog022eRecord>[];
    var index = 0;

    // Gen2 has both 5A 01 00 02 and 5A 02 00 02 Control streams.
    final controlStarts = <int>{
      ...starts,
      ..._findOptiaRecordStarts(payload, optiaGen2ControlMarker2),
    }.toList()..sort();

    diagnostics.add('Registros Optia Control combinados 5A01/5A02: ${controlStarts.length}');

    for (final start in controlStarts) {
      final r = _decodeOptiaRecord(payload, start, index, base);
      if (r != null) {
        records.add(r);
        index++;
      }
    }

    final safetyStarts = <int>{
      ..._findOptiaRecordStarts(payload, optiaSafetyMarker),
      ..._findOptiaRecordStarts(payload, optiaGen2SafetyMarker2),
    }.toList()..sort();
    diagnostics.add('Registros Optia Safety candidatos 5A01/5A02: ${safetyStarts.length}');
    var safetyValid = 0;
    for (final start in safetyStarts) {
      final r = _decodeOptiaSafetyRecord(payload, start, index, base);
      if (r != null) {
        records.add(r);
        index++;
        safetyValid++;
      }
    }
    diagnostics.add('Registros Optia Safety válidos: $safetyValid');

    // TRACE Optia: prefijo 03 55 + seconds(uint32) + nanoseconds(uint32).
    // En el archivo de referencia hay 570 de estos registros; sumados a
    // 7 MAIN + 2 SAFETY reproducen las 579 filas de datos del CSV original.
    final traceRecords = _decodeOptiaTraceRecords(payload, index, base);
    records.addAll(traceRecords);
    index += traceRecords.length;
    diagnostics.add('Registros Optia TRACE válidos: ${traceRecords.length}');

    // Gen2 APC binary chunks are native event/CSV rows too.  Keep image
    // reconstruction lazy, but do not remove the chunk rows from the event
    // stream.
    final imageRows = _decodeOptiaGen2ImageRows(payload, index, base);
    records.addAll(imageRows);
    index += imageRows.length;
    diagnostics.add('Registros Optia Gen2 IM01: ${imageRows.length}');

    // IMPORTANTE OPTIA: el CSV original conserva el orden físico del DLOG.
    // Los nodos tienen relojes relativos independientes y por eso ordenar por
    // timestamp altera el orden original (por ejemplo, Node:a500001 puede
    // volver a tiempos anteriores después de Node:a500002).
    records.sort((a, b) => a.offset.compareTo(b.offset));
    for (var i=0;i<records.length;i++) records[i].indexOverride = i;

    DateTime? first;
    for (final r in records) {
      if (r.timestamp == null) continue;
      first ??= r.timestamp;
      r.elapsedMs = r.timestamp!.difference(first!).inMilliseconds;
    }

    diagnostics.add('Registros Optia válidos: ${records.length}');
    diagnostics.add('Campos Optia exportables: ${records.fold<int>(0,(s,r)=>s+r.fields.length)}');

    final ti = _TimestampInfo(
      mode: base == null ? TimestampMode.none : TimestampMode.optiaSecondsNanoseconds,
      dlogStart: base,
      diagnostics: const [],
    );

    return DlogDecodeResult(
      ok: records.isNotEmpty,
      sourcePath: sourcePath,
      gzipOffset: gzipOffset,
      decompressedSize: decompressedSize,
      payloadSize: payload.length,
      records: records,
      diagnostics: diagnostics,
      timestampInfo: ti,
      originalHeader: optiaCsvColumns,
      machine: DlogMachine.optia,
      machineInfo: _extractMachineInfo(input, payload, DlogMachine.optia, gzipOffset),
      originalBytes: input,
      imageRefs: imageRefs,
    );
  }

  static Dlog022eRecord? _decodeOptiaRecord(
    Uint8List data, int offset, int index, DateTime? base) {
    // Native Optia DATA rows are framed by 04 55 + sec/ns immediately
    // before the two-byte family and the 5A stream marker. Requiring the
    // envelope rejects marker-like byte sequences inside payloads.
    if (offset < 10 || offset + 8 > data.length) return null;
    if (data[offset - 10] != 0x04 || data[offset - 9] != 0x55) return null;
    // Control Gen2: 5A 01/02 00 02.
    if (data[offset + 2] != 0x5A ||
        (data[offset + 3] != 0x01 && data[offset + 3] != 0x02) ||
        data[offset + 4] != 0x00 ||
        data[offset + 5] != 0x02) {
      return null;
    }
    final count = _u16(data, offset + 6);
    if (count <= 0 || count > 500) return null;
    var pos = offset + 8;
    final fields = <DlogField>[];
    for (var n=0;n<count;n++) {
      if (pos + 4 > data.length) return null;
      final len = _u16(data,pos);
      final id = _u16(data,pos+2);
      final fieldOffset = pos-offset;
      pos += 4;
      if (len < 0 || len > 4096 || pos + len > data.length) return null;
      final raw = Uint8List.fromList(data.sublist(pos,pos+len));
      pos += len;
      final def = optiaFieldDefinitions[id];
      if (def == null) continue;
      final value = _decodeOptiaValue(raw);
      fields.add(DlogField(
        relativeOffset: fieldOffset, id:id, name:def.name, typeCode:def.typeCode,
        length:len, value:value, formattedValue:_formatValue(def,value),
        rawHex:_hex(raw), trailer:0,
      ));
    }
    final raw = Uint8List.fromList(data.sublist(offset,pos));
    final r = Dlog022eRecord(
      index:index, offset:offset, length:raw.length, raw:raw, fields:fields,
      asciiRatio:_asciiRatio(raw), traceMarkers:0, printableText:_extractPrintable(raw),
    );
    r.classification = DlogRecordClass.procedure;
    if (base != null) {
      final sec = _u32(data,offset-8);
      final ns = _u32(data,offset-4);
      if (ns < 1000000000) {
        r.timestamp = base.add(Duration(seconds:sec,microseconds:ns ~/ 1000));
      }
    }
    return r;
  }

  static Dlog022eRecord? _decodeOptiaSafetyRecord(
    Uint8List data, int offset, int index, DateTime? base) {
    // Same native DATA envelope used by the official Optia exporter.
    if (offset < 10 || offset + 8 > data.length) return null;
    if (data[offset - 10] != 0x04 || data[offset - 9] != 0x55) return null;
    // Safety Gen2: 5A 01/02 00 01.
    if (data[offset + 2] != 0x5A ||
        (data[offset + 3] != 0x01 && data[offset + 3] != 0x02) ||
        data[offset + 4] != 0x00 ||
        data[offset + 5] != 0x01) {
      return null;
    }
    final count = _u16(data, offset + 6);
    if (count <= 0 || count > 256) return null;
    var pos = offset + 8;
    final fields = <DlogField>[];
    for (var n=0;n<count;n++) {
      if (pos + 4 > data.length) return null;
      final len = _u16(data,pos);
      final id = _u16(data,pos+2);
      final fieldOffset = pos-offset;
      pos += 4;
      if (len <= 0 || len > 1024 || pos + len > data.length) return null;
      final raw = Uint8List.fromList(data.sublist(pos,pos+len));
      pos += len;
      final def = optiaSafetyFieldDefinitions[id];
      if (def == null) continue;
      final value = _decodeOptiaValue(raw);
      fields.add(DlogField(
        relativeOffset:fieldOffset,id:id,name:def.name,typeCode:def.typeCode,
        length:len,value:value,formattedValue:_formatValue(def,value),
        rawHex:_hex(raw),trailer:0,
      ));
    }
    // Gen2 family 0x006D is predominantly an internal safety frame and is
    // not emitted as a CSV row by the official exporter. The one observed
    // exportable 0x006D frame carries five mapped safety values.
    final family = _u16(data, offset);
    if (family == 0x006D && fields.length < 5) return null;

    final raw = Uint8List.fromList(data.sublist(offset,pos));
    final r = Dlog022eRecord(
      index:index,offset:offset,length:raw.length,raw:raw,fields:fields,
      asciiRatio:_asciiRatio(raw),traceMarkers:0,printableText:_extractPrintable(raw),
    );
    r.classification = DlogRecordClass.procedure;
    if (base != null) {
      final sec = _u32(data,offset-8);
      final ns = _u32(data,offset-4);
      if (ns < 1000000000) {
        r.timestamp = base.add(Duration(seconds:sec,microseconds:ns ~/ 1000));
      }
    }
    return r;
  }

  static List<Dlog022eRecord> _decodeOptiaTraceRecords(
    Uint8List data, int startIndex, DateTime? base) {
    final result = <Dlog022eRecord>[];
    var index = startIndex;

    for (var start = 0; start + 14 < data.length; start++) {
      // Optia Gen1/Gen2 TRACE:
      //   03 55 = typed trace
      //   02 55 = Gen2 plain-text trace (observed on a520001)
      final eventType = data[start];
      if ((eventType != 0x03 && eventType != 0x02) ||
          data[start + 1] != 0x55) continue;

      final sec = _u32(data, start + 2);
      final ns = _u32(data, start + 6);
      if (sec > 86400 * 7 || ns >= 1000000000) continue;

      // Node marker: 5A GG 00 NN
      // GG=01 => a51000N, GG=02 => a52000N, GG=00 => legacy a50000N.
      var nodeMarker = -1;
      final nodeSearchEnd = math.min(data.length - 4, start + 256);
      for (var p = start + 10; p <= nodeSearchEnd; p++) {
        if (data[p] == 0x5A &&
            (data[p + 1] == 0x00 ||
             data[p + 1] == 0x01 ||
             data[p + 1] == 0x02) &&
            data[p + 2] == 0x00 &&
            data[p + 3] >= 1 && data[p + 3] <= 9) {
          nodeMarker = p;
          break;
        }
      }
      if (nodeMarker < 0) continue;

      final nodeGroup = data[nodeMarker + 1];
      final nodeNo = data[nodeMarker + 3];
      final node = 'Node:a5${nodeGroup}000$nodeNo';
      final recordEnd = _findNextOptiaEventStart(data, start + 10);

      // ----------------------------------------------------------
      // Gen2 02 55: texto plano. Después del marker hay metadata,
      // nombre de fuente y mensaje ASCII terminado en NUL/LF. El mensaje
      // es la cadena imprimible más larga del evento.
      // ----------------------------------------------------------
      if (eventType == 0x02) {
        String message = '';
        var q = nodeMarker + 4;
        while (q < recordEnd) {
          while (q < recordEnd && (data[q] < 32 || data[q] > 126)) q++;
          final begin = q;
          while (q < recordEnd && data[q] >= 32 && data[q] <= 126) q++;
          if (q > begin) {
            final candidate = ascii(Uint8List.fromList(data.sublist(begin, q)))
                .replaceAll(',', ' ')
                .replaceAll('"', '')
                .trim();
            if (candidate.length > message.length) message = candidate;
          }
        }
        if (message.isEmpty) continue;

        final raw = Uint8List.fromList(data.sublist(start, recordEnd));
        final r = Dlog022eRecord(
          index: index++, offset: start, length: raw.length, raw: raw,
          fields: const [], asciiRatio: _asciiRatio(raw), traceMarkers: 1,
          printableText: message,
        );
        r.classification = DlogRecordClass.trace;
        r.traceNode = node;
        r.traceMessage = message;
        if (base != null) {
          r.timestamp = base.add(Duration(seconds: sec, microseconds: ns ~/ 1000));
        }
        result.add(r);
        continue;
      }

      // ----------------------------------------------------------
      // 03 55: TRACE tipado.
      // ----------------------------------------------------------
      var message = '';
      var firstFragment = -1;
      final firstSearchEnd = math.min(recordEnd, nodeMarker + 1024);
      for (var p = nodeMarker + 4; p + 3 <= firstSearchEnd; p++) {
        if (data[p] != 0x07) continue;
        final len = _u16(data, p + 1);
        if (len <= 0 || len > 512 || p + 3 + len > firstSearchEnd) continue;
        final bytes = Uint8List.fromList(data.sublist(p + 3, p + 3 + len));
        if (!_isOptiaTraceText(bytes)) continue;
        firstFragment = p;
        message = _decodeOptiaTypedTraceMessage(data, p, recordEnd);
        break;
      }
      if (firstFragment < 0 || message.isEmpty) continue;

      // Gen1/Gen2 typed log header. Algunos Gen2 válidos no incluyen
      // 10 40 TT antes del primer 07; en ese caso el 07 ya contiene la
      // secuencia tipada completa y se conserva el mensaje obtenido arriba.
      var messageTag = -1;
      for (var p = nodeMarker + 4; p + 4 < firstFragment; p++) {
        if (data[p] == 0x10 &&
            data[p + 1] == 0x40 &&
            data[p + 2] >= 0x01 &&
            data[p + 2] <= 0x08) {
          messageTag = p;
        }
      }
      if (messageTag >= 0) {
        final typed = _decodeOptiaTypedTraceMessage(data, messageTag + 5, recordEnd);
        if (typed.isNotEmpty) message = typed;
      }
      if (message.isEmpty) continue;

      final end = math.min(data.length,
          firstFragment + 3 + _u16(data, firstFragment + 1) + message.length + 32);
      final raw = Uint8List.fromList(data.sublist(start, end));
      final r = Dlog022eRecord(
        index: index++, offset: start, length: raw.length, raw: raw,
        fields: const [], asciiRatio: _asciiRatio(raw), traceMarkers: 1,
        printableText: message,
      );
      r.classification = DlogRecordClass.trace;
      r.traceNode = node;
      r.traceMessage = message;
      if (base != null) {
        r.timestamp = base.add(Duration(seconds: sec, microseconds: ns ~/ 1000));
      }
      result.add(r);
    }
    return result;
  }

  static int _findNextOptiaEventStart(Uint8List data, int from) {
    for (var p = from; p + 10 <= data.length; p++) {
      // Todos los eventos Optia observados llevan <tipo> 55 sec:u32 ns:u32.
      if (data[p + 1] != 0x55) continue;
      const knownTypes = <int>{0xFE,0x03,0x02,0x01,0x07,0x06,0x08,0x04,0x05,0x09,0xF0};
      if (!knownTypes.contains(data[p])) continue;
      final sec = _u32(data, p + 2);
      final ns = _u32(data, p + 6);
      if (sec <= 86400 * 7 && ns < 1000000000) return p;
    }
    return data.length;
  }

  static Object? _decodeOptiaValue(Uint8List raw) {
    if (raw.isEmpty) return null;
    if (raw.length == 8) {
      final v = ByteData.sublistView(raw).getFloat64(0,Endian.little);
      if (v.isFinite) return v;
    }
    if (_isStrictAscii(raw)) return ascii(raw);
    return _decodeInteger(raw);
  }

  static bool _isStrictAscii(Uint8List raw) {
    if (raw.isEmpty) return false;
    for (final b in raw) { if (b < 32 || b > 126) return false; }
    return true;
  }

  // TRACE puede contener caracteres de control de formato que el CSV
  // original no conserva literalmente (p. ej. TAB/CR/LF). Para los
  // mensajes aceptamos ASCII imprimible más esos controles.
  static bool _isOptiaTraceText(Uint8List raw) {
    if (raw.isEmpty) return false;
    for (final b in raw) {
      if (b >= 32 && b <= 126) continue;
      if (b == 0x09 || b == 0x0A || b == 0x0D) continue;
      return false;
    }
    return true;
  }

  static String _decodeOptiaTraceText(Uint8List raw) {
    final out = StringBuffer();
    for (final b in raw) {
      // El exportador Optia aplana los controles dentro del verbose.
      if (b == 0x09 || b == 0x0A || b == 0x0D) continue;
      if (b >= 32 && b <= 126) out.writeCharCode(b);
    }
    return out.toString();
  }

  // Decodifica la secuencia tipada que usa Optia dentro del verbose.
  // Tipos confirmados en el DLOG estudiado:
  //   01 char, 03 int32, 04/05 uint32, 06 hex32,
  //   07 string, 09 double, 0A bool.
  // 0x65 <n> fija la precision del siguiente double.
  // 0x64 xx 40 es metadata de formato y no forma parte del texto.
  static String _decodeOptiaTypedTraceMessage(
      Uint8List data, int start, int scanEnd) {
    final tokens = <String>[];
    final kinds = <int>[]; // 7=string, 0=valor
    var q = start;
    var precision = 5;
    var radix = 10;

    void addString(String value) {
      // El exportador original aplana TAB/CR/LF y reemplaza comas por
      // espacios en el verbose.
      tokens.add(value.replaceAll(',', ' '));
      kinds.add(7);
    }

    void addValue(String value) {
      tokens.add(value);
      kinds.add(0);
    }

    while (q < scanEnd) {
      // 64 20 40 => hexadecimal; 64 10 40 => decimal.
      if (q + 2 < scanEnd && data[q] == 0x64 && data[q + 2] == 0x40) {
        radix = data[q + 1] == 0x20 ? 16 : 10;
        q += 3;
        continue;
      }
      if (q + 1 < scanEnd && data[q] == 0x65) {
        precision = data[q + 1].clamp(0, 12);
        q += 2;
        continue;
      }

      final type = data[q];
      if (type == 0x07) {
        if (q + 3 > scanEnd) break;
        final len = _u16(data, q + 1);
        if (len > 4096 || q + 3 + len > scanEnd) break;
        final raw = Uint8List.fromList(data.sublist(q + 3, q + 3 + len));
        if (len > 0 && !_isOptiaTraceText(raw)) break;
        addString(_decodeOptiaTraceText(raw));
        q += 3 + len;
        continue;
      }

      if (type == 0x01 && q + 2 <= scanEnd) {
        final c = data[q + 1];
        if (c != 0x22 && c >= 32 && c <= 126) addString(String.fromCharCode(c));
        q += 2;
        continue;
      }

      if ((type == 0x03 || type == 0x05) && q + 5 <= scanEnd) {
        final bd = ByteData.sublistView(data, q + 1, q + 5);
        final signed = bd.getInt32(0, Endian.little);
        final unsigned = bd.getUint32(0, Endian.little);
        addValue(radix == 16 ? unsigned.toRadixString(16) : signed.toString());
        q += 5;
        continue;
      }

      if ((type == 0x04 || type == 0x06) && q + 5 <= scanEnd) {
        final bd = ByteData.sublistView(data, q + 1, q + 5);
        final v = bd.getUint32(0, Endian.little);
        addValue(radix == 16 ? v.toRadixString(16) : v.toString());
        q += 5;
        continue;
      }

      if (type == 0x09 && q + 9 <= scanEnd) {
        final bd = ByteData.sublistView(data, q + 1, q + 9);
        final v = bd.getFloat64(0, Endian.little);
        if (!v.isFinite) break;
        addValue(v.toStringAsFixed(precision));
        precision = 5;
        q += 9;
        continue;
      }

      if (type == 0x0A && q + 2 <= scanEnd) {
        addValue(data[q + 1] == 0 ? 'false' : 'true');
        q += 2;
        continue;
      }

      break;
    }

    String result;
    if (tokens.length >= 2 &&
        kinds[0] == 7 && tokens[0] == 'DATALOG_RESERVED' && kinds[1] == 7) {
      // Mensajes estructurados del exportador Optia:
      // DATALOG_RESERVED, EVENT, KEY, VALUE, ...
      final b = StringBuffer(tokens[1]);
      for (var i = 2; i < tokens.length; i += 2) {
        b.write(' {${tokens[i]}} ');
        if (i + 1 < tokens.length) b.write(tokens[i + 1]);
      }
      b.write(' {END}');
      result = b.toString();
    } else {
      result = tokens.join();
    }

    return result.replaceAll('"', '').trim();
  }

  static DateTime? _optiaStartDateTime(Uint8List input, String? sourcePath) {
    // Optia guarda fecha/hora en la cabecera binaria anterior al GZIP.
    // En el archivo estudiado aparece:
    // TAOS 5A 00 00 02 DD MM YYYY(le) HH mm ss xx 00
    // Ej.: 1D 0A E9 07 13 07 18 -> 2025-10-29 19:07:24.
    final gzip = _findGzip(input);
    final headerEnd = gzip >= 0 ? gzip : math.min(input.length, 4096);
    const sig = [0x54,0x41,0x4F,0x53,0x5A,0x00,0x00,0x02]; // "TAOSZ\0\0\2"
    for (var i=0; i + sig.length + 7 <= headerEnd; i++) {
      var ok = true;
      for (var j=0;j<sig.length;j++) {
        if (input[i+j] != sig[j]) { ok=false; break; }
      }
      if (!ok) continue;
      final p = i + sig.length;
      final day = input[p];
      final month = input[p+1];
      final year = input[p+2] | (input[p+3] << 8);
      final hour = input[p+4];
      final minute = input[p+5];
      final second = input[p+6];
      if (year >= 2000 && year <= 2100 && month >= 1 && month <= 12 &&
          day >= 1 && day <= 31 && hour < 24 && minute < 60 && second < 60) {
        return DateTime(year,month,day,hour,minute,second);
      }
    }

    // Respaldo: buscar timestamp ASCII completo si otra revisión lo incluye.
    final prefixLen = math.min(input.length, 65536);
    final text = latin1.decode(input.sublist(0,prefixLen),allowInvalid:true);
    final m = RegExp(r'(20\d{2})(\d{2})(\d{2})[_ ](\d{2}):(\d{2}):(\d{2})').firstMatch(text);
    if (m != null) {
      return DateTime(int.parse(m.group(1)!),int.parse(m.group(2)!),int.parse(m.group(3)!),
        int.parse(m.group(4)!),int.parse(m.group(5)!),int.parse(m.group(6)!));
    }
    return sourcePath == null ? null : _dateFromFilename(sourcePath);
  }

  // ============================================================
  // GZIP
  // ============================================================

  static int _findGzip(Uint8List data) {
    for (var i = 0; i + 2 < data.length; i++) {
      if (data[i] == 0x1F &&
          data[i + 1] == 0x8B &&
          data[i + 2] == 0x08) {
        return i;
      }
    }

    return -1;
  }

  static Uint8List? _gunzip(
    Uint8List data,
    int offset,
  ) {
    try {
      final compressed = data.sublist(offset);

      final result = GZipDecoder().decodeBytes(
        compressed,
        verify: false, // Reveos puede terminar sin trailer GZIP completo.
      );

      return Uint8List.fromList(result);
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // XOR
  // ============================================================

  static Uint8List _xor(
    Uint8List data,
    int key,
  ) {
    final result = Uint8List(
      data.length,
    );

    for (var i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key;
    }

    return result;
  }

  // ============================================================
  // FIND
  // ============================================================

  static List<int> _findAll(
    Uint8List data,
    List<int> pattern,
  ) {
    final result = <int>[];

    if (pattern.isEmpty ||
        data.length < pattern.length) {
      return result;
    }

    for (
      var i = 0;
      i <= data.length - pattern.length;
      i++
    ) {
      var match = true;

      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }

      if (match) {
        result.add(i);
      }
    }

    return result;
  }

  // ============================================================
  // FIELD DEFINITIONS
  // ============================================================

  static final Map<int, DlogFieldDefinition> fieldDefinitions =
      _createFieldDefinitions();

  static Map<int, DlogFieldDefinition>
      _createFieldDefinitions() {
    final map = <int, DlogFieldDefinition>{};

    void add(
      int id,
      String name,
      int type,
      String format,
    ) {
      map[id] = DlogFieldDefinition(
        id: id,
        name: name,
        typeCode: type,
        format: format,
      );
    }

    // ----------------------------------------------------------
    // TIME
    // ----------------------------------------------------------

    add(616, 'AbsTime', 5, '%.2lf');
    add(617, 'ProcTime', 5, '%.2lf');
    add(618, 'SysRunTime', 5, '%.2lf');
    add(691, 'ProcRunTime', 5, '%.2lf');

    // ----------------------------------------------------------
    // SYSTEM
    // ----------------------------------------------------------

    add(610, 'Alarm', 2, '%s');
    add(612, 'GUIButtonPress', 2, '%s');
    add(613, 'GUIButtonPressString', 2, '%s');
    add(622, 'SystemState', 2, '%s');
    add(625, 'Substate', 2, '%s');
    add(626, 'Recovery', 2, '%s');
    add(623, 'AlarmStateFlag', 2, '%s');

    // ----------------------------------------------------------
    // PRESSURE
    // ----------------------------------------------------------

    add(570, 'CPS', 4, '%.1f');
    add(571, 'APS', 4, '%.1f');
    add(675, 'APSLow', 2, '%d');
    add(676, 'APSHigh', 2, '%d');

    // ----------------------------------------------------------
    // OPTICAL
    // ----------------------------------------------------------

    add(560, 'RedReflectance', 2, '%d');
    add(527, 'Red', 2, '%d');
    add(561, 'GreenReflectance', 2, '%d');
    add(529, 'Green', 2, '%d');

    // ----------------------------------------------------------
    // PUMPS
    // ----------------------------------------------------------

    add(591, 'InletCmd', 4, '%.1f');
    add(598, 'InletAct', 4, '%.1f');

    add(592, 'ACCmd', 4, '%.1f');
    add(599, 'ACAct', 4, '%.1f');

    add(593, 'PlasmaCmd', 4, '%.1f');
    add(600, 'PlasmaAct', 4, '%.1f');

    add(594, 'CollectCmd', 4, '%.1f');
    add(601, 'CollectAct', 4, '%.1f');

    add(595, 'ReturnCmd', 4, '%.1f');
    add(602, 'ReturnAct', 4, '%.1f');

    // ----------------------------------------------------------
    // DRAW / RESERVOIR / CENTRIFUGE
    // ----------------------------------------------------------

    add(631, 'DrawCycle', 2, '%d');
    add(590, 'ReservoirStatus', 2, '%c');

    add(603, 'CentCmd', 4, '%.0f');
    add(604, 'CentAct', 4, '%.0f');

    // ----------------------------------------------------------
    // VALVES
    // ----------------------------------------------------------

    add(563, 'CollectValveCmd', 2, '%c');
    add(562, 'CollectValvePos', 2, '%c');

    add(565, 'PlasmaValveCmd', 2, '%c');
    add(564, 'PlasmaValvePos', 2, '%c');

    add(567, 'RBCValveCmd', 2, '%c');
    add(566, 'RBCValvePos', 2, '%c');

    // ----------------------------------------------------------
    // VOLUMES
    // ----------------------------------------------------------

    add(632, 'LastResVol', 4, '%.1f');
    add(633, 'InletVol', 4, '%.1f');
    add(634, 'InletTotalVol', 4, '%.1f');

    add(635, 'ACVol', 4, '%.1f');
    add(714, 'ACTotalVol', 4, '%.1f');

    add(636, 'PlasmaVol', 4, '%.1f');
    add(637, 'CollectVol', 4, '%.1f');
    add(642, 'ReturnVol', 4, '%.1f');

    // ----------------------------------------------------------
    // CASSETTE / DOOR
    // ----------------------------------------------------------

    add(569, 'CassetteCmd', 2, '%s');
    add(568, 'CassettePos', 2, '%c');

    add(575, 'DoorCommand', 2, '%d');
    add(576, 'DoorStatus', 2, '%s');

    add(577, 'LowAGC', 2, '%d');
    add(578, 'HighAGC', 2, '%d');

    add(673, 'CassetteState', 2, '%s');

    // ----------------------------------------------------------
    // ADJUSTMENTS
    // ----------------------------------------------------------

    add(645, 'QinAdjustment', 4, '%.2f');
    add(646, 'QrpAdjustment', 4, '%.2f');
    add(647, 'RatioAdjustment', 4, '%.2f');
    add(648, 'IRAdjustment', 4, '%.2f');

    add(653, 'AdjustedDonorHCT', 4, '%.5f');
    add(654, 'ReservoirHCT', 4, '%.2f');
    add(655, 'Hrbc', 4, '%.2f');
    add(656, 'CoagNeedleBlood', 4, '%.1f');

    // ----------------------------------------------------------
    // DETECTORS
    // ----------------------------------------------------------

    add(572, 'ACDetected', 2, '%c');
    add(573, 'LeakDetected', 2, '%c');

    add(652, 'InfusionRate', 4, '%.4f');
    add(657, 'IntegratedPltYield', 4, '%.1f');

    // ----------------------------------------------------------
    // DONOR
    // ----------------------------------------------------------

    add(556, 'DonorBloodType', 2, '%d');
    add(549, 'DonorGender', 2, '%d');

    add(550, 'DonorHeight', 5, '%.1lf');
    add(555, 'DonorHematocrit', 5, '%.2lf');
    add(554, 'DonorPreCount', 5, '%.1lf');
    add(552, 'DonorTBV', 5, '%.1lf');
    add(551, 'DonorWeight', 5, '%.1lf');

    // ----------------------------------------------------------
    // PROCEDURE
    // ----------------------------------------------------------

    add(614, 'Ref', 2, '%d');
    add(674, 'CassetteID', 2, '%d');
    add(621, 'ProcedureNumber', 2, '%d');

    add(658, 'TargetPltYield', 4, '%.1f');
    add(692, 'PlateletYield', 4, '%.1f');

    add(659, 'TargetPltVolume', 4, '%.1f');
    add(693, 'PlateletBagVolume', 4, '%.1f');

    add(661, 'TargetPlsVolume', 4, '%.1f');
    add(694, 'PlasmaBagVolume', 4, '%.1f');

    add(663, 'TargetRBCDose', 4, '%.1f');
    add(695, 'TotalRBCs', 4, '%.1f');

    add(662, 'TargetRBCVolume', 4, '%.1f');
    add(696, 'RBCBagVolume', 4, '%.1f');

    add(619, 'TargetRunTime', 4, '%.2f');

    // ----------------------------------------------------------
    // BLOOD PROCESSED
    // ----------------------------------------------------------

    add(712, 'VbpTotal', 4, '%.1f');
    add(713, 'VbpPlatelet', 4, '%.1f');

    add(715, 'ReplacementVolume', 4, '%.1f');

    // ----------------------------------------------------------
    // BAGS
    // ----------------------------------------------------------

    add(705, 'PlateletBagAC', 4, '%.3f');
    add(706, 'PlasmaBagAC', 4, '%.3f');
    add(707, 'RBCBagAC', 4, '%.3f');

    add(711, 'PASVolume', 4, '%.1f');
    add(671, 'TotalPASPumped', 4, '%.1f');

    add(668, 'PltBagCapacity', 4, '%.1f');
    add(709, 'PltStorageBag', 4, '%.1f');
    add(666, 'PltStorageRemaining', 4, '%.1f');

    add(670, 'RASDelivered', 4, '%.1f');
    add(710, 'RASVolume', 4, '%.1f');
    add(672, 'TotalRASPumped', 4, '%.1f');

    // ----------------------------------------------------------
    // RBC 1 / RBC 2
    // ----------------------------------------------------------

    add(699, 'RBC_1_AC', 4, '%.1f');
    add(698, 'RBC_1_Dose', 4, '%.1f');
    add(700, 'RBC_1_SS', 4, '%.1f');
    add(697, 'RBC_1_Vol', 4, '%.1f');

    add(703, 'RBC_2_AC', 4, '%.1f');
    add(702, 'RBC_2_Dose', 4, '%.1f');
    add(704, 'RBC_2_SS', 4, '%.1f');
    add(701, 'RBC_2_Vol', 4, '%.1f');

    add(669, 'RBCBagCapacity', 4, '%.1f');

    add(644, 'RBCinCal', 2, '%d');

    add(708, 'RBCStorageBag', 4, '%.1f');
    add(667, 'RBCStorageRemaining', 4, '%.1f');

    // ----------------------------------------------------------
    // SALINE
    // ----------------------------------------------------------

    add(665, 'SalineBolusVolume', 4, '%.1f');
    add(664, 'SalineRinsebackVolume', 4, '%.1f');

    // ----------------------------------------------------------
    // HARDWARE / POWER
    // ----------------------------------------------------------

    add(579, 'EMITemp', 4, '%.1f');
    add(589, 'CentI', 4, '%.3f');
    add(574, 'LeakValue', 2, '%d');

    add(580, 'PS+5V', 4, '%.3f');
    add(581, 'PS-12V', 4, '%.3f');
    add(582, 'PS+12V', 4, '%.3f');
    add(583, 'PS+24V', 4, '%.3f');
    add(584, 'PS+24V/Switched', 4, '%.3f');
    add(585, 'PS+24VI', 4, '%.3f');

    add(586, 'PS+64V', 4, '%.3f');
    add(587, 'PS+64V/Switched', 4, '%.3f');
    add(588, 'PS+64VI', 4, '%.3f');

    // ----------------------------------------------------------
    // MEMORY / CPU
    // ----------------------------------------------------------

    add(716, 'MemSize', 2, '%u');
    add(717, 'MemUsed', 2, '%u');

    add(719, 'MemUsedPct', 4, '%.2f');

    add(718, 'MemMax', 2, '%u');

    add(720, 'MemMaxPct', 4, '%.2f');

    add(722, 'CPUIdle', 2, '%d');
    add(723, 'FreeLogMem', 2, '%u');
    add(724, 'TraceLogMissed', 2, '%u');
    add(725, 'CriticalLogMissed', 2, '%u');

    // Trima End Of Run (familia EOR). IDs observados en el DLOG pareado.
    add(727, 'EOR_Offline_RAS1', 2, '%u');
    add(728, 'EOR_Offline_RAS2', 2, '%u');
    add(729, 'EOR_PAS_VOLM', 2, '%u');
    add(730, 'EOR_RAS1_VOLM', 2, '%u');
    add(731, 'EOR_RAS2_VOLM', 2, '%u');
    add(732, 'EOR_POSTCOUNT', 2, '%u');
    add(733, 'EOR_POSTHCT', 4, '%.1f');
    add(734, 'EOR_AC_TO_DONOR', 2, '%u');
    add(735, 'EOR_RBC_Residual', 2, '%u');
    add(736, 'EOR_PLS_Residual', 2, '%u');
    add(737, 'EOR_RBC1_VOLM', 2, '%u');
    add(738, 'EOR_RBC2_VOLM', 2, '%u');
    add(739, 'EOR_Offline_PAS', 2, '%u');

    add(620, 'MeteringTime', 4, '%.2f');

    return map;
  }

  static List<Dlog022eRecord> _readTrimaDataEnvelopes(Uint8List d) {
    final out = <Dlog022eRecord>[];
    var p = 0;
    var index = 0;

    // Trima DATA is an 04 55 envelope.  Inside it the native field
    // representation is [size:u16][id:u16][value:size], not the older
    // heuristic ID/value/trailer representation used by _decode022eRecord.
    // Decode the envelope directly so uncommon families (notably EOR 0x02D6)
    // are not lost and zero-valued fields are preserved.
    while (p + 18 <= d.length) {
      if (d[p] != 0x04 || d[p + 1] != 0x55) { p++; continue; }

      final sec = _u32(d, p + 2);
      final ns = _u32(d, p + 6);
      if (ns >= 1000000000 || sec > 100000) { p++; continue; }

      if (d[p + 12] != 0x5A || d[p + 13] != 0x00 ||
          d[p + 14] != 0x00 || d[p + 15] != 0x02) { p++; continue; }

      final count = _u16(d, p + 16);
      var q = p + 18;
      var ok = true;
      var known = 0;
      final fields = <DlogField>[];

      for (var n = 0; n < count; n++) {
        if (q + 4 > d.length) { ok = false; break; }
        final fieldStart = q;
        final size = _u16(d, q);
        final id = _u16(d, q + 2);
        q += 4;
        if (size > 4096 || q + size > d.length) { ok = false; break; }

        final valueBytes = Uint8List.fromList(d.sublist(q, q + size));
        final definition = fieldDefinitions[id];
        if (definition != null) {
          known++;
          final value = _decodeFieldValue(definition, valueBytes);
          fields.add(DlogField(
            relativeOffset: fieldStart - p,
            id: id,
            name: definition.name,
            typeCode: definition.typeCode,
            length: size,
            value: value,
            formattedValue: _formatValue(definition, value),
            rawHex: _hex(valueBytes),
            trailer: size,
          ));
        }
        q += size;
      }

      if (!ok || q + 2 > d.length || d[q] != 0xFE || d[q + 1] != 0x55 || known == 0) {
        p++; continue;
      }

      final raw = Uint8List.fromList(d.sublist(p + 10, q + 2));
      final r = Dlog022eRecord(
        index: index++,
        offset: p,
        length: raw.length,
        raw: raw,
        fields: fields,
        asciiRatio: _asciiRatio(raw),
        traceMarkers: _countPattern(raw, const [0x5A, 0x00, 0x00, 0x02]),
        printableText: _extractPrintable(raw),
      );
      r.classification = DlogRecordClass.procedure;
      r.elapsedMs = sec * 1000 + (ns ~/ 1000000);
      out.add(r);
      p = q + 2;
    }

    // V44 safety pass: EOR (family 0x02D6) is a valid DATA envelope but the
    // paired Trima log showed that it can be skipped by the generic walk.
    // Re-scan only this native family and append it iff its physical offset
    // was not already decoded. This does not synthesize a row: the complete
    // 04 55 envelope, count and FE 55 terminator must all validate.
    final decodedOffsets = out.map((r) => r.offset).toSet();
    for (var ep = 0; ep + 18 <= d.length; ep++) {
      if (decodedOffsets.contains(ep) ||
          d[ep] != 0x04 || d[ep + 1] != 0x55 ||
          d[ep + 10] != 0xD6 || d[ep + 11] != 0x02 ||
          d[ep + 12] != 0x5A || d[ep + 13] != 0x00 ||
          d[ep + 14] != 0x00 || d[ep + 15] != 0x02) {
        continue;
      }
      final sec = _u32(d, ep + 2);
      final ns = _u32(d, ep + 6);
      if (ns >= 1000000000 || sec > 100000) continue;
      final count = _u16(d, ep + 16);
      var eq = ep + 18;
      var eok = true;
      final efields = <DlogField>[];
      for (var n = 0; n < count; n++) {
        if (eq + 4 > d.length) { eok = false; break; }
        final fieldStart = eq;
        final size = _u16(d, eq);
        final id = _u16(d, eq + 2);
        eq += 4;
        if (size > 4096 || eq + size > d.length) { eok = false; break; }
        final valueBytes = Uint8List.fromList(d.sublist(eq, eq + size));
        final definition = fieldDefinitions[id];
        if (definition != null) {
          final value = _decodeFieldValue(definition, valueBytes);
          efields.add(DlogField(
            relativeOffset: fieldStart - ep, id: id, name: definition.name,
            typeCode: definition.typeCode, length: size, value: value,
            formattedValue: _formatValue(definition, value),
            rawHex: _hex(valueBytes), trailer: size,
          ));
        }
        eq += size;
      }
      if (!eok || efields.isEmpty || eq + 2 > d.length ||
          d[eq] != 0xFE || d[eq + 1] != 0x55) continue;
      final raw = Uint8List.fromList(d.sublist(ep + 10, eq + 2));
      final r = Dlog022eRecord(
        index: index++, offset: ep, length: raw.length, raw: raw,
        fields: efields, asciiRatio: _asciiRatio(raw),
        traceMarkers: _countPattern(raw, const [0x5A, 0x00, 0x00, 0x02]),
        printableText: _extractPrintable(raw),
      );
      r.classification = DlogRecordClass.procedure;
      r.elapsedMs = sec * 1000 + (ns ~/ 1000000);
      out.add(r);
      decodedOffsets.add(ep);
    }

    // Keep physical DLOG order after the EOR safety pass.
    out.sort((a, b) => a.offset.compareTo(b.offset));
    return out;
  }

  // ============================================================
  // 022E RECORD
  // ============================================================

  static Dlog022eRecord _decode022eRecord({
    required int index,
    required int offset,
    required Uint8List raw,
  }) {
    final candidates = _findFieldCandidates(
      raw,
    );

    final selected = _selectFieldChains(
      candidates,
      raw.length,
    );

    final fields = <DlogField>[];

    for (final candidate in selected) {
      final definition = fieldDefinitions[candidate.id];

      if (definition == null) {
        continue;
      }

      final value = _decodeFieldValue(
        definition,
        candidate.valueBytes,
      );

      fields.add(
        DlogField(
          relativeOffset: candidate.relativeOffset,
          id: candidate.id,
          name: definition.name,
          typeCode: definition.typeCode,
          length: candidate.valueBytes.length,
          value: value,
          formattedValue: _formatValue(
            definition,
            value,
          ),
          rawHex: _hex(candidate.valueBytes),
          trailer: candidate.trailer,
        ),
      );
    }

    final asciiRatio = _asciiRatio(raw);

    final traceMarkers = _countPattern(
      raw,
      const [0x5A, 0x00, 0x00, 0x02],
    );

    final printable = _extractPrintable(
      raw,
    );

    return Dlog022eRecord(
      index: index,
      offset: offset,
      length: raw.length,
      raw: raw,
      fields: fields,
      asciiRatio: asciiRatio,
      traceMarkers: traceMarkers,
      printableText: printable,
    );
  }

  // ============================================================
  // FIELD CANDIDATES
  // ============================================================

  static List<_FieldCandidate> _findFieldCandidates(
    Uint8List data,
  ) {
    final result = <_FieldCandidate>[];

    for (var pos = 2; pos + 4 <= data.length; pos++) {
      final id = _u16(data, pos);

      final definition = fieldDefinitions[id];

      if (definition == null) {
        continue;
      }

      // El formato observado es:
      //
      //   ID uint16
      //   VALUE N bytes
      //   TRAILER uint16
      //
      // El trailer aparece como 01 00, 02 00, 04 00,
      // 08 00, etc.
      //
      // Como todavía estamos haciendo ingeniería inversa,
      // probamos tamaños válidos y exigimos que el trailer
      // tenga una forma razonable.

      final sizes = _possibleValueSizes(
        definition,
      );

      for (final size in sizes) {
        final valueStart = pos + 2;
        final trailerStart = valueStart + size;

        if (trailerStart + 2 > data.length) {
          continue;
        }

        final trailer = _u16(
          data,
          trailerStart,
        );

        if (!_validTrailer(trailer)) {
          continue;
        }

        final valueBytes = Uint8List.fromList(
          data.sublist(
            valueStart,
            trailerStart,
          ),
        );

        if (!_valueIsPlausible(
          definition,
          valueBytes,
        )) {
          continue;
        }

        result.add(
          _FieldCandidate(
            relativeOffset: pos,
            id: id,
            valueBytes: valueBytes,
            trailer: trailer,
            endOffset: trailerStart + 2,
          ),
        );
      }
    }

    return result;
  }

  static List<int> _possibleValueSizes(
    DlogFieldDefinition definition,
  ) {
    switch (definition.typeCode) {
      case 4:
        return const [4];

      case 5:
        return const [8, 4];

      case 2:
        return const [
          1,
          2,
          4,
          8,
          16,
        ];

      default:
        return const [
          1,
          2,
          4,
          8,
        ];
    }
  }

  static bool _validTrailer(
    int value,
  ) {
    // Los trailers observados hasta ahora.
    //
    // No lo tratamos como longitud. Es un código asociado
    // a la representación del campo.
    return value >= 0 &&
        value <= 32;
  }

  static bool _valueIsPlausible(
    DlogFieldDefinition definition,
    Uint8List value,
  ) {
    if (value.isEmpty) {
      return false;
    }

    if (definition.typeCode == 4 &&
        value.length == 4) {
      final v = _float32(value);

      if (!v.isFinite) {
        return false;
      }

      // Evitamos coincidencias accidentales gigantes.
      if (v.abs() > 100000000) {
        return false;
      }

      return true;
    }

    if (definition.typeCode == 5 &&
        value.length == 8) {
      final v = _float64(value);

      if (!v.isFinite) {
        return false;
      }

      if (v.abs() > 1e15) {
        return false;
      }

      return true;
    }

    return true;
  }

  // ============================================================
  // FIELD CHAINS
  // ============================================================

  static List<_FieldCandidate> _selectFieldChains(
    List<_FieldCandidate> candidates,
    int recordLength,
  ) {
    if (candidates.isEmpty) {
      return const [];
    }

    final byOffset = <int, List<_FieldCandidate>>{};

    for (final candidate in candidates) {
      byOffset
          .putIfAbsent(
            candidate.relativeOffset,
            () => [],
          )
          .add(candidate);
    }

    final used = <int>{};
    final selected = <_FieldCandidate>[];

    // Buscar cadenas.
    //
    // Una cadena válida tiene:
    //
    //   campo
    //      ->
    //   siguiente campo exactamente después
    //
    // Esto es mucho más seguro que interpretar cada byte como
    // posible ID.

    for (final candidate in candidates) {
      if (used.contains(candidate.relativeOffset)) {
        continue;
      }

      final chain = <_FieldCandidate>[];
      var current = candidate;

      while (true) {
        if (used.contains(current.relativeOffset)) {
          break;
        }

        chain.add(current);

        final nextCandidates =
            byOffset[current.endOffset];

        if (nextCandidates == null ||
            nextCandidates.isEmpty) {
          break;
        }

        // Elegir el candidato más razonable.
        final next = _chooseCandidate(
          nextCandidates,
        );

        current = next;
      }

      // Exigimos al menos dos campos consecutivos.
      //
      // Una única coincidencia aislada en un trace puede ser
      // accidental.
      if (chain.length >= 2) {
        for (final c in chain) {
          used.add(c.relativeOffset);
          selected.add(c);
        }
      }
    }

    // También conservar cadenas largas aunque estén contenidas
    // dentro de otra.
    selected.sort(
      (a, b) => a.relativeOffset.compareTo(
        b.relativeOffset,
      ),
    );

    return selected;
  }

  static _FieldCandidate _chooseCandidate(
    List<_FieldCandidate> candidates,
  ) {
    if (candidates.length == 1) {
      return candidates.first;
    }

    // Preferir tamaños esperados.
    candidates.sort(
      (a, b) {
        final sa = _candidateScore(a);
        final sb = _candidateScore(b);
        return sb.compareTo(sa);
      },
    );

    return candidates.first;
  }

  static int _candidateScore(
    _FieldCandidate c,
  ) {
    var score = 0;

    final definition =
        fieldDefinitions[c.id];

    if (definition == null) {
      return -1000;
    }

    if (definition.typeCode == 4 &&
        c.valueBytes.length == 4) {
      score += 100;
    }

    if (definition.typeCode == 5 &&
        c.valueBytes.length == 8) {
      score += 100;
    }

    if (c.trailer == 4 &&
        c.valueBytes.length == 4) {
      score += 20;
    }

    if (c.trailer == 8 &&
        c.valueBytes.length == 8) {
      score += 20;
    }

    if (c.valueBytes.length <= 8) {
      score += 5;
    }

    return score;
  }

  // ============================================================
  // VALUE DECODING
  // ============================================================

  static Object? _decodeFieldValue(
    DlogFieldDefinition definition,
    Uint8List bytes,
  ) {
    if (bytes.isEmpty) {
      return null;
    }

    switch (definition.typeCode) {
      case 4:
        if (bytes.length == 4) {
          return _float32(bytes);
        }

        return _decodeInteger(
          bytes,
        );

      case 5:
        if (bytes.length == 8) {
          return _float64(bytes);
        }

        if (bytes.length == 4) {
          return _float32(bytes);
        }

        return _decodeInteger(
          bytes,
        );

      case 2:
        // Strings/códigos de estado.
        if (_isPrintable(
          bytes,
        )) {
          return ascii(
            bytes,
          );
        }

        return _decodeInteger(
          bytes,
        );

      default:
        return _decodeInteger(
          bytes,
        );
    }
  }

  static Object _decodeInteger(
    Uint8List bytes,
  ) {
    switch (bytes.length) {
      case 1:
        return bytes[0];

      case 2:
        return _u16(
          bytes,
          0,
        );

      case 4:
        return _u32(
          bytes,
          0,
        );

      case 8:
        return _u64(
          bytes,
          0,
        );

      default:
        return _hex(bytes);
    }
  }

  static String _formatValue(
    DlogFieldDefinition definition,
    Object? value,
  ) {
    if (value == null) {
      return '';
    }

    if (value is double) {
      final format = definition.format;

      if (format.contains('.5')) {
        return value.toStringAsFixed(5);
      }

      if (format.contains('.4')) {
        return value.toStringAsFixed(4);
      }

      if (format.contains('.3')) {
        return value.toStringAsFixed(3);
      }

      if (format.contains('.2')) {
        return value.toStringAsFixed(2);
      }

      if (format.contains('.1')) {
        return value.toStringAsFixed(1);
      }

      if (format.contains('.0')) {
        return value.toStringAsFixed(0);
      }

      return value.toString();
    }

    return value.toString();
  }

  // ============================================================
  // CLASSIFICATION
  // ============================================================

  static void _classifyRecords(
    List<Dlog022eRecord> records,
  ) {
    for (final record in records) {
      final known = record.fields.length;

      final asciiRatio = record.asciiRatio;

      final trace = record.traceMarkers;

      if (known >= 5 &&
          record.length <= 5000 &&
          asciiRatio < 0.45) {
        record.classification =
            DlogRecordClass.procedure;
        continue;
      }

      if (known >= 2 &&
          (asciiRatio > 0.25 ||
              trace > 0)) {
        record.classification =
            DlogRecordClass.mixed;
        continue;
      }

      if (known < 2 &&
          (asciiRatio > 0.20 ||
              trace > 0)) {
        record.classification =
            DlogRecordClass.trace;
        continue;
      }

      if (known >= 2) {
        record.classification =
            DlogRecordClass.procedure;
      } else {
        record.classification =
            DlogRecordClass.unknown;
      }
    }
  }

  // ============================================================
  // TIMESTAMP MODEL
  // ============================================================

  static _TimestampInfo _buildTimestampModel({
    required List<Dlog022eRecord> records,
    String? sourcePath,
  }) {
    final diagnostics = <String>[];

    final procedureRecords = records
        .where(
          (r) => r.fields.any(
            (f) => f.name == 'AbsTime',
          ),
        )
        .toList();

    if (procedureRecords.isEmpty) {
      diagnostics.add(
        'Timestamp: no se encontraron AbsTime.',
      );

      return _TimestampInfo(
        mode: TimestampMode.none,
        dlogStart: null,
        diagnostics: diagnostics,
      );
    }

    // ----------------------------------------------------------
    // Extraer el primer AbsTime
    // ----------------------------------------------------------

    final firstAbs =
        _getDoubleField(
      procedureRecords.first,
      'AbsTime',
    );

    diagnostics.add(
      'Primer AbsTime encontrado: $firstAbs',
    );

    // ----------------------------------------------------------
    // Fecha del nombre del archivo
    // ----------------------------------------------------------

    DateTime? dateFromFilename;

    if (sourcePath != null) {
      dateFromFilename =
          _dateFromFilename(
        sourcePath,
      );
    }

    if (dateFromFilename != null) {
      diagnostics.add(
        'Fecha detectada en nombre DLOG: '
        '${_formatDate(dateFromFilename)}',
      );
    }

    // ----------------------------------------------------------
    // Caso 1:
    //
    // AbsTime parece minutos desde medianoche.
    //
    // El mapping dice:
    //
    //   AbsTime = absolute time (minutes)
    //
    // Por lo tanto, si está entre 0 y 1440,
    // podemos comprobar:
    //
    //   timestamp =
    //       fecha DLOG + AbsTime minutos
    //
    // ----------------------------------------------------------

    if (firstAbs != null &&
        dateFromFilename != null &&
        firstAbs >= 0 &&
        firstAbs < 1440) {
      final start = dateFromFilename;

      diagnostics.add(
        'Timestamp: AbsTime interpretado como '
        'minutos desde medianoche.',
      );

      diagnostics.add(
        'Timestamp base: ${start.toIso8601String()}',
      );

      return _TimestampInfo(
        mode: TimestampMode.absTimeMinutesFromMidnight,
        dlogStart: start,
        diagnostics: diagnostics,
      );
    }

    // ----------------------------------------------------------
    // Caso 2:
    //
    // AbsTime parece tiempo transcurrido desde el comienzo.
    //
    // En ese caso usamos la fecha del DLOG como base.
    // ----------------------------------------------------------

    if (firstAbs != null &&
        dateFromFilename != null) {
      diagnostics.add(
        'Timestamp: AbsTime interpretado como tiempo '
        'relativo al comienzo del DLOG.',
      );

      return _TimestampInfo(
        mode: TimestampMode.absTimeRelativeToDlog,
        dlogStart: dateFromFilename,
        diagnostics: diagnostics,
      );
    }

    // ----------------------------------------------------------
    // No se pudo determinar fecha.
    // ----------------------------------------------------------

    diagnostics.add(
      'Timestamp: no se pudo determinar la fecha inicial '
      'del DLOG.',
    );

    return _TimestampInfo(
      mode: TimestampMode.none,
      dlogStart: null,
      diagnostics: diagnostics,
    );
  }

  static void _applyTimestamps(
    List<Dlog022eRecord> records,
    _TimestampInfo info,
  ) {
    for (final record in records) {
      final abs =
          _getDoubleField(
        record,
        'AbsTime',
      );

      if (abs == null ||
          info.dlogStart == null) {
        continue;
      }

      DateTime? timestamp;

      switch (info.mode) {
        case TimestampMode.absTimeMinutesFromMidnight:
          timestamp = info.dlogStart!.add(
            Duration(
              milliseconds:
                  (abs * 60.0 * 1000.0).round(),
            ),
          );
          break;

        case TimestampMode.absTimeRelativeToDlog:
          timestamp = info.dlogStart!.add(
            Duration(
              milliseconds:
                  (abs * 60.0 * 1000.0).round(),
            ),
          );
          break;

        case TimestampMode.optiaSecondsNanoseconds:
          // Optia asigna el timestamp directamente al decodificar su registro.
          break;

        case TimestampMode.reveosSecondsNanoseconds:
          // Reveos asigna el timestamp directamente al decodificar cada
          // registro desde DLOG start + seconds + nanoseconds. Este bloque
          // procesa AbsTime de Trima/Optia, por lo que no recalcula nada.
          break;

        case TimestampMode.none:
          break;
      }

      record.timestamp = timestamp;
    }

    // ----------------------------------------------------------
    // Segundo paso:
    //
    // Si tenemos timestamps válidos, calculamos elapsed_ms
    // desde el primer timestamp de datos.
    //
    // Esto es útil para comprobar la relación con el inicio.
    // ----------------------------------------------------------

    DateTime? firstTimestamp;

    for (final record in records) {
      final ts = record.timestamp;

      if (ts == null) {
        continue;
      }

      if (firstTimestamp == null ||
          ts.isBefore(firstTimestamp)) {
        firstTimestamp = ts;
      }
    }

    if (firstTimestamp != null) {
      for (final record in records) {
        final ts = record.timestamp;

        if (ts == null) {
          continue;
        }

        record.elapsedMs =
            ts.difference(firstTimestamp).inMilliseconds;
      }
    }
  }

  static double? _getDoubleField(
    Dlog022eRecord record,
    String name,
  ) {
    for (final field in record.fields) {
      if (field.name != name) {
        continue;
      }

      if (field.value is num) {
        return (field.value as num).toDouble();
      }
    }

    return null;
  }

  // ============================================================
  // DATE FROM FILENAME
  // ============================================================

  static DateTime? _dateFromFilename(
    String path,
  ) {
    final name =
        path.split(RegExp(r'[\\/]')).last;

    // Busca:
    //
    // 20260505
    // 20260818
    // etc.
    //
    final match = RegExp(
      r'(20\d{2})(\d{2})(\d{2})',
    ).firstMatch(name);

    if (match == null) {
      return null;
    }

    final year =
        int.tryParse(match.group(1)!);

    final month =
        int.tryParse(match.group(2)!);

    final day =
        int.tryParse(match.group(3)!);

    if (year == null ||
        month == null ||
        day == null) {
      return null;
    }

    try {
      return DateTime(
        year,
        month,
        day,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // CSV RECORDS
  // ============================================================

  static String recordsCsv(
    List<Dlog022eRecord> records,
  ) {
    final b = StringBuffer();

    b.writeln(
      [
        'record',
        'dlog_offset',
        'record_length',
        'class',
        'known_fields',
        'trace_markers',
        'ascii_ratio',
        'timestamp',
        'elapsed_ms',
      ].join(','),
    );

    for (final r in records) {
      b.writeln(
        [
          r.index,
          r.offset,
          r.length,
          r.classification.name,
          r.fields.length,
          r.traceMarkers,
          r.asciiRatio.toStringAsFixed(4),
          r.timestampString,
          r.elapsedMs ?? '',
        ].map(_csv).join(','),
      );
    }

    return b.toString();
  }

  // ============================================================
  // CSV FIELDS
  // ============================================================

  static String fieldsCsv(
    List<Dlog022eRecord> records,
  ) {
    final b = StringBuffer();

    b.writeln(
      [
        'record',
        'dlog_offset',
        'record_length',
        'class',
        'field_offset',
        'field_id',
        'field_name',
        'type_code',
        'value_length',
        'value',
        'formatted_value',
        'raw_hex',
        'trailer',
      ].join(','),
    );

    for (final record in records) {
      for (final field in record.fields) {
        b.writeln(
          [
            record.index,
            record.offset,
            record.length,
            record.classification.name,
            field.relativeOffset,
            field.id,
            field.name,
            field.typeCode,
            field.length,
            field.value ?? '',
            field.formattedValue,
            field.rawHex,
            '0x${field.trailer.toRadixString(16).padLeft(4, '0')}',
          ].map(_csv).join(','),
        );
      }
    }

    return b.toString();
  }

  // ============================================================
  // PROCEDURE CSV
  // ============================================================

  static const List<String> csvColumns = [
    'index',
    'timestamp',
    'AbsTime',
    'ProcTime',
    'SysRunTime',
    'ProcRunTime',
    'Alarm',
    'GUIButtonPress',
    'GUIButtonPressString',
    'SystemState',
    'Substate',
    'Recovery',
    'AlarmStateFlag',
    'CPS',
    'APS',
    'APSLow',
    'APSHigh',
    'RedReflectance',
    'Red',
    'GreenReflectance',
    'Green',
    'InletCmd',
    'InletAct',
    'ACCmd',
    'ACAct',
    'PlasmaCmd',
    'PlasmaAct',
    'CollectCmd',
    'CollectAct',
    'ReturnCmd',
    'ReturnAct',
    'DrawCycle',
    'ReservoirStatus',
    'CentCmd',
    'CentAct',
    'CollectValveCmd',
    'CollectValvePos',
    'PlasmaValveCmd',
    'PlasmaValvePos',
    'RBCValveCmd',
    'RBCValvePos',
    'LastResVol',
    'InletVol',
    'InletTotalVol',
    'ACVol',
    'ACTotalVol',
    'PlasmaVol',
    'CollectVol',
    'ReturnVol',
    'CassetteCmd',
    'CassettePos',
    'DoorCommand',
    'DoorStatus',
    'LowAGC',
    'HighAGC',
    'CassetteState',
    'QinAdjustment',
    'QrpAdjustment',
    'RatioAdjustment',
    'IRAdjustment',
    'AdjustedDonorHCT',
    'ReservoirHCT',
    'Hrbc',
    'CoagNeedleBlood',
    'ACDetected',
    'LeakDetected',
    'InfusionRate',
    'IntegratedPltYield',
    'DonorBloodType',
    'DonorGender',
    'DonorHeight',
    'DonorHematocrit',
    'DonorPreCount',
    'DonorTBV',
    'DonorWeight',
    'Ref',
    'CassetteID',
    'ProcedureNumber',
    'TargetPltYield',
    'PlateletYield',
    'TargetPltVolume',
    'PlateletBagVolume',
    'TargetPlsVolume',
    'PlasmaBagVolume',
    'TargetRBCDose',
    'TotalRBCs',
    'TargetRBCVolume',
    'RBCBagVolume',
    'TargetRunTime',
    'VbpTotal',
    'VbpPlatelet',
    'ReplacementVolume',
    'PlateletBagAC',
    'PlasmaBagAC',
    'RBCBagAC',
    'PASVolume',
    'TotalPASPumped',
    'PltBagCapacity',
    'PltStorageBag',
    'PltStorageRemaining',
    'RASDelivered',
    'RASVolume',
    'TotalRASPumped',
    'RBC_1_AC',
    'RBC_1_Dose',
    'RBC_1_SS',
    'RBC_1_Vol',
    'RBC_2_AC',
    'RBC_2_Dose',
    'RBC_2_SS',
    'RBC_2_Vol',
    'RBCBagCapacity',
    'RBCinCal',
    'RBCStorageBag',
    'RBCStorageRemaining',
    'SalineBolusVolume',
    'SalineRinsebackVolume',
    'EMITemp',
    'CentI',
    'LeakValue',
    'PS+5V',
    'PS-12V',
    'PS+12V',
    'PS+24V',
    'PS+24V/Switched',
    'PS+24VI',
    'PS+64V',
    'PS+64V/Switched',
    'PS+64VI',
    'MemSize',
    'MemUsed',
    'MemUsedPct',
    'MemMax',
    'MemMaxPct',
    'CPUIdle',
    'FreeLogMem',
    'TraceLogMissed',
    'CriticalLogMissed',
    'MeteringTime',
    'EOR_AC_TO_DONOR',
    'EOR_Offline_PAS',
    'EOR_Offline_RAS1',
    'EOR_Offline_RAS2',
    'EOR_PAS_VOLM',
    'EOR_PLS_Residual',
    'EOR_POSTCOUNT',
    'EOR_POSTHCT',
    'EOR_RAS1_VOLM',
    'EOR_RAS2_VOLM',
    'EOR_RBC_Residual',
    'EOR_RBC1_VOLM',
    'EOR_RBC2_VOLM',
  ];

  static String procedureCsv(
  List<Dlog022eRecord> records, {
  List<String>? originalHeader,
}) {
  final b = StringBuffer();

  // ----------------------------------------------------------
  // CABECERA
  // ----------------------------------------------------------
  //
  // Si tenemos la cabecera original, la usamos.
  // Si no, usamos csvColumns como respaldo.
  //
  // En ambos casos eliminamos SIEMPRE la primera columna,
  // que es "index".
  // ----------------------------------------------------------

  final sourceHeader =
      originalHeader != null &&
              originalHeader.isNotEmpty
          ? originalHeader
          : csvColumns;

  final header = sourceHeader.length > 1
      ? sourceHeader.sublist(1)
      : <String>[];

  b.writeln(
    header.map(_csv).join(','),
  );

  // ----------------------------------------------------------
  // DATOS
  // ----------------------------------------------------------

  for (final record in records) {
    if (record.classification != DlogRecordClass.procedure &&
        record.classification != DlogRecordClass.trace) {
      continue;
    }

    final values = <String, String>{};

    for (final field in record.fields) {
      values[field.name] =
          field.formattedValue;
    }

    final row = <String>[];

    // Empezamos desde 1 porque eliminamos "index".
    for (var i = 1;
        i < sourceHeader.length;
        i++) {
      final column = sourceHeader[i];

      // --------------------------------------------
      // TIMESTAMP
      // --------------------------------------------

      if (column == 'timestamp') {
        // IMPORTANTE:
        // si no hay timestamp, queda vacío.
        row.add(
          record.timestampString,
        );

        continue;
      }

      // --------------------------------------------
      // RESTO DE CAMPOS
      // --------------------------------------------

      row.add(
        values[column] ?? '',
      );
    }

    // Los traces Optia llevan dos campos adicionales sin cabecera en
    // el CSV original: Node:a50000N y el mensaje.
    if (record.traceNode != null) {
      if (record.traceCategory != null) {
        // Reveos: EVENT => category,name ; TRACE => category,Node:,verbose.
        row.add(record.traceCategory!);
        row.add(record.traceNode!);
        if (record.traceMessage != null) row.add(record.traceMessage!);
      } else {
        // Optia conserva sus dos columnas extra originales.
        row.add(record.traceNode!);
        row.add('  ${record.traceMessage ?? ''}'.trimRight());
      }
    }

    b.writeln(
      row.map(_csv).join(','),
    );
  }

  return b.toString();
}
  // ============================================================
  // SUMMARY
  // ============================================================

  static String summary(
    DlogDecodeResult result,
  ) {
    final records = result.records;

    final procedure = records
        .where(
          (r) => r.classification ==
              DlogRecordClass.procedure,
        )
        .length;

    final mixed = records
        .where(
          (r) => r.classification ==
              DlogRecordClass.mixed,
        )
        .length;

    final trace = records
        .where(
          (r) => r.classification ==
              DlogRecordClass.trace,
        )
        .length;

    final unknown = records
        .where(
          (r) => r.classification ==
              DlogRecordClass.unknown,
        )
        .length;

    // Optia usa dos familias de registros de datos: MAIN y SAFETY.
    // Se mantienen ambos como `procedure` internamente para no alterar
    // la compatibilidad con Trima/procedureCsv, pero el summary los
    // informa por separado.
    final optiaSafety = result.machine == DlogMachine.optia
        ? records.where((r) =>
            r.classification == DlogRecordClass.procedure &&
            r.fields.any((f) => f.name.startsWith('S_'))).length
        : 0;
    final optiaMain = result.machine == DlogMachine.optia
        ? procedure - optiaSafety
        : 0;

    final fieldFrequency =
        <String, int>{};

    for (final record in records) {
      for (final field in record.fields) {
        fieldFrequency[field.name] =
            (fieldFrequency[field.name] ?? 0) + 1;
      }
    }

    final sortedFields =
        fieldFrequency.entries.toList()
          ..sort(
            (a, b) =>
                b.value.compareTo(a.value),
          );

    final b = StringBuffer();

    b.writeln(
      'DLOG DECODER SUMMARY',
    );

    b.writeln('Decoder version: $decoderVersion');
    b.writeln('Machine: ${result.machine.name}');

    b.writeln(
      '====================',
    );

    b.writeln();

    b.writeln(
      'Original bytes: ${result.sourcePath ?? ''}',
    );

    b.writeln(
      'GZIP offset: ${result.gzipOffset}',
    );

    b.writeln(
      'Decompressed: ${result.decompressedSize}',
    );

    b.writeln(
      'Decoded payload: ${result.payloadSize}',
    );

    b.writeln();

    b.writeln(
      result.machine == DlogMachine.optia
          ? 'Optia records: ${records.length}'
          : '0x022E records: ${records.length}',
    );

    if (result.machine == DlogMachine.optia) {
      b.writeln('Optia MAIN: $optiaMain');
      b.writeln('Optia SAFETY: $optiaSafety');
      b.writeln('Optia TRACE: $trace');
      b.writeln('Optia TOTAL: ${records.length}');
    } else {
      b.writeln('Procedure: $procedure');
      b.writeln('Mixed: $mixed');
      b.writeln('Trace: $trace');
      b.writeln('Unknown: $unknown');
    }


    b.writeln();

    b.writeln(
      'Timestamp mode: '
      '${result.timestampInfo.mode.name}',
    );

    b.writeln(
      'DLOG start: '
      '${result.timestampInfo.dlogStart?.toIso8601String() ?? ''}',
    );

    b.writeln();

    b.writeln(
      'Field frequencies:',
    );

    for (final e in sortedFields.take(30)) {
      b.writeln(
        '  ${e.key}: ${e.value}',
      );
    }

    b.writeln();

    b.writeln(
      'Diagnostics:',
    );

    for (final line in result.diagnostics) {
      b.writeln(
        '  $line',
      );
    }

    return b.toString();
  }

  static String _optiaPreambleFromDlog(Uint8List input, DlogDecodeResult result) {
    final gzip = result.gzipOffset >= 0 ? result.gzipOffset : _findGzip(input);
    final end = gzip > 0 ? gzip : math.min(input.length, 2048);
    final text = latin1.decode(input.sublist(0, end), allowInvalid: true);
    final lines = text.split(RegExp(r'[\r\n]+'));

    String confidential = '';
    String logFile = '';
    String optia = '';
    for (final line in lines) {
      final t = line.trimRight();
      if (confidential.isEmpty && t.startsWith('CONFIDENTIAL:')) confidential = t;
      if (logFile.isEmpty && t.startsWith('Log file:')) logFile = t;
      if (optia.isEmpty && t.startsWith('Optia:')) optia = t;
    }

    final dt = result.timestampInfo.dlogStart;
    final date = dt == null
        ? ''
        : '${dt.year.toString().padLeft(4,'0')}${dt.month.toString().padLeft(2,'0')}${dt.day.toString().padLeft(2,'0')}_'
          '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';

    final b = StringBuffer();
    if (confidential.isNotEmpty) b.writeln(confidential.replaceAll(',', ' '));
    if (logFile.isNotEmpty) b.writeln(logFile);
    if (optia.isNotEmpty) b.writeln(optia.replaceAll(',', ' '));
    b.writeln(' ');
    b.writeln(' ');
    b.writeln('Log Version: 3.1       Platform: Optia    Date: $date');
    return b.toString();
  }


  static const String trimaDescriptionRow = ',absolute time (minutes),procedure time (minutes),system run time (minutes),procedure run time (minutes),Current top alarm,GUI Button Id (SSBB) S-screen B-button,GUI Button String (C=count;S=Screen;B=Button),system wide procedure state,procedure substate name sent to Vista,procedure recovery name,system has an active alarm,CPS (mm Hg),APS (mm Hg),APS low limit,APS high limit,red reflectance,average red,green reflectance,average green,inlet pump command (ml/min),inlet pump actual (ml/min),AC pump command (ml/min),AC pump actual (ml/min),plasma pump command (ml/min),plasma pump actual (ml/min),collect pump command (ml/min),collect pump actual (ml/min),return pump command (ml/min),return pump actual (ml/min),draw cycle (1=draw 0=return),F=ERROR E=EMPTY L=MIDDLE H=HIGH U=UNKNOWN,centrifuge command (RPM),centrifuge actual (RPM),collect valve command,collect valve position,plasma valve command,plasma valve position,RBC valve command,RBC valve position,last reservoir volume (ml),inlet pump volume (ml),inlet pump total volume (ml),AC pump volume (ml),AC pump total volume (ml),plasma pump volume (ml),collect pump volume (ml),return pump volume (ml),Cassette command,Cassette position,1=door commanded locked,O/C=open/close L/U=lock/unlock,lower level sensor raw reading,upper level sensor raw reading,Cassette State,inlet flow rate operator adjustment,return flow rate operator adjustment,AC ratio operator adjustment,AC infusion rate operator adjustment,adjusted donor HCT (fraction),reservoir HCT (fraction),rbc line HCT (fraction),coagulated needle blood (ml),1=fluid 0=air E=error,1=fluid 0=air E=error,instantaneous AC infusion rate,platelet yield as seen from the RBC detector,donor blood type (see documentation),donor gender (1=female 0=male),donor height,donor hematocrit,donor platelet pre-count,donor TBV (ml),donor weight,disposable set REF number,Cassette type,selected procedure number,target platelet yield,platelet yield as predicted by the collection algorithm,target platelet volume (ml),total volume in the platelet bag (ml),target plasma volume (ml),total volume in the plasma bag (ml),target RBC dose,total rbcs in the RBC bag,target RBC volume (ml),total volume in the RBC bag (ml),procedure target run time (minutes),total volume of blood processed,volume of blood processed during platelet collection,volume of replacement fluid given during the run,AC volume in the platelet bag (ml),AC volume in the plasma bag (ml),AC volume in the RBC bag (ml),Required PAS Volm mL,Total PAS volume pumped out,PAS storage bag capacity,PAS in prod bag,Remaining storage volume in PAS bag,RAS Delivered in the product bag mL,Required RAS Volm mL,Total RAS volume pumped out,AC volume past the valve to RBC bag 1 (ml),RBC Dose past the valve to RBC bag 1 (ml),SS volume past the valve to RBC bag 1 (ml),RBC volume past the valve to RBC bag 1 (ml) ,AC volume past the valve to RBC bag 2 (ml),RBC Dose past the valve to RBC bag 2 (ml),SS volume past the valve to RBC bag 2 (ml),RBC volume past the valve to RBC bag 2 (ml),RAS storage bag capacity,cal=1,RAS in prod bag,Remaining storage volume in RAS bag,volume of saline bolus given during the run,volume of replacement fluid given during saline Rinseback,EMI box temperature (celsius),centrifuge current (amps),raw leak sensor reading,+5 supply (volts),-12 supply (volts),+12 supply (volts),+24 supply (volts),+24 switched supply (volts),+24 supply current (amps),+64 supply (volts),+64 switched supply (volts),+64 supply current (amps),total global heap memory size (words),current global heap allocated memory (words),current global heap allocated memory (%),max global heap allocated memory (words),max global heap allocated memory (%),percent idle CPU time,free log buffer memory (bytes),cumulative lost trace log (bytes),cumulative lost critical log (bytes),metered storage run time (minutes),end of run value AC to Donor (use last entry),end of run value Offline PAS (use last entry),end of run value Offline RAS prod 1 (use last entry),end of run value Offline RAS prod 2 (use last entry),end of run value PAS volume in PLT prod (use last entry),end of run value PLS Residual (use last entry),end of run value PostCount (use last entry),end of run value Post HCT (use last entry),end of run value RAS volume in prod 1 (use last entry),end of run value RAS volume in prod 2 (use last entry),end of run value RBC Residual (use last entry),end of run value RBC volume prod 1 (use last entry),end of run value RBC volume prod 2 (use last entry)';

  static const String reveosDescriptionRow = ',configuration name,current sequence state,accumulated time (secs),time remaining (secs),active alarms,Language,machine in service mode (1=service 0=normal,lid state (Open Closed Unknown),lid lock command (Unlock Lock Stop),lid lock state (Locked Unlocked Unknown),lid lock power state (On Off),centrifuge RPM command (0 to 3200),centrifuge ramp rate (0 to 160 RPM/sec),actual centrifuge RPM (0 to 3500),centrifuge line voltage (0 to 300 V),centrifuge bus voltage (0 to 300 V),Line sensor autocal underway for bucket 1 (On Off),Bucket sensor autocal underway for bucket 1 (On Off),gain 1 for line sensor 1,gain 2 for line sensor 1,Led Adjust 1 for line sensor 1,Led Adjust 2 for line sensor 1,gain for bucket 1 sensor,Led Adjust for bucket 1 sensor,bucket 1 rotor interface fault,bucket 1 sensor fault,Bucket sensor reading for bucket 1,Temp sensor reading for bucket 1,Pressure sensor reading for bucket 1,Bucket lid latch status for bucket 1,line BlueTransmit for bucket 1,line BlueReflect for bucket 1,line RedTransmit for bucket 1,line RedReflect for bucket 1,plasma valve RF enable for bucket 1,plasma valve seal complete for bucket 1,Plasma Valve Rf Select Command for Bucket 1,platelet valve RF enable for bucket 1,platelet valve seal complete for bucket 1,Platelet Valve Rf Select Command for Bucket 1,leukopack valve RF enable for bucket 1,leukopack valve seal complete for bucket 1,Leukopack Valve Rf Select Command for Bucket 1,Line sensor autocal underway for bucket 2 (On Off),Bucket sensor autocal underway for bucket 2 (On Off),gain 1 for line sensor 2,gain 2 for line sensor 2,Led Adjust 1 for line sensor 2,Led Adjust 2 for line sensor 2,gain for bucket 2 sensor,Led Adjust for bucket 2 sensor,bucket 2 rotor interface fault,bucket 2 sensor fault,Bucket sensor reading for bucket 2,Temp sensor reading for bucket 2,Pressure sensor reading for bucket 2,Bucket lid latch status for bucket 2,line BlueTransmit for bucket 2,line BlueReflect for bucket 2,line RedTransmit for bucket 2,line RedReflect for bucket 2,plasma valve RF enable for bucket 2,plasma valve seal complete for bucket 2,Plasma Valve Rf Select Command for Bucket 2,platelet valve RF enable for bucket 2,platelet valve seal complete for bucket 2,Platelet Valve Rf Select Command for Bucket 2,leukopack valve RF enable for bucket 2,leukopack valve seal complete for bucket 2,Leukopack Valve Rf Select Command for Bucket 2,Line sensor autocal underway for bucket 3 (On Off),Bucket sensor autocal underway for bucket 3 (On Off),gain 1 for line sensor 3,gain 2 for line sensor 3,Led Adjust 1 for line sensor 3,Led Adjust 2 for line sensor 3,gain for bucket 3 sensor,Led Adjust for bucket 3 sensor,bucket 3 rotor interface fault,bucket 3 sensor fault,Bucket sensor reading for bucket 3,Temp sensor reading for bucket 3,Pressure sensor reading for bucket 3,Bucket lid latch status for bucket 3,line BlueTransmit for bucket 3,line BlueReflect for bucket 3,line RedTransmit for bucket 3,line RedReflect for bucket 3,plasma valve RF enable for bucket 3,plasma valve seal complete for bucket 3,Plasma Valve Rf Select Command for Bucket 3,platelet valve RF enable for bucket 3,platelet valve seal complete for bucket 3,Platelet Valve Rf Select Command for Bucket 3,leukopack valve RF enable for bucket 3,leukopack valve seal complete for bucket 3,Leukopack Valve Rf Select Command for Bucket 3,Line sensor autocal underway for bucket 4 (On Off),Bucket sensor autocal underway for bucket 4 (On Off),gain 1 for line sensor 4,gain 2 for line sensor 4,Led Adjust 1 for line sensor 4,Led Adjust 2 for line sensor 4,gain for bucket 4 sensor,Led Adjust for bucket 4 sensor,bucket 4 rotor interface fault,bucket 4 sensor fault,Bucket sensor reading for bucket 4,Temp sensor reading for bucket 4,Pressure sensor reading for bucket 4,Bucket lid latch status for bucket 4,line BlueTransmit for bucket 4,line BlueReflect for bucket 4,line RedTransmit for bucket 4,line RedReflect for bucket 4,plasma valve RF enable for bucket 4,plasma valve seal complete for bucket 4,Plasma Valve Rf Select Command for Bucket 4,platelet valve RF enable for bucket 4,platelet valve seal complete for bucket 4,Platelet Valve Rf Select Command for Bucket 4,leukopack valve RF enable for bucket 4,leukopack valve seal complete for bucket 4,Leukopack Valve Rf Select Command for Bucket 4,Valve state for bucket 1 plasma valve,Valve state for bucket 2 plasma valve,Valve state for bucket 3 plasma valve,Valve state for bucket 4 plasma valve,Valve state for bucket 1 platelet valve,Valve state for bucket 2 platelet valve,Valve state for bucket 3 platelet valve,Valve state for bucket 4 platelet valve,Valve state for bucket 1 leukopack valve,Valve state for bucket 2 leukopack valve,Valve state for bucket 3 leukopack valve,Valve state for bucket 4 leukopack valve,hydraulic flow rate command (-3000 to 3000 ml/min),hydraulic flow ramp rate command (-1000 to 1000 ml/min/sec),Actual Piston Flow Rate (+ towards the ExtendedLS and - to the RetractedLS ),Actual Flow Rate to the Rotor( + to the Rotor and - from the Rotor),hydraulic pressure limit (0 to 4.0 bar),absolute hydraulic pressure reading (0 to 4.0 bar),raw hydraulic pressure reading (0 to 10000 mV),Hydraulic volume to the Rotor,hydraulic position reading,Hydraulic valve 1 ( Rod Side) command,Hydraulic valve 2 ( Head Side) command,hydraulic limit switch reading ( ExtendedLS Unknown RetractedLS Error ),5V reference(mv),Ground (mv),vibration force (g),vibration sensor raw reading,vibration displacement sensor raw reading,leak detector reading (Leak NoLeak Error),centrifuge power command (On Off),centrifuge power status (On Off),safety centrifuge speed (0 to 3500 RPM),safety lid position state (Open Closed Unknown),safety lid lock state (Locked Unlocked Unknown),lid lock power command (On Off),safety lid lock power state (On Off),safety stop switch state (Pressed Released Unknown),Safety fault status (bitfield),number of hours of accumulated centrifuge running time,number of accumulated procedures,number of hours of accumulated procedure time,Basin Temperature (Degrees C),Bearing Temperature (Degrees C),H2O Temperature (Degrees C),Rotor board Temperature (Celcius),Auto Calibration Command for Bucket 1 Line Sensor,Auto Calibration Command for Bucket 1 Bucket Sensor,Bucket Sensor Gain Command for Bucket 1,Line Sensor Gain Command for Bucket 1,Plasma Valve Command for Bucket 1,Platelet Valve Command for Bucket 1,Leukopack Valve Command for Bucket 1,Auto Calibration Command for Bucket 2 Line Sensor,Auto Calibration Command for Bucket 2 Bucket Sensor,Bucket Sensor Gain Command for Bucket 2,Line Sensor Gain Command for Bucket 2,Plasma Valve Command for Bucket 2,Platelet Valve Command for Bucket 2,Leukopack Valve Command for Bucket 2,Auto Calibration Command for Bucket 3 Line Sensor,Auto Calibration Command for Bucket 3 Bucket Sensor,Bucket Sensor Gain Command for Bucket 3,Line Sensor Gain Command for Bucket 3,Plasma Valve Command for Bucket 3,Platelet Valve Command for Bucket 3,Leukopack Valve Command for Bucket 3,Auto Calibration Command for Bucket 4 Line Sensor,Auto Calibration Command for Bucket 4 Bucket Sensor,Bucket Sensor Gain Command for Bucket 4,Line Sensor Gain Command for Bucket 4,Plasma Valve Command for Bucket 4,Platelet Valve Command for Bucket 4,Leukopack Valve Command for Bucket 4,Hydraulics Purge Command,Hydraulics System Reset Command,Lid Command,Lid Power Command,Bucket 1 Status,Bucket 2 Status,Bucket 3 Status,Bucket 4 Status';

  static String _nativePreambleFromDlog(
    Uint8List input,
    DlogDecodeResult result,
    String platform,
  ) {
    final gzip = result.gzipOffset >= 0 ? result.gzipOffset : _findGzip(input);
    final end = gzip > 0 ? gzip : math.min(input.length, 2048);
    final text = latin1.decode(input.sublist(0, end), allowInvalid: true);
    final lines = text.split(RegExp(r'[\r\n]+'));

    String confidential = '';
    String logFile = '';
    String machineLine = '';
    String trimaBuildLine = '';
    for (final line in lines) {
      final t = line.trimRight();
      if (confidential.isEmpty && t.startsWith('CONFIDENTIAL:')) confidential = t;
      if (logFile.isEmpty && t.startsWith('Log file:')) logFile = t;
      if (platform == 'Trima' && trimaBuildLine.isEmpty && t.startsWith('Trima Build')) {
        final cut = t.indexOf(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'));
        trimaBuildLine = cut >= 0 ? t.substring(0, cut) : t;
      }
      if (machineLine.isEmpty && t.toLowerCase().startsWith(platform.toLowerCase() + ':')) {
        // La línea de identificación termina antes del primer byte de control.
        // En Reveos, después de id=cidsvcusb comienza inmediatamente una
        // estructura binaria de la cabecera DLOG (por ejemplo 0x1A 0x04 ...).
        // No debe copiarse esa estructura al CSV nativo.
        final cut = t.indexOf(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'));
        machineLine = cut >= 0 ? t.substring(0, cut) : t;
      }
    }

    final dt = platform == 'Trima'
        ? (_trimaStartFromHeader(input) ?? result.timestampInfo.dlogStart)
        : result.timestampInfo.dlogStart;
    final date = dt == null ? ''
        : '${dt.year.toString().padLeft(4,'0')}${dt.month.toString().padLeft(2,'0')}${dt.day.toString().padLeft(2,'0')}_'
          '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';

    final b = StringBuffer();
    // El CSV nativo reemplaza las comas del aviso confidencial por espacios.
    if (confidential.isNotEmpty) b.writeln(confidential.replaceAll(',', ' '));
    if (logFile.isNotEmpty) b.writeln(logFile);
    if (platform == 'Trima' && trimaBuildLine.isNotEmpty) b.writeln(trimaBuildLine.replaceAll(',', ' '));
    if (machineLine.isNotEmpty) b.writeln(machineLine.replaceAll(',', ' '));
    b.writeln(' ');
    b.writeln(' ');
    b.writeln('Log Version: 3.1       Platform: $platform    Date: $date');
    return b.toString();
  }

  static String reveosFullCsv(DlogDecodeResult result, Uint8List originalDlog) {
    final b = StringBuffer();
    b.write(_nativePreambleFromDlog(originalDlog, result, 'Reveos'));
    final sourceHeader = result.originalHeader;
    final header = sourceHeader.length > 1 ? sourceHeader.sublist(1) : <String>[];
    b.writeln(header.map(_csv).join(','));
    b.writeln(reveosDescriptionRow);

    for (final record in result.records) {
      if (record.classification != DlogRecordClass.procedure &&
          record.classification != DlogRecordClass.trace) continue;
      final values = <String,String>{};
      for (final field in record.fields) values[field.name] = field.formattedValue;
      final row = <String>[];
      for (var i=1; i<sourceHeader.length; i++) {
        final column = sourceHeader[i];
        var cell = column == 'timestamp' ? record.timestampString : (values[column] ?? '');
        row.add(cell);
      }
      if (record.traceNode != null) {
        if (record.traceCategory != null) {
          row.add(record.traceCategory!);
          row.add(record.traceNode!);
          if (record.traceMessage != null) row.add(record.traceMessage!);
        } else {
          row.add(record.traceNode!);
          row.add('  ${record.traceMessage ?? ''}'.trimRight());
        }
      }
      b.writeln(row.map(_csv).join(','));
    }
    if (!_reveosHasCompleteGzipTrailer(originalDlog, result.gzipOffset, result.decompressedSize)) {
      // El conversor oficial deja una fila vacia y explicita la ausencia del EOF record.
      b.writeln();
      b.writeln('<<EOF RECORD NOT FOUND>>');
    } else {
      // En un log completo conserva el cierre normal del CSV.
      b.writeln();
      b.writeln();
      b.writeln();
    }
    return b.toString();
  }

  static String trimaFullCsv(DlogDecodeResult result, Uint8List originalDlog) {
    final b = StringBuffer();
    b.write(_nativePreambleFromDlog(originalDlog, result, 'Trima'));
    final procedure = procedureCsv(result.records, originalHeader: result.originalHeader);
    final firstNl = procedure.indexOf('\n');
    if (firstNl >= 0) {
      b.write(procedure.substring(0, firstNl + 1));
      b.writeln(trimaDescriptionRow);
      b.write(procedure.substring(firstNl + 1));
    } else {
      b.write(procedure);
    }
    return b.toString();
  }

  static String optiaFullCsv(DlogDecodeResult result, Uint8List originalDlog) {
    final b = StringBuffer();
    b.write(_optiaPreambleFromDlog(originalDlog, result));

    final sourceHeader = result.originalHeader;
    final header = sourceHeader.length > 1 ? sourceHeader.sublist(1) : <String>[];
    b.writeln(header.map(_csv).join(','));
    b.writeln(optiaDescriptionRow);

    for (final record in result.records) {
      if (record.classification != DlogRecordClass.procedure &&
          record.classification != DlogRecordClass.trace) continue;

      final values = <String,String>{};
      for (final field in record.fields) {
        values[field.name] = field.formattedValue;
      }

      final row = <String>[];
      for (var i=1; i<sourceHeader.length; i++) {
        final column = sourceHeader[i];
        row.add(column == 'timestamp' ? record.timestampString : (values[column] ?? ''));
      }
      if (record.traceNode != null) {
        row.add(record.traceNode!);
        row.add('  ${record.traceMessage ?? ''}'.trimRight());
      } else if (record.optiaExtraColumn != null) {
        // Gen2 binary/image records occupy the first native extra column.
        row.add(record.optiaExtraColumn!);
      }
      b.writeln(row.map(_csv).join(','));
    }
    return b.toString();
  }

  // ============================================================
  // ALARM OUTPUT
  // ============================================================

  /// Extrae cambios de alarma de los registros ya decodificados.
  /// No modifica el CSV nativo. Funciona para Trima, Optia y Reveos
  /// usando los campos Alarm/Alarms disponibles en cada formato.
  /// Extrae eventos técnicos de Trima registrados en TRACE como
  /// `CriticalOutput`. Estos eventos se mantienen separados de [DlogAlarm]:
  /// un CriticalOutput no implica necesariamente una alarma oficial.
  ///
  /// Ejemplo real observado:
  ///   CriticalOutput | Node:SAFETY | Ultrasonic read discrepancy: ...
  static List<DlogCriticalEvent> criticalEvents(DlogDecodeResult result) {
    if (result.machine != DlogMachine.trima) return const <DlogCriticalEvent>[];

    final out = <DlogCriticalEvent>[];
    for (final record in result.records) {
      final category = (record.traceCategory ?? '').trim();
      if (category.toLowerCase() != 'criticaloutput') continue;

      final message = (record.traceMessage ?? '').trim();
      if (message.isEmpty) continue;

      final node = (record.traceNode ?? '').trim();
      final key = _criticalEventKey(message);
      out.add(DlogCriticalEvent(
        timestamp: record.timestamp,
        sourcePath: result.sourcePath ?? '',
        machine: result.machine.name,
        category: category,
        node: node,
        eventKey: key,
        message: message,
        isFault: _criticalOutputLooksLikeFault(message),
        recordIndex: record.outputIndex,
      ));
    }
    return out;
  }

  /// Sólo los CriticalOutput que tienen semántica de falla/anomalía.
  /// Se usa para RAT sin convertirlos en alarmas oficiales ni sumarlos al
  /// contador de alarmas.
  static List<DlogCriticalEvent> criticalFaultEvents(DlogDecodeResult result) =>
      criticalEvents(result).where((e) => e.isFault).toList(growable: false);

  static String _criticalEventKey(String message) {
    final text = message.trim();
    final colon = text.indexOf(':');
    final head = (colon >= 0 ? text.substring(0, colon) : text).trim();
    // Mantiene una clave estable para agrupar incidencias del mismo tipo.
    return head.replaceAll(RegExp(r'\s+'), ' ');
  }

  static bool _criticalOutputLooksLikeFault(String message) {
    final m = message.toLowerCase();

    // Mensajes de inicialización/estado conocidos que pueden viajar por
    // CriticalOutput pero no representan una falla.
    const benign = <String>[
      ' ready',
      'ready ',
      'doonceregistrar',
      'serializer junction ready',
      'initialized',
      'initialised',
    ];
    if (m.trim() == 'ready' || benign.any(m.contains)) return false;

    // Marcadores deliberadamente conservadores. Podemos ampliar esta lista
    // con nuevos DLOG reales sin alterar la detección de alarmas oficiales.
    const faultMarkers = <String>[
      'discrepancy',
      'fault',
      'failure',
      'failed',
      'error',
      'mismatch',
      'out of range',
      'invalid',
      'timeout',
      'too high',
      'too low',
    ];
    return faultMarkers.any(m.contains);
  }

  static String criticalEventsCsv(DlogDecodeResult result, {bool faultsOnly = false}) {
    final events = faultsOnly ? criticalFaultEvents(result) : criticalEvents(result);
    final b = StringBuffer();
    b.writeln('timestamp,dateMillisecondsSinceEpoch,filePath,machine,category,node,eventKey,isFault,message,recordIndex');
    for (final event in events) {
      b.writeln(<String>[
        event.timestampString,
        event.dateMillisecondsSinceEpoch?.toString() ?? '',
        event.sourcePath,
        event.machine,
        event.category,
        event.node,
        event.eventKey,
        event.isFault ? '1' : '0',
        event.message,
        event.recordIndex.toString(),
      ].map(_csv).join(','));
    }
    return b.toString();
  }

  static List<DlogAlarm> alarms(DlogDecodeResult result) {
    // Optia y Reveos: la fuente de verdad es exclusivamente el TRACE
    // que contiene RAISED_ALARM. No inferimos alarmas desde Alarm,
    // Alarms, AlarmStateFlag ni desde cualquier texto que contenga ALARM.
    if (result.machine == DlogMachine.optia ||
        result.machine == DlogMachine.reveos) {
      return _raisedAlarmsFromTrace(result);
    }

    // Trima conserva por ahora la lógica anterior basada en campos.
    // Su tratamiento específico de alarmas se revisará por separado.
    return _alarmsFromFields(result);
  }

  static List<DlogAlarm> _raisedAlarmsFromTrace(DlogDecodeResult result) {
    final out = <DlogAlarm>[];

    for (final record in result.records) {
      final message = record.traceMessage;
      if (message == null || message.isEmpty) continue;

      // Coincidencia deliberadamente exacta: para Optia/Reveos solamente
      // RAISED_ALARM representa el evento que queremos exportar.
      if (!message.contains('RAISED_ALARM')) continue;

      final alarmName = _raisedAlarmValue(message, 'ALARM_NAME');
      final alarmId = _raisedAlarmValue(message, 'ALARM_ID');
      final nodeId = _raisedAlarmValue(message, 'NODE_ID');

      // Evita generar DlogAlarm incompletos por mensajes no conformes.
      if (alarmName == null || alarmName.isEmpty ||
          alarmId == null || alarmId.isEmpty) {
        continue;
      }

      // Para Optia/Reveos priorizamos ALARM_NAME contra el campo
      // "Alarm Identification" del manual. ALARM_ID queda preservado
      // únicamente como identificador técnico original del DLOG.
      final ref = DlogAlarmCatalog.byAlarmIdentification(
            result.machine.name,
            alarmName,
          ) ??
          DlogAlarmCatalog.lookup(
            machine: result.machine.name,
            alarmName: alarmName,
            dlogText: message,
          );

      out.add(DlogAlarm(
        timestamp: record.timestamp,
        sourcePath: result.sourcePath ?? '',
        machine: result.machine.name,
        // ALARM_ID es el identificador interno del DLOG. No se expone como
        // código oficial. Reveos obtiene el código numérico del manual;
        // Optia no inventa un código cuando el manual sólo define
        // Alarm Identification.
        alarmId: alarmId,
        alarmKey: ref?.alarmId ?? alarmName,
        alarmCode: result.machine == DlogMachine.reveos
            ? (ref?.code ?? '')
            : '',
        alarmName: ref?.name.isNotEmpty == true ? ref!.name : alarmName,
        rawAlarmName: alarmName,
        catalogKnown: ref != null,
        category: ref?.category ?? '',
        statusLine: ref?.statusLine ?? '',
        messageType: ref?.messageType ?? '',
        dlogText: ref?.dlogText ?? '',
        occursDuring: ref?.occursDuring ?? '',
        detection: ref?.detection ?? '',
        possibleCauses: ref?.possibleCauses ?? '',
        suggestedActions: ref?.suggestedActions ?? '',
        state: 'RAISED',
        node: (nodeId != null && nodeId.isNotEmpty)
            ? nodeId
            : (record.traceNode ?? ''),
        // Conservamos el verbose completo para no perder MODULE_LEVEL,
        // ADDED_CONSTRAINT u otros campos que aparezcan en el futuro.
        source: message,
        active: true,
        recordIndex: record.outputIndex,
      ));
    }

    return out;
  }

  static String? _raisedAlarmValue(String message, String key) {
    // Captura el valor hasta el siguiente campo {XXX}, fin de línea o fin
    // del mensaje. Tolera espacios, tabs y mensajes multilínea.
    final match = RegExp(
      '\\{$key\\}\\s*([^\\r\\n{]+)',
      caseSensitive: false,
    ).firstMatch(message);

    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static List<DlogAlarm> _alarmsFromFields(DlogDecodeResult result) {
    // Trima 7.x expone dos campos especialmente útiles:
    //   AlarmEnumCurrent -> número de mensaje (ej. 163)
    //   AlarmCurrent     -> texto/tipo de la alarma actual
    //
    // AlarmStateFlag cambia también durante actividad normal y NO debe
    // considerarse por sí solo una nueva incidencia.
    if (result.machine == DlogMachine.trima) {
      // Hay al menos dos variantes reales de Trima en los DLOG estudiados:
      //  - nuevas: AlarmEnumCurrent + AlarmCurrent
      //  - anteriores (p.ej. build 20.8): sólo el campo Alarm contiene
      //    "ALARM TYPE: <tipo>-<leyenda DLOG>".
      // Elegimos la fuente disponible sin usar AlarmStateFlag como incidencia.
      final current = _trimaAlarmsFromCurrentFields(result);
      if (current.isNotEmpty) return current;
      return _trimaAlarmsFromLegacyAlarmField(result);
    }

    // Fallback histórico para familias/formats todavía no caracterizados.
    final out = <DlogAlarm>[];
    String? previousAlarm;
    String? previousState;

    for (final record in result.records) {
      String alarm = '';
      String state = '';

      for (final field in record.fields) {
        final n = field.name.toLowerCase();
        if (n == 'alarm' || n == 'alarms') {
          alarm = field.formattedValue.trim();
        } else if (n == 'alarmstateflag') {
          state = field.formattedValue.trim();
        }
      }

      if (alarm.isNotEmpty || state.isNotEmpty) {
        if (alarm != previousAlarm || state != previousState) {
          final active = _alarmLooksActive(alarm, state);
          out.add(DlogAlarm(
            timestamp: record.timestamp,
            sourcePath: result.sourcePath ?? '',
            machine: result.machine.name,
            alarmCode: _alarmCode(alarm),
            alarmName: alarm,
            state: state.isNotEmpty ? state : (active ? 'ACTIVE' : 'INACTIVE'),
            node: record.traceNode ?? '',
            source: 'FIELD',
            active: active,
            recordIndex: record.outputIndex,
          ));
          previousAlarm = alarm;
          previousState = state;
        }
      }
    }

    return out;
  }

  static List<DlogAlarm> _trimaAlarmsFromCurrentFields(
    DlogDecodeResult result,
  ) {
    final out = <DlogAlarm>[];

    String activeCode = '';
    String lastAlarmText = '';

    for (final record in result.records) {
      String enumValue = '';
      String alarmCurrent = '';
      String alarmStateFlag = '';
      bool hasEnumField = false;
      bool hasCurrentField = false;

      for (final field in record.fields) {
        final name = field.name.trim().toLowerCase();
        if (name == 'alarmenumcurrent') {
          hasEnumField = true;
          enumValue = field.formattedValue.trim();
        } else if (name == 'alarmcurrent') {
          hasCurrentField = true;
          alarmCurrent = field.formattedValue.trim();
        } else if (name == 'alarmstateflag') {
          // Se conserva sólo como contexto. No genera incidencias.
          alarmStateFlag = field.formattedValue.trim();
        }
      }

      // Los DATA de Trima son snapshots parciales. Si un campo no está en
      // este registro no significa que haya cambiado: conservamos el último
      // texto conocido.
      if (hasCurrentField) {
        lastAlarmText = alarmCurrent;
      }

      if (!hasEnumField) continue;

      final code = _trimaAlarmEnumCode(enumValue);

      // 0/vacío/valor no numérico = no hay una alarma enumerada actual.
      // Sirve para rearmar la detección, pero NO crea una incidencia CLEAR.
      if (code.isEmpty) {
        activeCode = '';
        continue;
      }

      // Mientras el mismo código permanezca activo no volvemos a contarlo.
      if (code == activeCode) continue;
      activeCode = code;

      final rawName = alarmCurrent.isNotEmpty ? alarmCurrent : lastAlarmText;
      final ref = DlogAlarmCatalog.lookup(
        machine: 'trima',
        code: code,
        alarmName: rawName,
        dlogText: rawName,
      );
      final canonical = ref?.name;

      out.add(DlogAlarm(
        timestamp: record.timestamp,
        sourcePath: result.sourcePath ?? '',
        machine: result.machine.name,
        alarmId: enumValue,
        alarmKey: ref?.alarmId ?? '',
        alarmCode: ref?.code.isNotEmpty == true ? ref!.code : code,
        alarmName: canonical?.isNotEmpty == true ? canonical! : rawName,
        rawAlarmName: rawName,
        catalogKnown: ref != null,
        category: ref?.category ?? '',
        statusLine: ref?.statusLine ?? '',
        messageType: ref?.messageType ?? '',
        dlogText: ref?.dlogText ?? '',
        occursDuring: ref?.occursDuring ?? '',
        detection: ref?.detection ?? '',
        possibleCauses: ref?.possibleCauses ?? '',
        suggestedActions: ref?.suggestedActions ?? '',
        state: 'RAISED',
        node: record.traceNode ?? '',
        source: rawName.isEmpty
            ? 'AlarmEnumCurrent=$enumValue'
            : 'AlarmEnumCurrent=$enumValue; AlarmCurrent=$rawName'
                '${alarmStateFlag.isEmpty ? '' : '; AlarmStateFlag=$alarmStateFlag'}',
        active: true,
        recordIndex: record.outputIndex,
      ));
    }

    return out;
  }

  static List<DlogAlarm> _trimaAlarmsFromLegacyAlarmField(
    DlogDecodeResult result,
  ) {
    final out = <DlogAlarm>[];
    String previous = '';

    for (final record in result.records) {
      String raw = '';
      bool hasAlarm = false;
      for (final field in record.fields) {
        if (field.name.trim().toLowerCase() == 'alarm') {
          hasAlarm = true;
          raw = field.formattedValue.trim();
          break;
        }
      }
      if (!hasAlarm) continue;

      // El campo Alarm también es snapshot parcial: un valor vacío explícito
      // rearma la detección; registros sin el campo no cambian el estado.
      if (raw.isEmpty || _trimaLegacyAlarmIsClear(raw)) {
        previous = '';
        continue;
      }
      if (raw == previous) continue;
      previous = raw;

      final parsed = _parseTrimaLegacyAlarm(raw);
      final legend = parsed.$2;
      final type = parsed.$1;
      if (legend.isEmpty) continue;

      // En estos DLOG no hay AlarmEnumCurrent. El código se obtiene del
      // catálogo comparando la leyenda DLOG, nunca de AlarmStateFlag.
      final ref = DlogAlarmCatalog.lookup(
        machine: 'trima',
        alarmName: legend,
        dlogText: legend,
      );

      out.add(DlogAlarm(
        timestamp: record.timestamp,
        sourcePath: result.sourcePath ?? '',
        machine: result.machine.name,
        alarmId: '',
        alarmKey: ref?.alarmId ?? '',
        alarmCode: ref?.code ?? '',
        alarmName: ref?.name.isNotEmpty == true ? ref!.name : legend,
        rawAlarmName: raw,
        catalogKnown: ref != null,
        category: ref?.category ?? '',
        statusLine: ref?.statusLine ?? '',
        messageType: ref?.messageType.isNotEmpty == true ? ref!.messageType : type,
        dlogText: ref?.dlogText.isNotEmpty == true ? ref!.dlogText : legend,
        occursDuring: ref?.occursDuring ?? '',
        detection: ref?.detection ?? '',
        possibleCauses: ref?.possibleCauses ?? '',
        suggestedActions: ref?.suggestedActions ?? '',
        state: 'RAISED',
        node: record.traceNode ?? '',
        source: 'Alarm=$raw',
        active: true,
        recordIndex: record.outputIndex,
      ));
    }
    return out;
  }

  static (String, String) _parseTrimaLegacyAlarm(String raw) {
    var text = raw.trim();
    final m = RegExp(r'^ALARM\s+TYPE\s*:\s*([^\-]+)-\s*(.*)$', caseSensitive: false)
        .firstMatch(text);
    if (m != null) {
      return ((m.group(1) ?? '').trim(), (m.group(2) ?? '').trim());
    }
    return ('', text);
  }

  static bool _trimaLegacyAlarmIsClear(String value) {
    final v = value.trim().toUpperCase();
    return v.isEmpty || v == '0' || v == 'NONE' || v == 'NO ALARM' ||
        v == 'NO_ALARM' || v == 'CLEAR' || v == 'CLEARED';
  }

  static String _trimaAlarmEnumCode(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';

    // Acepta "163", "163.0" y representaciones que incluyan el número,
    // pero evita convertir AlarmStateFlag u otros estados en incidencias.
    final direct = num.tryParse(v.replaceAll(',', '.'));
    if (direct != null) {
      final n = direct.toInt();
      return n > 0 ? n.toString() : '';
    }

    final m = RegExp(r'(?<!\d)(\d{1,6})(?!\d)').firstMatch(v);
    if (m == null) return '';
    final n = int.tryParse(m.group(1)!);
    return (n != null && n > 0) ? n.toString() : '';
  }

  static bool _alarmLooksActive(String alarm, String state) {
    final a = alarm.trim().toUpperCase();
    final s = state.trim().toUpperCase();
    if (a.isEmpty && s.isEmpty) return false;
    const inactive = <String>{'0', 'FALSE', 'OFF', 'NONE', 'NO ALARM', 'NO_ALARM', 'CLEAR', 'CLEARED', 'INACTIVE'};
    if (inactive.contains(a) || inactive.contains(s)) return false;
    return true;
  }

  static String _alarmCode(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    final m = RegExp(r'(?<![A-Za-z0-9])([A-Za-z]*\d+[A-Za-z0-9_-]*)').firstMatch(v);
    return m?.group(1) ?? '';
  }

  static String alarmsCsv(DlogDecodeResult result) {
    final b = StringBuffer();
    b.writeln('timestamp,dateMillisecondsSinceEpoch,filePath,machine,alarmId,alarmKey,alarmCode,alarmName,rawAlarmName,catalogKnown,category,statusLine,messageType,dlogText,occursDuring,detection,possibleCauses,suggestedActions,state,active,node,source,recordIndex');
    for (final alarm in alarms(result)) {
      b.writeln(<String>[
        alarm.timestampString,
        alarm.dateMillisecondsSinceEpoch?.toString() ?? '',
        alarm.sourcePath,
        alarm.machine,
        alarm.alarmId,
        alarm.alarmKey,
        alarm.alarmCode,
        alarm.alarmName,
        alarm.rawAlarmName,
        alarm.catalogKnown ? '1' : '0',
        alarm.category,
        alarm.statusLine,
        alarm.messageType,
        alarm.dlogText,
        alarm.occursDuring,
        alarm.detection,
        alarm.possibleCauses,
        alarm.suggestedActions,
        alarm.state,
        alarm.active ? '1' : '0',
        alarm.node,
        alarm.source,
        alarm.recordIndex.toString(),
      ].map(_csv).join(','));
    }
    return b.toString();
  }

  // ============================================================
  // MULTIPLATFORM OUTPUT (NO dart:io)
  // ============================================================

  /// Genera todos los resultados en memoria. Funciona en Web, Windows,
  /// Android, iOS, macOS y Linux.
  static DlogOutputBundle buildOutputBundle(
    DlogDecodeResult result, {
    DlogOutputOptions options = const DlogOutputOptions(),
  }) {
    final sourceName =
        result.sourcePath?.replaceAll('\\', '/').split('/').last ?? 'dlog';
    final dot = sourceName.lastIndexOf('.');
    final baseName = dot > 0 ? sourceName.substring(0, dot) : sourceName;

    // El CSV nativo y procedureCsv son la misma representación para
    // Trima/Optia/Reveos. Si se piden ambos se construye UNA sola vez.
    String? procedureOutput;
    if (options.nativeCsv || options.procedureCsv) {
      final original = result.originalBytes;
      if (original != null &&
          (result.machine == DlogMachine.trima ||
              result.machine == DlogMachine.optia ||
              result.machine == DlogMachine.reveos)) {
        procedureOutput = switch (result.machine) {
          DlogMachine.trima => trimaFullCsv(result, original),
          DlogMachine.optia => optiaFullCsv(result, original),
          DlogMachine.reveos => reveosFullCsv(result, original),
          DlogMachine.unknown => procedureCsv(
              result.records,
              originalHeader: result.originalHeader,
            ),
        };
      } else {
        procedureOutput = procedureCsv(
          result.records,
          originalHeader: result.originalHeader,
        );
      }
    }

    // Las alarmas pueden alimentar List<DlogAlarm> y/o alarmsCsv.
    // Se detectan una sola vez si cualquiera de las dos salidas fue pedida.
    List<DlogAlarm>? detectedAlarms;
    if (options.alarms || options.alarmsCsv) {
      detectedAlarms = alarms(result);
    }

    String? alarmCsvOutput;
    if (options.alarmsCsv) {
      final b = StringBuffer();
      b.writeln(
        'timestamp,dateMillisecondsSinceEpoch,filePath,machine,alarmId,alarmKey,alarmCode,alarmName,rawAlarmName,catalogKnown,category,statusLine,messageType,dlogText,occursDuring,detection,possibleCauses,suggestedActions,state,active,node,source,recordIndex',
      );
      for (final alarm in detectedAlarms ?? const <DlogAlarm>[]) {
        b.writeln(<String>[
          alarm.timestampString,
          alarm.machine,
          alarm.alarmId,
          alarm.alarmKey,
          alarm.alarmCode,
          alarm.alarmName,
          alarm.state,
          alarm.active ? '1' : '0',
          alarm.node,
          alarm.source,
          alarm.recordIndex.toString(),
        ].map(_csv).join(','));
      }
      alarmCsvOutput = b.toString();
    }

    return DlogOutputBundle(
      baseName: baseName,
      recordsCsv: options.recordsCsv ? recordsCsv(result.records) : null,
      fieldsCsv: options.fieldsCsv ? fieldsCsv(result.records) : null,
      procedureCsv: options.procedureCsv ? procedureOutput : null,
      nativeCsv: options.nativeCsv ? procedureOutput : null,
      alarms: options.alarms ? detectedAlarms : null,
      alarmsCsv: alarmCsvOutput,
      summaryText: options.summary ? summary(result) : null,
    );
  }

  // ============================================================
  // UTILITIES
  // ============================================================

  static int _u16(
    Uint8List data,
    int offset,
  ) {
    if (offset + 2 > data.length) {
      return 0;
    }

    return data[offset] |
        (data[offset + 1] << 8);
  }

  static int _u32(
    Uint8List data,
    int offset,
  ) {
    if (offset + 4 > data.length) {
      return 0;
    }

    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static int _u64(
    Uint8List data,
    int offset,
  ) {
    if (offset + 8 > data.length) {
      return 0;
    }

    var result = 0;

    for (var i = 0; i < 8; i++) {
      result |=
          data[offset + i] << (8 * i);
    }

    return result;
  }

  static double _float32(
    Uint8List data,
  ) {
    final bd =
        ByteData.sublistView(data);

    return bd.getFloat32(
      0,
      Endian.little,
    );
  }

  static double _float64(
    Uint8List data,
  ) {
    final bd =
        ByteData.sublistView(data);

    return bd.getFloat64(
      0,
      Endian.little,
    );
  }

  static bool _isPrintable(
    Uint8List bytes,
  ) {
    if (bytes.isEmpty) {
      return false;
    }

    var printable = 0;

    for (final b in bytes) {
      if ((b >= 32 && b <= 126) ||
          b == 9 ||
          b == 10 ||
          b == 13) {
        printable++;
      }
    }

    return printable /
            bytes.length >
        0.75;
  }

  static double _asciiRatio(
    Uint8List bytes,
  ) {
    if (bytes.isEmpty) {
      return 0;
    }

    var count = 0;

    for (final b in bytes) {
      if (b >= 32 && b <= 126) {
        count++;
      }
    }

    return count / bytes.length;
  }

  static String _extractPrintable(
    Uint8List bytes,
  ) {
    final b = StringBuffer();

    var run = StringBuffer();

    void flush() {
      if (run.length >= 4) {
        if (b.isNotEmpty) {
          b.write(' | ');
        }

        b.write(run.toString());
      }

      run = StringBuffer();
    }

    for (final byte in bytes) {
      if (byte >= 32 &&
          byte <= 126) {
        run.write(
          String.fromCharCode(byte),
        );
      } else {
        flush();
      }
    }

    flush();

    final text = b.toString();

    if (text.length > 500) {
      return text.substring(
        0,
        500,
      );
    }

    return text;
  }

  static int _countPattern(
    Uint8List data,
    List<int> pattern,
  ) {
    return _findAll(
      data,
      pattern,
    ).length;
  }

  static String _hex(
    Uint8List bytes,
  ) {
    return bytes
        .map(
          (b) => b
              .toRadixString(16)
              .padLeft(2, '0')
              .toUpperCase(),
        )
        .join(' ');
  }

  static String ascii(
    Uint8List bytes,
  ) {
    return String.fromCharCodes(
      bytes,
    );
  }

  static String _csv(
    Object? value,
  ) {
    final text =
        value?.toString() ?? '';

    if (text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '"${text.replaceAll('"', '""')}"';
    }

    return text;
  }

  static String _formatDate(
    DateTime value,
  ) {
    return '${value.year.toString().padLeft(4, '0')}/'
        '${value.month.toString().padLeft(2, '0')}/'
        '${value.day.toString().padLeft(2, '0')}';
  }

  static String _recordPreview(
    Dlog022eRecord record,
  ) {
    final values =
        record.fields.take(12).map(
      (f) {
        return '${f.name}=${f.formattedValue}';
      },
    ).join(', ');

    return 'Record #${record.index} '
        'offset=${record.offset} '
        'length=${record.length} '
        'timestamp=${record.timestampString} '
        'fields=${record.fields.length} '
        '[$values]';
  }
 
}

// ================================================================
// MACHINE INFORMATION (V64)
// ================================================================

DlogMachineInfo _extractMachineInfo(
  Uint8List input,
  Uint8List payload,
  DlogMachine machine,
  int gzipOffset,
) {
  final headerLen = gzipOffset > 0 ? gzipOffset : math.min(input.length, 4096);
  final header = latin1.decode(input.sublist(0, headerLen), allowInvalid: true);
  final body = latin1.decode(payload, allowInvalid: true);
  final all = '$header\n$body';

  String? first(List<RegExp> patterns) {
    for (final rx in patterns) {
      final m = rx.firstMatch(all);
      if (m != null) {
        final v = m.group(1)?.trim();
        if (v != null && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  String? last(List<RegExp> patterns) {
    String? value;
    for (final rx in patterns) {
      for (final m in rx.allMatches(all)) {
        final v = m.group(1)?.trim();
        if (v != null && v.isNotEmpty) value = v;
      }
    }
    return value;
  }

  double? number(String? v) {
    if (v == null) return null;
    return double.tryParse(v.replaceAll(',', '.'));
  }
  int? integer(String? v) {
    if (v == null) return null;
    return int.tryParse(v);
  }

  final revision = first([
    RegExp(r'revision\s*=\s*([^\s,\]\r\n]+)', caseSensitive: false),
    RegExp(r'(?:software|program)\s+version\s*[:=]\s*([^\s,\]\r\n]+)', caseSensitive: false),
  ]);

  final buildDate = first([
    RegExp(r'date\s*=\s*([^\r\n]+?)\s{2,}time=', caseSensitive: false),
    RegExp(r'BUILD_DATE\}?\s*[:=]?\s*([^,\]\r\n]+)', caseSensitive: false),
  ]);

  EBoxGeneration? ebox;
  String? iface;
  String? boardPackage;
  if (machine == DlogMachine.trima || machine == DlogMachine.optia) {
    final low = all.toLowerCase();
    final gen2 = low.contains('control pci cca interface') ||
        low.contains('safety pci cca interface') ||
        low.contains('stc pci fpga hardware version');
    final gen1 = low.contains('control2 isa cca interface') ||
        low.contains('safety2 isa cca interface') ||
        low.contains('ebx-11_board_pkg');
    if (gen2) {
      ebox = EBoxGeneration.gen2;
      iface = 'PCI';
    } else if (gen1) {
      ebox = EBoxGeneration.gen1;
      iface = 'ISA';
    } else {
      ebox = EBoxGeneration.unknown;
    }
    boardPackage = first([
      RegExp(r'([A-Za-z0-9_-]+_board_pkg\.out)', caseSensitive: false),
      RegExp(r'(EBX-11)', caseSensitive: false),
    ]);
  }

  final controlHw = first([
    RegExp(r'ControlHW\s+version\s*[:=]\s*([^\r\n]+)', caseSensitive: false),
    RegExp(r'Control2?\s+(?:ISA|PCI)\s+CCA\s+Interface:\s*version\s*=\s*([^\s\r\n]+)', caseSensitive: false),
  ]);
  final safetyHw = first([
    RegExp(r'SafetyHW\s+version\s*[:=]\s*([^\r\n]+)', caseSensitive: false),
    RegExp(r'Safety2?\s+(?:ISA|PCI)\s+CCA\s+Interface:\s*version\s*=\s*([^\s\r\n]+)', caseSensitive: false),
  ]);

  final machineHours = number(last([
    RegExp(r'MachineHours\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false),
    RegExp(r'Current\s+Machine\s+Hour\s+Meter\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false),
  ]));
  final centrifugeHours = number(last([
    RegExp(r'CentrifugeHours\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false),
    RegExp(r'Current\s+Centrifuge\s+Hour\s+Meter\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false),
  ]));
  final procedureCount = integer(last([
    RegExp(r'ProcedureCount\s*=\s*([0-9]+)', caseSensitive: false),
    RegExp(r'(?:Total)?ProcedureCount\s*[:=]\s*([0-9]+)', caseSensitive: false),
  ]));
  final proceduresCompleted = integer(last([
    RegExp(r'ProceduresCompleted\s*=\s*([0-9]+)', caseSensitive: false),
    RegExp(r'CompletedProcedures\s*[:=]\s*([0-9]+)', caseSensitive: false),
  ]));

  return DlogMachineInfo(
    product: machine,
    softwareVersion: revision,
    softwareRevision: revision,
    buildDate: buildDate,
    eBoxGeneration: ebox,
    boardPackage: boardPackage,
    hardwareInterface: iface,
    controlHwVersion: controlHw,
    safetyHwVersion: safetyHw,
    machineHours: machineHours,
    centrifugeHours: centrifugeHours,
    procedureCount: procedureCount,
    proceduresCompleted: proceduresCompleted,
  );
}

// ================================================================
// RESULT
// ================================================================

class DlogImageChunkRef {
  final int index;
  final int payloadOffset;
  const DlogImageChunkRef({required this.index, required this.payloadOffset});
}

class DlogImageRef {
  final int imageId;
  final int? width;
  final int? height;
  final int chunkCount;
  final List<DlogImageChunkRef> chunks;

  const DlogImageRef({
    required this.imageId,
    required this.width,
    required this.height,
    required this.chunkCount,
    required this.chunks,
  });
}


/// Resultado comun para entradas .dlog y .csv usadas por GraphicPage.
class DlogInputResult {
  final bool ok;
  final bool isCsv;
  final DlogOutputBundle? outputs;
  final DlogDecodeResult? decodeResult;
  final List<String> diagnostics;

  const DlogInputResult({
    required this.ok,
    required this.isCsv,
    required this.outputs,
    required this.decodeResult,
    required this.diagnostics,
  });

  factory DlogInputResult.failure(String message) => DlogInputResult(
        ok: false,
        isCsv: false,
        outputs: null,
        decodeResult: null,
        diagnostics: <String>[message],
      );
}

class DlogDecodeResult {
  final bool ok;

  final String? sourcePath;

  final int gzipOffset;

  final int decompressedSize;

  final int payloadSize;

  final List<Dlog022eRecord> records;

  final List<String> diagnostics;

  final _TimestampInfo timestampInfo;

  final List<String> originalHeader;

  final DlogMachine machine;

  /// Normalized machine metadata extracted without changing telemetry decoding.
  final DlogMachineInfo? machineInfo;

  /// Copia de los bytes originales necesaria para generar el CSV nativo
  /// sin volver a leer el archivo (compatible con Flutter Web).
  final Uint8List? originalBytes;

  /// Lightweight index only. Pixel bytes are NOT reconstructed here.
  final List<DlogImageRef> imageRefs;
  bool get hasImages => imageRefs.isNotEmpty;

  // V51 direct outputs: ya se generan dentro de decodeBytes().
  final Uint8List? recordsCsvBytes;
  final Uint8List? fieldsCsvBytes;
  final Uint8List? procedureCsvBytes;
  final Uint8List? nativeCsvBytes;
  final List<DlogAlarm>? alarms;
  final Uint8List? alarmsCsvBytes;
  final String? summaryText;

  DlogDecodeResult({
    required this.ok,
    required this.sourcePath,
    required this.gzipOffset,
    required this.decompressedSize,
    required this.payloadSize,
    required this.records,
    required this.diagnostics,
    required this.timestampInfo,
    required this.originalHeader,
    required this.machine,
    this.machineInfo,
    this.originalBytes,
    this.imageRefs = const <DlogImageRef>[],
    this.recordsCsvBytes,
    this.fieldsCsvBytes,
    this.procedureCsvBytes,
    this.nativeCsvBytes,
    this.alarms,
    this.alarmsCsvBytes,
    this.summaryText,
  });

  
  DlogDecodeResult copyWithOutputs({
    Uint8List? recordsCsvBytes,
    Uint8List? fieldsCsvBytes,
    Uint8List? procedureCsvBytes,
    Uint8List? nativeCsvBytes,
    List<DlogAlarm>? alarms,
    Uint8List? alarmsCsvBytes,
    String? summaryText,
  }) => DlogDecodeResult(
    ok: ok, sourcePath: sourcePath, gzipOffset: gzipOffset,
    decompressedSize: decompressedSize, payloadSize: payloadSize,
    records: records, diagnostics: diagnostics, timestampInfo: timestampInfo,
    originalHeader: originalHeader, machine: machine, machineInfo: machineInfo, originalBytes: originalBytes,
    imageRefs: imageRefs,
    recordsCsvBytes: recordsCsvBytes, fieldsCsvBytes: fieldsCsvBytes,
    procedureCsvBytes: procedureCsvBytes, nativeCsvBytes: nativeCsvBytes,
    alarms: alarms, alarmsCsvBytes: alarmsCsvBytes, summaryText: summaryText,
  );

  factory DlogDecodeResult.failure({
    required List<String> diagnostics,
    }) {
      return DlogDecodeResult(
        ok: false,
        sourcePath: null,
        gzipOffset: -1,
        decompressedSize: 0,
        payloadSize: 0,
        records: const [],
        diagnostics: diagnostics,
        timestampInfo: _TimestampInfo(
          mode: TimestampMode.none,
          dlogStart: null,
          diagnostics: const [],
        ),
        originalHeader: const [],
        machine: DlogMachine.unknown,
        originalBytes: null,
      );
  }
  String get summary {
    return DlogDecoder.summary(
      this,
    );
  }

  /// Genera únicamente las salidas solicitadas en memoria.
  ///
  /// Por defecto TODAS están desactivadas para minimizar memoria.
  DlogOutputBundle buildOutputs({
    DlogOutputOptions options = const DlogOutputOptions(),
  }) =>
      DlogDecoder.buildOutputBundle(this, options: options);

}

// ================================================================
// 022E RECORD
// ================================================================

class Dlog022eRecord {
  final int index;

  // Solo se usa para mantener orden estable en perfiles que se reordenan.
  int? indexOverride;
  int get outputIndex => indexOverride ?? index;

  final int offset;

  final int length;

  final Uint8List raw;

  final List<DlogField> fields;

  final double asciiRatio;

  final int traceMarkers;

  final String printableText;

  DlogRecordClass classification =
      DlogRecordClass.unknown;

  DateTime? timestamp;

  int? elapsedMs;

  // Optia TRACE: columnas adicionales sin cabecera del CSV original.
  String? traceCategory;
  String? traceNode;
  String? traceMessage;

  // Optia eBox Gen2: columna nativa adicional sin cabecera.
  // Ej.: Binary Record Observed_APC Image_1_<imageId>_<chunk>
  String? optiaExtraColumn;

  Dlog022eRecord({
    required this.index,
    required this.offset,
    required this.length,
    required this.raw,
    required this.fields,
    required this.asciiRatio,
    required this.traceMarkers,
    required this.printableText,
  });

  String get timestampString {
    final ts = timestamp;

    if (ts == null) {
      return '';
    }

    return _formatTimestamp(
      ts,
    );
  }

  static String _formatTimestamp(
    DateTime value,
  ) {
    final y =
        value.year.toString().padLeft(4, '0');

    final m =
        value.month.toString().padLeft(2, '0');

    final d =
        value.day.toString().padLeft(2, '0');

    final h =
        value.hour.toString().padLeft(2, '0');

    final min =
        value.minute.toString().padLeft(2, '0');

    final sec =
        value.second.toString().padLeft(2, '0');

    final ms =
        value.millisecond.toString().padLeft(3, '0');

    return '$y/$m/${d}_$h:$min:$sec.$ms';
  }
}

// ================================================================
// FIELD
// ================================================================

class DlogField {
  final int relativeOffset;

  final int id;

  final String name;

  final int typeCode;

  final int length;

  final Object? value;

  final String formattedValue;

  final String rawHex;

  final int trailer;

  DlogField({
    required this.relativeOffset,
    required this.id,
    required this.name,
    required this.typeCode,
    required this.length,
    required this.value,
    required this.formattedValue,
    required this.rawHex,
    required this.trailer,
  });
}

// ================================================================
// FIELD DEFINITION
// ================================================================

class DlogFieldDefinition {
  final int id;

  final String name;

  final int typeCode;

  final String format;

  DlogFieldDefinition({
    required this.id,
    required this.name,
    required this.typeCode,
    required this.format,
  });
}

// ================================================================
// FIELD CANDIDATE
// ================================================================

class _FieldCandidate {
  final int relativeOffset;

  final int id;

  final Uint8List valueBytes;

  final int trailer;

  final int endOffset;

  _FieldCandidate({
    required this.relativeOffset,
    required this.id,
    required this.valueBytes,
    required this.trailer,
    required this.endOffset,
  });
}

// ================================================================
// CLASSIFICATION
// ================================================================

enum DlogRecordClass {
  procedure,
  mixed,
  trace,
  unknown,
}

// ================================================================
// TIMESTAMP
// ================================================================

class _ReveosData { final int start,end,sec,ns; final Map<int,Uint8List> fields; _ReveosData(this.start,this.end,this.sec,this.ns,this.fields); }

enum EBoxGeneration { gen1, gen2, unknown }

class DlogMachineInfo {
  final DlogMachine product;
  final String? softwareVersion;
  final String? softwareRevision;
  final String? buildDate;
  /// Only meaningful for Trima/Optia. Reveos is always null.
  final EBoxGeneration? eBoxGeneration;
  final String? boardPackage;
  final String? hardwareInterface;
  final String? controlHwVersion;
  final String? safetyHwVersion;
  final double? machineHours;
  final double? centrifugeHours;
  final int? procedureCount;
  final int? proceduresCompleted;

  const DlogMachineInfo({
    required this.product,
    this.softwareVersion,
    this.softwareRevision,
    this.buildDate,
    this.eBoxGeneration,
    this.boardPackage,
    this.hardwareInterface,
    this.controlHwVersion,
    this.safetyHwVersion,
    this.machineHours,
    this.centrifugeHours,
    this.procedureCount,
    this.proceduresCompleted,
  });

  String? get eBoxLabel => eBoxGeneration == null ? null :
      (eBoxGeneration == EBoxGeneration.gen1 ? 'eBox Gen1' :
       eBoxGeneration == EBoxGeneration.gen2 ? 'eBox Gen2' : 'Unknown');
}

enum DlogMachine { trima, optia, reveos, unknown }

enum TimestampMode {
  none,
  optiaSecondsNanoseconds,
  reveosSecondsNanoseconds,
  absTimeMinutesFromMidnight,
  absTimeRelativeToDlog,
}

class _TimestampInfo {
  final TimestampMode mode;

  final DateTime? dlogStart;

  final List<String> diagnostics;

  _TimestampInfo({
    required this.mode,
    required this.dlogStart,
    required this.diagnostics,
  });
}

/// Alarma detectada durante la decodificación.
class DlogAlarm {
  /// Momento exacto en que ocurrió la alarma.
  final DateTime? timestamp;

  /// Path/nombre de origen recibido por decodeBytes/decodeFile.
  final String sourcePath;

  /// Fecha de la alarma normalizada a 00:00:00 local, expresada como
  /// millisecondsSinceEpoch. Ej.: 25/09/2026 -> DateTime(2026, 9, 25).
  final int? dateMillisecondsSinceEpoch;

  final String machine;
  /// Identificador técnico original recibido desde el DLOG.
  final String alarmId;
  /// Alarm Identification del manual (p. ej. FTPFailureAlert/T0ValveOpen).
  final String alarmKey;
  /// Código oficial del manual. Reveos/Trima son numéricos; Optia puede quedar vacío.
  final String alarmCode;
  final String alarmName;
  final String rawAlarmName;
  final bool catalogKnown;
  final String category;
  final String statusLine;
  final String messageType;
  final String dlogText;
  final String occursDuring;
  final String detection;
  final String possibleCauses;
  final String suggestedActions;
  final String state;
  final String node;
  final String source;
  final bool active;
  final int recordIndex;

  DlogAlarm({
    required this.timestamp,
    required this.sourcePath,
    required this.machine,
    this.alarmId = '',
    this.alarmKey = '',
    required this.alarmCode,
    required this.alarmName,
    this.rawAlarmName = '',
    this.catalogKnown = false,
    this.category = '',
    this.statusLine = '',
    this.messageType = '',
    this.dlogText = '',
    this.occursDuring = '',
    this.detection = '',
    this.possibleCauses = '',
    this.suggestedActions = '',
    required this.state,
    required this.node,
    required this.source,
    required this.active,
    required this.recordIndex,
  }) : dateMillisecondsSinceEpoch = timestamp == null
            ? null
            : DateTime(
                timestamp.year,
                timestamp.month,
                timestamp.day,
              ).millisecondsSinceEpoch;

  String get timestampString => timestamp == null
      ? ''
      : Dlog022eRecord._formatTimestamp(timestamp!);
}

/// Resultado compacto para DlogHome.
/// Alarmas oficiales y eventos técnicos se mantienen separados.
class DlogDashboardExtraction {
  final List<DlogAlarm> alarms;
  final List<DlogCriticalEvent> criticalFaultEvents;

  const DlogDashboardExtraction({
    this.alarms = const <DlogAlarm>[],
    this.criticalFaultEvents = const <DlogCriticalEvent>[],
  });
}

/// Evento técnico extraído de TRACE/CriticalOutput.
///
/// Se mantiene separado de [DlogAlarm] porque CriticalOutput es un canal de
/// diagnóstico y puede contener tanto anomalías como mensajes informativos.
class DlogCriticalEvent {
  final DateTime? timestamp;
  final String sourcePath;
  final int? dateMillisecondsSinceEpoch;
  final String machine;
  final String category;
  final String node;
  final String eventKey;
  final String message;
  final bool isFault;
  final int recordIndex;

  DlogCriticalEvent({
    required this.timestamp,
    required this.sourcePath,
    required this.machine,
    required this.category,
    required this.node,
    required this.eventKey,
    required this.message,
    required this.isFault,
    required this.recordIndex,
  }) : dateMillisecondsSinceEpoch = timestamp == null
            ? null
            : DateTime(timestamp.year, timestamp.month, timestamp.day)
                .millisecondsSinceEpoch;

  String get timestampString => timestamp == null
      ? ''
      : Dlog022eRecord._formatTimestamp(timestamp!);
}

/// Selector de salidas.
///
/// Todas las opciones son `false` por defecto para no reservar memoria
/// construyendo CSVs que la aplicación no va a utilizar.
class DlogOutputOptions {
  final bool recordsCsv;
  final bool fieldsCsv;
  final bool procedureCsv;
  final bool nativeCsv;
  final bool alarms;
  final bool alarmsCsv;
  final bool summary;

  const DlogOutputOptions({
    this.recordsCsv = false,
    this.fieldsCsv = false,
    this.procedureCsv = false,
    this.nativeCsv = false,
    this.alarms = false,
    this.alarmsCsv = false,
    this.summary = false,
  });

  /// Útil para diagnóstico/exportación completa explícita.
  const DlogOutputOptions.all()
      : recordsCsv = true,
        fieldsCsv = true,
        procedureCsv = true,
        nativeCsv = true,
        alarms = true,
        alarmsCsv = true,
        summary = true;
}

/// Salidas del decoder en memoria. Ideal para Flutter Web.
///
/// Las salidas no solicitadas son `null`.
class DlogOutputBundle {
  final String baseName;
  final String? recordsCsv;
  final String? fieldsCsv;
  final String? procedureCsv;
  final String? nativeCsv;
  final List<DlogAlarm>? alarms;
  final String? alarmsCsv;
  final String? summaryText;

  const DlogOutputBundle({
    required this.baseName,
    required this.recordsCsv,
    required this.fieldsCsv,
    required this.procedureCsv,
    required this.nativeCsv,
    required this.alarms,
    required this.alarmsCsv,
    required this.summaryText,
  });

  Uint8List? get nativeCsvBytes =>
      nativeCsv == null ? null : Uint8List.fromList(utf8.encode(nativeCsv!));

  Uint8List? get alarmsCsvBytes =>
      alarmsCsv == null ? null : Uint8List.fromList(utf8.encode(alarmsCsv!));

  Uint8List? get procedureCsvBytes =>
      procedureCsv == null
          ? null
          : Uint8List.fromList(utf8.encode(procedureCsv!));

  Uint8List? get recordsCsvBytes =>
      recordsCsv == null ? null : Uint8List.fromList(utf8.encode(recordsCsv!));

  Uint8List? get fieldsCsvBytes =>
      fieldsCsv == null ? null : Uint8List.fromList(utf8.encode(fieldsCsv!));

  Uint8List? get summaryBytes =>
      summaryText == null ? null : Uint8List.fromList(utf8.encode(summaryText!));
}
/*

*/