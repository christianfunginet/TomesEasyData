import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'export_folder.dart';
import 'pdf_report.dart';

import 'package:csv/csv.dart';
import 'package:csv/csv_settings_autodetection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
//import 'package:material_charts/material_charts.dart';
import 'package:searchable_listview/searchable_listview.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:tomesdashboard/cont.dart';
import 'package:tomesdashboard/screens/dloganalyzer/dlog_decoder/dlog_decoder_chatgpt.dart';
import 'package:tomesdashboard/screens/dloganalyzer/episodic.dart';

class GraphicPage extends StatefulWidget {
  final String? filePath;
  final String fileName;
  final Uint8List? fileBytes;

  const GraphicPage({
    super.key,
    required this.title,
    this.filePath,
    required this.fileName,
    this.fileBytes,
  });

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<GraphicPage> createState() => _GraphicPageState();
}

class _GraphicPageState extends State<GraphicPage> {
  List<String> searchAlarms = [];
  List<String> types = [];
  List<String> filtredSearchAlarms = [];
  List<List<dynamic>> rowFromFiles = [];
  List<String> timeLineSeries = [];
  bool isLoading = true;
  List<CartesianSeries> cartesianSeries = [];
  List<String> episodios = [];
  List<CartesianChartAnnotation> verticalRangeAnnotations = [];
  List<CartesianChartAnnotation> otherAnotation = [];

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final GlobalKey _reportChartKey = GlobalKey();
  late ZoomPanBehavior zoom;
  late TrackballBehavior trackball;
  List<String> machineData = [];
  bool isEpisodic = false;
  DlogOutputBundle? _exportOutputs;
  DateTime? _dataStart;
  DateTime? _dataEnd;
  Uint8List? _loadedDlogBytes;

  // Performance caches: timestamps are parsed once and generated series are
  // reused when a variable is selected again.
  final List<DateTime?> _rowTimes = <DateTime?>[];
  final Map<String, int> _columnIndex = <String, int>{};
  final Map<String, List<_GraphPoint>> _seriesCache = <String, List<_GraphPoint>>{};
  final Map<String, List<CartesianChartAnnotation>> _annotationCache = <String, List<CartesianChartAnnotation>>{};

