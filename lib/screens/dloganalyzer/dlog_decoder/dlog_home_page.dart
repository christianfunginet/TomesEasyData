// App minima: elegir un .dlog, convertirlo con dlog_decoder.dart y
// compartir/guardar el CSV resultante. Pensada como punto de partida,
// no como una app terminada (sin manejo de permisos avanzado, sin tests).
//
// NO VERIFICADO: no pude compilar ni correr esta app en el entorno donde
// la escribi (no hay Flutter/Dart instalados aca). Probala con
// `flutter pub get && flutter run` antes de confiar en ella.

import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:tomesdashboard/screens/dloganalyzer/dlog_decoder/dlog_decoder_chatgpt.dart';
import 'package:tomesdashboard/screens/dloganalyzer/equipment_chart/eq_pie.dart';
import 'package:tomesdashboard/screens/tomes/subsscreens/dashboard/value_info_card.dart';


class DlogHomePage extends StatefulWidget {
  final FilePickerResult files;
  final void Function(
    String? path,
    String fileName,
    Uint8List? bytes,
  ) onAnalyzeRequest;
  const DlogHomePage({super.key,required this.files, required this.onAnalyzeRequest});

  @override
  State<DlogHomePage> createState() => _DlogHomePageState();
}

class _DlogHomePageState extends State<DlogHomePage> {
  String _status = 'Elegi un archivo .dlog para convertir.';
  List<FlSpot> set1=[];
  List<TimePoint> data=[];  
  DateTime start =DateTime.now();
  DateTime end = DateTime.now();
  double maxX=0;
  late ZoomPanBehavior zoom;
  List<String> unReadedFiles=[];  
  List<String> readedFiles=[];
  final List<PlatformFile> _processedFiles = <PlatformFile>[];
  PlatformFile? _selectedProcessedFile;

  bool _busy = true;
  bool _end=false;
  List<CartesianSeries> cartesianSeries = [];
  Map<String, int> alarmCount = {}; // alarm name -> incidences
  final Map<String, String> _alarmNamesByCode = <String, String>{};
  final Map<int, TimePoint> _pointsByDate = <int, TimePoint>{};
  bool _cancelRequested = false;
  int percent=0;        
  bool _showStacked = true;
  static const int _topAlarmSeries = 8;

  final TextEditingController _controller=TextEditingController();
  @override
  void initState(){
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
    _convert(widget.files);
    super.initState();
  }
  @override
  void dispose(){
    _controller.dispose();
    super.dispose();
  }