  DateTime? _parseTimestamp(dynamic raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text.replaceAll('/', '-').replaceAll('_', ' '));
  }

  String _formatClock(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

  double? _numericValue(dynamic raw, double lastValue) {
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return lastValue;
    final parsed = double.tryParse(text);
    if (parsed != null) return parsed;
    switch (text) {
      case 'On':
      case 'Opened':
      case 'Open':
      case 'Unlocked':
        return 1000.0;
      case 'Off':
      case 'Closed':
      case 'Stop':
      case 'Unknown':
      case 'Unknow':
        return 0.0;
    }
    return null;
  }

  @override
  void initState() {
    zoom = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableSelectionZooming: true,
      //enableMouseWheelZooming: true,
      enableDirectionalZooming: true,
      enableDoubleTapZooming: true,
      zoomMode: ZoomMode.xy,
      enableMouseWheelZooming: true,
      //maximumZoomLevel: 1.0
    );

    trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      tooltipSettings: const InteractiveTooltip(enable: true),
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
      lineType: TrackballLineType.vertical,
    );

    
    
    _loadDlog();

    filtredVariables = variables;
    super.initState();
  }

  Future<void> _loadDlog() async {
    try {
      Uint8List? fileBytes = widget.fileBytes;

      // Web: FilePicker normally has no physical path, so bytes are primary.
      // Desktop/mobile: keep path as a fallback for existing callers.
      if (fileBytes == null &&
          widget.filePath != null &&
          widget.filePath!.isNotEmpty) {
        fileBytes = await XFile(widget.filePath!).readAsBytes();
      }

      if (fileBytes == null || fileBytes.isEmpty) {
        throw StateError('No data available for ${widget.fileName}');
      }

      // Keep the original DLOG bytes for EpisodicPage -> Optia IMAGES.
      // CSV inputs deliberately do not populate this field.
      if (widget.fileName.toLowerCase().endsWith('.dlog')) {
        _loadedDlogBytes = fileBytes;
      }

      // Entrada unificada: el decoder decide si debe decodificar un DLOG
      // o simplemente pasar un CSV ya decodificado.
      final inputResult = DlogDecoder.decodeInput(
        fileBytes,
        fileName: widget.fileName,
        sourcePath: widget.filePath ?? widget.fileName,
        options: const DlogOutputOptions.all(),
      );

      if (!inputResult.ok || inputResult.outputs == null) {
        throw StateError(
          inputResult.diagnostics.isNotEmpty
              ? inputResult.diagnostics.join('\n')
              : 'Unable to open ${widget.fileName}',
        );
      }

      final outputs = inputResult.outputs!;
      _exportOutputs = outputs;

      final csvBytes = outputs.procedureCsvBytes;
      if (csvBytes == null || csvBytes.isEmpty) {
        throw StateError('Procedure CSV is empty for ${widget.fileName}');
      }


      final detector = FirstOccurrenceSettingsDetector(
        eols: ['\r\n', '\n'],
        textDelimiters: ['"', "'"],
      );

      final fields = await Stream<List<int>>.value(csvBytes)
          .transform(utf8.decoder)
          .transform(
            CsvToListConverter(
              csvSettingsDetector: detector,
              shouldParseNumbers: true,
            ),
          )
          .toList();

      _consumeProcedureFields(fields);
    } catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Error opening ${widget.fileName}: $e')),
        );
      });
    }
  }

  void _consumeProcedureFields(List<List<dynamic>> fields) {
    int count = 0;
    timeLineSeries.clear();
    int idx = 1;

    for (var element in fields) {
      if (count >= 8) {
        if (element.length > 10) {
          rowFromFiles.add(element);
          final parsedTime =
              _parseTimestamp(element.isNotEmpty ? element[0] : null);
          _rowTimes.add(parsedTime);

          if (parsedTime != null) {
            if (_dataStart == null || parsedTime.isBefore(_dataStart!)) {
              _dataStart = parsedTime;
            }
            if (_dataEnd == null || parsedTime.isAfter(_dataEnd!)) {
              _dataEnd = parsedTime;
            }
          }

          // Preserve the row timestamp in episodic TRACE messages.
          // EpisodicPage uses it to calculate HvE ΔV/Δt pump flow.
          final verbose = element.last.toString();
          final episodicTimestamp =
              element.isNotEmpty ? element[0].toString().trim() : '';
          episodios.add(
            episodicTimestamp.isEmpty
                ? verbose
                : '$episodicTimestamp  $verbose',
          );

          if (idx < element.length &&
              element[idx] is String &&
              element[idx].toString().isNotEmpty &&
              parsedTime != null) {
            verticalRangeAnnotations.add(
              CartesianChartAnnotation(
                coordinateUnit: CoordinateUnit.point,
                region: AnnotationRegion.plotArea,
                x: parsedTime,
                y: 0,
                widget: Tooltip(
                  message:
                      'Alarm ${element[idx]} at ${_formatClock(parsedTime)}',
                  child: Icon(
                    Icons.warning,
                    color: Colors.red.withAlpha(200),
                    size: 16,
                  ),
                ),
              ),
            );
          }
        }
      } else {
        int colindex = 0;

        if ((count == 1 || count == 2 || count == 5) &&
            count < fields.length) {
          machineData.add(fields[count].toString());
        }

        if (element.contains("timestamp")) {
          _columnIndex.clear();
          for (var c = 0; c < element.length; c++) {
            final name = element[c].toString();
            variables.add(Variable(name, 0, 0, '', false, false));
            _columnIndex[name] = c;
          }
        }

        for (var col in element) {
          if (col.toString() == "Alarms") {
            idx = colindex;
          }
          colindex++;
        }
      }

      count++;
      if (count >= 8 && element.isEmpty) break;
    }

    cartesianSeries.clear();
    filtredVariables = variables;

    if (mounted) {
      setState(() => isLoading = false);
    }
  }



  List<Variable> filtredVariables = [];
  List<Variable> variables = [];
  bool proccessing = false;

  Future<void> processData() async {
    final selected = filtredVariables.where((element) => element.selected).toList();

    for (final variable in selected) {
      if (timeLineSeries.contains(variable.name)) continue;

      final varIdx = _columnIndex[variable.name] ??
          variables.indexWhere((element) => element.name == variable.name);
      if (varIdx < 0) continue;

      final cachedAnnotations = _annotationCache[variable.name];
      if (cachedAnnotations != null && cachedAnnotations.isNotEmpty) {
        otherAnotation.addAll(cachedAnnotations);
        variables[varIdx].isAnotation = true;
        timeLineSeries.add(variable.name);
        continue;
      }

      final cachedSeries = _seriesCache[variable.name];
      if (cachedSeries != null) {
        cartesianSeries.add(_buildLineSeries(variable.name, cachedSeries, varIdx));
        timeLineSeries.add(variable.name);
        continue;
      }

      final points = <_GraphPoint>[];
      final annotations = <CartesianChartAnnotation>[];
      double lastValue = 0.0;
      DateTime? lastTime;


      for (var rowIndex = 0; rowIndex < rowFromFiles.length; rowIndex++) {
        final row = rowFromFiles[rowIndex];
        if (varIdx >= row.length) continue;
        final time = rowIndex < _rowTimes.length ? _rowTimes[rowIndex] : _parseTimestamp(row[0]);
        if (time == null) continue;

        final raw = row[varIdx];
        final text = raw?.toString() ?? '';
        final isState = const {
          'On', 'Off', 'Opened', 'Open', 'Closed', 'Unknown', 'Unknow', 'Stop', 'Unlocked'
        }.contains(text);

        if (isState) {
          annotations.add(
            CartesianChartAnnotation(
              coordinateUnit: CoordinateUnit.point,
              region: AnnotationRegion.plotArea,
              x: time,
              y: 0,
              widget: Tooltip(
                message: '${variable.name} $text at ${_formatClock(time)}',
                child: Icon(Icons.info, color: lineColors[varIdx], size: 16),
              ),
            ),
          );
        }

        final value = _numericValue(raw, lastValue);
        if (value == null) continue;

        // Preserve the original step-line behaviour, but without reparsing the
        // timestamp for every point and every rebuild.
        if (lastTime == null) {
          // First valid sample establishes the initial state.
          lastValue = value;
          lastTime = time;
          continue;
        }

        // IMPORTANT: DLOG rows from different nodes can contain timestamps
        // that move backwards. The original implementation ignored those
        // rows for the plotted series. Do not move lastTime backwards or the
        // chart will connect later samples in the wrong temporal order.
        if (!time.isAfter(lastTime!)) {
          continue;
        }

        if (value != lastValue) {
          points.add(_GraphPoint(lastTime!, lastValue));
          points.add(_GraphPoint(time, value));
          lastValue = value;
        }

        lastTime = time;
      }

      if (lastTime != null) {
        points.add(_GraphPoint(lastTime, lastValue));
      }

      if (annotations.isNotEmpty) {
        _annotationCache[variable.name] = annotations;
        otherAnotation.addAll(annotations);
        variables[varIdx].isAnotation = true;
      } else {
        _seriesCache[variable.name] = points;
        cartesianSeries.add(_buildLineSeries(variable.name, points, varIdx));
      }
      timeLineSeries.add(variable.name);
    }
  }

  LineSeries<_GraphPoint, DateTime> _buildLineSeries(
    String name,
    List<_GraphPoint> points,
    int varIdx,
  ) {
    return LineSeries<_GraphPoint, DateTime>(
      name: name,
      dataSource: points,
      xValueMapper: (_GraphPoint point, _) => point.time,
      yValueMapper: (_GraphPoint point, _) => point.value,
      color: lineColors[varIdx],
      width: 2,
      animationDuration: 0,
    );
  }

  Future<Uint8List?> _captureReportChart() async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _reportChartKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _generatePdfReport() async {
    final selected =
        variables.where((item) => item.selected == true).toList();

    final chartPng = await _captureReportChart();
    final baseName = widget.fileName
        .replaceAll(RegExp(r'\.dlog$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\.csv$', caseSensitive: false), '');

    try {
      await saveAnalysisPdfReport(
        fileName: '${baseName}_report.pdf',
        title: 'DLOG Analysis Report',
        subtitle: widget.fileName,
        chartPng: chartPng,
        summary: [
          PdfReportRow('File', widget.fileName),
          PdfReportRow('Selected variables', '${selected.length}'),
          if (_dataStart != null)
            PdfReportRow('Start', _dataStart.toString()),
          if (_dataEnd != null)
            PdfReportRow('End', _dataEnd.toString()),
        ],
        selectedItems: selected.map((item) => item.name.toString()).toList(),
        notes: [
          if (chartPng == null)
            'The chart image could not be captured; report data was exported without it.',
        ],
      );
    } catch (e) {
      if (!mounted) return;
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Unable to create PDF report: $e')),
      );
    }
  }

  Future<void> _showExportDialog() async {
    final outputs = _exportOutputs;
    if (outputs == null) {
      _scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Outputs are not available yet')),
      );
      return;
    }

    final available = <_ExportOutput>[
      if (outputs.procedureCsvBytes != null)
        _ExportOutput(
          id: 'procedure',
          label: 'Procedure CSV',
          description: 'CSV used by GraphicPage',
          extension: 'csv',
          suffix: 'procedure',
          bytes: outputs.procedureCsvBytes!,
        ),
      if (outputs.nativeCsvBytes != null)
        _ExportOutput(
          id: 'native',
          label: 'Native / Full CSV',
          description: 'Complete native decoder CSV',
          extension: 'csv',
          suffix: 'native',
          bytes: outputs.nativeCsvBytes!,
        ),
      if (outputs.recordsCsvBytes != null)
        _ExportOutput(
          id: 'records',
          label: 'Records CSV',
          description: 'Decoded record-level output',
          extension: 'csv',
          suffix: 'records',
          bytes: outputs.recordsCsvBytes!,
        ),
      if (outputs.fieldsCsvBytes != null)
        _ExportOutput(
          id: 'fields',
          label: 'Fields CSV',
          description: 'Decoded field-level output',
          extension: 'csv',
          suffix: 'fields',
          bytes: outputs.fieldsCsvBytes!,
        ),
      if (outputs.alarmsCsvBytes != null)
        _ExportOutput(
          id: 'alarms',
          label: 'Alarms CSV',
          description: 'Extracted alarm incidences',
          extension: 'csv',
          suffix: 'alarms',
          bytes: outputs.alarmsCsvBytes!,
        ),
      if (outputs.summaryBytes != null)
        _ExportOutput(
          id: 'summary',
          label: 'Summary',
          description: 'Decoder summary and diagnostics',
          extension: 'txt',
          suffix: 'summary',
          bytes: outputs.summaryBytes!,
        ),
    ];

    if (available.isEmpty) {
      _scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('There are no exportable outputs')),
      );
      return;
    }

    // Procedure CSV starts selected because it is the output currently shown.
    final selected = <String>{
      if (available.any((e) => e.id == 'procedure')) 'procedure',
    };

    final exportAction = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final allSelected = selected.length == available.length;

            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.download),
                  SizedBox(width: 10),
                  Text('Export DLOG outputs'),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CheckboxListTile(
                        value: allSelected,
                        tristate: selected.isNotEmpty && !allSelected,
                        title: const Text(
                          'Select all',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (_) {
                          setDialogState(() {
                            if (allSelected) {
                              selected.clear();
                            } else {
                              selected
                                ..clear()
                                ..addAll(available.map((e) => e.id));
                            }
                          });
                        },
                      ),
                      const Divider(),
                      ...available.map(
                        (item) => CheckboxListTile(
                          value: selected.contains(item.id),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(item.label),
                          subtitle: Text(
                            '${item.description}  •  ${_formatBytes(item.bytes.length)}',
                          ),
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selected.add(item.id);
                              } else {
                                selected.remove(item.id);
                              }
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton.tonalIcon(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, 'folder'),
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    selected.length == 1
                        ? 'Export 1 file to folder'
                        : 'Export ${selected.length} files to folder',
                  ),
                ),

              ],
            );
          },
        );
      },
    );

    if (exportAction != 'folder' || !mounted) return;

    final chosen =
        available.where((item) => selected.contains(item.id)).toList();
    await _exportSelectedOutputsToFolder(chosen);
  }

  Future<void> _exportSelectedOutputsToFolder(
    List<_ExportOutput> selected,
  ) async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select export folder',
    );
    if (folder == null || !mounted) return;

    final baseName = widget.fileName
        .replaceAll(RegExp(r'\.dlog$', caseSensitive: false), '');

    try {
      final files = <FolderExportFile>[
        for (final item in selected)
          FolderExportFile(
            fileName: '${baseName}_${item.suffix}.${item.extension}',
            bytes: item.bytes,
          ),
      ];

      await exportFilesToFolder(folder, files);

      if (!mounted) return;
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            '${selected.length} output${selected.length == 1 ? '' : 's'} exported to $folder',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Unable to export folder: $e')),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    if (isLoading) {
      return const Scaffold(
        body: Column(
          children: [
            LinearProgressIndicator(minHeight: 3),
            Expanded(child: SizedBox.shrink()),
          ],
        ),
      );
    }
    if (isEpisodic) {
      return EpisodicPage(
        episodios: episodios,
        machineData: machineData,
        fileName: widget.fileName,
        dataStart: _dataStart,
        dataEnd: _dataEnd,
        dlogBytes: _loadedDlogBytes,
        onClose: () {
          setState(() {
            isEpisodic = false;
            filtredVariables = variables;
          });
        },
      );
    }
    var seleccionados=variables.where((test)=>test.selected==true).toList();
    return Scaffold(
      key: _scaffoldMessengerKey,
      body: SizedBox(
        height: MediaQuery.of(context).size.height,
        width: MediaQuery.of(context).size.width,
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 7,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Stack(
                      children: [
                        
                        RepaintBoundary(
                          key: _reportChartKey,
                          child: SfCartesianChart(
                          onZoomReset: (ZoomPanArgs args) {},
                          primaryXAxis: DateTimeAxis(
                            edgeLabelPlacement: EdgeLabelPlacement.shift,
                            majorGridLines: const MajorGridLines(width: 0),
                          ),
                          primaryYAxis: const NumericAxis(
                            rangePadding: ChartRangePadding.additional,
                          ),
                          series: cartesianSeries,
                          zoomPanBehavior: zoom,
                          trackballBehavior: trackball,
                          tooltipBehavior: TooltipBehavior(enable: true, header: '', canShowMarker: true, shared: true),
                          crosshairBehavior: CrosshairBehavior(enable: true, lineType: CrosshairLineType.both, lineWidth: 1, lineColor: Colors.grey, shouldAlwaysShow: false),
                          legend: const Legend(
                            isVisible: true,
                            position: LegendPosition.bottom,
                            overflowMode: LegendItemOverflowMode.wrap,
                            toggleSeriesVisibility: true,
                          ),
                          annotations: [...verticalRangeAnnotations, ...otherAnotation],
                          ),
                        ),
                        if (proccessing)
                          const Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: LinearProgressIndicator(minHeight: 3),
                          ),
                        Positioned(
                          left: 8,
                          top: 8,
                          child: _DataRangeBadge(start: _dataStart, end: _dataEnd),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Tooltip(
                              message: 'Export decoder outputs',
                              child: IconButton.filledTonal(
                                onPressed: _exportOutputs == null
                                    ? null
                                    : _showExportDialog,
                                icon: const Icon(Icons.download),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Tooltip(
                              message: 'Generate PDF report',
                              child: IconButton.filledTonal(
                                onPressed: _generatePdfReport,
                                icon: const Icon(Icons.picture_as_pdf_outlined),
                              ),
                            ),
                            const SizedBox(width: 10),
                            IconButton.filledTonal(
                              onPressed: () {
                                zoom.zoomIn();
                              },
                              icon: const Icon(Icons.add),
                            ),
                            const SizedBox(width: 10),
                            IconButton.filledTonal(
                              onPressed: () {
                                zoom.reset();
                              },
                              icon: const Icon(Icons.center_focus_weak),
                            ),
                            const SizedBox(width: 10),
                            IconButton.filledTonal(
                              onPressed: () {
                                zoom.zoomOut();
                              },
                              icon: const Icon(Icons.remove),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex:2,
                          child: Text(widget.title)),
                        Expanded(
                          flex:15,
                          child: SearchableList<Variable>(
                            inputDecoration: InputDecoration(
                              contentPadding: EdgeInsets.all(0.1),
                              prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
                              hintText: 'Search Variables',
                              hintStyle: TextStyle(color: Colors.grey[600]),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12.0),
                                borderSide: BorderSide(color: Colors.grey[600]!),
                              ),
                            ),
                            secondaryWidget: Padding(
                              padding: const EdgeInsets.all(1.0),
                              child: IconButton.outlined(
                                onPressed: () {
                                  setState(() {
                                    for (var element in variables) {
                                      element.selected = false;
                                    }
                                    timeLineSeries.clear();
                                    cartesianSeries.clear();
                                  });
                                },
                                icon: Icon(Icons.refresh, color: Colors.green, size: 18),
                              ),
                            ),
                            textAlignVertical: TextAlignVertical.center,
                            searchFieldHeight: 40,
                            lazyLoadingEnabled: false,
                                                    
                            sortPredicate: (a, b) => a.name.compareTo(b.name),
                            itemBuilder: (item) {
                              int index = filtredVariables.indexOf(item);
                                                    
                              return VariableItem(
                                onClear: () {
                                  setState(() {
                                    for (var vari in variables) {
                                      if (vari.isAnotation) {
                                        vari.selected = false;
                                      }
                                    }
                                    for (var vari in filtredVariables) {
                                      if (vari.isAnotation) {
                                        vari.selected = false;
                                      }
                                    }
                                                    
                                    otherAnotation.clear();
                                  });
                                },
                                actor: filtredVariables[index],
                                color: filtredVariables[index].selected ? lineColors[variables.indexWhere((varElement) => varElement.name == filtredVariables[index].name)] : null,
                                onTap: () async {
                                  setState(() {
                                    proccessing = true;
                                  });
                                                    
                                  filtredVariables[index].selected = !filtredVariables[index].selected;
                                  if (filtredVariables[index].selected) {
                                    await processData();
                                  } else {
                                    var i = variables.indexWhere((varElement) => varElement.name == filtredVariables[index].name);
                                    if (!variables[i].isAnotation) {
                                      //var idx = timeLineSeries.indexOf(filtredVariables[index].name);
                                      cartesianSeries.firstWhere((element) => element.name == filtredVariables[index].name);
                                      int idx = 0;
                                      for (var serie in cartesianSeries) {
                                        if (serie.name == filtredVariables[index].name) {
                                          break;
                                        }
                                        idx++;
                                      }
                                      if (idx != -1) {
                                        //lineBarsData.removeAt(idx);
                                        timeLineSeries.removeAt(idx);
                                        cartesianSeries.removeAt(idx);
                                      }
                                    }
                                  }
                                  setState(() {
                                    proccessing = false;
                                  });
                                },
                              );
                            },
                            emptyWidget: Column(
                              children: [
                                Container(color: Colors.red, height: 10, width: 300),
                                const Column(children: [Icon(Icons.error), Text('No Data found')]),
                              ],
                            ),
                            filter: (query) {
                              filtredVariables = variables.where((element) => element.name.toLowerCase().contains(query.toLowerCase())).toList();
                              return filtredVariables;
                            },
                            initialList: variables,
                          ),
                        ),
                        Divider(),
                       Text("Selected"),
                       Expanded(
                        flex:15,
                        child: ListView.builder(
                          itemCount: seleccionados.length,
                          itemBuilder: (context,builderIndex){
                          return  VariableItem(
                                color: seleccionados[builderIndex].selected ? lineColors[variables.indexWhere((varElement) => varElement.name == seleccionados[builderIndex].name)] : null,
                                onTap: () async {
                                  setState(() {
                                    proccessing = true;
                                  });
                                  int index = filtredVariables.indexOf(seleccionados[builderIndex]);
                             
                                                    
                                  filtredVariables[index].selected = !filtredVariables[index].selected;
                                  if (filtredVariables[index].selected) {
                                    await processData();
                                  } else {
                                    var i = variables.indexWhere((varElement) => varElement.name == filtredVariables[index].name);
                                    if (!variables[i].isAnotation) {
                                      //var idx = timeLineSeries.indexOf(filtredVariables[index].name);
                                      cartesianSeries.firstWhere((element) => element.name == filtredVariables[index].name);
                                      int idx = 0;
                                      for (var serie in cartesianSeries) {
                                        if (serie.name == filtredVariables[index].name) {
                                          break;
                                        }
                                        idx++;
                                      }
                                      if (idx != -1) {
                                        //lineBarsData.removeAt(idx);
                                        timeLineSeries.removeAt(idx);
                                        cartesianSeries.removeAt(idx);
                                      }
                                    }
                                  }
                                  setState(() {
                                    proccessing = false;
                                  });
                                  var i=variables.indexWhere((varElement) => varElement.name == seleccionados[builderIndex].name);
                                  variables[i].selected=false;
                                  setState(() {
                                  });
                                },
                                onClear: () {
                                  setState(() {
                                    for (var vari in variables) {
                                      if (vari.isAnotation) {
                                        vari.selected = false;
                                      }
                                    }
                                    for (var vari in variables) {
                                      if (vari.isAnotation) {
                                        vari.selected = false;
                                      }
                                    }
                                                    
                                    otherAnotation.clear();
                                  });
                                }, 
                                actor: seleccionados[builderIndex],);
                        })),
                       Expanded(
                        flex:2,
                         child: OutlinedButton(
                            onPressed: () async {
                              setState(() {
                                isEpisodic = true;
                              });
                            },
                            child: const Text('EPISODIC'),
                          ),
                       ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // This trailing comma makes auto-formatting nicer for build methods.
  }
}

class _DataRangeBadge extends StatelessWidget {
  final DateTime? start;
  final DateTime? end;
  const _DataRangeBadge({required this.start, required this.end});

  String _two(int v) => v.toString().padLeft(2, '0');
  String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

  String _duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${h}h ${m}m ${s}s' : '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    if (start == null || end == null) return const SizedBox.shrink();
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          '${_time(start!)} → ${_time(end!)}  •  ${_duration(end!.difference(start!))}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}

class _GraphPoint {
  final DateTime time;
  final double value;
  const _GraphPoint(this.time, this.value);
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


class _ExportOutput {
  final String id;
  final String label;
  final String description;
  final String extension;
  final String suffix;
  final Uint8List bytes;

  const _ExportOutput({
    required this.id,
    required this.label,
    required this.description,
    required this.extension,
    required this.suffix,
    required this.bytes,
  });
}