  Future<void> _convert(FilePickerResult files) async {
    final picked = files;

    // Reset completo para permitir volver a ejecutar el análisis.
    data.clear();
    _pointsByDate.clear();
    alarmCount.clear();
    _alarmNamesByCode.clear();
    readedFiles.clear();
    _processedFiles.clear();
    _selectedProcessedFile = null;
    unReadedFiles.clear();
    _controller.clear();
    _cancelRequested = false;

    if (mounted) {
      setState(() {
        _busy = true;
        _end = false;
        _status = 'Preparing ${picked.files.length} files...';
        percent = 0;
      });
    }

    final alarmText = StringBuffer();
    var processed = 0;

    try {
      for (var i = 0; i < picked.files.length; i++) {
        if (_cancelRequested) break;

        final f = picked.files[i];
        final sourceId = f.path ?? f.name;

        if (mounted) {
          setState(() {
            _status = 'Processing ${i + 1} / ${picked.files.length}: ${f.name}';
            percent = ((i / picked.files.length) * 100).floor();
          });
        }

        // Deja al navegador pintar el progreso ANTES del trabajo pesado.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (_cancelRequested) break;

        try {
          final bytes = f.bytes;
          if (bytes == null) {
            // En Web, FilePicker debe usarse con withData: true.
            unReadedFiles.add(sourceId);
          } else {
            final alarms = DlogDecoder.extractAlarmsBytes(
              bytes,
              sourcePath: sourceId,
            );

            for (final alarm in alarms) {
              final graphDate = alarm.dateMillisecondsSinceEpoch;
              if (graphDate == null) continue;

              final alarmName = alarm.alarmName.trim().isEmpty
                  ? alarm.alarmCode
                  : alarm.alarmName.trim();

              alarmText.writeln('${alarm.alarmCode} - $alarmName');
              alarmCount[alarmName] = (alarmCount[alarmName] ?? 0) + 1;
              _alarmNamesByCode[alarm.alarmCode] = alarmName;

              final occurrence = AlarmOccurrence(
                code: alarm.alarmCode,
                name: alarmName,
              );

              final current = _pointsByDate[graphDate];
              if (current == null) {
                _pointsByDate[graphDate] = TimePoint(
                  DateTime.fromMillisecondsSinceEpoch(graphDate),
                  1,
                  <AlarmOccurrence>[occurrence],
                  f,
                );
              } else {
                current.value += 1;
                current.alarms.add(occurrence);
              }
            }

            readedFiles.add(sourceId);
            _processedFiles.add(f);
            _selectedProcessedFile ??= f;
          }
        } catch (e) {
          unReadedFiles.add(sourceId);
        }

        processed++;

        // Actualización de UI una sola vez por archivo, no por alarma.
        if (mounted) {
          setState(() {
            percent = ((processed / picked.files.length) * 100).floor();
            _controller.text = alarmText.toString();
          });
        }

        // Yield explícito: especialmente importante en Flutter Web.
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      data
        ..clear()
        ..addAll(_pointsByDate.values)
        ..sort((a, b) => a.time.compareTo(b.time));

      if (mounted) {
        setState(() {
          if (_cancelRequested) {
            _status = 'Cancelled: $processed / ${picked.files.length} files processed';
          } else {
            _status = 'Ready: $processed files processed';
            percent = 100;
          }
          _controller.text = alarmText.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _end = true;
        });
      }
    }
  }

  void _cancelAnalysis() {
    if (!_busy) return;
    setState(() {
      _cancelRequested = true;
      _status = 'Cancelling after current file...';
    });
  }
  
  String _normalizeAlarmName(String value) =>
      value.trim().replaceAll(RegExp(r'\\s+'), ' ').toLowerCase();

  Map<String, String> get _displayNameByNormalized {
    final result = <String, String>{};
    for (final point in data) {
      for (final alarm in point.alarms) {
        final key = _normalizeAlarmName(alarm.name);
        if (key.isNotEmpty) result.putIfAbsent(key, () => alarm.name.trim());
      }
    }
    return result;
  }

  Map<String, int> _alarmNameCountsFromChart() {
    final counts = <String, int>{};
    for (final point in data) {
      for (final alarm in point.alarms) {
        final key = _normalizeAlarmName(alarm.name);
        if (key.isEmpty) continue;
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return counts;
  }

  List<String> _topAlarmNames() {
    final entries = _alarmNameCountsFromChart().entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    return entries.take(_topAlarmSeries).map((e) => e.key).toList();
  }

  int get _totalAlarmIncidences =>
      alarmCount.values.fold<int>(0, (sum, value) => sum + value);

  List<MapEntry<String, int>> get _alarmRanking {
    final entries = alarmCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  Map<String, int> _groupOccurrences(List<AlarmOccurrence> alarms) {
    final grouped = <String, int>{};
    for (final alarm in alarms) {
      final label = '${alarm.code} - ${alarm.name}';
      grouped[label] = (grouped[label] ?? 0) + 1;
    }
    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(entries);
  }

  List<_AlarmStackPoint> _buildStackData(List<String> topNames) {
    final topSet = topNames.toSet();
    return data.map((point) {
      final counts = <String, int>{};
      var other = 0;
      for (final alarm in point.alarms) {
        final key = _normalizeAlarmName(alarm.name);
        if (topSet.contains(key)) {
          counts[key] = (counts[key] ?? 0) + 1;
        } else {
          other++;
        }
      }
      return _AlarmStackPoint(
        time: point.time,
        counts: counts,
        other: other,
        total: point.value.toInt(),
        file: point.file,
      );
    }).toList();
  }

  double get _maxDailyAlarms {
    if (data.isEmpty) return 0;
    return data.fold<double>(
      0,
      (max, point) => point.value.toDouble() > max
          ? point.value.toDouble()
          : max,
    );
  }

  /// Heatmap por altura:
  /// - la barra de mayor incidencia termina en rojo;
  /// - las demás terminan en un tono proporcional amarillo -> rojo.
  Color _heatColorForValue(num value) {
    final maxValue = _maxDailyAlarms;
    if (maxValue <= 0) return Colors.yellow;
    final ratio = (value.toDouble() / maxValue).clamp(0.0, 1.0);
    return Color.lerp(Colors.yellow, Colors.red, ratio)!;
  }

  void _openProcessedFile(PlatformFile? file) {
    if (file == null) return;
    widget.onAnalyzeRequest(
      file.path,
      file.name,
      file.bytes,
    );
  }

  @override
  Widget build(BuildContext context) {
  final TooltipBehavior _tooltipBehavior = TooltipBehavior(
    duration: 10000,
    enable: true,
    activationMode: ActivationMode.singleTap,
    builder: (dynamic rawData, dynamic point, dynamic series, int? pointIndex, int? seriesIndex) {
      DateTime time;
      int quantity;
      PlatformFile file;
      List<AlarmOccurrence> alarms;
      String? segmentLabel;
      int? segmentQuantity;

      if (rawData is _AlarmStackPoint) {
        time = rawData.time;
        quantity = rawData.total;
        file = rawData.file;
        alarms = const <AlarmOccurrence>[];
        if (seriesIndex != null) {
          final topNames = _topAlarmNames();
          if (seriesIndex < topNames.length) {
            final key = topNames[seriesIndex];
            segmentLabel = _displayNameByNormalized[key] ?? key;
            segmentQuantity = rawData.counts[key] ?? 0;
          } else {
            segmentLabel = 'Other';
            segmentQuantity = rawData.other;
          }
        }
      } else {
        final item = rawData as TimePoint;
        time = item.time;
        quantity = item.value.toInt();
        file = item.file;
        alarms = item.alarms;
      }

      return Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat.yMMMd().format(time),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text('Total alarms: $quantity', style: const TextStyle(color: Colors.white)),
            if (segmentLabel != null)
              Text('$segmentLabel: $segmentQuantity', style: const TextStyle(color: Colors.white)),
            TextButton(
              onPressed: () => _openProcessedFile(file),
              child: const Text('Analyze'),
            ),
            if (!_showStacked && alarms.isNotEmpty)
              SizedBox(
                height: 120,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _groupOccurrences(alarms).entries.map((e) => Text(
                      '${e.key}  ×${e.value}',
                      style: const TextStyle(color: Colors.white),
                    )).toList(),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
   void _hideTooltip() {
    _tooltipBehavior.hide();
  }
  //final start = set1.first.x;
    //final end = set1.last.x;
    //final maxX =Duration(milliseconds:  (end- start).floor()).inMinutes.toDouble();
    return Scaffold(
      body:SizedBox(
        height: MediaQuery.of(context).size.height,
        width: MediaQuery.of(context).size.width,
        child: Row(
          children: <Widget>[
            Flexible(
              flex:7,
              child: SizedBox(
                width: MediaQuery.of(context).size.width - 332,
                height: MediaQuery.of(context).size.height,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Stack(
                        children: [
                          Center(
                            child: 
                              Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if(_end)
                                  Expanded(
                                    child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _hideTooltip,
                                    child: data.isNotEmpty ? Builder(
                                      builder: (context) {
                                        final topNames = _topAlarmNames();
                                        final stackData = _buildStackData(topNames);
              
                                        final List<CartesianSeries<dynamic, DateTime>> series;
                                        if (_showStacked) {
                                          series = <CartesianSeries<dynamic, DateTime>>[
                                            ...topNames.map((key) => StackedColumnSeries<_AlarmStackPoint, DateTime>(
                                                  name: _displayNameByNormalized[key] ?? key,
                                                  dataSource: stackData,
                                                  xValueMapper: (p, _) => p.time,
                                                  yValueMapper: (p, _) => p.counts[key] ?? 0,
                                                  enableTooltip: true,
                                                )),
                                            if (stackData.any((p) => p.other > 0))
                                              StackedColumnSeries<_AlarmStackPoint, DateTime>(
                                                name: 'Other',
                                                dataSource: stackData,
                                                xValueMapper: (p, _) => p.time,
                                                yValueMapper: (p, _) => p.other,
                                                enableTooltip: true,
                                              ),
                                          ];
                                        } else {
                                          series = <CartesianSeries<dynamic, DateTime>>[
                                            ColumnSeries<TimePoint, DateTime>(
                                              name: 'Total alarms',
                                              dataSource: data,
                                              xValueMapper: (p, _) => p.time,
                                              yValueMapper: (p, _) => p.value,
                                              // Solo el máximo llega a rojo.
                                              // Cada barra recibe un color proporcional
                                              // a su altura respecto del máximo diario.
                                              pointColorMapper: (p, _) =>
                                                  _heatColorForValue(p.value),
                                              enableTooltip: true,
                                            ),
                                          ];
                                        }
              
                                        return SfCartesianChart(
                                          zoomPanBehavior: zoom,
                                          tooltipBehavior: _tooltipBehavior,
                                          legend: Legend(
                                            isVisible: _showStacked,
                                            position: LegendPosition.bottom,
                                            overflowMode: LegendItemOverflowMode.wrap,
                                          ),
                                          primaryXAxis: DateTimeAxis(
                                            minimum: data.first.time.subtract(const Duration(days: 1)),
                                            maximum: data.length < 2
                                                ? data.first.time.add(const Duration(days: 1))
                                                : data.last.time.add(const Duration(days: 1)),
                                            intervalType: DateTimeIntervalType.days,
                                            interval: 2,
                                            dateFormat: DateFormat.yMMMd(),
                                          ),
                                          primaryYAxis: NumericAxis(
                                            title: AxisTitle(text: 'Alarms'),
                                            minimum: 0,
                                          ),
                                          series: series,
                                        );
                                      },
                                    ) : const _EmptyAlarmState(),
                                    ),
                                  ),
                                  if (_busy)
                                    Expanded(
                                      child: Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surface
                                            .withOpacity(0.82),
                                        child: Center(
                                          child: ConstrainedBox(
                                            constraints:
                                                const BoxConstraints(maxWidth: 420),
                                            child: Padding(
                                              padding: const EdgeInsets.all(24),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.analytics_outlined,
                                                    size: 42,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                  ),
                                                  const SizedBox(height: 18),
                                                  ProgressLine(
                                                    percentage: percent,
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    '$percent%',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleLarge
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    _status,
                                                    textAlign: TextAlign.center,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                  const SizedBox(height: 14),
                                                  FilledButton.tonalIcon(
                                                    onPressed: _cancelRequested
                                                        ? null
                                                        : _cancelAnalysis,
                                                    icon: const Icon(
                                                      Icons.stop_circle_outlined,
                                                    ),
                                                    label: Text(
                                                      _cancelRequested
                                                          ? 'Cancelling...'
                                                          : 'Cancel',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (_end && _processedFiles.isNotEmpty)
                            Material(
                              color: Colors.transparent,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (_processedFiles.isNotEmpty)
                                    SizedBox(
                                      width: 260,
                                      child: DropdownButtonFormField<PlatformFile>(
                                        initialValue: _selectedProcessedFile,
                                        isExpanded: true,
                                        borderRadius: BorderRadius.circular(16),
                                        decoration: InputDecoration(
                                          prefixIcon: const Icon(
                                            Icons.description_outlined,
                                          ),
                                          isDense: true,
                                          filled: true,
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            borderSide: BorderSide.none,
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .outlineVariant,
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            borderSide: BorderSide(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              width: 1.5,
                                            ),
                                          ),
                                        ),
                                        items: _processedFiles.map((file) {
                                          return DropdownMenuItem<PlatformFile>(
                                            value: file,
                                            child: Text(
                                              file.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          );
                                        }).toList(),
                                        onChanged: (file) {
                                          if (file == null) return;
                                          setState(
                                            () => _selectedProcessedFile = file,
                                          );
                                          _openProcessedFile(file);
                                        },
                                      ),
                                    ),
                                  const SizedBox(width: 12),
                                  SegmentedButton<bool>(
                                    segments: const <ButtonSegment<bool>>[
                                      ButtonSegment<bool>(
                                        value: true,
                                        icon: Icon(Icons.stacked_bar_chart),
                                        label: Text('Stacked'),
                                      ),
                                      ButtonSegment<bool>(
                                        value: false,
                                        icon: Icon(Icons.local_fire_department_outlined),
                                        label: Text('Heat'),
                                      ),
                                    ],
                                    selected: <bool>{_showStacked},
                                    onSelectionChanged: (selection) {
                                      _tooltipBehavior.hide();
                                      setState(() => _showStacked = selection.first);
                                    },
                                  ),
                                  if (_end && data.isNotEmpty) ...[
                                    const SizedBox(width: 10),
                                    Tooltip(
                                      message: unReadedFiles.isEmpty
                                          ? 'No empty files'
                                          : unReadedFiles.join('\n'),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outlineVariant,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              unReadedFiles.isEmpty
                                                  ? Icons.check_circle_outline_rounded
                                                  : Icons.warning_amber_rounded,
                                              size: 17,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              'Empty: ${unReadedFiles.length}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Tooltip(
                                      message: 'Zoom in',
                                      child: IconButton.filledTonal(
                                        onPressed: zoom.zoomIn,
                                        icon: const Icon(Icons.add),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Reset zoom',
                                      child: IconButton.filledTonal(
                                        onPressed: zoom.reset,
                                        icon: const Icon(Icons.center_focus_weak),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Zoom out',
                                      child: IconButton.filledTonal(
                                        onPressed: zoom.zoomOut,
                                        icon: const Icon(Icons.remove),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Flexible(
              flex: 3,
              child: SizedBox(
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.all(10.0),
                      child: Column(
                        children: [
                          if (!_end && !_busy)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                _status,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          if (_end) ...[
                            _AlarmSummaryCards(
                              total: _totalAlarmIncidences,
                              unique: alarmCount.length,
                              topAlarm: _alarmRanking.isEmpty
                                  ? null
                                  : _alarmRanking.first,
                            ),
                            const SizedBox(height: 10),
              
                            // El donut es solo resumen visual. La lista inferior
                            // funciona como leyenda y detalle.
                            SizedBox(
                              height: 190,
                              child: EquipmetnPieChart(
                                values: alarmCount,
                                topAlarms: 8,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Divider(
                              height: 1,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                            const SizedBox(height: 8),
              
                            // Única zona flexible: si la pantalla es baja,
                            // solamente el ranking hace scroll.
                            Expanded(
                              child: _AlarmRankingList(
                                entries: _alarmRanking,
                                total: _totalAlarmIncidences,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ); 
      
      
    
  }
}
String getOptiaCode( String str){
  var s=str.split(": ");
  return s[2].split(" ").first;
}
String getOptiaAlarm( String str){
  var s=str.split(": ");
  return s[1].split(" ").first;
}

class _AlarmStackPoint {
  final DateTime time;
  final Map<String, int> counts;
  final int other;
  final int total;
  final PlatformFile file;

  const _AlarmStackPoint({
    required this.time,
    required this.counts,
    required this.other,
    required this.total,
    required this.file,
  });
}


class AlarmOccurrence {
  final String code;
  final String name;

  const AlarmOccurrence({
    required this.code,
    required this.name,
  });
}

class _AlarmSummaryCards extends StatelessWidget {
  final int total;
  final int unique;
  final MapEntry<String, int>? topAlarm;

  const _AlarmSummaryCards({
    required this.total,
    required this.unique,
    required this.topAlarm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return Row(
              children: [
                Expanded(
                  child: _SummaryTile(
                    label: 'Incidences',
                    value: '$total',
                    icon: Icons.notifications_active_outlined,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SummaryTile(
                    label: 'Unique',
                    value: '$unique',
                    icon: Icons.category_outlined,
                  ),
                ),
              ],
            );
          },
        ),
        if (topAlarm != null) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.trending_up_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Most frequent',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      Text(
                        topAlarm!.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${topAlarm!.value}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _SummaryTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlarmRankingList extends StatelessWidget {
  final List<MapEntry<String, int>> entries;
  final int total;

  const _AlarmRankingList({required this.entries, required this.total});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('No alarm incidences'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Alarm incidence',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final e = entries[index];
              final fraction = total == 0 ? 0.0 : e.value / total;
              return Tooltip(
                message: e.key,
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text('${index + 1}.',
                              style: Theme.of(context).textTheme.labelSmall),
                        ),
                        Expanded(
                          child: Text(
                            e.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 30,
                          child: Text(
                            '${e.value}',
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${(fraction * 100).toStringAsFixed(1)}%',
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                      value: fraction.clamp(0.0, 1.0),
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TimePoint {
  final PlatformFile file;
  final DateTime time;
  num value;
  final List<AlarmOccurrence> alarms;
  TimePoint(this.time, this.value,this.alarms,this.file);

  TimePoint copyWith({
  DateTime? time,
  num?  value,
  List<AlarmOccurrence>? alarms,
  PlatformFile? file,

  }){
    return TimePoint(
       time ?? this.time,
       value ?? this.value,
       alarms?? this.alarms, 
       file ?? this.file,
    );
  }
}


class _EmptyAlarmState extends StatelessWidget {
  const _EmptyAlarmState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withOpacity(0.35),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle_outline_rounded,
                  size: 32,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No alarms found',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 7),
              Text(
                'There are no alarm incidences to display for the analyzed period.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
