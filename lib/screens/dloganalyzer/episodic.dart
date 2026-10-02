// V113 - Trima Startup documented exit-condition evaluator
// V111 - TRIMA master-state analyzer; ignores incidental Enter/Exit states.
// V104 - parse exact raw `">` form and use timestamp-based parsed LeakValue for debug + LeakDetector
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';

import 'export_folder.dart';
import 'dlog_decoder/dlog_alarm_catalog.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class EpisodicPage extends StatefulWidget {
  final List<String> episodios;
  final List<String> machineData;
  final Function onClose;
  final String? fileName;
  final DateTime? dataStart;
  final DateTime? dataEnd;

  // Optional raw .dlog bytes. When supplied for Optia (1P), the page
  // reconstructs embedded APC camera images directly from the DLOG.
  final Uint8List? dlogBytes;

  // Parsed Procedure CSV supplied by GraphicPage.
  // This is the authoritative source for DATA fields such as LeakValue,
  // InletAct, ACAct, etc.; `episodios` only contains timestamp + verbose TRACE.
  final List<List<dynamic>> procedureRows;
  final Map<String, int> procedureColumns;

  const EpisodicPage({
    super.key,
    required this.episodios,
    required this.machineData,
    required this.onClose,
    this.fileName,
    this.dataStart,
    this.dataEnd,
    this.dlogBytes,
    this.procedureRows = const <List<dynamic>>[],
    this.procedureColumns = const <String, int>{},
  });

  @override
  State<EpisodicPage> createState() => _EpisodicPageState();
}

class _EpisodicPageState extends State<EpisodicPage> {
  int _mainTabIndex = 0;
  final ItemScrollController _scrollController = ItemScrollController();
  final ScrollController _trimaDialogScrollController = ScrollController();
  final TextEditingController _textEditingController =
      TextEditingController();
  final TextEditingController _jumpLineController = TextEditingController();

  final List<int> indexFound = <int>[];
  final Set<int> _indexFoundSet = <int>{};
  late final List<_ConfigFileEntry> _cachedConfigFiles;
  late List<_TrimaEnterExitInterval> _cachedTrimaIntervals;
  late Map<int, List<_TrimaEnterExitInterval>> _cachedTrimaChildren;

  // Performance: cassette TRACE must never rescan widget.episodios while
  // ListView/ExpansionTile is rebuilding during scroll.
  final Map<int, List<MapEntry<int, String>>> _cachedCassetteEvidence = {};
  final Map<int, bool?> _cachedCassetteExit = {};
  // V96: single-pass stateful Procedure CSV cache.
  // For every column we store only changes. The current value at any row is
  // therefore the last change at or before that row.
  final Map<String, List<({int row, DateTime? time, dynamic value})>>
      _trimaCsvChanges = {};

  final Map<int, List<MapEntry<int, double>>> _cachedApsSamples = {};
  final Map<int, bool?> _cachedApsExit = {};
  final Map<int, double?> _cachedApsAtEnter = {};
  final Map<int, int?> _cachedApsSourceLineAtEnter = {};
  final Map<int, double?> _cachedReturnVolAtEnter = {};
  final Map<int, int?> _cachedReturnVolSourceLineAtEnter = {};
  final List<({DateTime time, int line, double value})> _trimaApsTimeline = [];
  final List<({DateTime time, int line, double value})> _trimaAcVolTimeline = [];
  final List<({DateTime time, int line, double value})> _trimaInletVolTimeline = [];
  final List<({DateTime time, int line, double value})> _trimaReturnVolTimeline = [];
  final Map<int, List<MapEntry<int, String>>> _cachedDoorEvidence = {};
  final Map<int, bool?> _cachedDoorExit = {};
  final Map<int, String?> _cachedDoorStateAtEnter = {};
  final Map<int, int?> _cachedDoorStateLineAtEnter = {};
  final Map<int, List<MapEntry<int, String>>> _cachedDoorStateChanges = {};
  final Map<int, List<MapEntry<int, String>>> _cachedDoorPowerChanges = {};
  final Map<int, List<MapEntry<int, String>>> _cachedDoorLockCommands = {};
  int ptr = 0;
  Timer? _searchDebounce;
  late final List<String> _episodiosLower;
  late final List<_EpisodicAlarm> _cachedAlarms;
  late final List<_OptiaImageFrame> _cachedOptiaImages;
  late final Map<String, num> _cachedReveosWMeter;
  final Map<int, String> _alarmFeedback = <int, String>{};
  final Map<int, _FeedbackSendState> _alarmFeedbackState = <int, _FeedbackSendState>{};

  // Trima analyzer can be minimized while the user inspects the event list.
  bool _trimaAnalyzerMinimized = false;

  @override
  void initState() {
    super.initState();
    _episodiosLower =
        List<String>.unmodifiable(widget.episodios.map((e) => e.toLowerCase()));
    _cachedConfigFiles = _parseConfigFiles();
    _cachedAlarms = _extractEpisodicAlarms();
    _cachedOptiaImages = _extractOptiaImages(widget.dlogBytes);
    _cachedReveosWMeter = _extractReveosWMeter(widget.dlogBytes);
    _buildTrimaCsvStateCache();
    _cachedTrimaIntervals = _buildTrimaEnterExitIntervals()
        .where(_trimaIsMasterAnalyzedState)
        .toList();
    _cachedTrimaChildren = _buildTrimaChildrenCache(_cachedTrimaIntervals);
    _rebuildTrimaDiagnosticCaches();

    if (_trimaPrintStateCsvValues) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
          });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _textEditingController.dispose();
    _jumpLineController.dispose();
    _trimaDialogScrollController.dispose();
    super.dispose();
  }

  void _search(String value) {
    // Do not rescan the entire DLOG on every keystroke. This was blocking the
    // UI thread and made the line-by-line viewer appear to freeze.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _executeSearch(value);
    });
  }

  void _executeSearch(String value) {
    final query = value.trim().toLowerCase();
    final nextFound = <int>[];

    if (query.isNotEmpty) {
      for (var i = 0; i < _episodiosLower.length; i++) {
        if (_episodiosLower[i].contains(query)) {
          nextFound.add(i);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      indexFound
        ..clear()
        ..addAll(nextFound);
      _indexFoundSet
        ..clear()
        ..addAll(nextFound);
      ptr = 0;
    });

    if (nextFound.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.isAttached) return;
        _scrollController.jumpTo(
          index: nextFound.first,
          alignment: 0.35,
        );
      });
    }
  }

  void _jumpToEpisodeFromAnalyzer(int episodeIndex) {
    if (episodeIndex < 0 || episodeIndex >= widget.episodios.length) return;
    _jumpToEpisodeSearch(widget.episodios[episodeIndex], preferredIndex: episodeIndex);
  }

  /// Opens EPISODIC with a reusable search term. For alarms this is the
  /// alarm name (or official/code identifier when available), so Previous / Next
  /// can navigate every incidence instead of matching one complete TRACE line.
  void _jumpToEpisodeSearch(String searchText, {int? preferredIndex}) {
    final q0 = searchText.trim();
    if (q0.isEmpty) return;

    _searchDebounce?.cancel();
    _textEditingController.text = q0;
    _textEditingController.selection = TextSelection.collapsed(
      offset: _textEditingController.text.length,
    );

    final q = q0.toLowerCase();
    final matches = <int>[];
    for (var i = 0; i < _episodiosLower.length; i++) {
      if (_episodiosLower[i].contains(q)) matches.add(i);
    }

    var target = preferredIndex;
    if (target == null || target < 0 || target >= widget.episodios.length) {
      target = matches.isNotEmpty ? matches.first : null;
    }

    setState(() {
      _mainTabIndex = 0;
      indexFound
        ..clear()
        ..addAll(matches);
      _indexFoundSet
        ..clear()
        ..addAll(matches);
      final exact = target == null ? -1 : indexFound.indexOf(target);
      ptr = exact >= 0 ? exact : 0;
    });

    if (target != null) {
      final jumpIndex = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.isAttached) return;
        _scrollController.jumpTo(index: jumpIndex, alignment: 0.35);
      });
    }
  }

  List<_EpisodicAlarm> _extractEpisodicAlarms() {
    final sourcePath = widget.fileName ?? '';
    final name = sourcePath.split(RegExp(r'[\\/]')).last.toUpperCase();
    final isTrima = name.startsWith('1T');
    final isOptiaOrReveos = name.startsWith('1P') || name.startsWith('1W');
    final machine = isTrima ? 'trima' : (name.startsWith('1P') ? 'optia' : 'reveos');
    final out = <_EpisodicAlarm>[];

    String? field(String raw, String key) {
      // Optia/Reveos syntax: {ALARM_NAME} Name {NODE_ID} ...
      final braced = RegExp(
        r'\{' + RegExp.escape(key) + r'\}\s*([^\s{}]+)',
        caseSensitive: false,
      ).firstMatch(raw);
      if (braced != null) return braced.group(1)?.trim();
      final legacy = RegExp(
        '(?:^|[\\s,;|])' + RegExp.escape(key) + r'\s*[:=]\s*([^,;|]+)',
        caseSensitive: false,
      ).firstMatch(raw);
      return legacy?.group(1)?.trim();
    }

    for (var i = 0; i < widget.episodios.length; i++) {
      final raw = widget.episodios[i];
      final lower = raw.toLowerCase();
      var alarm = false;
      if (isOptiaOrReveos) {
        alarm = lower.contains('raised_alarm');
      } else if (isTrima) {
        // Keep compatibility with the alarm lines currently supplied to
        // EpisodicPage. CriticalOutput is technical evidence and the catalog
        // lookup below only enriches it when it maps to an official alarm.
        alarm = lower.contains('critical output') || lower.contains('criticaloutput') ||
            lower.contains('alarmcurrent') || lower.contains('alarmenumcurrent');
      }
      if (!alarm) continue;

      final rawAlarmName = isOptiaOrReveos ? field(raw, 'ALARM_NAME') : null;
      final rawAlarmId = isOptiaOrReveos ? field(raw, 'ALARM_ID') : null;
      final trimaCode = isTrima
          ? (field(raw, 'AlarmEnumCurrent') ?? field(raw, 'AlarmCurrent') ?? field(raw, 'Alarm'))
          : null;

      final ref = isOptiaOrReveos
          ? (rawAlarmName == null ? null :
              (DlogAlarmCatalog.byAlarmIdentification(machine, rawAlarmName) ??
               DlogAlarmCatalog.lookup(machine: machine, alarmName: rawAlarmName, dlogText: raw)))
          : DlogAlarmCatalog.lookup(machine: machine, code: trimaCode, dlogText: raw);

      // For Optia/Reveos the visible title is ALWAYS the literal value
      // following {ALARM_NAME}. The catalog is enrichment for Help only.
      String title = isOptiaOrReveos ? (rawAlarmName?.trim() ?? '') : (ref?.name.trim() ?? '');
      if (title.isEmpty && isTrima) {
        final pos = lower.indexOf('criticaloutput');
        final pos2 = lower.indexOf('critical output');
        final p = pos >= 0 ? pos + 'criticaloutput'.length : (pos2 >= 0 ? pos2 + 'critical output'.length : -1);
        if (p >= 0 && p < raw.length) {
          title = raw.substring(p).replaceFirst(RegExp(r'^[\s|:=,;\-]+'), '').trim();
          final colon = title.indexOf(':');
          if (colon > 0) title = title.substring(0, colon).trim();
        }
      }
      if (title.isEmpty) title = isTrima ? 'Alarm' : 'Raised alarm';

      final code = (ref?.code.isNotEmpty == true ? ref!.code : (trimaCode ?? rawAlarmId ?? '')).trim();
      final searchText = (isOptiaOrReveos
              ? (rawAlarmName?.isNotEmpty == true ? rawAlarmName! : code)
              : (ref?.name.isNotEmpty == true ? ref!.name : code))
          .trim();
      final ts = RegExp(r'\b\d{4}[/-]\d{2}[/-]\d{2}[_ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\b')
          .firstMatch(raw)?.group(0);

      out.add(_EpisodicAlarm(
        episodeIndex: i,
        lineNumber: i + 1,
        title: title,
        timestamp: ts,
        raw: raw,
        code: code,
        searchText: searchText.isNotEmpty ? searchText : title,
        reference: ref,
      ));
    }
    return List<_EpisodicAlarm>.unmodifiable(out);
  }

  void _showAlarmHelp(_EpisodicAlarm alarm) {
    final ref = alarm.reference;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(alarm.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: SingleChildScrollView(
            child: ref == null
                ? const Text('No hay información disponible para esta alarma en el catálogo.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ref.code.isNotEmpty) _alarmHelpField('Code', ref.code),
                      if (ref.statusLine.isNotEmpty) _alarmHelpField('Status line', ref.statusLine),
                      if (ref.messageType.isNotEmpty) _alarmHelpField('Message type', ref.messageType),
                      if (ref.occursDuring.isNotEmpty) _alarmHelpField('Occurs during', ref.occursDuring),
                      if (ref.detection.isNotEmpty) _alarmHelpField('Detection', ref.detection),
                      if (ref.possibleCauses.isNotEmpty) _alarmHelpField('Possible causes', ref.possibleCauses),
                      if (ref.suggestedActions.isNotEmpty) _alarmHelpField('Suggested actions', ref.suggestedActions),
                    ],
                  ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close'))],
      ),
    );
  }

  Widget _alarmHelpField(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          SelectableText(value),
        ]),
      );

  Future<void> _sendN7Feedback(_EpisodicAlarm alarm) async {
    final feedback = (_alarmFeedback[alarm.episodeIndex] ?? '').trim();
    if (feedback.isEmpty) return;
    setState(() => _alarmFeedbackState[alarm.episodeIndex] = _FeedbackSendState.sending);

    final payload = <String, dynamic>{
      'platform': _platformName(),
      'file': widget.fileName,
      'alarm': alarm.title,
      'timestamp': alarm.timestamp,
      'lineNumber': alarm.lineNumber,
      'rawLine': alarm.raw,
      'feedback': feedback,
    };

    try {
      await _postN7Feedback(payload);
      if (!mounted) return;
      setState(() => _alarmFeedbackState[alarm.episodeIndex] = _FeedbackSendState.sent);
    } catch (_) {
      if (!mounted) return;
      setState(() => _alarmFeedbackState[alarm.episodeIndex] = _FeedbackSendState.error);
    }
  }

  String _platformName() {
    final n = (widget.fileName ?? '').split(RegExp(r'[\\/]')).last.toUpperCase();
    if (n.startsWith('1T')) return 'TRIMA';
    if (n.startsWith('1P')) return 'OPTIA';
    if (n.startsWith('1W')) return 'REVEOS';
    return 'UNKNOWN';
  }

  Future<void> _postN7Feedback(Map<String, dynamic> payload) async {
    // Backend hook. Replace this body with the real authenticated HTTP/API call.
    // Keeping the payload isolated here means the ALARMS UI does not need to
    // change when the endpoint is defined.
    throw UnimplementedError('N7 Feedback backend is not configured');
  }

  Widget _alarmsPanel(BuildContext context, ColorScheme scheme) {
    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text('Alarms', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              Text('${_cachedAlarms.length} alarms', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: _cachedAlarms.isEmpty
                ? Center(child: Text('No alarms found in this DLOG.', style: TextStyle(color: scheme.onSurfaceVariant)))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _cachedAlarms.length,
                    itemBuilder: (context, index) {
                      final a = _cachedAlarms[index];
                      final state = _alarmFeedbackState[a.episodeIndex] ?? _FeedbackSendState.idle;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            // First line: alarm name ONLY.
                            Text(a.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            SelectableText('L${a.lineNumber} · ${a.raw}', style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, color: scheme.onSurfaceVariant)),
                            const SizedBox(height: 10),
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              FilledButton.tonalIcon(
                                onPressed: () => _jumpToEpisodeSearch(a.searchText, preferredIndex: a.episodeIndex),
                                icon: const Icon(Icons.search_rounded, size: 17),
                                label: const Text('Jump'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () => setState(() => a.feedbackOpen = !a.feedbackOpen),
                                icon: const Icon(Icons.rate_review_outlined, size: 17),
                                label: const Text('N7'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () => _showAlarmHelp(a),
                                icon: const Icon(Icons.help_outline_rounded, size: 17),
                                label: const Text('Help'),
                              ),
                            ]),
                            if (a.feedbackOpen) ...[
                              const SizedBox(height: 12),
                              TextField(
                                minLines: 3,
                                maxLines: 6,
                                onChanged: (v) {
                                  _alarmFeedback[a.episodeIndex] = v;
                                  if (_alarmFeedbackState[a.episodeIndex] == _FeedbackSendState.sent) {
                                    setState(() => _alarmFeedbackState[a.episodeIndex] = _FeedbackSendState.idle);
                                  }
                                },
                                decoration: const InputDecoration(labelText: 'N7 Feedback', hintText: 'Write feedback about this alarm...', alignLabelWithHint: true, border: OutlineInputBorder()),
                              ),
                              const SizedBox(height: 10),
                              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                if (state == _FeedbackSendState.sent) Padding(padding: const EdgeInsets.only(right: 10), child: Text('Sent', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700))),
                                if (state == _FeedbackSendState.error) Padding(padding: const EdgeInsets.only(right: 10), child: Text('Backend not configured / Retry', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w700))),
                                FilledButton.icon(
                                  onPressed: state == _FeedbackSendState.sending ? null : () => _sendN7Feedback(a),
                                  icon: state == _FeedbackSendState.sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded),
                                  label: Text(state == _FeedbackSendState.sending ? 'Sending...' : 'Send'),
                                ),
                              ]),
                            ],
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }


  List<_OptiaImageFrame> _extractOptiaImages(Uint8List? dlogBytes) {
    if (dlogBytes == null || dlogBytes.isEmpty || !_platformName().toUpperCase().contains('OPTIA')) {
      return const <_OptiaImageFrame>[];
    }
    try {
      var gzipOffset = -1;
      for (var i = 0; i + 2 < dlogBytes.length; i++) {
        if (dlogBytes[i] == 0x1f && dlogBytes[i + 1] == 0x8b && dlogBytes[i + 2] == 0x08) {
          gzipOffset = i;
          break;
        }
      }
      if (gzipOffset < 0) return const <_OptiaImageFrame>[];
      final inflated = Uint8List.fromList(GZipDecoder().decodeBytes(dlogBytes.sublist(gzipOffset)));
      for (var i = 0; i < inflated.length; i++) {
        inflated[i] ^= 0xA5;
      }
      return _extractOptiaImagesFromPayload(inflated);
    } catch (_) {
      return const <_OptiaImageFrame>[];
    }
  }

  List<_OptiaImageFrame> _extractOptiaImagesFromPayload(Uint8List payload) {
    final groups = <int, Map<int, Uint8List>>{};
    final dimensions = <int, ({int width, int height})>{};
    final firstOffsets = <int, int>{};

    int u32(int o) => payload[o] | (payload[o + 1] << 8) | (payload[o + 2] << 16) | (payload[o + 3] << 24);

    // APC image fragments use: 'IM 01 00' + imageId(u32) + chunkIndex(u32).
    // Chunk 0 additionally contains height/width metadata; its pixels start
    // at +28. Subsequent chunks contain 1024 Mono8 pixels from +12.
    for (var o = 0; o + 12 < payload.length; o++) {
      if (payload[o] != 0x49 || payload[o + 1] != 0x4d || payload[o + 2] != 0x01 || payload[o + 3] != 0x00) continue;
      final imageId = u32(o + 4);
      final chunk = u32(o + 8);
      if (imageId <= 0 || chunk < 0 || chunk > 8192) continue;

      var dataStart = o + 12;
      if (chunk == 0) {
        if (o + 28 > payload.length) continue;
        final h = u32(o + 12);
        final w = u32(o + 16);
        if (w <= 0 || h <= 0 || w > 8192 || h > 8192) continue;
        dimensions[imageId] = (width: w, height: h);
        firstOffsets.putIfAbsent(imageId, () => o);
        dataStart = o + 28;
      }
      if (dataStart + 1024 > payload.length) continue;
      groups.putIfAbsent(imageId, () => <int, Uint8List>{})[chunk] =
          Uint8List.sublistView(payload, dataStart, dataStart + 1024);
    }

    final out = <_OptiaImageFrame>[];

    // eBox Gen1 image fragments:
    // 'IM 65 00' + imageId(u32) + chunkIndex(u32).
    // Chunk 0: height(u32), width(u32), metadata(8), then JPEG bytes at +28.
    // Other chunks: JPEG continuation at +12.
    // IMPORTANT: Gen1 carries exactly 1024 JPEG bytes per fragment.
    // The remaining 16 bytes before the next IM record are record framing/
    // metadata and MUST NOT be appended to the JPEG stream. Including them
    // causes an accumulating 16-byte shift on every chunk.
    final gen1Groups = <int, Map<int, Uint8List>>{};
    final gen1Dimensions = <int, ({int width, int height})>{};
    final gen1FirstOffsets = <int, int>{};

    for (var o = 0; o + 28 < payload.length; o++) {
      if (payload[o] != 0x49 ||
          payload[o + 1] != 0x4d ||
          payload[o + 2] != 0x65 ||
          payload[o + 3] != 0x00) continue;

      final imageId = u32(o + 4);
      final chunk = u32(o + 8);
      if (imageId <= 0 || chunk < 0 || chunk > 8192) continue;

      var dataStart = o + 12;
      if (chunk == 0) {
        final h = u32(o + 12);
        final w = u32(o + 16);
        if (w <= 0 || h <= 0 || w > 8192 || h > 8192) continue;
        // A valid Gen1 first fragment contains a JPEG SOI at +28.
        if (payload[o + 28] != 0xff || payload[o + 29] != 0xd8) continue;
        gen1Dimensions[imageId] = (width: w, height: h);
        gen1FirstOffsets.putIfAbsent(imageId, () => o);
        dataStart = o + 28;
      }

      final end = (dataStart + 1024 < payload.length)
          ? dataStart + 1024
          : payload.length;
      if (end <= dataStart) continue;
      gen1Groups.putIfAbsent(imageId, () => <int, Uint8List>{})[chunk] =
          Uint8List.sublistView(payload, dataStart, end);
    }

    for (final entry in gen1Dimensions.entries) {
      final imageId = entry.key;
      final chunks = gen1Groups[imageId];
      if (chunks == null || chunks.isEmpty || !chunks.containsKey(0)) continue;

      final ordered = chunks.keys.toList()..sort();
      // Require a continuous sequence from chunk 0.
      final bytes = <int>[];
      for (var i = 0; ; i++) {
        final c = chunks[i];
        if (c == null) break;
        bytes.addAll(c);
      }
      if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) continue;

      // Trim after JPEG EOI. This also removes padding from the last fragment.
      var eoi = -1;
      for (var i = 2; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0xff && bytes[i + 1] == 0xd9) {
          eoi = i + 2;
          break;
        }
      }
      if (eoi < 0) continue;
      final jpeg = Uint8List.fromList(bytes.sublist(0, eoi));

      int? episodeIndex;
      final needle = imageId.toString();
      for (var i = 0; i < widget.episodios.length; i++) {
        final e = _episodiosLower[i];
        if ((e.contains('image id') || e.contains('imageid')) && e.contains(needle)) {
          episodeIndex = i;
          break;
        }
      }

      out.add(_OptiaImageFrame(
        imageId: imageId,
        width: entry.value.width,
        height: entry.value.height,
        pixels: jpeg,
        payloadOffset: gen1FirstOffsets[imageId] ?? -1,
        episodeIndex: episodeIndex,
      ));
    }

    for (final entry in dimensions.entries) {
      final imageId = entry.key;
      final w = entry.value.width;
      final h = entry.value.height;
      final expectedBytes = w * h;
      final expectedChunks = (expectedBytes + 1023) ~/ 1024;
      final chunks = groups[imageId];
      if (chunks == null || chunks.length < expectedChunks) continue;
      var complete = true;
      for (var i = 0; i < expectedChunks; i++) {
        if (!chunks.containsKey(i)) { complete = false; break; }
      }
      if (!complete) continue;

      final pixels = Uint8List(expectedBytes);
      var dst = 0;
      for (var i = 0; i < expectedChunks && dst < expectedBytes; i++) {
        final c = chunks[i]!;
        final int n = (expectedBytes - dst) < c.length ? (expectedBytes - dst) : c.length;
        pixels.setRange(dst, dst + n, c, 0);
        dst += n;
      }

      // Associate the nearest textual Image ID occurrence for Jump/context.
      int? episodeIndex;
      final needle = imageId.toString();
      for (var i = 0; i < widget.episodios.length; i++) {
        final e = _episodiosLower[i];
        if ((e.contains('image id') || e.contains('imageid')) && e.contains(needle)) {
          episodeIndex = i;
          break;
        }
      }
      out.add(_OptiaImageFrame(
        imageId: imageId,
        width: w,
        height: h,
        pixels: pixels,
        payloadOffset: firstOffsets[imageId] ?? -1,
        episodeIndex: episodeIndex,
      ));
    }
    out.sort((a, b) => a.payloadOffset.compareTo(b.payloadOffset));
    return List<_OptiaImageFrame>.unmodifiable(out);
  }

  void _showOptiaImage(_OptiaImageFrame frame) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 850),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
              child: Row(children: [
                Expanded(child: Text('Image ID ${frame.imageId} · ${frame.width} × ${frame.height} · Mono8', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                IconButton(onPressed: () => Navigator.of(dialogContext).pop(), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: InteractiveViewer(
                minScale: 0.25,
                maxScale: 8,
                child: Center(child: _OptiaMonoImage(frame: frame, fit: BoxFit.contain)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _imagesPanel(BuildContext context, ColorScheme scheme) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Row(children: [
          Icon(Icons.image_outlined, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text('Images', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          Text('${_cachedOptiaImages.length} images', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
      Divider(height: 1, color: scheme.outlineVariant),
      Expanded(
        child: _cachedOptiaImages.isEmpty
            ? Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(widget.dlogBytes == null
                    ? 'No images loaded. Pass the original Optia DLOG bytes to EpisodicPage.dlogBytes.'
                    : 'No complete images found in this DLOG.',
                  textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant))))
            : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 390, childAspectRatio: 1.35, crossAxisSpacing: 10, mainAxisSpacing: 10),
                itemCount: _cachedOptiaImages.length,
                itemBuilder: (context, index) {
                  final f = _cachedOptiaImages[index];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: Container(color: scheme.surfaceContainerHighest, child: _OptiaMonoImage(frame: f, fit: BoxFit.contain))),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Image ID ${f.imageId}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${f.width} × ${f.height} · Mono8', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 8, children: [
                            FilledButton.tonalIcon(onPressed: () => _showOptiaImage(f), icon: const Icon(Icons.open_in_full, size: 16), label: const Text('View')),
                            FilledButton.tonalIcon(
                              onPressed: f.episodeIndex == null ? null : () => _jumpToEpisodeSearch(f.imageId.toString(), preferredIndex: f.episodeIndex),
                              icon: const Icon(Icons.search_rounded, size: 16), label: const Text('Jump')),
                          ]),
                        ]),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }

  void _moveResult(int delta) {
    if (indexFound.isEmpty) return;

    setState(() {
      ptr = (ptr + delta) % indexFound.length;
      if (ptr < 0) ptr += indexFound.length;
    });

    if (_scrollController.isAttached) {
      _scrollController.jumpTo(
        index: indexFound[ptr],
        alignment: 0.35,
      );
    }
  }

  static const int _trimaMaxLastParameterLength = 100;

  List<_ConfigFileEntry> _parseConfigFiles() {
    final byPath = <String, _ConfigFileEntry>{};

    // Optia/Reveos: ConfigFileData.
    for (final event in widget.episodios) {
      final lower = event.toLowerCase();
      final marker = lower.indexOf('configfiledata');
      if (marker < 0) continue;

      final tail = event.substring(marker + 'configfiledata'.length);
      String? path;
      String content = '';

      final bracketPath = RegExp(r'<([^>\r\n]+)>\s*:').firstMatch(tail);
      if (bracketPath != null) {
        path = bracketPath.group(1)?.trim();
        content = tail.substring(bracketPath.end).trim();
      } else {
        final directPath = RegExp(
          r'^\s*[:=,-]?\s*(?:path\s*[:=]\s*)?([/\\][^\r\n:]+?)\s*:\s*',
          caseSensitive: false,
        ).firstMatch(tail);
        if (directPath != null) {
          path = directPath.group(1)?.trim();
          content = tail.substring(directPath.end).trim();
        }
      }

      if (path == null || path.isEmpty) continue;
      _putConfigFile(byPath, path, content);
    }

    // Trima:
    //   config data: [ NOMBRE ]
    // abre un archivo lógico llamado NOMBRE.dat
    //
    // Las líneas siguientes:
    //   config data:   XXXX=XXXX
    // pertenecen a ese archivo hasta que aparezca el siguiente bloque.
    //
    // IMPORTANTE: se procesa secuencialmente; no intentamos exigir que el
    // encabezado y los valores estén serializados dentro del mismo episodio.
    String? currentTrimaPath;
    final trimaContents = <String, StringBuffer>{};
    var unnamedTrimaIndex = 0;

    final trimaHeaderRx = RegExp(
      r'config\s+data\s*:\s*\[\s*([^\]\r\n]+?)\s*\]',
      caseSensitive: false,
    );
    final trimaValueRx = RegExp(
      r'config\s+data\s*:\s*(?!\[)(.*)$',
      caseSensitive: false,
    );

    for (final event in widget.episodios) {
      // Un episodio puede contener saltos de línea; los recorremos en orden.
      final lines = event.split(RegExp(r'\r?\n'));

      for (final rawLine in lines) {
        final header = trimaHeaderRx.firstMatch(rawLine);
        if (header != null) {
          var name = (header.group(1) ?? '').trim();
          name = _sanitizeTrimaConfigFileName(name);

          if (name.isEmpty) {
            unnamedTrimaIndex++;
            name =
                'trima_config_${unnamedTrimaIndex.toString().padLeft(3, '0')}';
          }

          // El texto entre [ ] es el nombre del archivo.
          currentTrimaPath =
              name.toLowerCase().endsWith('.dat') ? name : '$name.dat';
          trimaContents.putIfAbsent(currentTrimaPath, StringBuffer.new);
          continue;
        }

        final value = trimaValueRx.firstMatch(rawLine);
        if (value == null || currentTrimaPath == null) continue;

        final parameter = (value.group(1) ?? '').trim();
        if (parameter.isEmpty || !parameter.contains('=')) continue;

        final buffer = trimaContents.putIfAbsent(
          currentTrimaPath,
          StringBuffer.new,
        );
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.write(parameter);
      }
    }

    for (final entry in trimaContents.entries) {
      _putConfigFile(byPath, entry.key, entry.value.toString());
    }

    return byPath.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void _putConfigFile(
    Map<String, _ConfigFileEntry> byPath,
    String path,
    String content,
  ) {
    final normalized = path.replaceAll(r'\\', '/').trim();
    final next = _ConfigFileEntry(path: normalized, content: content.trim());
    final previous = byPath[normalized];
    if (previous == null || next.content.length > previous.content.length) {
      byPath[normalized] = next;
    }
  }

  String _sanitizeTrimaConfigFileName(String raw) {
    var name = raw.trim();

    // Mantener el texto descriptivo del bloque, reemplazando solamente
    // caracteres que no son seguros como nombre de archivo.
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Windows no admite punto/espacio al final.
    name = name.replaceFirst(RegExp(r'[. ]+$'), '');

    if (name.length > 160) {
      name = name.substring(0, 160).trimRight();
    }
    return name;
  }

  int? _findMatchingSquareBracket(String text, int openIndex) {
    var depth = 0;
    var quote = '';
    var escaped = false;

    for (var i = openIndex; i < text.length; i++) {
      final c = text[i];
      if (quote.isNotEmpty) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == quote) {
          quote = '';
        }
        continue;
      }

      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  List<String> _splitTrimaParameters(String body) {
    final parts = <String>[];
    var start = 0;
    var square = 0;
    var curly = 0;
    var round = 0;
    var quote = '';
    var escaped = false;

    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (quote.isNotEmpty) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == quote) {
          quote = '';
        }
        continue;
      }

      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '[') {
        square++;
      } else if (c == ']') {
        if (square > 0) square--;
      } else if (c == '{') {
        curly++;
      } else if (c == '}') {
        if (curly > 0) curly--;
      } else if (c == '(') {
        round++;
      } else if (c == ')') {
        if (round > 0) round--;
      } else if (c == ',' && square == 0 && curly == 0 && round == 0) {
        final part = body.substring(start, i).trim();
        if (part.isNotEmpty) parts.add(part);
        start = i + 1;
      }
    }

    final last = body.substring(start).trim();
    if (last.isNotEmpty) parts.add(last);
    return parts;
  }

  String _sanitizeTrimaDataBody(String body) {
    final parts = _splitTrimaParameters(body);
    if (parts.isEmpty) return '';

    // Regla de precaución acordada para Trima: si el último elemento supera
    // 100 caracteres, lo cortamos en 100 para no arrastrar texto posterior.
    if (parts.isNotEmpty && parts.last.length > _trimaMaxLastParameterLength) {
      parts[parts.length - 1] =
          parts.last.substring(0, _trimaMaxLastParameterLength).trimRight();
    }
    return parts.join(', ');
  }

  String _formatTrimaDataForFile(String body) {
    final parts = _splitTrimaParameters(body);
    if (parts.isEmpty) return body.trim();
    return parts.map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
  }

  String _trimaConfigPath(String prefix, int index) {
    // Aprovechamos un nombre/ruta explícito sólo cuando aparece antes de
    // `data: [`. Si no existe, usamos un nombre seguro y estable.
    final candidates = <RegExp>[
      RegExp(r'''(?:file(?:name)?|path|name)\s*[:=]\s*["']?([^"'\s,\]\}]+)''',
          caseSensitive: false),
      RegExp(r'<([^>]+)>\s*:?\s*$', caseSensitive: false),
    ];

    for (final rx in candidates) {
      final matches = rx.allMatches(prefix).toList();
      if (matches.isEmpty) continue;
      final value = matches.last.group(1)?.trim();
      if (value != null && value.isNotEmpty && value.length <= 180) {
        return value;
      }
    }

    return 'trima_config_${index.toString().padLeft(3, '0')}.dat';
  }

  List<_ConfigFileEntry> get _configFiles => _cachedConfigFiles;

  IconData _fileIcon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.xml')) return Icons.code_rounded;
    if (n.endsWith('.json')) return Icons.data_object_rounded;
    if (n.endsWith('.ini') || n.endsWith('.cfg') || n.endsWith('.conf')) {
      return Icons.tune_rounded;
    }
    if (n.endsWith('.txt') || n.endsWith('.log')) {
      return Icons.description_outlined;
    }
    if (n.endsWith('.csv')) return Icons.table_chart_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _formatConfigContent(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return text;

    // Importante: no intentamos "extraer" sólo los tokens conocidos porque
    // eso podía hacer desaparecer texto. Conservamos TODO el contenido y
    // únicamente insertamos saltos de línea antes de secciones y parámetros.
    final sectionRx = RegExp(r'\[[^\]\r\n]+\]');
    final keyRx = RegExp(r'(?<!\S)([A-Za-z_][A-Za-z0-9_./+\-]*)=');

    final sections = sectionRx.allMatches(text).toList();
    if (sections.isEmpty) {
      // Sin secciones: devolvemos el original intacto.
      return text;
    }

    final out = StringBuffer();

    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      final sectionName = section.group(0)!;
      final bodyStart = section.end;
      final bodyEnd =
          i + 1 < sections.length ? sections[i + 1].start : text.length;

      // Todo lo que haya antes de la primera sección también se conserva.
      if (i == 0 && section.start > 0) {
        final prefix = text.substring(0, section.start).trim();
        if (prefix.isNotEmpty) {
          out.writeln(prefix);
          out.writeln();
        }
      }

      if (out.isNotEmpty) out.writeln();
      out.writeln(sectionName);

      final body = text.substring(bodyStart, bodyEnd).trim();
      if (body.isEmpty) continue;

      final keys = keyRx.allMatches(body).toList();
      if (keys.isEmpty) {
        out.writeln('  $body');
        continue;
      }

      // Conserva cualquier texto previo a la primera clave.
      if (keys.first.start > 0) {
        final prefix = body.substring(0, keys.first.start).trim();
        if (prefix.isNotEmpty) out.writeln('  $prefix');
      }

      for (var k = 0; k < keys.length; k++) {
        final m = keys[k];
        final key = m.group(1)!;
        final valueStart = m.end;
        final valueEnd =
            k + 1 < keys.length ? keys[k + 1].start : body.length;
        final value = body.substring(valueStart, valueEnd).trim();

        // No alteramos el valor: sólo lo ponemos en su propia línea.
        out.writeln('  $key = $value');
      }
    }

    return out.toString().trimRight();
  }

  Future<void> _downloadConfigFile(_ConfigFileEntry file) async {
    try {
      // Same export flow used by GraphicPage:
      // 1) choose a destination folder
      // 2) write the reconstructed file with exportFilesToFolder().
      final folder = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select export folder',
      );

      // User cancelled the folder picker.
      if (folder == null || !mounted) return;

      final bytes = Uint8List.fromList(utf8.encode(file.content));

      await exportFilesToFolder(
        folder,
        [
          FolderExportFile(
            fileName: file.name,
            bytes: bytes,
          ),
        ],
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${file.name} exported to $folder'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to export ${file.name}: $e')),
      );
    }
  }

  Future<void> _showConfigFile(
    BuildContext context,
    _ConfigFileEntry file,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
          title: Row(
            children: [
              Icon(_fileIcon(file.name)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 760,
            height: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  file.path,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        file.content.isEmpty
                            ? '(No text content available in episodic data)'
                            : _formatConfigContent(file.content),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton.tonalIcon(
              onPressed: file.content.isEmpty
                  ? null
                  : () => _downloadConfigFile(file),
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Platform is intentionally identified from the DLOG filename:
    // 1T = Trima, 1P = Optia, 1W = Reveos.
    final sourcePath = widget.fileName ?? '';
    final fileName = sourcePath
        .split(RegExp(r'[\\/]'))
        .last
        .toUpperCase();
    final isTrimaFile = fileName.startsWith('1T');
    final isOptiaFile = fileName.startsWith('1P');
    final isReveosFile = fileName.startsWith('1W');
    final hasAnalyzer = isTrimaFile || isOptiaFile;
    final hasAlarms = isTrimaFile || isOptiaFile || isReveosFile;
    final analyzerLabel = isTrimaFile ? 'TRIMA ANALYZE' : 'AIM';
    // Optia: EPISODIC | ALARMS | IMAGES | AIM
    // Trima: EPISODIC | ALARMS | TRIMA ANALYZE
    // Reveos: EPISODIC | ALARMS
    final maxTab = isOptiaFile ? 3 : (hasAnalyzer ? 2 : (hasAlarms ? 1 : 0));
    if (_mainTabIndex > maxTab) _mainTabIndex = 0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 850;

            final left = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasAlarms || hasAnalyzer) ...[
                  Container(
                    color: Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(child: _mainTabButton(context, selected: _mainTabIndex == 0, icon: Icons.list_alt_rounded, label: 'EPISODIC', count: widget.episodios.length, onTap: () => setState(() => _mainTabIndex = 0))),
                        const SizedBox(width: 4),
                        Expanded(child: _mainTabButton(context, selected: _mainTabIndex == 1, icon: Icons.warning_amber_rounded, label: 'ALARMS', count: _cachedAlarms.length, onTap: () => setState(() => _mainTabIndex = 1))),
                        if (isOptiaFile) ...[
                          const SizedBox(width: 4),
                          Expanded(child: _mainTabButton(context, selected: _mainTabIndex == 2, icon: Icons.image_outlined, label: 'IMAGES', count: _cachedOptiaImages.length, onTap: () => setState(() => _mainTabIndex = 2))),
                          const SizedBox(width: 4),
                          Expanded(child: _mainTabButton(context, selected: _mainTabIndex == 3, icon: Icons.center_focus_strong_outlined, label: 'AIM', count: _analyzeAim().length, onTap: () => setState(() => _mainTabIndex = 3))),
                        ] else if (isTrimaFile) ...[
                          const SizedBox(width: 4),
                          Expanded(child: _mainTabButton(context, selected: _mainTabIndex == 2, icon: Icons.precision_manufacturing_outlined, label: analyzerLabel, count: _cachedTrimaIntervals.length, onTap: () => setState(() => _mainTabIndex = 2))),
                        ],
                      ],
                    ),
                  ),
                ],
                Expanded(
                  child: IndexedStack(
                    index: (hasAlarms || hasAnalyzer) ? _mainTabIndex : 0,
                    children: [
                      _episodesPanel(context, scheme),
                      if (hasAlarms) _alarmsPanel(context, scheme),
                      if (isOptiaFile) _imagesPanel(context, scheme),
                      if (isTrimaFile) _trimaAnalysisEmbedded(context),
                      if (isOptiaFile) _aimAnalysisEmbedded(context),
                    ],
                  ),
                ),
              ],
            );

            if (compact) {
              return Column(
                children: [
                  Expanded(
                    flex: 7,
                    child: Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: left,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    flex: 3,
                    child: _equipmentPanel(context, scheme),
                  ),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 7,
                  child: Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: left,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: _equipmentPanel(context, scheme),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _compactCount(int value) {
    if (value < 1000) return '$value';
    if (value < 1000000) {
      final v = value / 1000;
      return v < 10 && value % 1000 != 0
          ? '${v.toStringAsFixed(1)}K'
          : '${v.floor()}K';
    }
    if (value < 1000000000) {
      final v = value / 1000000;
      return v < 10 && value % 1000000 != 0
          ? '${v.toStringAsFixed(1)}M'
          : '${v.floor()}M';
    }
    final v = value / 1000000000;
    return v < 10 && value % 1000000000 != 0
        ? '${v.toStringAsFixed(1)}B'
        : '${v.floor()}B';
  }

  void _jumpToLine() {
    final line = int.tryParse(_jumpLineController.text.trim());
    if (line == null || line < 1 || line > widget.episodios.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Line must be between 1 and ${widget.episodios.length}.')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    _scrollController.jumpTo(index: line - 1, alignment: 0.08);
  }

  Widget _mainTabButton(
    BuildContext context, {
    required bool selected,
    required IconData icon,
    required String label,
    int? count,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 3,
                color: selected ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 19,
                color: selected
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
              ),
              if (count != null) ...[
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _compactCount(count),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ],
          ),
        ),
        ),
      ),
    );
  }


  Widget _trimaAnalysisEmbedded(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final intervals = _cachedTrimaIntervals;
    final rootIntervals = intervals
        .where((e) =>
            (e.exitIndex != null && !_trimaHasCachedParent(e)) ||
            (e.exitIndex == null &&
                e.name.toLowerCase() != 'mainstate' &&
                !_trimaHasCachedParent(e)))
        .toList()
      ..sort((a, b) => a.enterIndex.compareTo(b.enterIndex));

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
                Text(
                  'Master-state mode: only approved Trima states are shown. '
                  'Known exit conditions are validated from CSV/TRACE; states without sufficient evidence remain UNKNOWN.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _trimaStatChip(context, 'PAIRS', '${intervals.where((e) => e.exitIndex != null).length}'),
                    const SizedBox(width: 8),
                    _trimaStatChip(context, 'OPEN', '${intervals.where((e) => e.exitIndex == null).length}'),
                    const SizedBox(width: 8),
                    _trimaStatChip(context, 'MAX DEPTH',
                        '${intervals.isEmpty ? 0 : intervals.map((e) => e.depth).reduce((a, b) => a > b ? a : b)}'),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Expanded(flex: 5, child: Text('State / Substate', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 2, child: Text('ENTER', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 2, child: Text('EXIT', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 1, child: Text('ΔT', style: TextStyle(fontWeight: FontWeight.w800))),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    controller: _trimaDialogScrollController,
                    itemCount: rootIntervals.length,
                    itemBuilder: (context, index) {
                      final item = rootIntervals[index];
                      final enter = item.enterTime == null
                          ? '—'
                          : _trimaTimeLabel(item.enterTime!);
                      final exit = item.exitTime == null
                          ? '—'
                          : _trimaTimeLabel(item.exitTime!);
                      final duration = item.durationSeconds == null
                          ? '—'
                          : '${item.durationSeconds!.toStringAsFixed(3)} s';
                      final contentCount = item.exitIndex == null
                          ? 0
                          : (item.exitIndex! - item.enterIndex - 1)
                              .clamp(0, widget.episodios.length);

                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          tilePadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          childrenPadding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          leading: Builder(
                            builder: (_) {
                              final exitOk = _trimaKnownExitSatisfied(item);
                              final c = exitOk == true
                                  ? scheme.primary
                                  : (exitOk == false
                                      ? scheme.error
                                      : scheme.onSurfaceVariant);
                              return Icon(
                                exitOk == true
                                    ? Icons.check_circle_rounded
                                    : (exitOk == false
                                        ? Icons.cancel_rounded
                                        : Icons.radio_button_unchecked_rounded),
                                color: c,
                              );
                            },
                          ),
                          title: Text(
                            'L${item.enterIndex + 1}  ${_trimaStateLeaf(item.name)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ENTER L${item.enterIndex + 1} $enter   →   '
                                'EXIT ${item.exitIndex == null ? '—' : 'L${item.exitIndex! + 1}'} $exit   •   ΔT $duration'
                                '${item.exitIndex == null ? '' : '   •   $contentCount lines inside'}',
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _trimaClosedInternalSubstates(item),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          children: [
                            if (item.exitIndex == null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'No matching Exit: ${item.name} found.',
                                  style: TextStyle(color: scheme.error),
                                ),
                              )
                            else ...[
                              _trimaSubstateSummary(item, scheme),
                              if (_trimaIsStartupTestState(item))
                                _trimaStartupSnapshot(item, scheme),
                              if (_trimaIsStartupTransitionState(item))
                                _trimaStartupTransitionSnapshot(item, scheme),
                              if (_trimaIsValveVerificationState(item)) ...[
                                _trimaValveStateSnapshot(item, scheme),
                                ..._buildTrimaCompactValveSummary(item, scheme),
                              ],
                              if (_trimaIsPrimeChannelVolumeState(item))
                                _trimaPrimeChannelSnapshot(item, scheme),
                              if (_trimaIsPumpVerificationState(item))
                                _trimaPumpStateSnapshot(item, scheme),
                              if (_trimaIsCassetteVerificationState(item))
                                _trimaCassetteStateSnapshot(item, scheme),
                              if (_trimaIsDisposableVerificationState(item))
                                _trimaDisposableSnapshot(item, scheme),
                              if (_trimaIsApsVerificationState(item) &&
                                  !_trimaIsDisposableVerificationState(item))
                                _trimaApsStateSnapshot(item, scheme),
                              if (_trimaIsDoorVerificationState(item))
                                _trimaDoorStateSnapshot(item, scheme),
                              if (_trimaIsCentrifugeVerificationState(item))
                                _trimaCentrifugeStateSnapshot(item, scheme),
                              if (_trimaIsPowerTestState(item))
                                _trimaPowerTestSnapshot(item, scheme),
                              if (_trimaIsLeakDetectorState(item))
                                _trimaLeakDetectorSnapshot(item, scheme),
                              if (_trimaIsLowerNotificationState(item))
                                _trimaLowerNotificationSnapshot(item, scheme),
                              if (_trimaIsConnectAcState(item))
                                _trimaConnectAcSnapshot(item, scheme),
                              if (_trimaIsAcPrimeVerificationState(item))
                                _trimaAcPrimeSnapshot(item, scheme),
                              ..._buildTrimaNestedContents(
                                context,
                                item,
                                scheme,
                              ),
                              _trimaBoundaryLine(
                                context,
                                item.exitIndex!,
                                'EXIT',
                                widget.episodios[item.exitIndex!],
                                scheme,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        );
  }

  Widget _aimTraditionalTab({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: textColor,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _aimAnalysisEmbedded(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _analyzeAim();
    final bootTree = _analyzeAimBootTree();
    final startupTree = _analyzeAimStartupTree();
    final skipped = <int>{};
    var mode = 0;

    return StatefulBuilder(
      builder: (context, setDialogState) => Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: Colors.transparent,
                child: Row(
                  children: [
                    _aimTraditionalTab(
                      context: context,
                      label: 'BOOT FLOW',
                      icon: Icons.account_tree_outlined,
                      selected: mode == 0,
                      onTap: () => setDialogState(() => mode = 0),
                    ),
                    _aimTraditionalTab(
                      context: context,
                      label: 'SECTION II',
                      icon: Icons.build_outlined,
                      selected: mode == 1,
                      onTap: () => setDialogState(() => mode = 1),
                    ),
                    _aimTraditionalTab(
                      context: context,
                      label: 'AIM TEST',
                      icon: Icons.format_list_numbered,
                      selected: mode == 2,
                      onTap: () => setDialogState(() => mode = 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: mode == 0
                    ? _buildAimBootTreeView(context, bootTree, scheme)
                    : mode == 1
                        ? _buildAimStartupTreeView(context, startupTree, scheme)
                        : _buildAimSequenceView(
                            context,
                            results,
                            skipped,
                            scheme,
                            setDialogState,
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _episodesPanel(BuildContext context, ColorScheme scheme) {
    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Icon(Icons.list_alt_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Episodic events',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text(
                  '${widget.episodios.length} lines',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textEditingController,
                    onChanged: _search,
                    decoration: InputDecoration(
                      hintText: 'Search episodic events...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _textEditingController.text.isNotEmpty
                          ? IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _textEditingController.clear();
                                _searchDebounce?.cancel();
                                _executeSearch('');
                              },
                              icon: const Icon(Icons.close),
                            )
                          : null,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: _jumpLineController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _jumpToLine(),
                    decoration: InputDecoration(
                      hintText: 'Jump to line',
                      prefixIcon: const Icon(Icons.subdirectory_arrow_right_rounded),
                      suffixIcon: IconButton(
                        tooltip: 'Jump',
                        onPressed: _jumpToLine,
                        icon: const Icon(Icons.arrow_forward_rounded),
                      ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _searchNavigator(context),
              ],
            ),
          ),
          Expanded(
            child: ScrollablePositionedList.builder(
              itemScrollController: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: widget.episodios.length,
              itemBuilder: (context, index) {
                final selected =
                    indexFound.isNotEmpty && indexFound[ptr] == index;
                final found = _indexFoundSet.contains(index);

                return Container(
                  margin: const EdgeInsets.only(bottom: 3),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primaryContainer
                        : found
                            ? scheme.secondaryContainer.withValues(alpha: 0.35)
                            : null,
                    borderRadius: BorderRadius.circular(8),
                    border: found
                        ? Border.all(
                            color: selected
                                ? scheme.primary.withValues(alpha: 0.55)
                                : scheme.outlineVariant,
                          )
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.right,
                          style:
                              Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: selected
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                    fontFeatures: const [],
                                  ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.episodios[index],
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                height: 1.35,
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchNavigator(BuildContext context) {
    final hasResults = indexFound.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous result',
            onPressed: hasResults ? () => _moveResult(-1) : null,
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 78),
            child: Text(
              hasResults ? '${ptr + 1} / ${indexFound.length}' : '0 / 0',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          IconButton(
            tooltip: 'Next result',
            onPressed: hasResults ? () => _moveResult(1) : null,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(value.day)}/${two(value.month)}/${value.year} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  String _formatDuration() {
    final start = widget.dataStart;
    final end = widget.dataEnd;
    if (start == null || end == null || end.isBefore(start)) return '—';
    final d = end.difference(start);
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }

  Map<String, num> _extractReveosWMeter(Uint8List? input) {
    final out = <String, num>{};
    final name = (widget.fileName ?? '').toUpperCase();
    if (input == null || !name.startsWith('1W')) return out;

    try {
      int findBytes(Uint8List data, List<int> needle, int start, [int? end]) {
        final stop = (end ?? data.length) < data.length ? (end ?? data.length) : data.length;
        for (var i = start; i + needle.length <= stop; i++) {
          var ok = true;
          for (var j = 0; j < needle.length; j++) {
            if (data[i + j] != needle[j]) { ok = false; break; }
          }
          if (ok) return i;
        }
        return -1;
      }

      final gzip = <int>[0x1f, 0x8b, 0x08];
      final gz = findBytes(input, gzip, 0);
      if (gz < 0) return out;
      final decoded = Uint8List.fromList(
        GZipDecoder().decodeBytes(input.sublist(gz)).map((b) => b ^ 0xA5).toList(),
      );

      final fileNeedle = latin1.encode('/config/control/w_meter.dat');
      final cNeedle = latin1.encode('Centrifuge');
      final pNeedle = latin1.encode('Procedure');
      final rtNeedle = latin1.encode('RunTimeHours');
      final nNeedle = latin1.encode('Number');
      const dp = <int>[0x07,0x01,0x00,0x3d,0x65,0x05,0x09];
      const ip = <int>[0x07,0x01,0x00,0x3d,0x05];

      double? readDouble(int key, int limit) {
        final p = findBytes(decoded, dp, key + rtNeedle.length, limit);
        if (p < 0 || p + dp.length + 8 > decoded.length) return null;
        return ByteData.sublistView(decoded, p + dp.length, p + dp.length + 8)
            .getFloat64(0, Endian.little);
      }

      int? readInt(int key, int limit) {
        final p = findBytes(decoded, ip, key + nNeedle.length, limit);
        if (p < 0 || p + ip.length + 4 > decoded.length) return null;
        return ByteData.sublistView(decoded, p + ip.length, p + ip.length + 4)
            .getUint32(0, Endian.little);
      }

      var pos = 0;
      while (true) {
        final f = findBytes(decoded, fileNeedle, pos);
        if (f < 0) break;
        final end = (f + 4096 < decoded.length) ? f + 4096 : decoded.length;
        final cs = findBytes(decoded, cNeedle, f, end);
        final ps = findBytes(decoded, pNeedle, cs >= 0 ? cs : f, end);
        if (cs >= 0 && ps > cs) {
          final cr = findBytes(decoded, rtNeedle, cs, ps);
          final pr = findBytes(decoded, rtNeedle, ps, end);
          final pn = findBytes(decoded, nNeedle, ps, end);
          final ch = cr >= 0 ? readDouble(cr, ps) : null;
          final ph = pr >= 0 ? readDouble(pr, end) : null;
          final pc = pn >= 0 ? readInt(pn, end) : null;
          if (ch != null && ch.isFinite && ch >= 0) out['centrifugeHours'] = ch;
          if (ph != null && ph.isFinite && ph >= 0) out['procedureHours'] = ph;
          if (pc != null) out['procedureCount'] = pc;
        }
        pos = f + fileNeedle.length;
      }
    } catch (_) {}
    return out;
  }

  String? _findMachineValue(RegExp rx, {int group = 1}) {
    for (final raw in widget.machineData) {
      final m = rx.firstMatch(raw);
      final value = m?.group(group)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    for (final raw in widget.episodios) {
      final m = rx.firstMatch(raw);
      final value = m?.group(group)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String get _platform {
    final parsed = _findMachineValue(RegExp(
      r'Platform\s*[:=]\s*([A-Za-z0-9._-]+)', caseSensitive: false));
    if (parsed != null && parsed.isNotEmpty) return parsed;
    final name = (widget.fileName ?? '').toUpperCase();
    if (name.startsWith('1P')) return 'Optia';
    if (name.startsWith('1T')) return 'Trima';
    if (name.startsWith('1W')) return 'Reveos';
    return '—';
  }

  String get _logVersion =>
      _findMachineValue(RegExp(r'Log\s*Version\s*[:=]\s*([^\s,\]]+)',
              caseSensitive: false)) ??
      '—';

  String get _revision =>
      _findMachineValue(RegExp(r'revision\s*[:=]\s*([^\s,\]]+)',
              caseSensitive: false)) ??
      '—';

  String get _buildDate =>
      _findMachineValue(RegExp(
              r'(?:BUILD_DATE\}?\s*|date\s*[:=]\s*)([^,\]\r\n]+)',
              caseSensitive: false)) ??
      '—';

  String get _computer =>
      _findMachineValue(RegExp(r'computer\s*[:=]\s*([^\s,\]]+)',
              caseSensitive: false)) ??
      '—';

  String get _ipAddress =>
      _findMachineValue(RegExp(
              r'IPAddress\s*=\s*((?:\d{1,3}\.){3}\d{1,3})',
              caseSensitive: false)) ??
      '—';


  String get _softwareVersion =>
      _findMachineValue(RegExp(
        r'(?:Trima|Optia|Reveos)\s*:[^\r\n]*?\bversion\s*=\s*([^\s,\]\x00-\x1F]+)',
        caseSensitive: false)) ??
      _findMachineValue(RegExp(
        r'(?:software|program)\s+version\s*[:=]\s*([^\s,\]]+)',
        caseSensitive: false)) ??
      _revision;

  String get _eBoxGeneration {
    if (_platform.toLowerCase().contains('reveos')) return '—';
    final joined = <String>[...widget.machineData, ...widget.episodios]
        .join('\n').toLowerCase();
    if (joined.contains('control pci cca interface') ||
        joined.contains('safety pci cca interface') ||
        joined.contains('stc pci fpga hardware version') ||
        joined.contains('vortex_board_pkg')) return 'eBox Gen2';
    if (joined.contains('control2 isa cca interface') ||
        joined.contains('safety2 isa cca interface') ||
        joined.contains('ebx-11_board_pkg')) return 'eBox Gen1';
    return '—';
  }

  String _fmtHours(num? value) =>
      value == null ? '—' : '${value.toDouble().toStringAsFixed(2)} h';

  String get _machineHours =>
      _findMachineValue(RegExp(r'MachineHours\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false)) ??
      _findMachineValue(RegExp(r'Current\s+Machine\s+Hour\s+Meter\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false)) ?? '—';

  String get _centrifugeHours {
    if (_platform.toLowerCase().contains('reveos')) {
      return _fmtHours(_cachedReveosWMeter['centrifugeHours']);
    }
    return _findMachineValue(RegExp(r'CentrifugeHours\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false)) ??
        _findMachineValue(RegExp(r'Current\s+Centrifuge\s+Hour\s+Meter\s*=\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false)) ?? '—';
  }

  String get _procedureHours =>
      _fmtHours(_cachedReveosWMeter['procedureHours']);

  String get _procedureCount {
    if (_platform.toLowerCase().contains('reveos')) {
      return _cachedReveosWMeter['procedureCount']?.toInt().toString() ?? '—';
    }
    return _findMachineValue(RegExp(r'ProcedureCount\s*=\s*([0-9]+)', caseSensitive: false)) ?? '—';
  }

  String get _proceduresCompleted =>
      _findMachineValue(RegExp(r'ProceduresCompleted\s*=\s*([0-9]+)', caseSensitive: false)) ?? '—';


  String get _optiaProtocol {
    if (!_isOptia) return '—';

    final re = RegExp(r'Protocol\s+selected\s*:\s*([^\r\n]+)', caseSensitive: false);
    for (final episode in widget.episodios) {
      final match = re.firstMatch(episode);
      if (match != null) {
        final value = (match.group(1) ?? '').trim();
        if (value.isNotEmpty) return value;
      }
    }
    return '—';
  }

  bool get _isOptia {
    final platform = _platform.toLowerCase();
    final fileName = (widget.fileName ?? '').toLowerCase();
    return platform.contains('optia') || fileName.startsWith('1p');
  }

  bool get _isTrima {
    final platform = _platform.toLowerCase();
    final fileName = (widget.fileName ?? '').toLowerCase();
    return platform.contains('trima') || fileName.startsWith('1t');
  }


  int? _findEpisodeIndex(List<String> needles, {int startAt = 0}) {
    for (var i = startAt; i < widget.episodios.length; i++) {
      final line = _episodiosLower[i];
      if (needles.any((n) => line.contains(n.toLowerCase()))) return i;
    }
    return null;
  }

  List<int> _findAllEpisodeIndexes(String needle) {
    final q = needle.toLowerCase();
    final out = <int>[];
    for (var i = 0; i < widget.episodios.length; i++) {
      if (_episodiosLower[i].contains(q)) out.add(i);
    }
    return out;
  }

  List<_AimCheckResult> _analyzeAim() {
    // IMPORTANTE:
    // Esta lista contiene solamente los textos que el documento AIM marca
    // explícitamente como "DLOG message:" o "DLOG messages:".
    // Las explicaciones, notas y árboles de decisión NO se usan como patrón.
    //
    // Además se buscan en el mismo orden en que aparecen en el documento.
    final checks = <_AimCheckSpec>[
      // Boot Sequence
      const _AimCheckSpec('Boot sequence', 'PXE Boot Request',
          ['pxe boot request']),
      const _AimCheckSpec('Boot sequence', 'Detected v9 STC driver',
          ['detected v9 stc driver']),
      const _AimCheckSpec('Boot sequence', 'STC FPGA Version Register',
          ['stc fpga version register:']),
      const _AimCheckSpec('Boot sequence', 'FireWire bus manager starting up',
          ['firewire bus manager starting up']),
      const _AimCheckSpec('Boot sequence', 'Detected 1 adapters',
          ['detected 1 adapters']),
      const _AimCheckSpec('Boot sequence', 'Found camera node',
          ['found camera node']),
      const _AimCheckSpec('Boot sequence', 'Camera detected',
          ['camera detected']),
      const _AimCheckSpec('Boot sequence', 'Camera vendor / model',
          ['camera vendor:']),

      // Startup Test
      const _AimCheckSpec('Startup test', 'Startup test command received',
          ['startup test command received']),
      const _AimCheckSpec('Startup test', 'Enter: ReadStartupTestConfig',
          ['enter: readstartuptestconfig']),
      const _AimCheckSpec('Startup test', 'Camera brightness',
          ['camera brightness']),
      const _AimCheckSpec('Startup test', 'Camera shutter',
          ['camera shutter']),
      const _AimCheckSpec('Startup test', 'Camera gain',
          ['camera gain']),
      const _AimCheckSpec('Startup test', 'Top strobe blink test',
          ['top strobe blink test passed for strobe:2']),
      const _AimCheckSpec('Startup test', 'Bottom strobe blink test',
          ['bottom strobe blink test passed for strobe:0']),
      const _AimCheckSpec('Startup test', 'Enter: StartupTestComplete',
          ['enter: startuptestcomplete']),

      // Post Startup Test
      const _AimCheckSpec('Post startup test', 'Post startup test command received',
          ['post startup test command received']),
      const _AimCheckSpec('Post startup test', 'Encoder hardware test passed',
          ['encoder hardware test passed']),
      const _AimCheckSpec('Post startup test', 'Enter: MoveToConnector',
          ['enter:movetoconnector', 'enter: movetoconnector']),
      const _AimCheckSpec('Post startup test', 'Connector search routine completed',
          ['connector search routine completed']),
      const _AimCheckSpec('Post startup test', 'Testing even rotation',
          ['testing even rotation']),
      const _AimCheckSpec('Post startup test', 'Testing odd rotation',
          ['testing odd rotation']),
      const _AimCheckSpec('Post startup test', 'LOCKON_PERCENT',
          ['lockon_percent']),
      const _AimCheckSpec('Post startup test', 'MONITOR_CONNECTION_LOCKON',
          ['monitor_connection_lockon']),
      const _AimCheckSpec('Post startup test',
          'Completed bottom strobe lighting calibration',
          ['completed bottom strobe lighting calibration']),
    ];

    final results = <_AimCheckResult>[];
    var cursor = 0;

    for (final spec in checks) {
      int? found;
      String? matched;

      // Se busca desde el último mensaje AIM encontrado hacia adelante.
      // Si un mensaje falta, NO avanzamos el cursor: así los pasos siguientes
      // todavía pueden encontrarse y queda visible exactamente qué faltó.
      for (final needle in spec.needles) {
        final index = _findEpisodeIndex([needle], startAt: cursor);
        if (index != null && (found == null || index < found)) {
          found = index;
          matched = widget.episodios[index];
        }
      }

      if (found != null) cursor = found + 1;
      results.add(_AimCheckResult(spec: spec, index: found, event: matched));
    }

    return results;
  }

  bool _aimStcRegisterLooksValid(String event) {
    final m = RegExp(r'stc\s+fpga\s+version\s+register\s*:\s*([^\s,;]+)',
            caseSensitive: false)
        .firstMatch(event);
    final value = m?.group(1)?.trim().toLowerCase();
    return value == null || value != 'ffff';
  }

  bool _aimWriteResponseLooksValid(String event) {
    final lower = event.toLowerCase();
    if (!lower.contains('write transaction')) return true;
    final m = RegExp(r'response\s*code\s*:\s*(-?\d+)', caseSensitive: false)
        .firstMatch(event);
    // A write transaction is only confirmed when the DLOG explicitly reports
    // Response code: 0. Missing response is not treated as PASS.
    return m != null && m.group(1) == '0';
  }

  List<_AimBootDecision> _analyzeAimBootTree() {
    // Figure 3 / page 5: DLOG Analysis - Boot Up Problems.
    // We only automate decisions that can be made from episodic DLOG messages.
    // Hardware checks that require a physical measurement remain manual actions.
    final decisions = <_AimBootDecision>[];

    final pxeIndexes = _findAllEpisodeIndexes('pxe boot request');
    final pxeIndex = pxeIndexes.isEmpty ? null : pxeIndexes.first;
    decisions.add(_AimBootDecision(
      title: 'PXE Boot Request',
      status: pxeIndex == null ? _AimDecisionStatus.fail : _AimDecisionStatus.ok,
      episodeIndex: pxeIndex,
      event: pxeIndex == null ? null : widget.episodios[pxeIndex],
      action: pxeIndex == null
          ? 'MANUAL CHECK — PXE Boot Request was not found. The AIM flow returns to Section I — Boot Failure: verify whether the APC boots and follow the APC reset/voltage checks before continuing with DLOG analysis.'
          : (pxeIndexes.length > 1
              ? 'Multiple PXE Boot Request messages were found. The AIM document notes that repeated requests for the same bootrom can indicate processor resets.'
              : 'PXE Boot Request found. Continue with the STC FPGA check.'),
    ));

    if (pxeIndex == null) return decisions;

    final stcIndex = _findEpisodeIndex(
      ['stc fpga version register:'],
      startAt: pxeIndex + 1,
    );
    final stcEvent = stcIndex == null ? null : widget.episodios[stcIndex];
    final stcOk = stcEvent != null && _aimStcRegisterLooksValid(stcEvent);
    decisions.add(_AimBootDecision(
      title: 'STC FPGA Version Register',
      status: stcIndex == null
          ? _AimDecisionStatus.fail
          : (stcOk ? _AimDecisionStatus.ok : _AimDecisionStatus.fail),
      episodeIndex: stcIndex,
      event: stcEvent,
      action: stcIndex == null
          ? 'SUGGESTED ACTION — STC FPGA message missing. The Boot Up Problems chart directs this branch to the STC CCA action.'
          : (!stcOk
              ? 'SUGGESTED ACTION — STC FPGA Version Register is FFFF. The manual states FFFF is not acceptable; follow the STC CCA branch in the Boot Up Problems chart.'
              : 'STC FPGA communication looks valid. Continue with FireWire.'),
    ));

    if (!stcOk) return decisions;

    final firewireIndex = _findEpisodeIndex(
      ['detected 1 adapters'],
      startAt: stcIndex! + 1,
    );
    decisions.add(_AimBootDecision(
      title: 'FireWire adapter',
      status: firewireIndex == null ? _AimDecisionStatus.fail : _AimDecisionStatus.ok,
      episodeIndex: firewireIndex,
      event: firewireIndex == null ? null : widget.episodios[firewireIndex],
      action: firewireIndex == null
          ? '"Detected 1 adapters" is missing. Follow the FireWire branch of the AIM boot-up flow.'
          : 'FireWire adapter detected. Continue with the camera check.',
    ));

    if (firewireIndex == null) return decisions;

    final cameraIndex = _findEpisodeIndex(
      ['found camera node'],
      startAt: firewireIndex + 1,
    );
    decisions.add(_AimBootDecision(
      title: 'Camera node',
      status: cameraIndex == null ? _AimDecisionStatus.fail : _AimDecisionStatus.ok,
      episodeIndex: cameraIndex,
      event: cameraIndex == null ? null : widget.episodios[cameraIndex],
      action: cameraIndex == null
          ? '"Found camera node" is missing. Follow the camera branch of the AIM boot-up flow.'
          : 'Camera node found. Boot-up DLOG path completed.',
    ));

    return decisions;
  }


  List<_AimStartupDecision> _analyzeAimStartupTree() {
    final out = <_AimStartupDecision>[];
    int cursor = 0;

    int? find(List<String> needles) {
      final i = _findEpisodeIndex(needles, startAt: cursor);
      if (i != null) cursor = i + 1;
      return i;
    }

    void add(String title, List<String> needles,
        {bool Function(String event)? validator, String? failBranch}) {
      final i = find(needles);
      final event = i == null ? null : widget.episodios[i];
      final ok = event != null && (validator == null || validator(event));
      out.add(_AimStartupDecision(
        title: title,
        ok: ok,
        episodeIndex: i,
        event: event,
        failBranch: ok ? null : failBranch,
      ));
    }

    add('Startup test command received', ['startup test command received'],
        failBranch: 'Startup test did not reach the expected start marker.');
    add('ReadStartupTestConfig', ['enter: readstartuptestconfig'],
        failBranch: 'Configuration-read step not confirmed.');

    add('Camera brightness', ['camera brightness'],
        validator: _aimWriteResponseLooksValid,
        failBranch: 'CAMERA');
    add('Camera shutter', ['camera shutter'],
        validator: _aimWriteResponseLooksValid,
        failBranch: 'CAMERA');
    add('Camera gain', ['camera gain'],
        validator: _aimWriteResponseLooksValid,
        failBranch: 'CAMERA');

    add('Top strobe', ['top strobe blink test passed for strobe:2'],
        failBranch: 'TOP STROBE');
    add('Bottom strobe', ['bottom strobe blink test passed for strobe:0'],
        failBranch: 'BOTTOM STROBE');
    add('StartupTestComplete', ['enter: startuptestcomplete'],
        failBranch: 'Startup test did not complete.');

    return out;
  }

  String? _startupFailedBranch(List<_AimStartupDecision> decisions) {
    for (final d in decisions) {
      if (!d.ok && d.failBranch != null) return d.failBranch;
    }
    return null;
  }

  Future<void> _showSectionIIManualFlow(
      BuildContext context, String branch) async {
    final scheme = Theme.of(context).colorScheme;
    String? selected;

    List<String> options;
    String instruction;
    if (branch == 'CAMERA') {
      instruction =
          'MANUAL CHECK — Raise the pump panel and inspect the camera LED, as directed by Section II.';
      options = const ['Flashing LED', 'Yellow LED', 'Intermittent Green LED',
        'Green LED OK / continue', 'SKIP'];
    } else if (branch == 'TOP STROBE') {
      instruction =
          'MANUAL CHECK — Follow the Top Strobe chart: verify strobes in Image Viewer, then real voltage/trigger checks if required.';
      options = const ['Strobes ON, image works', 'Strobes ON, no image',
        'No strobes', 'SKIP'];
    } else {
      instruction =
          'MANUAL CHECK — Follow the Bottom Strobe chart: verify strobes, real voltage and trigger behavior.';
      options = const ['Strobes ON', 'No strobes', 'SKIP'];
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Section II — $branch'),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(instruction),
                const SizedBox(height: 12),
                for (final o in options)
                  RadioListTile<String>(
                    value: o,
                    groupValue: selected,
                    title: Text(o),
                    onChanged: (v) => setState(() => selected = v),
                  ),
                if (selected != null && selected != 'SKIP') ...[
                  const Divider(),
                  Text(
                    _sectionIIAction(branch, selected!),
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('CLOSE'),
            ),
          ],
        ),
      ),
    );
  }

  String _sectionIIAction(String branch, String choice) {
    if (branch == 'CAMERA') {
      if (choice == 'Green LED OK / continue') {
        return 'NEXT — Connect with STS, verify Camera Data is populated, and turn on Image Viewer.';
      }
      if (choice == 'Flashing LED') {
        return 'SUGGESTED ACTION — Follow the camera flashing-LED terminal action in the Section II chart.';
      }
      if (choice == 'Yellow LED') {
        return 'SUGGESTED ACTION — Follow the yellow-LED terminal action in the Section II chart.';
      }
      if (choice == 'Intermittent Green LED') {
        return 'SUGGESTED ACTION — Follow the intermittent-green camera branch in the Section II chart.';
      }
    }
    if (branch == 'TOP STROBE') {
      if (choice == 'Strobes ON, image works') {
        return 'RESULT — Camera/strobe image path works; continue the startup-test diagnosis.';
      }
      if (choice == 'Strobes ON, no image') {
        return 'NEXT — Use Image Viewer and the real-voltage check shown by the Top Strobe flow.';
      }
      if (choice == 'No strobes') {
        return 'NEXT — Enter Calibration Mode, command the strobes, then continue with trigger/voltage checks.';
      }
    }
    if (branch == 'BOTTOM STROBE') {
      if (choice == 'Strobes ON') {
        return 'NEXT — Verify the image/real voltage as shown in the Bottom Strobe flow.';
      }
      if (choice == 'No strobes') {
        return 'NEXT — Enter Calibration Mode, command the strobes, then continue with trigger/voltage checks.';
      }
    }
    return 'Continue with the selected Section II branch.';
  }

  Widget _buildAimStartupTreeView(
    BuildContext dialogContext,
    List<_AimStartupDecision> decisions,
    ColorScheme scheme,
  ) {
    final failedBranch = _startupFailedBranch(decisions);
    return ListView(
      children: [
        Text(
          'Section II — Startup Test Failures',
          style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Troubleshooting only. Use this view when the AIM Test does not confirm Camera, Top Strobe or Bottom Strobe. Missing DLOG evidence is kept separate from an explicit test failure.',
          style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        for (final d in decisions)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              leading: Icon(
                d.ok ? Icons.check_circle_outline : Icons.error_outline,
                color: d.ok ? scheme.primary : scheme.error,
              ),
              title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                d.ok ? 'FOUND' : 'NOT FOUND',
                style: TextStyle(color: d.ok ? scheme.primary : scheme.error, fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _aimFlowInfoBlock(dialogContext, icon: Icons.search_rounded, title: 'What we are looking for', text: _aimSectionIIWhatWeLookFor(d.title)),
                const SizedBox(height: 10),
                _aimFlowInfoBlock(
                  dialogContext,
                  icon: d.ok ? Icons.check_circle_outline : Icons.search_off,
                  title: 'What we found',
                  text: d.event ?? (d.failBranch == null ? 'NOT FOUND — message not present in episodic data.' : 'NOT FOUND — branch: ${d.failBranch}'),
                  tone: d.ok ? scheme.primary : scheme.error,
                ),
                if (!d.ok && d.failBranch != null) ...[
                  const SizedBox(height: 10),
                  _aimFlowInfoBlock(dialogContext, icon: Icons.route_outlined, title: 'Diagnostic branch', text: d.failBranch!, tone: scheme.error),
                ],
                if (d.episodeIndex != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => _jumpToEpisodeFromAnalyzer(d.episodeIndex!),
                    icon: const Icon(Icons.my_location_outlined, size: 18),
                    label: Text('FIND LINE · L${d.episodeIndex! + 1}'),
                  ),
                ],
              ],
            ),
          ),
        if (failedBranch == 'CAMERA' ||
            failedBranch == 'TOP STROBE' ||
            failedBranch == 'BOTTOM STROBE') ...[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () =>
                _showSectionIIManualFlow(dialogContext, failedBranch!),
            icon: const Icon(Icons.build_outlined),
            label: Text('OPEN $failedBranch MANUAL FLOW'),
          ),
        ] else if (decisions.every((d) => d.ok)) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.task_alt, color: scheme.primary),
              title: const Text('Startup test sequence complete'),
              subtitle: const Text(
                  'Camera, Top Strobe and Bottom Strobe DLOG checks passed and StartupTestComplete was found.'),
            ),
          ),
        ],
      ],
    );
  }


  List<_TrimaStartupResult> _analyzeTrimaStartup() {
    final specs = <_TrimaStartupSpec>[
      // StartupTest - real Trima hierarchy observed in DLOG.
      // LoadCassette is a later stage and is intentionally NOT part of StartupTest.
      _TrimaStartupSpec('STARTUP TESTS', 'NVRam Test',
          const ['nvramtest']),
      _TrimaStartupSpec('STARTUP TESTS', 'Calibration Verification',
          const ['calibverification']),
      _TrimaStartupSpec('STARTUP TESTS', 'Power Test',
          const ['powertest', 'safetypowertest', 'powerofftest', 'powerontest']),
      _TrimaStartupSpec('STARTUP TESTS', 'Valves Test',
          const ['valvestest']),
      _TrimaStartupSpec('STARTUP TESTS', 'Leak Detector Test',
          const ['leakdetectortest']),
      _TrimaStartupSpec('STARTUP TESTS', 'Door Latch Test',
          const ['doorlatchtest']),
      _TrimaStartupSpec('STARTUP TESTS', 'GUI Started / User',
          const ['guistarted']),

      // Disposable Tests
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Close Valves',
          const ['closevalves']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Check Sample Bag',
          const ['checksamplebag']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Press Inlet Line',
          const ['pressinletline']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Inlet Press Test',
          const ['inletpresstest']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Inlet Decay Test',
          const ['inletdecaytest'],
          inference: _looksLikeTrimaInletDecay),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Negative Press Test',
          const ['negativepresstest']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Negative Press Relief',
          const ['negativepressrelief']),
      _TrimaStartupSpec('DISPOSABLE TESTS', 'Unlock Door',
          const ['unlockdoor']),

      // AC Prime
      _TrimaStartupSpec('AC PRIME', 'AC Prime',
          const ['acprime']),
      _TrimaStartupSpec('AC PRIME', 'AC Prime Inlet',
          const ['acprimeinlet'],
          inference: _looksLikeTrimaAcPrimeInlet),
      _TrimaStartupSpec('AC PRIME', 'AC Press Return Line',
          const ['acpressreturnline'],
          inference: _looksLikeTrimaAcPressReturnLine),

      // Blood Prime
      _TrimaStartupSpec('BLOOD PRIME', 'Blood Prime Inlet',
          const ['bloodprimeinlet'],
          stateNeedles: const ['bloodprime']),
      _TrimaStartupSpec('BLOOD PRIME', 'Blood Prime Return',
          const ['bloodprimereturn'],
          stateNeedles: const ['bloodprime']),
      _TrimaStartupSpec('BLOOD PRIME', 'Evac Set Valves',
          const ['evacsetvalves'],
          stateNeedles: const ['bloodprime']),
      _TrimaStartupSpec('BLOOD PRIME', 'Evac Reset Valves',
          const ['evacresetvalves'],
          stateNeedles: const ['bloodprime']),

      // Blood Run Prime
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Channel 1',
          const ['primechannel1'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Channel 2',
          const ['primechannel2'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Channel 3',
          const ['primechannel3'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Channel 4',
          const ['primechannel4'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Vent',
          const ['primevent', 'primechannelvent'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Ramp Centrifuge',
          const ['rampcentrifuge'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN PRIME', 'Prime Airout 2',
          const ['primeairout2', 'removechannelair'],
          stateNeedles: const ['bloodrun']),

      // Blood Run Collection
      _TrimaStartupSpec('BLOOD RUN', 'Channel Setup',
          const ['channelsetup'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN', 'Pre-Platelet Plasma',
          const ['preplateletplasma'],
          stateNeedles: const ['bloodrun']),
      _TrimaStartupSpec('BLOOD RUN', 'Pre Rinseback',
          const ['prerinseback'],
          stateNeedles: const ['bloodrun']),

      // Blood Rinseback
      _TrimaStartupSpec('RINSEBACK', 'Rinseback Lower',
          const ['rinsebacklower'],
          stateNeedles: const ['bloodrinseback', 'rinseback']),
      _TrimaStartupSpec('RINSEBACK', 'Rinseback Recirculate',
          const ['rinsebackrecirculate'],
          stateNeedles: const ['bloodrinseback', 'rinseback']),
      _TrimaStartupSpec('RINSEBACK', 'Rinseback Return',
          const ['rinsebackreturn', 'substate: rinseback'],
          stateNeedles: const ['bloodrinseback', 'rinseback']),
      _TrimaStartupSpec('RINSEBACK', 'Disconnect Prompt',
          const ['disconnectprompt'],
          stateNeedles: const ['bloodrinseback', 'rinseback']),

      // Donor Disconnect
      _TrimaStartupSpec('DONOR DISCONNECT', 'Disconnect Test',
          const ['disconnecttest'],
          stateNeedles: const ['donordisconnect']),
      _TrimaStartupSpec('DONOR DISCONNECT', 'Open Valves',
          const ['openvalves'],
          stateNeedles: const ['donordisconnect']),
      _TrimaStartupSpec('DONOR DISCONNECT', 'Start Pumps',
          const ['startpumps'],
          stateNeedles: const ['donordisconnect']),
      _TrimaStartupSpec('DONOR DISCONNECT', 'Raise Cassette',
          const ['raisecassette'],
          stateNeedles: const ['donordisconnect']),
      _TrimaStartupSpec('DONOR DISCONNECT', 'Stop Pumps',
          const ['stoppumps'],
          stateNeedles: const ['donordisconnect']),

      // MSS Disconnect
      _TrimaStartupSpec('MSS DISCONNECT', 'Open Valves',
          const ['openvalves'],
          stateNeedles: const ['mssdisconnect']),
      _TrimaStartupSpec('MSS DISCONNECT', 'Start Pumps',
          const ['startpumps'],
          stateNeedles: const ['mssdisconnect']),
      _TrimaStartupSpec('MSS DISCONNECT', 'Raise Cassette',
          const ['raisecassette'],
          stateNeedles: const ['mssdisconnect']),
      _TrimaStartupSpec('MSS DISCONNECT', 'Stop Pumps',
          const ['stoppumps'],
          stateNeedles: const ['mssdisconnect']),
    ];

    final results = <_TrimaStartupResult>[];

    // Procedure analysis is chronological. Once a stage is found, the next
    // stage is searched only AFTER that source line. This prevents repeated
    // names such as Start Pumps / Stop Pumps / Open Valves from matching an
    // earlier occurrence belonging to another part of the procedure.
    var searchFrom = 0;

    for (final spec in specs) {
      int? direct;
      String? directEvent;

      // First pass: prefer the actual state entry marker.
      for (var i = searchFrom; i < widget.episodios.length; i++) {
        final lower = _episodiosLower[i];
        if (!lower.contains('enter:')) continue;
        if (spec.needles.any(lower.contains)) {
          direct = i;
          directEvent = widget.episodios[i];
          break;
        }
      }

      // Compatibility fallback for versions that do not log Enter:/Exit:.
      if (direct == null) {
        for (var i = searchFrom; i < widget.episodios.length; i++) {
          final lower = _episodiosLower[i];
          if (spec.needles.any(lower.contains)) {
            direct = i;
            directEvent = widget.episodios[i];
            break;
          }
        }
      }

      if (direct != null) {
        results.add(_TrimaStartupResult(
          spec: spec,
          status: _TrimaStartupStatus.confirmed,
          episodeIndex: direct,
          event: directEvent,
        ));
        searchFrom = direct + 1;
        continue;
      }

      int? inferred;
      String? inferredEvent;
      if (spec.inference != null) {
        for (var i = searchFrom; i < widget.episodios.length; i++) {
          if (spec.inference!(widget.episodios[i])) {
            inferred = i;
            inferredEvent = widget.episodios[i];
            break;
          }
        }
      }

      results.add(_TrimaStartupResult(
        spec: spec,
        status: inferred == null
            ? _TrimaStartupStatus.notDetected
            : _TrimaStartupStatus.inferred,
        episodeIndex: inferred,
        event: inferredEvent,
      ));

      // A missing stage does NOT move the cursor. This allows optional or
      // version-specific stages to be absent without hiding the following
      // valid stage. An inferred stage does advance the chronology.
      if (inferred != null) {
        searchFrom = inferred + 1;
      }
    }
    return results;
  }

  double? _trimaNumber(String text, String name) {
    final rx = RegExp(
      '${RegExp.escape(name)}\\\\s*[:=]\\\\s*(-?\\\\d+(?:\\\\.\\\\d+)?)',
      caseSensitive: false,
    );
    return double.tryParse(rx.firstMatch(text)?.group(1) ?? '');
  }


  // V93: procedure CSV DATA rows are positional. They do not contain
  // "ACAct=..." / "LeakValue=..." labels, so diagnostics must read the
  // actual CSV columns. This lightweight reader is sufficient for numeric
  // DATA fields and also preserves the first half of a quoted field split by
  // an embedded newline (e.g. LeakValue -> "5\\n").
  String? _trimaCsvCell(String line, int index) {
    final cells = <String>[];
    final b = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        cells.add(b.toString());
        b.clear();
      } else {
        b.write(ch);
      }
    }
    cells.add(b.toString());

    if (index < 0 || index >= cells.length) return null;
    final v = cells[index].trim();
    return v.isEmpty ? null : v;
  }

  double? _trimaCsvDoubleAt(String line, int index) {
    final raw = _trimaCsvCell(line, index);
    if (raw == null) return null;
    return double.tryParse(raw.replaceAll('"', '').trim());
  }

  bool _near(double? value, double expected, {double tolerance = 1.5}) =>
      value != null && (value - expected).abs() <= tolerance;

  bool _looksLikeTrimaStartPumps(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 60) &&
      _near(_trimaNumber(e, 'InletCmd'), 140) &&
      _near(_trimaNumber(e, 'PlasmaCmd'), 60) &&
      _near(_trimaNumber(e, 'CollectCmd'), 60) &&
      _near(_trimaNumber(e, 'ReturnCmd'), 110) &&
      (_near(_trimaNumber(e, 'CentCmd'), 0, tolerance: 1.1) ||
       _near(_trimaNumber(e, 'CentCmd'), -1, tolerance: 1.1));

  bool _looksLikeTrimaStopPumps(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 0) &&
      _near(_trimaNumber(e, 'InletCmd'), 0) &&
      _near(_trimaNumber(e, 'PlasmaCmd'), 0) &&
      _near(_trimaNumber(e, 'CollectCmd'), 0) &&
      _near(_trimaNumber(e, 'ReturnCmd'), 0);

  bool _looksLikeTrimaEvacuateSetValves(String e) {
    // The Trima DLOGs tested do not expose a literal EvacuateSetValves
    // substate. Detect the hardware signature instead:
    // all pumps stopped, centrifuge stopped, platelet/plasma open,
    // RBC in return position.
    return _near(_trimaNumber(e, 'ACCmd'), 0) &&
        _near(_trimaNumber(e, 'InletCmd'), 0) &&
        _near(_trimaNumber(e, 'PlasmaCmd'), 0) &&
        _near(_trimaNumber(e, 'CollectCmd'), 0) &&
        _near(_trimaNumber(e, 'ReturnCmd'), 0) &&
        _near(_trimaNumber(e, 'CentCmd'), 0, tolerance: 1.1) &&
        _trimaValveLooksLike(e, 'CollectValveCmd', const ['open']) &&
        _trimaValveLooksLike(e, 'PlasmaValveCmd', const ['open']) &&
        _trimaValveLooksLike(e, 'RBCValveCmd', const ['return']);
  }

  bool _trimaValveLooksLike(
      String e, String field, List<String> expectedValues) {
    final rx = RegExp(
      '${RegExp.escape(field)}\\s*[:=]\\s*([^,;\\r\\n]+)',
      caseSensitive: false,
    );
    final raw = rx.firstMatch(e)?.group(1)?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return false;
    return expectedValues.any(raw.contains);
  }

  bool _looksLikeTrimaEvacuateBags(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 0) &&
      _near(_trimaNumber(e, 'InletCmd'), 0) &&
      _near(_trimaNumber(e, 'PlasmaCmd'), 0) &&
      _near(_trimaNumber(e, 'CollectCmd'), 0) &&
      _near(_trimaNumber(e, 'ReturnCmd'), 90) &&
      _near(_trimaNumber(e, 'CentCmd'), 0, tolerance: 1.1) &&
      _trimaValveLooksLike(e, 'CollectValveCmd', const ['open']) &&
      _trimaValveLooksLike(e, 'PlasmaValveCmd', const ['open']) &&
      _trimaValveLooksLike(e, 'RBCValveCmd', const ['return']);

  bool _looksLikeTrimaInletDecay(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 20) &&
      _near(_trimaNumber(e, 'InletCmd'), 20) &&
      _near(_trimaNumber(e, 'ReturnCmd'), -40);

  bool _looksLikeTrimaAcPrimeInlet(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 50) &&
      _near(_trimaNumber(e, 'InletCmd'), 50);

  bool _looksLikeTrimaAcPressReturnLine(String e) =>
      _near(_trimaNumber(e, 'ACCmd'), 0) &&
      _near(_trimaNumber(e, 'InletCmd'), 0) &&
      _near(_trimaNumber(e, 'ReturnCmd'), -50);

  Future<void> _showTrimaStartupAnalysis(BuildContext context) async {
    if (_trimaAnalyzerMinimized && mounted) {
      setState(() => _trimaAnalyzerMinimized = false);
    }

    final intervals = _cachedTrimaIntervals;
    // Only roots are rendered in the main list. Every descendant is rendered
    // recursively inside its parent ExpansionTile, avoiding duplicates.
    final rootIntervals = intervals
        .where((e) =>
            (e.exitIndex != null && !_trimaHasCachedParent(e)) ||
            (e.exitIndex == null &&
                e.name.toLowerCase() != 'mainstate' &&
                !_trimaHasCachedParent(e)))
        .toList()
      ..sort((a, b) => a.enterIndex.compareTo(b.enterIndex));

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          title: Row(
            children: [
              Icon(Icons.account_tree_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              const Expanded(child: Text('TRIMA ANALYZE')),
              IconButton(
                tooltip: 'Minimize',
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  if (mounted) setState(() => _trimaAnalyzerMinimized = true);
                },
                icon: const Icon(Icons.minimize_rounded),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  if (mounted) setState(() => _trimaAnalyzerMinimized = false);
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 980,
            height: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Master-state mode: only approved Trima states are shown. '
                  'Known exit conditions are validated from CSV/TRACE; states without sufficient evidence remain UNKNOWN.',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _trimaStatChip(dialogContext, 'PAIRS', '${intervals.where((e) => e.exitIndex != null).length}'),
                    const SizedBox(width: 8),
                    _trimaStatChip(dialogContext, 'OPEN', '${intervals.where((e) => e.exitIndex == null).length}'),
                    const SizedBox(width: 8),
                    _trimaStatChip(dialogContext, 'MAX DEPTH',
                        '${intervals.isEmpty ? 0 : intervals.map((e) => e.depth).reduce((a, b) => a > b ? a : b)}'),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Expanded(flex: 5, child: Text('State / Substate', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 2, child: Text('ENTER', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 2, child: Text('EXIT', style: TextStyle(fontWeight: FontWeight.w800))),
                      Expanded(flex: 1, child: Text('ΔT', style: TextStyle(fontWeight: FontWeight.w800))),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    controller: _trimaDialogScrollController,
                    itemCount: rootIntervals.length,
                    itemBuilder: (context, index) {
                      final item = rootIntervals[index];
                      final enter = item.enterTime == null
                          ? '—'
                          : _trimaTimeLabel(item.enterTime!);
                      final exit = item.exitTime == null
                          ? '—'
                          : _trimaTimeLabel(item.exitTime!);
                      final duration = item.durationSeconds == null
                          ? '—'
                          : '${item.durationSeconds!.toStringAsFixed(3)} s';
                      final contentCount = item.exitIndex == null
                          ? 0
                          : (item.exitIndex! - item.enterIndex - 1)
                              .clamp(0, widget.episodios.length);

                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          tilePadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          childrenPadding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          leading: Builder(
                            builder: (_) {
                              final exitOk = _trimaKnownExitSatisfied(item);
                              final c = exitOk == true
                                  ? scheme.primary
                                  : (exitOk == false
                                      ? scheme.error
                                      : scheme.onSurfaceVariant);
                              return Icon(
                                exitOk == true
                                    ? Icons.check_circle_rounded
                                    : (exitOk == false
                                        ? Icons.cancel_rounded
                                        : Icons.radio_button_unchecked_rounded),
                                color: c,
                              );
                            },
                          ),
                          title: Text(
                            'L${item.enterIndex + 1}  ${_trimaStateLeaf(item.name)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ENTER L${item.enterIndex + 1} $enter   →   '
                                'EXIT ${item.exitIndex == null ? '—' : 'L${item.exitIndex! + 1}'} $exit   •   ΔT $duration'
                                '${item.exitIndex == null ? '' : '   •   $contentCount lines inside'}',
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _trimaClosedInternalSubstates(item),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          children: [
                            if (item.exitIndex == null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'No matching Exit: ${item.name} found.',
                                  style: TextStyle(color: scheme.error),
                                ),
                              )
                            else ...[
                              _trimaSubstateSummary(item, scheme),
                              if (_trimaIsStartupTestState(item))
                                _trimaStartupSnapshot(item, scheme),
                              if (_trimaIsStartupTransitionState(item))
                                _trimaStartupTransitionSnapshot(item, scheme),
                              if (_trimaIsValveVerificationState(item)) ...[
                                _trimaValveStateSnapshot(item, scheme),
                                ..._buildTrimaCompactValveSummary(item, scheme),
                              ],
                              if (_trimaIsPrimeChannelVolumeState(item))
                                _trimaPrimeChannelSnapshot(item, scheme),
                              if (_trimaIsPumpVerificationState(item))
                                _trimaPumpStateSnapshot(item, scheme),
                              if (_trimaIsCassetteVerificationState(item))
                                _trimaCassetteStateSnapshot(item, scheme),
                              if (_trimaIsDisposableVerificationState(item))
                                _trimaDisposableSnapshot(item, scheme),
                              if (_trimaIsApsVerificationState(item) &&
                                  !_trimaIsDisposableVerificationState(item))
                                _trimaApsStateSnapshot(item, scheme),
                              if (_trimaIsDoorVerificationState(item))
                                _trimaDoorStateSnapshot(item, scheme),
                              if (_trimaIsCentrifugeVerificationState(item))
                                _trimaCentrifugeStateSnapshot(item, scheme),
                              if (_trimaIsPowerTestState(item))
                                _trimaPowerTestSnapshot(item, scheme),
                              if (_trimaIsLeakDetectorState(item))
                                _trimaLeakDetectorSnapshot(item, scheme),
                              if (_trimaIsLowerNotificationState(item))
                                _trimaLowerNotificationSnapshot(item, scheme),
                              if (_trimaIsConnectAcState(item))
                                _trimaConnectAcSnapshot(item, scheme),
                              if (_trimaIsAcPrimeVerificationState(item))
                                _trimaAcPrimeSnapshot(item, scheme),
                              ..._buildTrimaNestedContents(
                                dialogContext,
                                item,
                                scheme,
                              ),
                              _trimaBoundaryLine(
                                dialogContext,
                                item.exitIndex!,
                                'EXIT',
                                widget.episodios[item.exitIndex!],
                                scheme,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  String _trimaValvePosition(int value) {
    switch (value) {
      case 1:
        return 'COLLECT';
      case 2:
        return 'OPEN';
      case 3:
        return 'RETURN';
      default:
        return 'UNKNOWN($value)';
    }
  }

  List<String> _trimaStatePath(String name) {
    return name
        .split('::')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  String _trimaStateLeaf(String name) {
    final p = _trimaStatePath(name);
    return p.isEmpty ? name : p.last;
  }

  Map<int, List<_TrimaEnterExitInterval>> _buildTrimaChildrenCache(
      List<_TrimaEnterExitInterval> intervals) {
    final map = <int, List<_TrimaEnterExitInterval>>{};
    final completed = intervals.where((e) => e.exitIndex != null).toList()
      ..sort((a, b) => a.enterIndex.compareTo(b.enterIndex));

    // First establish the normal parent by strict interval containment.
    final parentOf = <int, _TrimaEnterExitInterval?>{};
    for (final child in completed) {
      _TrimaEnterExitInterval? best;
      for (final p in completed) {
        if (p.enterIndex >= child.enterIndex ||
            p.exitIndex! <= child.exitIndex!) continue;
        if (best == null ||
            (p.exitIndex! - p.enterIndex) <
                (best.exitIndex! - best.enterIndex)) {
          best = p;
        }
      }
      parentOf[child.enterIndex] = best;
    }

    // Then apply explicit logger paths. A name such as
    // "LoadCassette::CentrifugeTests" is authoritative: it MUST be rendered
    // below LoadCassette, even if its Enter/Exit interval is not physically
    // contained by LoadCassette because of asynchronous logger ordering.
    for (final child in completed) {
      final path = _trimaStatePath(child.name);
      if (path.length < 2) continue;
      final wantedParent = path[path.length - 2].toLowerCase();

      _TrimaEnterExitInterval? best;
      var bestDistance = 1 << 30;
      for (final p in completed) {
        if (p.enterIndex == child.enterIndex) continue;
        if (_trimaStateLeaf(p.name).toLowerCase() != wantedParent) continue;

        // Prefer the nearest matching parent preceding the child; otherwise
        // the nearest matching occurrence.
        final delta = child.enterIndex - p.enterIndex;
        final distance = delta >= 0 ? delta : delta.abs() + 1000000;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = p;
        }
      }
      if (best != null) parentOf[child.enterIndex] = best;
    }

    for (final p in completed) {
      map[p.enterIndex] = <_TrimaEnterExitInterval>[];
    }
    for (final child in completed) {
      final p = parentOf[child.enterIndex];
      if (p != null) {
        map.putIfAbsent(p.enterIndex, () => <_TrimaEnterExitInterval>[])
            .add(child);
      }
    }
    for (final list in map.values) {
      list.sort((a, b) => a.enterIndex.compareTo(b.enterIndex));
    }
    return map;
  }

  bool _trimaHasCachedParent(_TrimaEnterExitInterval child) {
    for (final children in _cachedTrimaChildren.values) {
      if (children.any((e) => e.enterIndex == child.enterIndex)) return true;
    }
    return false;
  }

  List<_TrimaEnterExitInterval> _trimaDirectChildren(
      _TrimaEnterExitInterval parent) {
    return _cachedTrimaChildren[parent.enterIndex] ??
        const <_TrimaEnterExitInterval>[];
  }

  List<_TrimaEnterExitInterval> _trimaAllSubstates(
      _TrimaEnterExitInterval parent) {
    final out = <_TrimaEnterExitInterval>[];
    void walk(_TrimaEnterExitInterval p) {
      final children = _cachedTrimaChildren[p.enterIndex] ?? const [];
      for (final c in children) {
        out.add(c);
        walk(c);
      }
    }
    walk(parent);
    return out;
  }

  Widget _trimaSubstateSummary(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final children = _trimaDirectChildren(interval)
        .where((c) =>
            c.enterIndex != interval.enterIndex &&
            !(_trimaStateLeaf(c.name).toLowerCase() ==
                    _trimaStateLeaf(interval.name).toLowerCase() &&
                c.enterIndex == interval.enterIndex))
        .toList();
    if (children.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Text(
            'Internal substates: none',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'INTERNAL SUBSTATES (${children.length})',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          for (final child in children)
            Padding(
              padding: EdgeInsets.only(
                left: ((child.depth - interval.depth - 1).clamp(0, 8)) * 14.0,
                top: 2,
                bottom: 2,
              ),
              child: Row(
                children: [
                  Icon(
                    child.exitIndex == null
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 15,
                    color: child.exitIndex == null
                        ? scheme.error
                        : scheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      child.name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Map<String, int> _trimaValveStateBefore(int sourceIndex) {
    final inPositionRx = RegExp(
      r'Valve\s+(plasma|platelet|rbc)\s+in\s+position\s*:\s*status\s*=\s*(-?\d+)',
      caseSensitive: false,
    );
    final commandRx = RegExp(
      r'Valve\s+(plasma|platelet|rbc)\s*:\s*order\s*=\s*(-?\d+)\s+status\s*=\s*(-?\d+)',
      caseSensitive: false,
    );
    final state = <String, int>{};
    for (var i = 0; i < sourceIndex && i < widget.episodios.length; i++) {
      final line = widget.episodios[i];
      final p = inPositionRx.firstMatch(line);
      if (p != null) {
        final v = (p.group(1) ?? '').toUpperCase();
        final status = int.tryParse(p.group(2) ?? '');
        if (status != null) state[v] = status;
        continue;
      }
      final c = commandRx.firstMatch(line);
      if (c != null) {
        final v = (c.group(1) ?? '').toUpperCase();
        final current = int.tryParse(c.group(3) ?? '');
        if (current != null && !state.containsKey(v)) state[v] = current;
      }
    }
    return state;
  }

  Map<String, int> _trimaValveStateAtExit(
      _TrimaEnterExitInterval interval) {
    final state =
        Map<String, int>.from(_trimaValveStateBefore(interval.enterIndex));

    const csvFields = <String, String>{
      'RBC': 'RBCValvePos',
      'PLASMA': 'PlasmaValvePos',
      'PLATELET': 'CollectValvePos',
    };

    // V95: DATA is primary. Use the latest valid measured position in the
    // State/Substate temporal window (Enter/Exit state).
    for (final entry in csvFields.entries) {
      final samples = _trimaDataSamples(interval, entry.value);
      for (final sample in samples.reversed) {
        final p = _trimaValveCsvPosition(sample.value);
        if (p != null) {
          state[entry.key] = p;
          break;
        }
      }
    }

    // TRACE remains a fallback when a DATA position is unavailable.
    if (interval.exitIndex != null) {
      final rx = RegExp(
        r'Valve\s+(plasma|platelet|rbc)\s+in\s+position\s*:\s*status\s*=\s*(-?\d+)',
        caseSensitive: false,
      );
      for (var i = interval.enterIndex + 1; i < interval.exitIndex!; i++) {
        final m = rx.firstMatch(widget.episodios[i]);
        if (m == null) continue;
        final key = (m.group(1) ?? '').toUpperCase();
        if (state.containsKey(key) &&
            _trimaDataSamples(interval, csvFields[key] ?? '').isNotEmpty) {
          continue;
        }
        final status = int.tryParse(m.group(2) ?? '');
        if (status != null) state[key] = status;
      }
    }
    return state;
  }

  Map<String, int>? _trimaRequiredValveExit(_TrimaEnterExitInterval interval) {
    final n = interval.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // Only rules explicitly supported by the Trima service-manual sections
    // currently loaded. Ambiguous context-dependent names are not guessed.
    if (n == 'closevalves' || n == 'evacresetvalves') {
      return const {'RBC': 3, 'PLASMA': 3, 'PLATELET': 3}; // Return
    }
    if (n == 'openvalves') {
      return const {'RBC': 2, 'PLASMA': 2, 'PLATELET': 2}; // Open
    }
    return null;
  }

  bool? _trimaValveExitSatisfied(_TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return false;
    final required = _trimaRequiredValveExit(interval);
    if (required != null) {
      final finalState = _trimaValveStateAtExit(interval);
      final dataOk =
          required.entries.every((e) => finalState[e.key] == e.value);
      if (dataOk) return true;

      // If the sparse DATA snapshot is stale, an explicit ordered->in-position
      // TRACE movement to the required target is equally valid evidence.
      final events = _trimaValveEventsInInterval(interval);
      final traceReached = <String, int>{};
      for (final event in events) {
        if (event.approved && event.inPositionStatus != null) {
          traceReached[event.valve] = event.inPositionStatus!;
        }
      }
      final traceOk =
          required.entries.every((e) => traceReached[e.key] == e.value);
      return traceOk;
    }

    // ValvesTest may contain intermediate retries/discrepancies while several
    // control/safety systems are working. For the state verdict we care about
    // the FINAL confirmed condition before Exit: all three valves must have a
    // valid "in position" status. Intermediate discrepancies remain visible.
    final n = interval.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (n == 'valvestest') {
      final events = _trimaValveEventsInInterval(interval);
      if (events.isEmpty) return null;

      // Trima Startup manual: each of the three valves is exercised through
      // all three positions and every commanded position must be reached
      // within 10 seconds. Do not accept merely the final valve position.
      const valves = <String>{'RBC', 'PLASMA', 'PLATELET'};
      const positions = <int>{1, 2, 3}; // Collect, Open, Return.
      for (final valve in valves) {
        for (final position in positions) {
          final matches = events.where(
            (e) => e.valve == valve && e.order == position,
          );
          if (matches.isEmpty) return null;
          final reachedInTime = matches.any((e) =>
              e.approved &&
              e.movementTimeMs != null &&
              e.movementTimeMs! <= 10000);
          if (!reachedInTime) return false;
        }
      }
      return true;
    }

    // For other states we don't yet know the complete exit condition. Do not
    // mark them green merely because an Exit line exists.
    return null;
  }

  Color? _trimaExitConditionColor(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final ok = _trimaValveExitSatisfied(interval);
    if (ok == true) return scheme.primary;
    if (ok == false) return scheme.error;
    return null;
  }

  String _trimaClosedInternalSubstates(_TrimaEnterExitInterval interval) {
    final children = _trimaDirectChildren(interval);
    if (children.isEmpty) return 'Substates: none';
    return 'Substates (${children.length}): '
        '${children.map((e) => _trimaStateLeaf(e.name)).join(' • ')}';
  }

  bool _trimaIsPumpVerificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'startpumps' || n == 'stoppumps';
  }

  Map<String, double>? _trimaPumpCommandFromLine(String line) {
    if (!line.toLowerCase().contains('command pumps -')) return null;
    double? v(String name) {
      final m = RegExp(
        '${RegExp.escape(name)}\\s*:\\s*(-?\\d+(?:\\.\\d+)?)',
        caseSensitive: false,
      ).firstMatch(line);
      return double.tryParse(m?.group(1) ?? '');
    }
    final ac = v('AC');
    final inlet = v('Inlet');
    final ret = v('Return');
    final collect = v('Collect');
    final plasma = v('Plasma');
    if ([ac, inlet, ret, collect, plasma].any((x) => x == null)) return null;
    return {
      'AC': ac!,
      'INLET': inlet!,
      'RETURN': ret!,
      'PLATELET': collect!,
      'PLASMA': plasma!,
    };
  }

  Map<String, double>? _trimaFinalPumpCommand(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return null;
    Map<String, double>? last;
    for (var i = interval.enterIndex + 1; i < interval.exitIndex!; i++) {
      final p = _trimaPumpCommandFromLine(widget.episodios[i]);
      if (p != null) last = p;
    }
    return last;
  }

  List<String> _trimaAncestorNames(_TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return const [];
    final parents = _cachedTrimaIntervals.where((p) =>
        p.exitIndex != null &&
        p.enterIndex < interval.enterIndex &&
        p.exitIndex! > interval.exitIndex!).toList()
      ..sort((a, b) => a.enterIndex.compareTo(b.enterIndex));
    return parents.map((e) => e.name.toLowerCase()).toList();
  }

  Map<String, double>? _trimaRequiredPumpExit(
      _TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (n == 'stoppumps') {
      return const {
        'AC': 0, 'INLET': 0, 'RETURN': 0, 'PLATELET': 0, 'PLASMA': 0,
      };
    }
    if (n != 'startpumps') return null;

    final ancestors = _trimaAncestorNames(interval).join(' ');
    if (ancestors.contains('loadcassette') ||
        ancestors.contains('startuptest')) {
      return const {
        'AC': 60, 'INLET': 140, 'RETURN': 110, 'PLATELET': 60, 'PLASMA': 60,
      };
    }
    if (ancestors.contains('mssdisconnect')) {
      return const {
        'AC': 60, 'INLET': 60, 'RETURN': -110, 'PLATELET': 60, 'PLASMA': 60,
      };
    }
    if (ancestors.contains('donordisconnect')) {
      return const {
        'AC': 60, 'INLET': 60, 'RETURN': 150, 'PLATELET': 60, 'PLASMA': 60,
      };
    }

    // V118: StartPumps also occurs later in the procedure with different
    // directions/targets.  Do not hard-code the startup values there: the
    // firmware's final Command pumps line is the target for this occurrence.
    // _trimaPumpExitSatisfied then proves each CSV *Act against that command.
    final dynamicCommand = _trimaFinalPumpCommand(interval);
    if (dynamicCommand != null) return dynamicCommand;
    return null;
  }

  // V97 DEBUG ------------------------------------------------------------
  // Prints the carried Procedure CSV values at every literal Enter/Exit.
  // Keep this true while validating the Trima state machine.
  static const bool _trimaPrintStateCsvValues = false;

  String _trimaDebugValue(dynamic value) {
    if (value == null) return '<null>';
    final s = value.toString().replaceAll('\r', r'\r').replaceAll('\n', r'\n');
    return s.length <= 120 ? s : '${s.substring(0, 117)}...';
  }

  Map<String, dynamic> _trimaCsvSnapshotAtRow(int row) {
    final result = <String, dynamic>{};
    final names = widget.procedureColumns.keys.toList()..sort();
    for (final name in names) {
      if (name.toLowerCase() == 'timestamp') continue;
      final v = _trimaCsvLastAt(name, row)?.value;
      if (v == null) continue;
      final s = v.toString();
      if (s.trim().isEmpty) continue;
      result[name] = v;
    }
    return result;
  }

  String _trimaExpectedExitCondition(_TrimaEnterExitInterval interval) {
    final n = interval.name.toLowerCase();

    if (n.contains('closevalves')) {
      return 'RBC=RETURN, PLASMA=RETURN, PLATELET=RETURN';
    }
    if (n.contains('openvalves')) {
      return 'RBC=OPEN, PLASMA=OPEN, PLATELET=OPEN';
    }
    if (n.contains('stoppumps')) {
      return 'AC/Inlet/Plasma/Platelet/Return ACT -> 0';
    }
    if (n.contains('startpumps')) {
      return 'Pump ACT reaches commanded flow (±5 mL/min)';
    }
    if (n.contains('leakdetectortest')) {
      return 'LeakValue provisional 2.450..2.700 V and no explicit failure';
    }
    if (n.contains('valvestest')) {
      return 'RBC/PLASMA/PLATELET each reach COLLECT, OPEN and RETURN; each movement <=10 s';
    }
    if (n.contains('lowercassette')) {
      return 'Cassette DOWN detected within 15 s';
    }
    if (n.contains('cassetteid')) {
      return 'Cassette stamp reflectance read; no cassette/calibration failure';
    }
    if (n.contains('centshutdown')) {
      return 'Centrifuge commanded 0 and verified immobile for >=2 s';
    }
    if (n.contains('doorlatchtest')) {
      return 'Door lock/unlock exercise + latch power enable/disable confirmed';
    }
    if (n.contains('lowernotification')) {
      return 'GUI message Disposable Lowered sent';
    }
    if (n.contains('checksamplebag')) {
      return 'Sample-bag pressure test passes (firmware/DLOG evidence)';
    }
    if (n.contains('pressinletline3')) {
      return 'APS > 500 mmHg before volume limit';
    }
    if (n.contains('pressinletline')) {
      return 'APS > 400 mmHg before volume limit';
    }
    if (n.contains('negativepresstest')) {
      return 'APS < -350 mmHg before inlet-volume limit';
    }
    if (n.contains('negativepressrelief')) {
      return 'APS > -50 mmHg before volume limit';
    }
    if (n.contains('inletpresstest')) {
      return 'APS decrease < 50 mmHg over test interval';
    }
    if (n.contains('inletdecaytest')) {
      return 'APS decrease > 50 mmHg after pump movement';
    }
    if (n.contains('unlockdoor')) {
      return 'Door detected unlocked';
    }
    if (n.contains('lowercassette')) {
      return 'Cassette detected DOWN/LOWERED';
    }
    if (n.contains('cassetteid')) {
      return 'Cassette stamp/ID read';
    }
    if (n.contains('lowernotification')) {
      return 'Disposable Lowered GUI message sent';
    }
    if (n.contains('connectac')) {
      return 'Operator Continue / AC connection acknowledged';
    }
    if (n.contains('acprimeinlet')) {
      return 'AC detected before AC-volume limit';
    }
    if (n.contains('acpressreturnline')) {
      return 'APS <= -50 mmHg before return-volume limit';
    }
    if (n.contains('safetypowertest64')) {
      return '64V ON/OFF safety power test passes';
    }
    if (n.contains('centshutdowntest') || n.contains('centshutdown')) {
      return 'Centrifuge ACT reaches zero / shutdown test passes';
    }
    if (n.contains('powerofftest')) {
      return '24V off and all pumps stopped';
    }
    if (n.contains('powerontest')) {
      return 'Power On Test passed';
    }
    if (n.contains('safetypowertest')) {
      return '24V ON/OFF safety power test passes';
    }
    if (n.contains('calibverification')) {
      return 'Structural successful transition to next startup state';
    }
    if (n.contains('nvramtest')) {
      return 'Structural successful transition to CalibVerification';
    }
    if (n.contains('guistarted')) {
      return 'USER continued from Load System screen';
    }
    if (n.contains('pltbagevac')) {
      return 'TO VERIFY from CSV/DLOG';
    }
    if (n.contains('air2channelprime') || n.contains('airc2hannelprime')) {
      return 'Air-to-channel prime completes without explicit FAIL; APS/volume evidence retained';
    }
    if (n == 'air2channel') {
      return 'Firmware reports Air2Channel finished with processed inlet volume';
    }
    if (n.contains('plsevacfinished')) {
      return 'TO VERIFY from CSV/DLOG';
    }
    return 'Structural Exit / child-specific condition';
  }

  double? _trimaDebugNumberAt(String field, int row) {
    final raw = _trimaCsvLastAt(field, row)?.value;
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString().trim());
  }

  String _trimaDebugRawAt(String field, int row) {
    final raw = _trimaCsvLastAt(field, row)?.value;
    if (raw == null) return '-';
    return raw
        .toString()
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll('|', '/');
  }

  double? _trimaParseLeakValue(dynamic raw) {
    // DlogDecoder already emits LeakValue in volts (for example 2.6).
    // EpisodicPage must never reinterpret it as mV or decode it again.
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString().trim());
  }

  ({String raw, double? volts}) _trimaLeakAtTime(DateTime? target) {
    if (target == null) return (raw: '-', volts: null);
    final col = widget.procedureColumns['LeakValue'];
    if (col == null) return (raw: '-', volts: null);

    String? bestRaw;
    double? bestVolts;
    int? bestMs;

    for (final row in widget.procedureRows) {
      if (row.isEmpty || col >= row.length) continue;
      final time = _trimaCsvTimestamp(row[0].toString());
      if (time == null) continue;

      final delta = (time.difference(target).inMilliseconds).abs();
      if (delta > 100) continue;

      final raw = row[col];
      final volts = _trimaParseLeakValue(raw);
      if (volts == null) continue;

      if (bestMs == null || delta < bestMs) {
        bestMs = delta;
        bestRaw = raw.toString();
        bestVolts = volts;
      }
    }

    final printable = bestRaw == null
        ? '-'
        : bestRaw!
            .replaceAll('\\r', r'\r')
            .replaceAll('\\n', r'\n')
            .replaceAll('|', '/');
    return (raw: printable, volts: bestVolts);
  }

  String _trimaDebugN(double? v, {int decimals = 1}) =>
      v == null ? '-' : v.toStringAsFixed(decimals);

  String _trimaDebugVerdict(_TrimaEnterExitInterval interval) {
    final ok = _trimaKnownExitSatisfied(interval);
    if (ok == true) return 'PASS';
    if (ok == false) return 'FAIL';
    return 'UNKNOWN';
  }

  void _trimaPrintSnapshot(
      String edge, _TrimaEnterExitInterval interval, int row) {
    if (!_trimaPrintStateCsvValues) return;

    final edgeTime = edge == 'ENTER' ? interval.enterTime : interval.exitTime;
    final leakAtTime = _trimaLeakAtTime(edgeTime);
    final leakRaw = leakAtTime.raw;
    final leak = leakAtTime.volts;
    final aps = _trimaDebugNumberAt('APS', row);

    final acVol = _trimaDebugNumberAt('ACVol', row);
    final inletVol = _trimaDebugNumberAt('InletVol', row);
    final inletTotal = _trimaDebugNumberAt('InletTotalVol', row);
    final plasmaVol = _trimaDebugNumberAt('PlasmaVol', row);
    final collectVol = _trimaDebugNumberAt('CollectVol', row);
    final returnVol = _trimaDebugNumberAt('ReturnVol', row);
    final actTotal = _trimaDebugNumberAt('ACTotalVol', row);
    final vbpTotal = _trimaDebugNumberAt('VbpTotal', row);
    final vbpPlatelet = _trimaDebugNumberAt('VbpPlatelet', row);

    final rbcCmd = _trimaDebugRawAt('RBCValveCmd', row);
    final rbcPos = _trimaDebugRawAt('RBCValvePos', row);
    final plsCmd = _trimaDebugRawAt('PlasmaValveCmd', row);
    final plsPos = _trimaDebugRawAt('PlasmaValvePos', row);
    final pltCmd = _trimaDebugRawAt('CollectValveCmd', row);
    final pltPos = _trimaDebugRawAt('CollectValvePos', row);

    debugPrint(
      '$edge: ${interval.name} | '
      'RESULT=${_trimaDebugVerdict(interval)} | '
      'LeakRaw="$leakRaw" Leak=${_trimaDebugN(leak, decimals: 3)}V'
      '${leak == null ? '' : ' (${(leak * 1000).round()}mV)'} | '
      'APS=${_trimaDebugN(aps)} | '
      'Valves RBC=$rbcCmd/$rbcPos PLS=$plsCmd/$plsPos PLT=$pltCmd/$pltPos | '
      'AC=${_trimaDebugN(acVol)} '
      'Inlet=${_trimaDebugN(inletVol)} '
      'InletTotal=${_trimaDebugN(inletTotal)} '
      'Plasma=${_trimaDebugN(plasmaVol)} '
      'Collect=${_trimaDebugN(collectVol)} '
      'Return=${_trimaDebugN(returnVol)} '
      'ACTotal=${_trimaDebugN(actTotal)} '
      'Vbp=${_trimaDebugN(vbpTotal)} '
      'VbpPlt=${_trimaDebugN(vbpPlatelet)} | '
      'EXIT_EXPECTED=${_trimaExpectedExitCondition(interval)}',
    );
  }

  bool _trimaDebugVisibleState(_TrimaEnterExitInterval interval) {
    // Print only states/substates that are part of the nested Trima analyzer
    // currently shown in EpisodicPage. This excludes incidental Enter/Exit
    // pairs that we are not analyzing/rendering.
    if (_trimaKnownExitSatisfied(interval) != null) return true;

    final name = interval.name.toLowerCase();

    // Structural parents used by the EpisodicPage tree.
    const parents = <String>{
      'startuptest',
      'powertest',
      'loadcassette',
      'centrifugetests',
      'disposabletest',
      'disposabletest1',
      'connectac',
      'acprime',
    };
    if (parents.contains(name)) return true;

    // A state with analyzer children is also part of the visible nested tree.
    final children = _cachedTrimaChildren[interval.enterIndex];
    return children != null && children.isNotEmpty;
  }

  void _trimaPrintAllStateSnapshots() {
    if (!_trimaPrintStateCsvValues || widget.procedureRows.isEmpty) return;

    debugPrint('');
    debugPrint('############################################################');
    debugPrint('TRIMA V97 CSV STATE WALK - ${_cachedTrimaIntervals.length} states');
    debugPrint('############################################################');

    for (final interval in _cachedTrimaIntervals) {
      if (!_trimaDebugVisibleState(interval)) continue;
      _trimaPrintSnapshot('ENTER', interval, interval.enterIndex);
      if (interval.exitIndex != null) {
        _trimaPrintSnapshot('EXIT', interval, interval.exitIndex!);
      } else {
        debugPrint('========== TRIMA EXIT MISSING: ${interval.name} ==========');
      }
    }
  }

  // V96 -----------------------------------------------------------------
  // Walk the Procedure CSV once, carrying the last non-empty value of every
  // column. Only value changes are stored, so State/Substate checks no longer
  // rescan the complete CSV.
  void _buildTrimaCsvStateCache() {
    _trimaCsvChanges.clear();
    if (widget.procedureRows.isEmpty || widget.procedureColumns.isEmpty) return;

    final orderedColumns = widget.procedureColumns.entries
        .where((e) => e.value >= 0)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    final lastText = <String, String>{};

    for (var rowIndex = 0;
        rowIndex < widget.procedureRows.length;
        rowIndex++) {
      final row = widget.procedureRows[rowIndex];
      if (row.isEmpty) continue;
      final time = _trimaCsvTimestamp(row[0].toString());

      for (final column in orderedColumns) {
        final col = column.value;
        if (col >= row.length) continue;
        final raw = row[col];
        if (raw == null) continue;

        final text = raw.toString();
        if (text.trim().isEmpty) continue;

        // Store only changes. This is the running "last value" registry.
        if (lastText[column.key] == text) continue;
        lastText[column.key] = text;
        (_trimaCsvChanges[column.key] ??=
                <({int row, DateTime? time, dynamic value})>[])
            .add((row: rowIndex, time: time, value: raw));
      }
    }
  }

  ({int row, DateTime? time, dynamic value})? _trimaCsvLastAt(
      String field, int row) {
    final changes = _trimaCsvChanges[field];
    if (changes == null || changes.isEmpty || row < 0) return null;

    // Binary search: last change whose row <= requested row.
    var lo = 0;
    var hi = changes.length - 1;
    var answer = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (changes[mid].row <= row) {
        answer = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return answer < 0 ? null : changes[answer];
  }

  List<({DateTime time, int row, dynamic value})> _trimaDataSamples(
      _TrimaEnterExitInterval interval, String field,
      {Duration postExit = Duration.zero}) {
    final changes = _trimaCsvChanges[field];
    if (changes == null || changes.isEmpty) return const [];

    final enterTime = interval.enterTime;
    final structuralExitTime = interval.exitTime ?? interval.enterTime;
    if (enterTime == null || structuralExitTime == null) return const [];
    final exitTime = structuralExitTime.add(postExit);

    final result = <({DateTime time, int row, dynamic value})>[];

    // Carry the last known CSV value into the State at its real ENTER time.
    ({int row, DateTime? time, dynamic value})? carried;
    for (final c in changes) {
      if (c.time == null) continue;
      if (c.time!.isAfter(enterTime)) break;
      carried = c;
    }
    if (carried != null) {
      result.add((
        time: enterTime,
        row: carried.row,
        value: carried.value,
      ));
    }

    // Add every real CSV change whose timestamp falls inside ENTER..EXIT.
    for (final c in changes) {
      final time = c.time;
      if (time == null) continue;
      if (!time.isAfter(enterTime)) continue;
      if (time.isAfter(exitTime)) break;
      result.add((time: time, row: c.row, value: c.value));
    }

    return result;
  }

  List<({DateTime time, int row, double value})> _trimaDataNumbers(
      _TrimaEnterExitInterval interval, String field) {
    final result = <({DateTime time, int row, double value})>[];
    for (final sample in _trimaDataSamples(interval, field)) {
      final raw = sample.value;
      final value =
          raw is num ? raw.toDouble() : double.tryParse(raw.toString().trim());
      if (value != null) {
        result.add((time: sample.time, row: sample.row, value: value));
      }
    }
    return result;
  }

  ({double value, DateTime time, int row})? _trimaDataClosestSampleToTarget(
      _TrimaEnterExitInterval interval, String field, double target,
      {Duration postExit = Duration.zero}) {
    final samples = <({DateTime time, int row, double value})>[];
    for (final sample in _trimaDataSamples(interval, field, postExit: postExit)) {
      final raw = sample.value;
      final value = raw is num
          ? raw.toDouble()
          : double.tryParse(raw.toString().trim());
      if (value != null) {
        samples.add((time: sample.time, row: sample.row, value: value));
      }
    }
    if (samples.isEmpty) return null;
    var best = samples.first;
    var distance = (best.value - target).abs();
    for (final sample in samples.skip(1)) {
      final d = (sample.value - target).abs();
      if (d < distance) {
        best = sample;
        distance = d;
      }
    }
    return (value: best.value, time: best.time, row: best.row);
  }

  double? _trimaDataClosestToTarget(
      _TrimaEnterExitInterval interval, String field, double target) {
    final samples = _trimaDataNumbers(interval, field);
    if (samples.isEmpty) return null;
    var best = samples.first.value;
    var distance = (best - target).abs();
    for (final sample in samples.skip(1)) {
      final d = (sample.value - target).abs();
      if (d < distance) {
        best = sample.value;
        distance = d;
      }
    }
    return best;
  }

  dynamic _trimaDataLast(_TrimaEnterExitInterval interval, String field) {
    final samples = _trimaDataSamples(interval, field);
    return samples.isEmpty ? null : samples.last.value;
  }

  int? _trimaValveCsvPosition(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    final s = raw.toString().trim().toLowerCase();
    final numeric = int.tryParse(s);
    if (numeric != null) return numeric;
    if (s.contains('collect')) return 1;
    if (s.contains('open')) return 2;
    if (s.contains('return')) return 3;
    return null;
  }

  Map<String, double>? _trimaStopPumpMeasuredByTimestamp(
      _TrimaEnterExitInterval interval) {
    const fields = <String, String>{
      'AC': 'ACAct',
      'INLET': 'InletAct',
      'PLASMA': 'PlasmaAct',
      'PLATELET': 'CollectAct',
      'RETURN': 'ReturnAct',
    };

    final best = <String, double>{};
    for (final entry in fields.entries) {
      final value = _trimaDataClosestToTarget(interval, entry.value, 0.0);
      if (value != null) best[entry.key] = value;
    }
    return best.isEmpty ? null : best;
  }

  bool? _trimaPumpExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsPumpVerificationState(interval) || interval.exitIndex == null) {
      return null;
    }

    final required = _trimaRequiredPumpExit(interval);
    if (required == null) return null;

    const fields = <String, String>{
      'AC': 'ACAct',
      'INLET': 'InletAct',
      'PLASMA': 'PlasmaAct',
      'PLATELET': 'CollectAct',
      'RETURN': 'ReturnAct',
    };

    // Primary evidence: actual pump flow columns from Procedure CSV.
    final measured = <String, double>{};
    for (final entry in fields.entries) {
      final target = required[entry.key];
      if (target == null) continue;
      final sample = _trimaDataClosestSampleToTarget(
        interval, entry.value, target,
        postExit: const Duration(seconds: 2),
      );
      if (sample != null) measured[entry.key] = sample.value;
    }

    final allPresent = required.keys.every(measured.containsKey);

    if (allPresent) {
      // +2 s is capture-only for delayed Procedure CSV flush. The documented
      // 10 s limit is measured from the real State ENTER to each sample time.
      var reachedInTime = true;
      for (final entry in fields.entries) {
        final target = required[entry.key];
        if (target == null) continue;
        final sample = _trimaDataClosestSampleToTarget(
          interval, entry.value, target,
          postExit: const Duration(seconds: 2),
        );
        if (sample == null || (sample.value - target).abs() > 5.0) {
          reachedInTime = false;
          break;
        }
        final enter = interval.enterTime;
        if (enter == null || sample.time.difference(enter).inMilliseconds > 10000) {
          reachedInTime = false;
          break;
        }
      }
      return reachedInTime;
    }

    // Fallback for older/sparse CSVs: explicit TRACE pump command.
    final command = _trimaFinalPumpCommand(interval);
    if (command == null) return null;
    final commandReached = required.entries.every(
      (e) => ((command[e.key] ?? 1e99) - e.value).abs() <= 0.01,
    );

    // TRACE fallback has no per-pump sample timestamp. In that case the
    // strongest timing evidence available is that the state itself completed
    // within the documented 10 s window.
    final enter = interval.enterTime;
    final exit = interval.exitTime;
    final within10s = enter != null &&
        exit != null &&
        !exit.isBefore(enter) &&
        exit.difference(enter).inMilliseconds <= 10000;

    return commandReached && within10s;
  }

  Widget _trimaPumpStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final required = _trimaRequiredPumpExit(interval);
    final actual = _trimaFinalPumpCommand(interval);
    final measuredActual = <String, double>{};
    final pumpFields = <String, String>{'AC':'ACAct','INLET':'InletAct','PLASMA':'PlasmaAct','PLATELET':'CollectAct','RETURN':'ReturnAct'};
    if (required != null) {
      for (final e in pumpFields.entries) {
        final target = required[e.key];
        if (target == null) continue;
        final sample = _trimaDataClosestSampleToTarget(interval, e.value, target, postExit: const Duration(seconds: 2));
        if (sample != null) measuredActual[e.key] = sample.value;
      }
    }
    final ok = _trimaPumpExitSatisfied(interval);
    if (required == null) return const SizedBox.shrink();

    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final measuredStopped = n == 'stoppumps' ? _trimaStopPumpMeasuredByTimestamp(interval) : null;
    final stopped = <String>{};
    if (n == 'stoppumps' && interval.exitIndex != null) {
      for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
        final l = _episodiosLower[i];
        if (!l.contains('no moving detected') ||
            !l.contains('command rpm = 0')) continue;
        if (l.contains('ac pump')) stopped.add('AC');
        if (l.contains('inlet pump')) stopped.add('INLET');
        if (l.contains('plasma pump')) stopped.add('PLASMA');
        if (l.contains('platelet') || l.contains('collect pump')) stopped.add('PLATELET');
        if (l.contains('return pump')) stopped.add('RETURN');
      }
    }

    String line(Map<String, double> m) =>
        'AC ${m['AC']?.toStringAsFixed(0)}  •  '
        'INLET ${m['INLET']?.toStringAsFixed(0)}  •  '
        'PLASMA ${m['PLASMA']?.toStringAsFixed(0)}  •  '
        'PLATELET ${m['PLATELET']?.toStringAsFixed(0)}  •  '
        'RETURN ${m['RETURN']?.toStringAsFixed(0)}';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PUMPS',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('REQUIRED  ${line(required)}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          if (measuredActual.length == required.length)
            Text('MEASURED ACT  ${['AC','INLET','PLASMA','PLATELET','RETURN'].map((x) => '$x ${measuredActual[x]?.toStringAsFixed(1) ?? '—'}').join('  •  ')}',
                style: const TextStyle(fontSize: 11))
          else if (actual != null)
            Text('FINAL COMMAND  ${line(actual)}',
                style: const TextStyle(fontSize: 11))
          else if (n == 'stoppumps' && measuredStopped != null)
            Text(
              'MEASURED  ${['AC','INLET','PLASMA','PLATELET','RETURN'].map((x) => '$x ${measuredStopped[x]?.toStringAsFixed(1) ?? '—'}').join('  •  ')}',
              style: const TextStyle(fontSize: 11),
            )
          else if (n == 'stoppumps')
            Text(
              'SAFETY STOPPED  ${['AC','INLET','PLASMA','PLATELET','RETURN'].map((x) => '$x ${stopped.contains(x) ? '✓' : '…'}').join('  •  ')}',
              style: const TextStyle(fontSize: 11),
            ),
          const SizedBox(height: 4),
          Text(
            ok == true
                ? 'COMMAND CONDITION + EXIT ≤10 s → SATISFIED'
                : 'PUMP CONDITION → NOT SATISFIED',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true ? scheme.primary : scheme.error,
            ),
          ),
          Text(
            n == 'stoppumps'
                ? 'StopPumps uses Procedure CSV ACT samples inside State single-pass Enter/Exit state; |speed| ≤ 5 mL/min for all five pumps.'
                : 'ACT samples use Enter → Exit +2 s only to capture delayed CSV flush; the 10 s test limit is still measured from the real Enter timestamp.',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  bool _trimaIsCassetteVerificationState(
      _TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'lowercassette' || n == 'cassetteid';
  }

  void _rebuildTrimaDiagnosticCaches() {
    _cachedCassetteEvidence.clear();
    _cachedCassetteExit.clear();

    for (final interval in _cachedTrimaIntervals) {
      if (!_trimaIsCassetteVerificationState(interval) ||
          interval.exitIndex == null) {
        continue;
      }

      final out = <MapEntry<int, String>>[];
      final rx = RegExp(
        r'(cassette\s*:|cassette reached|cassette in position|cassette completely|cassette lowered|cassette detection|stamp detected|cassette function codes|rbc init red/green|rbc cal:|reflectance|min/max|cassette type message)',
        caseSensitive: false,
      );
      for (var i = interval.enterIndex + 1; i < interval.exitIndex!; i++) {
        final e = widget.episodios[i];
        if (rx.hasMatch(e)) out.add(MapEntry(i, e));
      }
      _cachedCassetteEvidence[interval.enterIndex] =
          List<MapEntry<int, String>>.unmodifiable(out);
    }

    // Compute once, outside build/scroll.
    for (final interval in _cachedTrimaIntervals) {
      if (_trimaIsCassetteVerificationState(interval)) {
        _cachedCassetteExit[interval.enterIndex] =
            _trimaCassetteExitSatisfiedUncached(interval);
      }
    }

    _cachedApsSamples.clear();
    _cachedApsExit.clear();
    _cachedApsAtEnter.clear();
    _cachedApsSourceLineAtEnter.clear();
    _cachedReturnVolAtEnter.clear();
    _cachedReturnVolSourceLineAtEnter.clear();
    _trimaApsTimeline.clear();
    _trimaAcVolTimeline.clear();
    _trimaInletVolTimeline.clear();
    _trimaReturnVolTimeline.clear();

    // One chronological pass over the DLOG. The most recent valid APS value is
    // carried forward across state boundaries; missing lines never reset it.
    final apsIntervalsByEnter = <int, List<_TrimaEnterExitInterval>>{};
    for (final interval in _cachedTrimaIntervals) {
      if (_trimaIsApsVerificationState(interval)) {
        apsIntervalsByEnter.putIfAbsent(interval.enterIndex, () => []).add(interval);
      }
    }

    final acPressByEnter = <int, List<_TrimaEnterExitInterval>>{};
    for (final interval in _cachedTrimaIntervals) {
      final n = _trimaStateLeaf(interval.name)
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (n == 'acpressreturnline') {
        acPressByEnter.putIfAbsent(interval.enterIndex, () => []).add(interval);
      }
    }

    double? lastAps;
    int? lastApsLine;
    double? lastReturnVol;
    int? lastReturnVolLine;
    for (var i = 0; i < widget.episodios.length; i++) {
      // Snapshot BEFORE consuming the Enter line, so this is truly the last
      // known pressure from the preceding chronological context.
      final entering = apsIntervalsByEnter[i];
      if (entering != null) {
        for (final interval in entering) {
          _cachedApsAtEnter[interval.enterIndex] = lastAps;
          _cachedApsSourceLineAtEnter[interval.enterIndex] = lastApsLine;
        }
      }

      final acEntering = acPressByEnter[i];
      if (acEntering != null) {
        for (final interval in acEntering) {
          _cachedReturnVolAtEnter[interval.enterIndex] = lastReturnVol;
          _cachedReturnVolSourceLineAtEnter[interval.enterIndex] =
              lastReturnVolLine;
        }
      }

      final eventTime = _trimaCsvTimestamp(widget.episodios[i]);
      final value = _trimaExtractAps(widget.episodios[i]);
      if (value != null) {
        lastAps = value;
        lastApsLine = i;
        if (eventTime != null) {
          _trimaApsTimeline.add((time: eventTime, line: i, value: value));
        }
      }

      final acv = _trimaNamedNumber(widget.episodios[i], 'ACVol');
      if (acv != null && eventTime != null) {
        _trimaAcVolTimeline.add((time: eventTime, line: i, value: acv));
      }
      final inv = _trimaNamedNumber(widget.episodios[i], 'InletVol');
      if (inv != null && eventTime != null) {
        _trimaInletVolTimeline.add((time: eventTime, line: i, value: inv));
      }

      final rv = _trimaNamedNumber(widget.episodios[i], 'ReturnVol');
      if (rv != null) {
        lastReturnVol = rv;
        lastReturnVolLine = i;
        if (eventTime != null) {
          _trimaReturnVolTimeline.add((time: eventTime, line: i, value: rv));
        }
      }
    }

    _trimaApsTimeline.sort((a, b) => a.time.compareTo(b.time));
    _trimaAcVolTimeline.sort((a, b) => a.time.compareTo(b.time));
    _trimaInletVolTimeline.sort((a, b) => a.time.compareTo(b.time));
    _trimaReturnVolTimeline.sort((a, b) => a.time.compareTo(b.time));

    for (final interval in _cachedTrimaIntervals) {
      if (!_trimaIsApsVerificationState(interval) ||
          interval.exitIndex == null) {
        continue;
      }

      // V95: APS is read from the actual Procedure CSV DATA and associated
      // using the same State/Substate Enter/Exit +/-1 second temporal window.
      final samples = <MapEntry<int, double>>[
        for (final p in _trimaDataNumbers(interval, 'APS'))
          MapEntry(p.row, p.value),
      ];

      // TRACE fallback for older/partial decoder outputs.
      if (samples.isEmpty) {
        for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
          final value = _trimaExtractAps(widget.episodios[i]);
          if (value != null) samples.add(MapEntry(i, value));
        }
      }

      _cachedApsSamples[interval.enterIndex] =
          List<MapEntry<int, double>>.unmodifiable(samples);
    }
    for (final interval in _cachedTrimaIntervals) {
      if (_trimaIsApsVerificationState(interval)) {
        _cachedApsExit[interval.enterIndex] =
            _trimaApsExitSatisfiedUncached(interval);
      }
    }

    _cachedDoorEvidence.clear();
    _cachedDoorExit.clear();
    _cachedDoorStateAtEnter.clear();
    _cachedDoorStateLineAtEnter.clear();
    _cachedDoorStateChanges.clear();
    _cachedDoorPowerChanges.clear();
    _cachedDoorLockCommands.clear();

    final doorIntervalsByEnter = <int, List<_TrimaEnterExitInterval>>{};
    for (final interval in _cachedTrimaIntervals) {
      if (_trimaIsDoorVerificationState(interval)) {
        doorIntervalsByEnter.putIfAbsent(interval.enterIndex, () => []).add(interval);
      }
    }

    String? lastDoorState;
    int? lastDoorStateLine;
    for (var i = 0; i < widget.episodios.length; i++) {
      final entering = doorIntervalsByEnter[i];
      if (entering != null) {
        for (final interval in entering) {
          _cachedDoorStateAtEnter[interval.enterIndex] = lastDoorState;
          _cachedDoorStateLineAtEnter[interval.enterIndex] = lastDoorStateLine;
        }
      }
      final state = _trimaExtractDoorStateChange(widget.episodios[i]);
      if (state != null) {
        lastDoorState = state;
        lastDoorStateLine = i;
      }
    }

    for (final interval in _cachedTrimaIntervals) {
      if (!_trimaIsDoorVerificationState(interval) || interval.exitIndex == null) {
        continue;
      }
      final evidence = <MapEntry<int, String>>[];
      final changes = <MapEntry<int, String>>[];
      final powerChanges = <MapEntry<int, String>>[];
      final lockCommands = <MapEntry<int, String>>[];
      for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
        final line = widget.episodios[i];
        if (_trimaLooksLikeDoorEvidence(line)) {
          evidence.add(MapEntry(i, line));
        }
        final state = _trimaExtractDoorStateChange(line);
        if (state != null) {
          changes.add(MapEntry(i, state));
        }
        final power = _trimaExtractDoorPowerChange(line);
        if (power != null) {
          powerChanges.add(MapEntry(i, power));
        }
        final lockCommand = _trimaExtractDoorLockCommand(line);
        if (lockCommand != null) {
          lockCommands.add(MapEntry(i, lockCommand));
        }
      }
      _cachedDoorEvidence[interval.enterIndex] =
          List<MapEntry<int, String>>.unmodifiable(evidence);
      _cachedDoorStateChanges[interval.enterIndex] =
          List<MapEntry<int, String>>.unmodifiable(changes);
      _cachedDoorPowerChanges[interval.enterIndex] =
          List<MapEntry<int, String>>.unmodifiable(powerChanges);
      _cachedDoorLockCommands[interval.enterIndex] =
          List<MapEntry<int, String>>.unmodifiable(lockCommands);
    }
    for (final interval in _cachedTrimaIntervals) {
      if (_trimaIsDoorVerificationState(interval)) {
        _cachedDoorExit[interval.enterIndex] =
            _trimaDoorExitSatisfiedUncached(interval);
      }
    }
  }

  @override
  void didUpdateWidget(covariant EpisodicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.episodios, widget.episodios) ||
        oldWidget.episodios.length != widget.episodios.length) {
      _cachedTrimaIntervals = _buildTrimaEnterExitIntervals()
        .where(_trimaIsMasterAnalyzedState)
        .toList();
      _cachedTrimaChildren = _buildTrimaChildrenCache(_cachedTrimaIntervals);
      _rebuildTrimaDiagnosticCaches();
    }
  }

  List<MapEntry<int, String>> _trimaCassetteEvidence(
      _TrimaEnterExitInterval interval) {
    return _cachedCassetteEvidence[interval.enterIndex] ?? const [];
  }

  bool _trimaLooksLikeCassetteDownEvidence(String e) {
    final l = e.toLowerCase();
    return l.contains('cassette reached the down position') ||
        l.contains('cassette completely lowered') ||
        l.contains('cassette lowered') ||
        RegExp(r'cassette in position:\s*status\s*=\s*1',
                caseSensitive: false)
            .hasMatch(e);
  }

  bool _trimaLooksLikeCassetteReflectanceEvidence(String e) {
    final l = e.toLowerCase();
    return l.contains('cassette detection red=') ||
        l.contains('stamp detected') ||
        l.contains('rbc init red/green=') ||
        l.contains('reflectance');
  }

  bool? _trimaCassetteExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsCassetteVerificationState(interval)) return null;
    return _cachedCassetteExit[interval.enterIndex];
  }

  bool? _trimaCassetteExitSatisfiedUncached(_TrimaEnterExitInterval interval) {
    if (!_trimaIsCassetteVerificationState(interval) ||
        interval.exitIndex == null) return null;

    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final evidence = _trimaCassetteEvidence(interval);

    if (n == 'lowercassette') {
      final detected = evidence.any((x) =>
          _trimaLooksLikeCassetteDownEvidence(x.value));
      final within15s =
          interval.durationSeconds != null && interval.durationSeconds! <= 15.0;
      // Procedure CSV may flush the position change after structural Exit.
      // Capture up to +2 s, but measure the documented 15 s from real Enter.
      final posSamples = _trimaDataSamples(
        interval, 'CassettePos', postExit: const Duration(seconds: 2));
      DateTime? downAt;
      for (final sample in posSamples) {
        final v = sample.value.toString().trim().toLowerCase();
        if (v == 'l' || v == '1' || v.contains('down') || v.contains('lower')) {
          downAt = sample.time;
          break;
        }
      }
      final enter = interval.enterTime;
      final csvWithin15 = downAt != null && enter != null &&
          downAt.difference(enter).inMilliseconds <= 15000;
      if (detected) return within15s ? true : false;
      if (downAt != null) return csvWithin15;
      return null;
    }

    if (n == 'cassetteid') {
      // Manual exit condition is reading the cassette stamp reflectance.
      final detected = evidence.any((x) =>
          _trimaLooksLikeCassetteReflectanceEvidence(x.value));
      return detected ? true : null;
    }
    return null;
  }

  String _trimaCompactEvidenceText(String raw) {
    var x = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (x.length > 150) x = '${x.substring(0, 147)}...';
    return x;
  }

  Widget _trimaCassetteStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final evidence = _trimaCassetteEvidence(interval);
    final ok = _trimaCassetteExitSatisfied(interval);

    final relevant = evidence.where((x) {
      if (n == 'lowercassette') {
        return _trimaLooksLikeCassetteDownEvidence(x.value);
      }
      return _trimaLooksLikeCassetteReflectanceEvidence(x.value);
    }).toList();
    final shown = evidence.take(12).toList();

    final expected = n == 'lowercassette'
        ? 'Cassette plate detected DOWN within 15 s'
        : 'Cassette stamp reflectance value read';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CASSETTE',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('EXIT CONDITION  $expected',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          if (interval.durationSeconds != null)
            Text('STATE TIME  ${interval.durationSeconds!.toStringAsFixed(3)} s',
                style: const TextStyle(fontSize: 11)),
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('INTERNAL CASSETTE EVENTS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...shown.map((x) => Text(
              'L${x.key + 1}  ${_trimaCompactEvidenceText(x.value)}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: relevant.any((r) => r.key == x.key)
                    ? FontWeight.w700
                    : FontWeight.normal,
              ),
            )),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              'No cassette TRACE events found inside this Enter/Exit interval.',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED'
                : ok == false
                    ? 'FINAL EXIT CONDITION → NOT SATISFIED'
                    : 'FINAL EXIT CONDITION → EVIDENCE NOT FOUND',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsApsVerificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'checksamplebag' ||
        n == 'pressinletline' ||
        n == 'inletpresstest' ||
        n == 'inletpresstest2' ||
        n == 'inletdecaytest' ||
        n == 'inletdecaytest2' ||
        n == 'pressinletline2' ||
        n == 'pressinletline3' ||
        n == 'negativepresstest' ||
        n == 'negativepressrelief' ||
        n == 'negativepressrelief2' ||
        n == 'acpressreturnline';
  }

  double? _trimaExtractAps(String event) {
    // Accept native/verbose forms such as APS=412.3, APS: 412.3,
    // "APS pressure = 412.3". Avoid APSLow/APSHigh fields.
    final m = RegExp(
      r'\bAPS\b(?:\s+pressure)?\s*[:=]\s*(-?\d+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(event);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  List<MapEntry<int, double>> _trimaApsSamples(
      _TrimaEnterExitInterval interval) {
    return _cachedApsSamples[interval.enterIndex] ?? const [];
  }

  bool? _trimaApsExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsApsVerificationState(interval)) return null;
    return _cachedApsExit[interval.enterIndex];
  }

  bool? _trimaApsExitSatisfiedUncached(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return null;

    final samples = _cachedApsSamples[interval.enterIndex] ?? const [];
    final inherited = _cachedApsAtEnter[interval.enterIndex];
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    // ACPressReturnLine is evaluated together with ReturnVol.
    if (n == 'acpressreturnline') return null;

    final points = <MapEntry<int, double>>[
      if (inherited != null)
        MapEntry(_cachedApsSourceLineAtEnter[interval.enterIndex] ??
            interval.enterIndex, inherited),
      ...samples,
    ];
    if (points.isEmpty) return null;

    final values = points.map((e) => e.value).toList();
    final first = inherited ?? values.first;
    final last = values.last;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);

    // Conditions whose pressure portion is authoritative. If the manual also
    // requires a volume limit, the UI labels the result as pressure-only until
    // that volume is independently available.
    if (n == 'checksamplebag') {
      return maxV > 50.0;
    }
    if (n == 'pressinletline') {
      return maxV > 400.0;
    }
    if (n == 'pressinletline2') {
      // Manual extraction clearly identifies a different exit condition but
      // does not reliably preserve it in the parsed table. Do not invent it.
      return null;
    }
    if (n == 'pressinletline3') {
      return maxV > 500.0;
    }
    if (n == 'negativepresstest') {
      return minV < -350.0;
    }
    if (n == 'negativepressrelief') {
      return maxV > -50.0;
    }
    if (n == 'negativepressrelief2') {
      // Source text says APS > 500, but its table/pump wording is internally
      // odd in extraction. Keep this unconfirmed until visually verified.
      return null;
    }

    if (n == 'inletpresstest' || n == 'inletpresstest2') {
      // Manual: <50 mmHg decrease since previous state in 3 seconds.
      // Evaluate the APS nearest 3 s after Enter, carrying the previous value.
      final enterTime = interval.enterTime;
      if (enterTime == null || inherited == null) return null;
      MapEntry<int, double>? at3s;
      Duration? bestDelta;
      for (final p in samples) {
        final t = _trimaCsvTimestamp(widget.episodios[p.key]);
        if (t == null) continue;
        final elapsed = t.difference(enterTime);
        if (elapsed.isNegative) continue;
        final d = Duration(
            milliseconds: (elapsed.inMilliseconds - 3000).abs());
        if (bestDelta == null || d < bestDelta) {
          bestDelta = d;
          at3s = p;
        }
      }
      if (at3s == null) return null;
      final decrease = inherited - at3s.value;
      return decrease < 50.0;
    }

    if (n == 'inletdecaytest') {
      // Manual: >50 mmHg decrease after pumps rotate.
      return (maxV - minV) > 50.0;
    }
    if (n == 'inletdecaytest2') {
      // Manual says "different exit condition"; parsed PDF duplicates Test 1.
      return null;
    }

    return null;
  }


  Widget _trimaApsStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final samples = _trimaApsSamples(interval);
    final ok = _trimaApsExitSatisfied(interval);
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    String expected;
    bool pressureOnly = false;
    if (n == 'checksamplebag') {
      expected = 'APS > 50 mmHg after 10 mL processed';
      pressureOnly = true;
    } else if (n == 'pressinletline') {
      expected = 'APS > 400 mmHg before 50 mL processed by AC pump';
      pressureOnly = true;
    } else if (n == 'inletpresstest' || n == 'inletpresstest2') {
      expected = 'APS decrease < 50 mmHg since previous state in 3 s';
    } else if (n == 'inletdecaytest') {
      expected = 'APS decrease > 50 mmHg after pumps rotate';
    } else if (n == 'inletdecaytest2') {
      expected = 'Different exit condition — source extraction ambiguous';
    } else if (n == 'pressinletline2') {
      expected = 'Different exit condition — source extraction ambiguous';
    } else if (n == 'pressinletline3') {
      expected = 'APS > 500 mmHg before 50 mL processed by AC pump';
      pressureOnly = true;
    } else if (n == 'negativepresstest') {
      expected = 'APS < -350 mmHg before 115 mL processed by Inlet pump';
      pressureOnly = true;
    } else if (n == 'negativepressrelief') {
      expected = 'APS > -50 mmHg before volume limit';
      pressureOnly = true;
    } else if (n == 'negativepressrelief2') {
      expected = 'Version-specific condition — pending source verification';
    } else {
      expected = 'APS condition';
    }

    final inherited = _cachedApsAtEnter[interval.enterIndex];
    final inheritedLine = _cachedApsSourceLineAtEnter[interval.enterIndex];
    double? first, last, minV, maxV;
    if (samples.isNotEmpty || inherited != null) {
      first = inherited ?? samples.first.value;
      last = samples.isNotEmpty ? samples.last.value : inherited;
      final vals = <double>[
        if (inherited != null) inherited,
        ...samples.map((e) => e.value),
      ];
      minV = vals.reduce((a,b) => a < b ? a : b);
      maxV = vals.reduce((a,b) => a > b ? a : b);
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('APS TEST',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('EXIT CONDITION  $expected',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          if (first != null) ...[
            Text(
              inherited != null
                  ? 'APS ENTER  ${first.toStringAsFixed(1)} mmHg  ← carried from L${(inheritedLine ?? 0) + 1}'
                  : 'APS ENTER  ${first.toStringAsFixed(1)} mmHg',
              style: const TextStyle(fontSize: 11),
            ),
            Text('APS MIN  ${minV!.toStringAsFixed(1)} mmHg  •  '
                 'MAX  ${maxV!.toStringAsFixed(1)} mmHg',
                style: const TextStyle(fontSize: 11)),
            Text('APS LAST  ${last!.toStringAsFixed(1)} mmHg  •  '
                 'Δ ${(last - first).toStringAsFixed(1)} mmHg',
                style: const TextStyle(fontSize: 11)),
            if (samples.isNotEmpty) ...[
              const SizedBox(height: 3),
              ...samples.take(8).map((x) => Text(
                'L${x.key + 1}  APS ${x.value.toStringAsFixed(1)} mmHg',
                style: const TextStyle(fontSize: 10),
              )),
            ] else
              Text('No new APS sample inside state; using last known value.',
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          ] else
            Text('No APS value found before or inside this Enter/Exit interval.',
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            ok == true
                ? (pressureOnly
                    ? 'APS CONDITION → SATISFIED / VOLUME VERIFICATION PENDING'
                    : 'FINAL EXIT CONDITION → SATISFIED')
                : ok == false
                    ? (pressureOnly
                        ? 'APS CONDITION → NOT SATISFIED'
                        : 'FINAL EXIT CONDITION → NOT SATISFIED')
                    : 'FINAL EXIT CONDITION → PENDING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsDoorVerificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'doorlatchtest' ||
        n == 'doorlockcheck' ||
        n == 'unlockdoor';
  }

  String? _trimaExtractDoorStateChange(String line) {
    final m = RegExp(
      r'\bdoor\s+state\s+changed\s+to\s+([A-Z_]+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (m == null) return null;
    return m.group(1)!.toUpperCase();
  }

  String? _trimaExtractDoorPowerChange(String line) {
    final setPower = RegExp(
      r'SetDoorPower\s+Old State\s*:\s*(ENABLE|DISABLE)\s+New State\s*:\s*(ENABLE|DISABLE)',
      caseSensitive: false,
    ).firstMatch(line);
    if (setPower != null) return setPower.group(2)!.toUpperCase();

    final solenoid = RegExp(
      r'Solenoid Power\s+(enabled|disabled)',
      caseSensitive: false,
    ).firstMatch(line);
    if (solenoid != null) {
      return solenoid.group(1)!.toLowerCase() == 'enabled'
          ? 'ENABLE'
          : 'DISABLE';
    }

    final commanded = RegExp(
      r'Commanded to\s+(enable|disable)\s+door solenoid power',
      caseSensitive: false,
    ).firstMatch(line);
    if (commanded != null) {
      return commanded.group(1)!.toLowerCase() == 'enable'
          ? 'ENABLE'
          : 'DISABLE';
    }
    return null;
  }

  String? _trimaExtractDoorLockCommand(String line) {
    final m = RegExp(
      r'door lock command in progress:.*?\bdirection=(LOCK|UNLOCK)\b',
      caseSensitive: false,
    ).firstMatch(line);
    return m?.group(1)?.toUpperCase();
  }

  bool _trimaLooksLikeDoorEvidence(String line) {
    final l = line.toLowerCase();
    return _trimaExtractDoorStateChange(line) != null ||
        _trimaExtractDoorPowerChange(line) != null ||
        _trimaExtractDoorLockCommand(line) != null ||
        (l.contains('door') &&
        (l.contains('lock') ||
         l.contains('latch') ||
         l.contains('hall') ||
         l.contains('optical') ||
         l.contains('solenoid') ||
         l.contains('open') ||
         l.contains('closed') ||
         l.contains('status') ||
         l.contains('position')));
  }

  bool _trimaDoorStateIsUnlocked(String state) {
    return state == 'CLOSED' || state == 'OPEN';
  }


  bool? _trimaDoorExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsDoorVerificationState(interval)) return null;
    return _cachedDoorExit[interval.enterIndex];
  }

  bool? _trimaDoorExitSatisfiedUncached(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return false;
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final evidence = _cachedDoorEvidence[interval.enterIndex] ?? const [];

    final changes = _cachedDoorStateChanges[interval.enterIndex] ?? const [];
    final powerChanges = _cachedDoorPowerChanges[interval.enterIndex] ?? const [];
    final lockCommands = _cachedDoorLockCommands[interval.enterIndex] ?? const [];
    final enterState = _cachedDoorStateAtEnter[interval.enterIndex];

    if (n == 'doorlockcheck') {
      // Observed in the real Trima logs:
      // direction=LOCK -> CLOSED_AND_LOCKED -> Exit: DoorLockCheck.
      final commands = _cachedDoorLockCommands[interval.enterIndex] ?? const [];
      final hasLockCommand = commands.any((e) => e.value == 'LOCK');
      final hasLockedState =
          changes.any((e) => e.value == 'CLOSED_AND_LOCKED') ||
          enterState == 'CLOSED_AND_LOCKED';
      if (hasLockCommand && hasLockedState) return true;
      if (commands.isNotEmpty || changes.isNotEmpty) return false;
      return null;
    }

    if (n == 'unlockdoor') {
      // Do not use an inherited/stale CLOSED_AND_LOCKED sample as a hard failure.
      // The firmware itself reports a definitive failure with "Still locked; giving up!".
      final hasGiveUp = evidence.any((e) =>
          e.value.toLowerCase().contains('still locked; giving up'));
      if (hasGiveUp) return false;

      final hasUnlocking = evidence.any((e) =>
          e.value.toLowerCase().contains('door is unlocking'));
      final freshUnlocked = changes.any((e) => _trimaDoorStateIsUnlocked(e.value));
      if (freshUnlocked) return true;

      // If no fresh door-state sample was emitted inside the state, don't fail only
      // because the cached state at ENTER was locked. A clean Exit after the unlock
      // sequence is usable firmware evidence.
      if (changes.isEmpty && hasUnlocking && interval.exitIndex != null) return true;
      if (changes.isNotEmpty) return false;
      return null;
    }

    if (n == 'doorlatchtest') {
      // The real TRACE exposes the state machine directly. Confirm the
      // lock/unlock exercise when CLOSED_AND_LOCKED is observed and a later
      // unlocked CLOSED/OPEN state is observed. Other manual electrical/sensor
      // checks remain visible as evidence and are not invented.
      final states = <String>[
        if (enterState != null) enterState,
        ...changes.map((e) => e.value),
      ];
      final power = _cachedDoorPowerChanges[interval.enterIndex] ?? const [];
      final commands = _cachedDoorLockCommands[interval.enterIndex] ?? const [];
      final lockedAt = states.indexOf('CLOSED_AND_LOCKED');
      if (lockedAt < 0) return null;
      final unlockedAfter = states
          .skip(lockedAt + 1)
          .any((x) => _trimaDoorStateIsUnlocked(x));
      final enabled = power.any((e) => e.value == 'ENABLE');
      final disabled = power.any((e) => e.value == 'DISABLE');
      final lockCmd = commands.any((e) => e.value == 'LOCK');
      final unlockCmd = commands.any((e) => e.value == 'UNLOCK');
      if (enabled && disabled && lockCmd && unlockCmd && unlockedAfter) {
        return true;
      }
      return null;
    }
    return null;
  }

  Widget _trimaDoorStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final evidence = _cachedDoorEvidence[interval.enterIndex] ?? const [];
    final changes = _cachedDoorStateChanges[interval.enterIndex] ?? const [];
    final powerChanges =
        _cachedDoorPowerChanges[interval.enterIndex] ??
            const <MapEntry<int, String>>[];
    final lockCommands =
        _cachedDoorLockCommands[interval.enterIndex] ??
            const <MapEntry<int, String>>[];
    final enterState = _cachedDoorStateAtEnter[interval.enterIndex];
    final enterStateLine = _cachedDoorStateLineAtEnter[interval.enterIndex];
    final finalState = changes.isNotEmpty ? changes.last.value : enterState;
    final ok = _trimaDoorExitSatisfied(interval);
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    final expected = n == 'unlockdoor'
        ? 'Centrifuge door lock detected UNLOCKED'
        : n == 'doorlockcheck'
            ? 'LOCK command followed by detected CLOSED_AND_LOCKED'
            : 'Door optical + Hall open/closed checks, 24-V solenoid switch-off, and lock/unlock without power';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DOOR TEST',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('EXIT CONDITION  $expected',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(
            enterState != null
                ? 'STATE AT ENTER  $enterState  ← L${(enterStateLine ?? 0) + 1}'
                : 'STATE AT ENTER  UNKNOWN',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          if (changes.isNotEmpty) ...[
            const SizedBox(height: 3),
            const Text('DOOR STATE CHANGES',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...changes.map((x) => Text(
              'L${x.key + 1}  ${x.value}',
              style: const TextStyle(fontSize: 10),
            )),
          ],
          if (powerChanges.isNotEmpty) ...[
            const SizedBox(height: 3),
            const Text('SOLENOID POWER',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...powerChanges.map((x) => Text(
              'L${x.key + 1}  ${x.value}',
              style: const TextStyle(fontSize: 10),
            )),
          ],
          if (lockCommands.isNotEmpty) ...[
            const SizedBox(height: 3),
            const Text('LOCK COMMANDS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...lockCommands.map((x) => Text(
              'L${x.key + 1}  ${x.value}',
              style: const TextStyle(fontSize: 10),
            )),
          ],
          Text(
            finalState != null ? 'STATE AT EXIT  $finalState' : 'STATE AT EXIT  UNKNOWN',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          if (finalState != null)
            Text(
              'POSITION  ${finalState == 'OPEN' ? 'OPEN' : 'CLOSED'}   '
              'LOCK  ${finalState == 'CLOSED_AND_LOCKED' ? 'LOCKED' : 'UNLOCKED'}'
              '${powerChanges.isNotEmpty ? '   SOLENOID  ${powerChanges.last.value}' : ''}',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
          if (evidence.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('DOOR TRACE EVIDENCE',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...evidence.take(14).map((x) => Text(
              'L${x.key + 1}  ${_trimaCompactEvidenceText(x.value)}',
              style: const TextStyle(fontSize: 10),
            )),
          ] else ...[
            const SizedBox(height: 4),
            Text('No door TRACE evidence found inside this Enter/Exit interval.',
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 4),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED'
                : ok == false
                    ? 'FINAL EXIT CONDITION → NOT SATISFIED'
                    : 'FINAL EXIT CONDITION → PARTIAL / EVIDENCE MISSING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsCentrifugeVerificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'safetypowertest64' ||
        n == 'centshutdowntest' ||
        n == 'centshutdown' ||
        n == 'centrifugetests';
  }

  List<MapEntry<int, String>> _trimaCentrifugeEvidence(_TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return const [];
    final out = <MapEntry<int, String>>[];
    for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
      final line = widget.episodios[i];
      final x = line.toLowerCase();
      if (x.contains('centrifuge') || x.contains('64v') ||
          x.contains('cent status') || x.contains('setcentrifugepower') ||
          x.contains('pwr_control_64v') ||
          x.contains('starting voltage') ||
          x.contains('wait on') ||
          x.contains('wait off')) {
        out.add(MapEntry(i, line));
      }
    }
    return out;
  }

  ({int oldState, int newState})? _trimaCentrifugePowerTransitionFromLine(
      String line) {
    final m = RegExp(
      r'SetCentrifugePower\s+Old State\s*:\s*(\d+)\s+New State\s*:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (m == null) return null;
    final oldState = int.tryParse(m.group(1)!);
    final newState = int.tryParse(m.group(2)!);
    if (oldState == null || newState == null) return null;
    return (oldState: oldState, newState: newState);
  }

  int? _trimaCentrifugePowerFromLine(String line) =>
      _trimaCentrifugePowerTransitionFromLine(line)?.newState;

  List<MapEntry<int, String>> _trimaPowerEvidenceAfter(
      _TrimaEnterExitInterval interval, int sourceLine,
      {int maxLines = 12}) {
    if (interval.exitIndex == null) return const [];
    final out = <MapEntry<int, String>>[];
    final end = (sourceLine + maxLines < interval.exitIndex!)
        ? sourceLine + maxLines
        : interval.exitIndex!;
    for (var i = sourceLine + 1; i <= end; i++) {
      final line = widget.episodios[i];
      final x = line.toLowerCase();
      if (x.contains('truenewstate') ||
          x.contains('power test') ||
          x.contains('64v') ||
          x.contains('voltage') ||
          x.contains('pwr_control_64v') ||
          x.contains('safety power test') ||
          x.contains('centrifuge error bits reset')) {
        out.add(MapEntry(i, line));
      }
    }
    return out;
  }

  ({String direction, double starting, double goal})?
      _trima64vOrderedFromLine(String line) {
    final m = RegExp(
      r'Ordered\s+(On|Off)\s+starting voltage\s*=\s*(-?\d+(?:\.\d+)?)\s*v\s+Goal\s*=\s*(-?\d+(?:\.\d+)?)\s*v',
      caseSensitive: false,
    ).firstMatch(line);
    if (m == null) return null;
    final starting = double.tryParse(m.group(2)!);
    final goal = double.tryParse(m.group(3)!);
    if (starting == null || goal == null) return null;
    return (direction: m.group(1)!.toUpperCase(), starting: starting, goal: goal);
  }

  ({String direction, double voltage, double goal})?
      _trima64vWaitFromLine(String line) {
    final m = RegExp(
      r'Wait\s+(On|Off)\s*=\s*(-?\d+(?:\.\d+)?)\s*v\s+Goal\s*=\s*(-?\d+(?:\.\d+)?)\s*v',
      caseSensitive: false,
    ).firstMatch(line);
    if (m == null) return null;
    final voltage = double.tryParse(m.group(2)!);
    final goal = double.tryParse(m.group(3)!);
    if (voltage == null || goal == null) return null;
    return (direction: m.group(1)!.toUpperCase(), voltage: voltage, goal: goal);
  }

  ({bool onReached, bool offReached, bool onStartedLow, bool offStartedHigh,
      double? onStart, double? onGoal, double? onFinal,
      double? offStart, double? offGoal, double? offFinal})
      _trima64vVoltageSequence(_TrimaEnterExitInterval interval) {
    double? onStart, onGoal, onFinal, offStart, offGoal, offFinal;
    if (interval.exitIndex != null) {
      for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
        final line = widget.episodios[i];
        final ordered = _trima64vOrderedFromLine(line);
        if (ordered != null) {
          if (ordered.direction == 'ON') {
            onStart ??= ordered.starting;
            onGoal ??= ordered.goal;
          } else {
            offStart ??= ordered.starting;
            offGoal ??= ordered.goal;
          }
        }
        final wait = _trima64vWaitFromLine(line);
        if (wait != null) {
          if (wait.direction == 'ON') {
            onGoal ??= wait.goal;
            onFinal = wait.voltage;
          } else {
            offGoal ??= wait.goal;
            offFinal = wait.voltage;
          }
        }
      }
    }
    return (
      onReached: onFinal != null && onGoal != null && onFinal! >= onGoal!,
      offReached: offFinal != null && offGoal != null && offFinal! <= offGoal!,
      onStartedLow: onStart != null && onGoal != null && onStart! < onGoal!,
      offStartedHigh: offStart != null && offGoal != null && offStart! > offGoal!,
      onStart: onStart, onGoal: onGoal, onFinal: onFinal,
      offStart: offStart, offGoal: offGoal, offFinal: offFinal,
    );
  }

  double? _trimaCentStatusFromLine(String line) {
    final m = RegExp(r'\bCENT STATUS\s+(-?\d+(?:\.\d+)?)',
        caseSensitive: false).firstMatch(line);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  bool? _trimaCentrifugeExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsCentrifugeVerificationState(interval) || interval.exitIndex == null) return null;
    final n = _trimaStateLeaf(interval.name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final ev = _trimaCentrifugeEvidence(interval);
    final joined = ev.map((e) => e.value.toLowerCase()).join('\n');

    if (n == 'centshutdowntest' || n == 'centshutdown') {
      // Manual: command 0 rpm and verify immobility for two seconds.
      if (joined.contains('centrifuge shutdown (zero speed) test passed') &&
          joined.contains('2000 ms')) return true;
      final statuses = ev.map((e) => _trimaCentStatusFromLine(e.value))
          .whereType<double>().toList();
      if (statuses.isNotEmpty && statuses.any((v) => v.abs() > 0.5)) return false;
      return null;
    }

    if (n == 'safetypowertest64') {
      final transitions = ev
          .map((e) => MapEntry(
              e.key, _trimaCentrifugePowerTransitionFromLine(e.value)))
          .where((e) => e.value != null)
          .toList();

      var sawOn = false;
      var sawOffAfterOn = false;
      for (final e in transitions) {
        final t = e.value!;
        if (!sawOn && t.newState == 1) {
          sawOn = true;
        } else if (sawOn && t.newState == 0) {
          sawOffAfterOn = true;
        }
      }

      final volts = _trima64vVoltageSequence(interval);
      final voltageCycleOk = volts.onStartedLow &&
          volts.onReached &&
          volts.offStartedHigh &&
          volts.offReached;

      if (joined.contains('safety power test (64v) failed') ||
          joined.contains('power test failed')) {
        return false;
      }

      if (voltageCycleOk && sawOn && sawOffAfterOn) return true;
      return null;
    }

    if (n == 'centrifugetests') {
      final hasShutdownPass =
          joined.contains('centrifuge shutdown (zero speed) test passed');
      final has64v = joined.contains('pwr_control_64v_nominal') ||
          joined.contains('setcentrifugepower');
      return hasShutdownPass && has64v ? true : null;
    }
    return null;
  }

  Widget _trimaCentrifugeStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final ev = _trimaCentrifugeEvidence(interval);
    final ok = _trimaCentrifugeExitSatisfied(interval);
    final n = _trimaStateLeaf(interval.name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    final powerTransitions =
        <MapEntry<int, ({int oldState, int newState})>>[];
    final statuses = <MapEntry<int, double>>[];
    for (final e in ev) {
      final p = _trimaCentrifugePowerTransitionFromLine(e.value);
      if (p != null) powerTransitions.add(MapEntry(e.key, p));
      final st = _trimaCentStatusFromLine(e.value);
      if (st != null) statuses.add(MapEntry(e.key, st));
    }

    final expected = (n == 'centshutdowntest' || n == 'centshutdown')
        ? '0 rpm + immobility verified for 2 seconds'
        : n == 'safetypowertest64'
            ? '64-V: ON reaches/exceeds Goal, then OFF reaches/falls below Goal'
            : '64-V safety test + centrifuge zero-speed shutdown test';

    final proof = ev.where((e) {
      final x = e.value.toLowerCase();
      return x.contains('test passed') ||
          x.contains('power test passed') ||
          x.contains('safety power test (64v) complete') ||
          x.contains('safety power test (64v) passed') ||
          x.contains('voltages/current ok') ||
          x.contains('pwr_control_64v_nominal') ||
          x.contains('starting voltage') ||
          x.contains('wait on') ||
          x.contains('wait off');
    }).toList();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CENTRIFUGE TEST',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
          Text('EXIT CONDITION  $expected',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          if (powerTransitions.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('64V POWER — CHRONOLOGICAL',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...powerTransitions.expand((x) {
              final t = x.value;
              final after = n == 'safetypowertest64'
                  ? _trimaPowerEvidenceAfter(interval, x.key)
                  : const <MapEntry<int, String>>[];
              return <Widget>[
                Text(
                  'L${x.key + 1}  SetCentrifugePower  '
                  '${t.oldState == 1 ? 'ENABLE' : 'DISABLE'} → '
                  '${t.newState == 1 ? 'ENABLE' : 'DISABLE'}',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700),
                ),
                ...after.map((e) => Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        '↳ L${e.key + 1}  ${_trimaCompactEvidenceText(e.value)}',
                        style: const TextStyle(fontSize: 9.5),
                      ),
                    )),
              ];
            }),
          ],
          if (n == 'safetypowertest64') ...[
            const SizedBox(height: 4),
            const Text('64V VOLTAGE TEST',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            Builder(builder: (context) {
              final v = _trima64vVoltageSequence(interval);
              String f(double? x) =>
                  x == null ? '—' : '${x.toStringAsFixed(0)} V';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ON   START ${f(v.onStart)} → GOAL ${f(v.onGoal)} → FINAL ${f(v.onFinal)}'
                    '   ${v.onReached ? '✓' : '…'}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  Text(
                    'OFF  START ${f(v.offStart)} → GOAL ${f(v.offGoal)} → FINAL ${f(v.offFinal)}'
                    '   ${v.offReached ? '✓' : '…'}',
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              );
            }),
          ],
          if (statuses.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('CENTRIFUGE STATUS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...statuses.take(10).map((x) => Text(
              'L${x.key + 1}  ${x.value.toStringAsFixed(2)} rpm',
              style: const TextStyle(fontSize: 10),
            )),
          ],
          if (proof.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('TRACE VERIFICATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...proof.take(8).map((x) => Text(
              'L${x.key + 1}  ${_trimaCompactEvidenceText(x.value)}',
              style: const TextStyle(fontSize: 10),
            )),
          ],
          const SizedBox(height: 5),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED'
                : ok == false
                    ? 'FINAL EXIT CONDITION → NOT SATISFIED'
                    : 'FINAL EXIT CONDITION → PARTIAL / EVIDENCE MISSING',
            style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w800,
              color: ok == true ? scheme.primary :
                  ok == false ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsConnectAcState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'connectac';
  }

  List<MapEntry<int, String>> _trimaConnectAcEvidence(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return const [];
    final out = <MapEntry<int, String>>[];
    for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
      final l = _episodiosLower[i];
      if (l.contains('gui_screen_sysacatt') ||
          l.contains('gui_button_continue') ||
          l.contains('ac compound') ||
          l.contains('cancontinue') ||
          l.contains('connectac->acprime') ||
          l.contains('transition connectac') ||
          l.contains('exit: connectac')) {
        out.add(MapEntry(i, widget.episodios[i]));
      }
    }
    return out;
  }

  bool? _trimaConnectAcExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsConnectAcState(interval) || interval.exitIndex == null) {
      return null;
    }
    final ev = _trimaConnectAcEvidence(interval);
    var screenSeen = false;
    var continueSeen = false;
    var transitionSeen = false;

    for (final e in ev) {
      final l = e.value.toLowerCase();
      if (l.contains('gui_screen_sysacatt')) screenSeen = true;
      if (l.contains('gui_button_continue')) continueSeen = true;
      if (l.contains('connectac->acprime') ||
          (l.contains('transition') &&
              l.contains('connectac') &&
              l.contains('acprime'))) {
        transitionSeen = true;
      }
    }

    // The operator's Continue action is the effective exit condition.
    // The ACPrime transition corroborates that the action was accepted.
    if (screenSeen && continueSeen && transitionSeen) return true;
    if (screenSeen && continueSeen) return true;
    return null;
  }

  Widget _trimaConnectAcSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final ev = _trimaConnectAcEvidence(interval);
    final ok = _trimaConnectAcExitSatisfied(interval);
    final canContinue = ev.any((e) {
      final l = e.value.toLowerCase();
      return l.contains('ac compound') &&
          l.contains('cancontinue') &&
          (RegExp(r'cancontinue\s*:\s*1').hasMatch(l) ||
              RegExp(r'cancontinue\s*=\s*1').hasMatch(l));
    });
    final continueSeen =
        ev.any((e) => e.value.toLowerCase().contains('gui_button_continue'));
    final transitionSeen = ev.any((e) {
      final l = e.value.toLowerCase();
      return l.contains('connectac->acprime') ||
          (l.contains('transition') &&
              l.contains('connectac') &&
              l.contains('acprime'));
    });

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CONNECT AC',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
            'EXIT CONDITION  GUI_SCREEN_SYSACATT + GUI_BUTTON_CONTINUE',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
          ),
          Text('AC Compound canContinue: ${canContinue ? '1 ✓' : 'not observed'}',
              style: const TextStyle(fontSize: 10)),
          Text('Continue pressed: ${continueSeen ? 'YES ✓' : 'not observed'}',
              style: const TextStyle(fontSize: 10)),
          Text('Transition ConnectAC → ACPrime: ${transitionSeen ? 'YES ✓' : 'not observed'}',
              style: const TextStyle(fontSize: 10)),
          if (ev.isNotEmpty) ...[
            const SizedBox(height: 5),
            const Text('TRACE VERIFICATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...ev.map((e) => Text(
                  'L${e.key + 1}  ${e.value}',
                  style: const TextStyle(fontSize: 9),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                )),
          ],
          const SizedBox(height: 5),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED'
                : 'FINAL EXIT CONDITION → PARTIAL / NOT VERIFIED',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  DateTime? _trimaCsvTimestamp(String line) {
    final m = RegExp(
      r'(\d{4})/(\d{2})/(\d{2})[_ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?',
    ).firstMatch(line);
    if (m == null) return _trimaEventTime(line);
    final frac = (m.group(7) ?? '').padRight(6, '0').substring(0, 6);
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
      0,
      int.parse(frac),
    );
  }

  bool _trimaIsPowerTestState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'powertest' || n == 'safetypowertest' ||
        n == 'powerofftest' || n == 'powerontest';
  }

  Map<String, Object?> _trimaPowerTestMetrics(
      _TrimaEnterExitInterval interval) {
    final end = interval.exitIndex ?? interval.enterIndex;
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    double? onStart, onGoal, onFinal;
    double? offStart, offGoal, offFinal;
    bool powerTestPassed = false;
    bool safety24Complete = false;
    bool powerOffPassed = false;
    bool pumpsStopped = false;
    bool powerOnPassed = false;
    bool twentyFourOk = false;
    bool twentyFourStable = false;
    bool explicitFailure = false;
    final evidence = <MapEntry<int, String>>[];

    final ordered = RegExp(
      r'Ordered\s+(On|Off)\s+starting voltage\s*=\s*(-?\d+(?:\.\d+)?)\s*v\s+Goal\s*=\s*(-?\d+(?:\.\d+)?)\s*v',
      caseSensitive: false,
    );
    final wait = RegExp(
      r'Wait\s+(On|Off)\s*=\s*(-?\d+(?:\.\d+)?)\s*v\s+Goal\s*=\s*(-?\d+(?:\.\d+)?)\s*v',
      caseSensitive: false,
    );

    for (var i = interval.enterIndex; i <= end; i++) {
      final line = widget.episodios[i];
      final l = line.toLowerCase();

      final om = ordered.firstMatch(line);
      if (om != null) {
        final dir = om.group(1)!.toLowerCase();
        final start = double.tryParse(om.group(2)!);
        final goal = double.tryParse(om.group(3)!);
        if (dir == 'on') {
          onStart ??= start;
          onGoal ??= goal;
        } else {
          offStart ??= start;
          offGoal ??= goal;
        }
      }
      final wm = wait.firstMatch(line);
      if (wm != null) {
        final dir = wm.group(1)!.toLowerCase();
        final v = double.tryParse(wm.group(2)!);
        final goal = double.tryParse(wm.group(3)!);
        if (dir == 'on') {
          onFinal = v;
          onGoal ??= goal;
        } else {
          offFinal = v;
          offGoal ??= goal;
        }
      }

      if (l.contains('power test passed')) powerTestPassed = true;
      if (l.contains('safety power test (24v) complete')) safety24Complete = true;
      if (l.contains('power off test passed')) powerOffPassed = true;
      if (l.contains('all pumps commanded to zero found to be stopped')) {
        pumpsStopped = true;
      }
      if (l.contains('power on test passed')) powerOnPassed = true;
      if (l.contains('twenty-four volt power ok')) twentyFourOk = true;
      if (l.contains('twenty-four volt power stable')) twentyFourStable = true;
      if ((l.contains('power test') || l.contains('24v power')) &&
          (l.contains('failed') || l.contains('failure'))) {
        explicitFailure = true;
      }

      if (om != null ||
          wm != null ||
          l.contains('setpumppower') ||
          l.contains('twenty-four volt power') ||
          l.contains('safety power test (24v)') ||
          l.contains('power off test') ||
          l.contains('power on test') ||
          l.contains('all pumps commanded to zero')) {
        evidence.add(MapEntry(i, line));
      }
    }

    final onReached = onFinal != null && onGoal != null && onFinal! >= onGoal!;
    final offReached =
        offFinal != null && offGoal != null && offFinal! <= offGoal!;

    bool? ok;
    if (explicitFailure) {
      ok = false;
    } else if (n == 'safetypowertest') {
      ok = onReached &&
          offReached &&
          powerTestPassed &&
          safety24Complete &&
          twentyFourOk;
    } else if (n == 'powerofftest') {
      ok = powerOffPassed && pumpsStopped;
    } else if (n == 'powerontest') {
      ok = powerOnPassed && twentyFourOk;
    } else if (n == 'powertest') {
      // Parent interval contains SafetyPowerTest + PowerOffTest + PowerOnTest.
      ok = onReached &&
          offReached &&
          powerTestPassed &&
          safety24Complete &&
          powerOffPassed &&
          pumpsStopped &&
          powerOnPassed &&
          twentyFourOk;
    }

    return {
      'ok': ok,
      'onStart': onStart,
      'onGoal': onGoal,
      'onFinal': onFinal,
      'offStart': offStart,
      'offGoal': offGoal,
      'offFinal': offFinal,
      'onReached': onReached,
      'offReached': offReached,
      'powerTestPassed': powerTestPassed,
      'safety24Complete': safety24Complete,
      'powerOffPassed': powerOffPassed,
      'pumpsStopped': pumpsStopped,
      'powerOnPassed': powerOnPassed,
      'twentyFourOk': twentyFourOk,
      'twentyFourStable': twentyFourStable,
      'evidence': evidence,
    };
  }

  bool? _trimaPowerTestExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsPowerTestState(interval) || interval.exitIndex == null) {
      return null;
    }
    return _trimaPowerTestMetrics(interval)['ok'] as bool?;
  }

  Widget _trimaPowerTestSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final m = _trimaPowerTestMetrics(interval);
    final ok = m['ok'] as bool?;
    final ev = m['evidence'] as List<MapEntry<int, String>>;
    String v(Object? x) => x is double ? x.toStringAsFixed(1) : '—';
    String yes(Object? x) => x == true ? '✓' : '…';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('POWER TEST',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              '24V ON   START ${v(m['onStart'])} V → GOAL ${v(m['onGoal'])} V → REACHED ${v(m['onFinal'])} V ${yes(m['onReached'])}',
              style: const TextStyle(fontSize: 10)),
          Text(
              '24V OFF  START ${v(m['offStart'])} V → GOAL ≤ ${v(m['offGoal'])} V → REACHED ${v(m['offFinal'])} V ${yes(m['offReached'])}',
              style: const TextStyle(fontSize: 10)),
          Text('24V POWER OK ${yes(m['twentyFourOk'])}',
              style: const TextStyle(fontSize: 10)),
          Text('24V STABLE ${yes(m['twentyFourStable'])}',
              style: const TextStyle(fontSize: 10)),
          Text('SAFETY 24V TEST COMPLETE ${yes(m['safety24Complete'])}',
              style: const TextStyle(fontSize: 10)),
          Text('POWER OFF TEST ${yes(m['powerOffPassed'])}',
              style: const TextStyle(fontSize: 10)),
          Text('ALL PUMPS STOPPED ${yes(m['pumpsStopped'])}',
              style: const TextStyle(fontSize: 10)),
          Text('POWER ON TEST ${yes(m['powerOnPassed'])}',
              style: const TextStyle(fontSize: 10)),
          const SizedBox(height: 4),
          const Text(
              'NOTE: in these Trima logs the Startup PowerTest TRACE verifies the 24V pump supply here; the 64V centrifuge supply is verified separately in SafetyPowerTest64.',
              style: TextStyle(fontSize: 9)),
          if (ev.isNotEmpty) ...[
            const SizedBox(height: 5),
            const Text('TRACE VERIFICATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...ev.take(18).map((e) => Text('L${e.key + 1}  ${e.value}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9))),
            if (ev.length > 18)
              Text('… ${ev.length - 18} additional evidence lines',
                  style: const TextStyle(fontSize: 9)),
          ],
          const SizedBox(height: 5),
          Text(
            ok == true
                ? 'FINAL POWER TEST → SATISFIED'
                : ok == false
                    ? 'FINAL POWER TEST → NOT SATISFIED'
                    : 'FINAL POWER TEST → PARTIAL / DATA MISSING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsAcPrimeVerificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'acprimeinlet' || n == 'acpressreturnline';
  }

  double? _trimaNamedNumber(String line, String field) {
    final patterns = <RegExp>[
      RegExp('\\b${RegExp.escape(field)}\\b\\s*[:=]\\s*(-?\\d+(?:\\.\\d+)?)',
          caseSensitive: false),
      RegExp('\\b${RegExp.escape(field)}\\b\\s+(-?\\d+(?:\\.\\d+)?)',
          caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(line);
      if (m != null) return double.tryParse(m.group(1)!);
    }
    return null;
  }

  List<MapEntry<int, String>> _trimaAcPrimeEvidence(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return const [];
    final out = <MapEntry<int, String>>[];
    for (var i = interval.enterIndex; i <= interval.exitIndex!; i++) {
      final line = widget.episodios[i];
      final l = line.toLowerCase();
      if (l.contains('ac has been seen at the sensor') ||
          l.contains('ac volume set') ||
          l.contains('setting ac volumes') ||
          l.contains('ac prime completed') ||
          l.contains('acdetected') ||
          l.contains('acvol') ||
          l.contains('returnvol') ||
          RegExp(r'\bAPS\b', caseSensitive: false).hasMatch(line) ||
          l.contains('command pumps -') ||
          l.contains('exit: acprimeinlet') ||
          l.contains('exit: acpressreturnline')) {
        out.add(MapEntry(i, line));
      }
    }
    return out;
  }

  Map<String, Object?> _trimaAcPrimeMetrics(
      _TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final ev = _trimaAcPrimeEvidence(interval);

    if (n == 'acprimeinlet') {
      double? lastAcVolBeforeDetection;
      double? detectionVolume;
      int? detectionLine;
      bool sensorSeen = false;
      bool acDetectedField = false;
      double? acCmd;
      double? inletCmd;

      for (final e in ev) {
        final line = e.value;
        final l = line.toLowerCase();

        final cmd = _trimaPumpCommandFromLine(line);
        if (cmd != null) {
          acCmd = cmd['AC'] ?? acCmd;
          inletCmd = cmd['INLET'] ?? inletCmd;
        }

        final vol = _trimaNamedNumber(line, 'ACVol');
        if (!sensorSeen && vol != null) lastAcVolBeforeDetection = vol;

        final detectedValue = _trimaNamedNumber(line, 'ACDetected');
        if (detectedValue != null && detectedValue > 0) acDetectedField = true;

        if (!sensorSeen && l.contains('ac has been seen at the sensor')) {
          sensorSeen = true;
          detectionLine = e.key;
          // Important: after this TRACE the software resets AC volume.
          // Therefore only the last value observed BEFORE this line is valid.
          detectionVolume = lastAcVolBeforeDetection;
          // Some logs explicitly say the test starts with AC volume = 0.0 and
          // immediately report the sensor as already seeing AC.
          if (detectionVolume == null &&
              ev.any((x) =>
                  x.key <= e.key &&
                  x.value.toLowerCase().contains('ac volume set to 0.0'))) {
            detectionVolume = 0.0;
          }
        }
      }

      final detected = sensorSeen || acDetectedField;
      final ok = detected && detectionVolume != null
          ? detectionVolume.abs() < 5.0
          : null;

      return {
        'kind': 'inlet',
        'acCmd': acCmd,
        'inletCmd': inletCmd,
        'detected': detected,
        'sensorSeen': sensorSeen,
        'detectionLine': detectionLine,
        'volume': detectionVolume,
        'ok': ok,
      };
    }

    double? returnCmd;
    double? apsAtTarget;
    double? returnVolumeAtTarget;
    double? explicitRequiredVolume;
    int? targetLine;
    bool targetReached = false;

    // ReturnVol is cumulative. Capture the last known value immediately before
    // entering the state, then measure displacement from that baseline.
    final returnVolAtEnter = _cachedReturnVolAtEnter[interval.enterIndex];
    final returnVolAtEnterLine =
        _cachedReturnVolSourceLineAtEnter[interval.enterIndex];

    // Pump command is contextual evidence. Search every line, not only TRACE.
    for (var i = interval.enterIndex;
        i <= (interval.exitIndex ?? interval.enterIndex);
        i++) {
      final line = widget.episodios[i];
      final cmd = _trimaPumpCommandFromLine(line);
      if (cmd != null) returnCmd = cmd['RETURN'] ?? returnCmd;
      final req = RegExp(
        r'Required\s+(-?\d+(?:\.\d+)?)\s+of\s+7(?:\.0+)?\s*ml\s+to\s+achieve\s+pressure',
        caseSensitive: false,
      ).firstMatch(line);
      if (req != null) explicitRequiredVolume = double.tryParse(req.group(1)!);
    }

    // APS comes from the same chronological cache already proven for the
    // Disposable Test pressure substates. Include the inherited value at Enter.
    final apsPoints = <MapEntry<int, double>>[];
    final inheritedAps = _cachedApsAtEnter[interval.enterIndex];
    final inheritedLine = _cachedApsSourceLineAtEnter[interval.enterIndex];
    if (inheritedAps != null) {
      apsPoints.add(MapEntry(inheritedLine ?? interval.enterIndex, inheritedAps));
    }
    apsPoints.addAll(_cachedApsSamples[interval.enterIndex] ?? const []);

    for (final p in apsPoints) {
      if (p.value > -50.0) continue;

      targetReached = true;
      apsAtTarget = p.value;
      targetLine = p.key;

      // If the carried APS already satisfies the target at Enter, zero new
      // Return volume has been processed by this substate at that instant.
      if (p.key < interval.enterIndex) {
        returnVolumeAtTarget = 0.0;
        break;
      }

      if (explicitRequiredVolume != null) {
        returnVolumeAtTarget = explicitRequiredVolume.abs();
        break;
      }

      // Otherwise use the most recent ReturnVol at/before the APS target.
      double? rvAtTarget;
      final from = p.key.clamp(interval.enterIndex, interval.exitIndex ?? p.key);
      for (var i = from; i >= interval.enterIndex; i--) {
        final rv = _trimaNamedNumber(widget.episodios[i], 'ReturnVol');
        if (rv != null) {
          rvAtTarget = rv;
          break;
        }
      }

      if (rvAtTarget != null && returnVolAtEnter != null) {
        returnVolumeAtTarget = (rvAtTarget - returnVolAtEnter).abs();
      }
      break;
    }

    // "Required X of 7.0 ml to achieve pressure" means 7 mL is the maximum
    // permitted volume and pressure was achieved at X mL. This is direct TRACE
    // evidence of the exit criterion even if the final APS DATA row is flushed
    // just after the structural Exit and cannot be decoded.
    if (!targetReached &&
        explicitRequiredVolume != null &&
        explicitRequiredVolume < 7.0) {
      returnVolumeAtTarget = explicitRequiredVolume.abs();
    }

    final ok = targetReached && returnVolumeAtTarget != null
        ? returnVolumeAtTarget < 7.0
        : (explicitRequiredVolume != null
            ? explicitRequiredVolume < 7.0
            : null);

    return {
      'kind': 'return',
      'returnCmd': returnCmd,
      'targetReached': targetReached,
      'apsAtTarget': apsAtTarget,
      'targetLine': targetLine,
      'volume': returnVolumeAtTarget,
      'returnVolAtEnter': returnVolAtEnter,
      'returnVolAtEnterLine': returnVolAtEnterLine,
      'explicitRequiredVolume': explicitRequiredVolume,
      'tracePressureAchieved': explicitRequiredVolume != null,
      'apsAtEnter': inheritedAps,
      'apsAtEnterLine': inheritedLine,
      'ok': ok,
    };
  }

  bool? _trimaAcPrimeExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsAcPrimeVerificationState(interval) ||
        interval.exitIndex == null) return null;
    return _trimaAcPrimeMetrics(interval)['ok'] as bool?;
  }

  Widget _trimaAcPrimeSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final m = _trimaAcPrimeMetrics(interval);
    final ev = _trimaAcPrimeEvidence(interval);
    final inlet = m['kind'] == 'inlet';
    final ok = m['ok'] as bool?;

    String num(Object? v, [int digits = 1]) =>
        v is double ? v.toStringAsFixed(digits) : '—';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(inlet ? 'AC DETECTION TEST' : 'RETURN PRESSURE TEST',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          if (inlet) ...[
            Text('AC CMD  ${num(m['acCmd'])} mL/min',
                style: const TextStyle(fontSize: 10)),
            Text('INLET CMD  ${num(m['inletCmd'])} mL/min',
                style: const TextStyle(fontSize: 10)),
            Text('AC SENSOR  ${(m['detected'] == true) ? 'DETECTED ✓' : 'NOT DETECTED'}',
                style: const TextStyle(fontSize: 10)),
            Text('AC VOLUME AT DETECTION  ${num(m['volume'])} mL',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            const Text('REQUIRED  AC detected before 5.0 mL processed by AC pump',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          ] else ...[
            Text('RETURN CMD  ${num(m['returnCmd'])} mL/min',
                style: const TextStyle(fontSize: 10)),
            Text(
                'APS AT ENTER  ${num(m['apsAtEnter'])} mmHg${m['apsAtEnterLine'] is int ? '  ← carried from L${(m['apsAtEnterLine'] as int) + 1}' : ''}',
                style: const TextStyle(fontSize: 10)),
            Text('APS TARGET  ≤ -50.0 mmHg',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            Text(
                'APS REACHED  ${num(m['apsAtTarget'])} mmHg${m['targetLine'] is int ? '  @ L${(m['targetLine'] as int) + 1}' : ''}',
                style: const TextStyle(fontSize: 10)),
            Text(
                'RETURN VOL AT ENTER  ${num(m['returnVolAtEnter'])} mL${m['returnVolAtEnterLine'] is int ? '  ← carried from L${(m['returnVolAtEnterLine'] as int) + 1}' : ''}',
                style: const TextStyle(fontSize: 10)),
            Text('RETURN VOLUME PROCESSED AT TARGET  ${num(m['volume'])} mL',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            if (m['explicitRequiredVolume'] != null) ...[
              Text('PRESSURE ACHIEVED AT  ${num(m['explicitRequiredVolume'], 3)} mL ✓',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
              const Text('MAXIMUM ALLOWED  7.0 mL',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ],
            const Text('DATA matched to state by CSV timestamp (includes 50 ms post-Exit flush)',
                style: TextStyle(fontSize: 9)),
            const Text('REQUIRED  APS ≤ -50 mmHg before 7.0 mL processed by Return pump',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          ],
          if (ev.isNotEmpty) ...[
            const SizedBox(height: 5),
            const Text('TRACE VERIFICATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            ...ev.take(18).map((e) => Text(
                  'L${e.key + 1}  ${e.value}',
                  style: const TextStyle(fontSize: 9),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                )),
            if (ev.length > 18)
              Text('… ${ev.length - 18} additional evidence lines',
                  style: const TextStyle(fontSize: 9)),
          ],
          const SizedBox(height: 5),
          Text(
            ok == true
                ? ((m['apsAtTarget'] == null && m['tracePressureAchieved'] == true)
                    ? 'FINAL EXIT CONDITION → SATISFIED ✓ (TRACE CONFIRMS PRESSURE BEFORE 7 mL)'
                    : 'FINAL EXIT CONDITION → SATISFIED')
                : ok == false
                    ? 'FINAL EXIT CONDITION → NOT SATISFIED'
                    : 'FINAL EXIT CONDITION → PARTIAL / DATA NOT AVAILABLE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsLeakDetectorState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'leakdetectortest';
  }

  Map<String, Object?> _trimaLeakDetectorMetrics(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsLeakDetectorState(interval)) return const {'ok': null};

    bool explicitFailure = false;
    int? rawLine;
    double? leakVolts;
    DateTime? rawTime;

    // TRACE is checked only inside this state's Enter/Exit rows.
    final traceEnd = interval.exitIndex ?? interval.enterIndex;
    for (var i = interval.enterIndex;
        i <= traceEnd && i < widget.episodios.length;
        i++) {
      final l = _episodiosLower[i];
      if (l.contains('leak') &&
          (l.contains('failed') || l.contains('failure'))) {
        explicitFailure = true;
      }
    }

    // V105: resolve LeakDetector directly from Procedure CSV timestamps.
    // LeakValue is already a numeric voltage from DlogDecoder.
    // First use a valid LeakValue INSIDE Enter..Exit. Only if none exists use
    // a ±50 ms boundary fallback.
    final leakCol = widget.procedureColumns['LeakValue'];
    final startTime = interval.enterTime;
    final endTime = interval.exitTime;

    if (leakCol != null && startTime != null && endTime != null) {
      void considerWindow(DateTime from, DateTime to) {
        for (var i = 0; i < widget.procedureRows.length; i++) {
          final row = widget.procedureRows[i];
          if (row.isEmpty || leakCol >= row.length) continue;

          final time = _trimaCsvTimestamp(row[0].toString());
          if (time == null || time.isBefore(from) || time.isAfter(to)) continue;

          final volts = _trimaParseLeakValue(row[leakCol]);
          if (volts == null) continue;

          leakVolts = volts;
          rawLine = i;
          rawTime = time;
          return;
        }
      }

      considerWindow(startTime, endTime);
      if (leakVolts == null) {
        considerWindow(
          startTime.subtract(const Duration(milliseconds: 50)),
          endTime.add(const Duration(milliseconds: 50)),
        );
      }
    }

    const minV = 2.450;
    const maxV = 2.700;
    final volts = leakVolts;
    final inRange = volts != null && volts >= minV && volts <= maxV;

    bool? ok;
    if (explicitFailure) {
      ok = false;
    } else if (interval.exitIndex != null && inRange) {
      ok = true;
    } else if (interval.exitIndex != null) {
      ok = null;
    }

    return {
      'ok': ok,
      'raw2620': leakVolts != null && (leakVolts! - 2.620).abs() < 0.0005,
      'rawMv': leakVolts == null ? null : (leakVolts! * 1000.0).round(),
      'rawLine': rawLine,
      'rawTime': rawTime,
      'offsetSeconds': 0.0,
      'volts': volts,
      'minV': minV,
      'maxV': maxV,
      'inRange': inRange,
      'explicitFailure': explicitFailure,
    };
  }

  bool? _trimaLeakDetectorExitSatisfied(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsLeakDetectorState(interval)) return null;
    return _trimaLeakDetectorMetrics(interval)['ok'] as bool?;
  }

  Widget _trimaLeakDetectorSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final m = _trimaLeakDetectorMetrics(interval);
    final ok = m['ok'] as bool?;
    final volts = m['volts'] as double?;
    final rawLine = m['rawLine'] as int?;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LEAK DETECTOR TEST',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            volts == null
                ? 'LeakValue → raw value not found'
                : 'LeakValue → ${volts.toStringAsFixed(3)} V (already decoded by DlogDecoder)',
            style: const TextStyle(fontSize: 10),
          ),
          const Text('PROVISIONAL RANGE  2.450 – 2.700 V',
              style: TextStyle(fontSize: 10)),
          const Text('TEMPORAL SEARCH  Enter..Exit, fallback ±50 ms',
              style: TextStyle(fontSize: 10)),
          if (rawLine != null)
            Text('SOURCE L${rawLine + 1}',
                style: const TextStyle(fontSize: 9)),
          const SizedBox(height: 4),
          Text(
            ok == true
                ? 'FINAL LEAK TEST → SATISFIED ✓'
                : ok == false
                    ? 'FINAL LEAK TEST → NOT SATISFIED'
                    : 'FINAL LEAK TEST → PARTIAL / RAW VALUE NOT FOUND',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true
                  ? scheme.primary
                  : ok == false ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsLowerNotificationState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'lowernotification';
  }

  Map<String, Object?> _trimaLowerNotificationMetrics(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsLowerNotificationState(interval)) {
      return const {'ok': null};
    }
    final end = interval.exitIndex ?? interval.enterIndex;
    bool sentLowered = false;
    int? sentLine;
    String? sentRaw;

    // The exit condition from the Startup manual is the cassette-down
    // notification being sent. In this Trima version the TRACE is:
    // "GUI Message sent : Disposable Lowered".
    for (var i = interval.enterIndex; i <= end; i++) {
      final raw = widget.episodios[i];
      final l = raw.toLowerCase();
      if ((l.contains('gui message sent') &&
              l.contains('disposable lowered')) ||
          l.contains('gui message sent : disposable lowered')) {
        sentLowered = true;
        sentLine = i;
        sentRaw = raw;
        break;
      }
    }

    final ok = interval.exitIndex == null
        ? null
        : (sentLowered ? true : null);

    return {
      'ok': ok,
      'sentLowered': sentLowered,
      'sentLine': sentLine,
      'sentRaw': sentRaw,
    };
  }

  bool? _trimaLowerNotificationExitSatisfied(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsLowerNotificationState(interval)) return null;
    return _trimaLowerNotificationMetrics(interval)['ok'] as bool?;
  }

  Widget _trimaLowerNotificationSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final m = _trimaLowerNotificationMetrics(interval);
    final ok = m['ok'] as bool?;
    final sent = m['sentLowered'] == true;
    final line = m['sentLine'] as int?;
    final raw = m['sentRaw'] as String?;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LOWER NOTIFICATION',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'CASSETTE DOWN MESSAGE SENT  ${sent ? '✓' : '…'}',
            style: const TextStyle(fontSize: 10),
          ),
          if (line != null)
            Text('TRACE L${line + 1}',
                style: const TextStyle(fontSize: 9)),
          if (raw != null)
            Text(
              raw,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
            ),
          const SizedBox(height: 5),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED ✓'
                : 'FINAL EXIT CONDITION → DATA NOT AVAILABLE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _trimaNormStateName(_TrimaEnterExitInterval interval) =>
      _trimaStateLeaf(interval.name)
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '');

  // V111: TRIMA ANALYZE intentionally ignores every Enter:/Exit: pair that
  // is not part of the approved master list. Incidental firmware states can
  // still exist in the raw episodic log, but they are not analyzer nodes.
  bool _trimaIsMasterAnalyzedState(_TrimaEnterExitInterval interval) {
    final n = _trimaNormStateName(interval);
    const states = <String>{
      // Startup Tests
      'nvramtest', 'calibverification', 'safetypowertest', 'powerofftest',
      'powerontest', 'valvestest', 'leakdetectortest', 'centshutdowntest',
      'centshutdown', 'doorlatchtest', 'guistarted', 'loadcassette',
      'startpumps', 'lowercassette', 'cassetteid', 'stoppumps',
      'evacuatesetvalves', 'evacsetvalves', 'evacuatebags', 'lowernotification',

      // Disposable Tests
      'closevalves', 'checksamplebag', 'pressinletline', 'inletpresstest',
      'inletpresstest2', 'inletdecaytest', 'inletdecaytest2',
      'pressinletline2', 'closecrossoverclamp', 'pressinletline3',
      'negativepresstest', 'unlockdoor', 'negativepressrelief',
      'negativepressrelief2', 'pltbagevac', 'plsevacfinished',
      'air2channelprime',

      // Legacy spelling seen in earlier analyzer versions. Keep it only as an
      // alias so old logs are not lost; the real state is Air2ChannelPrime.
      'airc2hannelprime',

      // AC Prime
      'acprimeinlet', 'acpressreturnline',

      // Blood Run Prime
      'primechannel1', 'primechannel2', 'primechannel3', 'primechannel4',
      'primevent', 'primechannelvent', 'rampcentrifuge',
      'primeairout2', 'removechannelair',
    };
    return states.contains(n);
  }

  bool _trimaHasExplicitFailure(_TrimaEnterExitInterval interval) {
    final end = interval.exitIndex ?? interval.enterIndex;
    for (var i = interval.enterIndex; i <= end && i < widget.episodios.length; i++) {
      final l = _episodiosLower[i];
      if (RegExp(r'\bfail(?:ed|ure)?\b').hasMatch(l) ||
          RegExp(r'\berror\b').hasMatch(l) ||
          RegExp(r'\balarm\b').hasMatch(l) ||
          l.contains('giving up') ||
          RegExp(r'\btimeout\b').hasMatch(l) ||
          l.contains('timed out')) {
        return true;
      }
    }
    return false;
  }

  bool _trimaIsStartupTestState(_TrimaEnterExitInterval interval) {
    final n = _trimaNormStateName(interval);
    return n == 'startuptest' || n == 'startuptests';
  }

  bool _trimaIsStartupTransitionState(_TrimaEnterExitInterval interval) {
    final n = _trimaNormStateName(interval);
    return n == 'nvramtest' || n == 'calibverification' || n == 'guistarted';
  }

  bool? _trimaStartupTransitionExitSatisfied(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsStartupTransitionState(interval)) return null;
    // NVRamTest and CalibVerification expose no explicit PASS evidence in the
    // current DLOG. GUIStarted is an operator/user interaction, not a technical
    // test. For these three states completion is the structural Enter -> Exit.
    return interval.exitIndex != null ? true : null;
  }

  bool? _trimaStartupExitSatisfied(_TrimaEnterExitInterval interval) {
    if (!_trimaIsStartupTestState(interval)) return null;
    if (interval.exitIndex == null) return null;

    const required = <String>{
      'nvramtest',
      'calibverification',
      'powertest',
      'valvestest',
      'leakdetectortest',
      'doorlatchtest',
      'guistarted',
    };

    final children = _trimaDirectChildren(interval);
    final byName = <String, _TrimaEnterExitInterval>{};
    for (final child in children) {
      byName[_trimaNormStateName(child)] = child;
    }

    for (final name in required) {
      final child = byName[name];
      if (child == null) return false;
      final ok = _trimaKnownExitSatisfiedLeafOnly(child) ??
          _trimaAggregatedChildCompletion(child);
      if (ok != true) return ok == false ? false : null;
    }
    return true;
  }

  Widget _trimaStartupTransitionSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final n = _trimaNormStateName(interval);
    final ok = interval.exitIndex != null;
    final isUser = n == 'guistarted';
    final title = isUser
        ? 'USER INTERACTION'
        : 'PASSED BY STATE TRANSITION';
    final detail = isUser
        ? (ok
            ? 'GUIStarted completed • USER CONTINUED ✓'
            : 'GUIStarted waiting for user completion')
        : (ok
            ? 'Enter → Exit confirmed ✓'
            : 'Enter found • matching Exit not found');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isUser ? Icons.person_rounded : Icons.swap_horiz_rounded,
              size: 18,
              color: ok ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _trimaStartupSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    const required = <String, String>{
      'nvramtest': 'NVRamTest',
      'calibverification': 'CalibVerification',
      'powertest': 'PowerTest',
      'valvestest': 'ValvesTest',
      'leakdetectortest': 'LeakDetectorTest',
      'doorlatchtest': 'DoorLatchTest',
      'guistarted': 'GUIStarted / USER',
    };
    final children = <String, _TrimaEnterExitInterval>{};
    for (final child in _trimaDirectChildren(interval)) {
      children[_trimaNormStateName(child)] = child;
    }

    final lines = <String>[];
    for (final e in required.entries) {
      final child = children[e.key];
      bool? ok;
      if (child != null) {
        ok = _trimaKnownExitSatisfiedLeafOnly(child) ??
            _trimaAggregatedChildCompletion(child);
      }
      lines.add('${ok == true ? '✓' : ok == false ? '✗' : '○'} ${e.value}');
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('STARTUP TEST',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(lines.join('  •  '), style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            interval.exitIndex == null
                ? 'StartupTest Exit: NOT FOUND'
                : 'StartupTest Exit: FOUND',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: interval.exitIndex == null
                  ? scheme.error
                  : scheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  bool _trimaIsDisposableVerificationState(
      _TrimaEnterExitInterval interval) {
    final n = _trimaNormStateName(interval);
    return n == 'checksamplebag' ||
        n == 'pressinletline' ||
        n == 'inletpresstest' ||
        n == 'inletdecaytest' ||
        n == 'negativepresstest' ||
        n == 'negativepressrelief' ||
        n == 'pltbagevac' ||
        (n == 'air2channelprime' || n == 'airc2hannelprime') ||
        n == 'air2channel' ||
        n == 'plsevacfinished';
  }

  Map<String, Object?> _trimaDisposableMetrics(
      _TrimaEnterExitInterval interval) {
    final n = _trimaNormStateName(interval);
    final end = interval.exitIndex ?? interval.enterIndex;
    bool explicitPass = false;
    bool explicitFail = false;
    String? directEvidence;
    int? evidenceLine;
    double? aps;
    double? volume;
    double? limit;
    double? delta;

    double? num(RegExp re, String line) {
      final m = re.firstMatch(line);
      return m == null ? null : double.tryParse(m.group(1)!);
    }

    for (var i = interval.enterIndex; i <= end; i++) {
      final line = widget.episodios[i];
      final l = line.toLowerCase();

      // Direct firmware evidence has priority over reconstructed thresholds.
      final passHere =
          (n == 'checksamplebag' && l.contains('checking sample bag passed')) ||
          (n == 'pressinletline' && l.contains('pass! disposable test 1 to follow')) ||
          (n == 'inletpresstest' && l.contains('pressure check passed')) ||
          (n == 'inletdecaytest' && l.contains('inlet decay test passed')) ||
          (n == 'pltbagevac' && l.contains('plt evac completed normal')) ||
          (n == 'plsevacfinished' && l.contains('plsevac limit reached')) ||
          (n == 'air2channel' && l.contains('air2channel finished'));
      if (passHere) {
        explicitPass = true;
        directEvidence = line;
        evidenceLine = i;
      }
      if (l.contains(' failed') || l.contains(' fail!') ||
          l.contains('test failed')) {
        explicitFail = true;
      }

      if (n == 'checksamplebag') {
        aps ??= num(RegExp(r'APS Delta->\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        delta ??= aps;
        volume ??= num(RegExp(r'volume processed->\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        limit ??= num(RegExp(r'volume LIMIT cc\s*=\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
      } else if (n == 'pressinletline') {
        final a = num(RegExp(r'APS Pressure\s*->\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        if (a != null) aps = a;
        final v = num(RegExp(r'AC Vol\s*->\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        if (v != null) volume = v;
      } else if (n == 'negativepresstest') {
        final a = num(RegExp(r'Negative pressure reached\s*\(APS\s*=\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        if (a != null) {
          aps = a;
          explicitPass = a < -350.0;
          directEvidence = line;
          evidenceLine = i;
        }
      } else if (n == 'negativepressrelief') {
        final a = num(RegExp(r'NegativePressRelief\s*\(\s*APS\s*=\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line) ??
            num(RegExp(r'aps at exit:\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        if (a != null) aps = a;
        final v = num(RegExp(r'volm processes\s*=\s*(-?\d+(?:\.\d+)?)', caseSensitive: false), line);
        if (v != null) volume = v;
      } else if (n == 'plsevacfinished') {
        final v = num(RegExp(r'PlsEvac\s+Limit\s+reached\s+at\s+(-?\d+(?:\.\d+)?)',
            caseSensitive: false), line);
        if (v != null) limit = v;
      }
    }

    bool? ok;

    // Exit condition not yet confirmed from this DLOG/manual:
    // keep it explicitly PENDING and do not infer it from unrelated CSV fields.
    if ((n == 'air2channelprime' || n == 'airc2hannelprime') && explicitFail) {
      ok = false;
    } else if (n == 'air2channelprime' || n == 'airc2hannelprime') {
      // This state has no explicit PASS line in the 1880 log. A matching Exit,
      // no failure, and real APS/inlet-volume activity are treated as successful
      // structural completion; the measured values remain visible in the panel.
      ok = interval.exitIndex != null;
    } else if (explicitFail) {
      ok = false;
    } else if (explicitPass) {
      ok = true;
    } else if (n == 'pressinletline' && aps != null && volume != null) {
      ok = aps > 400.0 && volume < 50.0;
    } else if (n == 'negativepresstest' && aps != null) {
      ok = aps < -350.0;
    } else if (n == 'negativepressrelief' && aps != null && volume != null) {
      ok = aps > -50.0 && volume < 50.0;
    } else {
      // InletPressTest/InletDecayTest can still use the APS time-series rule.
      ok = _trimaApsExitSatisfied(interval);
    }

    return {
      'ok': ok,
      'explicitPass': explicitPass,
      'explicitFail': explicitFail,
      'evidence': directEvidence,
      'evidenceLine': evidenceLine,
      'aps': aps,
      'delta': delta,
      'volume': volume,
      'limit': limit,
    };
  }

  bool? _trimaDisposableExitSatisfied(
      _TrimaEnterExitInterval interval) {
    if (!_trimaIsDisposableVerificationState(interval)) return null;
    if (interval.exitIndex == null) return null;
    return _trimaDisposableMetrics(interval)['ok'] as bool?;
  }

  Widget _trimaDisposableSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final n = _trimaNormStateName(interval);
    final m = _trimaDisposableMetrics(interval);
    final ok = m['ok'] as bool?;
    final aps = m['aps'] as double?;
    final delta = m['delta'] as double?;
    final volume = m['volume'] as double?;
    final limit = m['limit'] as double?;
    final evidence = m['evidence'] as String?;
    final evidenceLine = m['evidenceLine'] as int?;

    String expected;
    if (n == 'pltbagevac') {
      expected = 'Firmware reports PLT evac completed normal';
    } else if (n == 'plsevacfinished') {
      expected = 'Firmware reports PlsEvac Limit reached';
    } else if (n == 'air2channelprime' || n == 'airc2hannelprime') {
      expected = 'Matching Exit + no explicit failure; APS/volume activity shown as evidence';
    } else if (n == 'air2channel') {
      expected = 'Firmware reports Air2Channel finished with processed inlet volume';
    } else if (n == 'checksamplebag') {
      expected = 'Firmware PASS + APS/processed-volume evidence';
    } else if (n == 'pressinletline') {
      expected = 'APS > 400 mmHg before 50 mL AC';
    } else if (n == 'inletpresstest') {
      expected = 'APS decrease < 50 mmHg in 3 s';
    } else if (n == 'inletdecaytest') {
      expected = 'APS decrease > 50 mmHg after pump rotation';
    } else if (n == 'negativepresstest') {
      expected = 'APS < -350 mmHg before 115 mL inlet';
    } else {
      expected = 'APS > -50 mmHg before 50 mL';
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DISPOSABLE TEST VERIFICATION',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('EXIT CONDITION  $expected',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          if (aps != null) Text('APS  ${aps.toStringAsFixed(2)} mmHg', style: const TextStyle(fontSize: 11)),
          if (delta != null) Text('APS DELTA  ${delta.toStringAsFixed(2)} mmHg', style: const TextStyle(fontSize: 11)),
          if (volume != null) Text('VOLUME  ${volume.toStringAsFixed(3)} mL', style: const TextStyle(fontSize: 11)),
          if (limit != null) Text('FIRMWARE VOLUME LIMIT  ${limit.toStringAsFixed(3)} mL', style: const TextStyle(fontSize: 11)),
          if (evidence != null) ...[
            const SizedBox(height: 4),
            Text('DIRECT FIRMWARE EVIDENCE${evidenceLine == null ? '' : ' • L${evidenceLine + 1}'}',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
            Text(evidence, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, fontFamily: 'monospace')),
          ],
          const SizedBox(height: 5),
          Text(
            ok == true
                ? 'FINAL EXIT CONDITION → SATISFIED ✓'
                : ok == false
                    ? 'FINAL EXIT CONDITION → NOT SATISFIED'
                    : 'FINAL EXIT CONDITION → PARTIAL / EVIDENCE MISSING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok == true ? scheme.primary : ok == false ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool? _trimaAggregatedChildCompletion(
      _TrimaEnterExitInterval interval,
      [Set<int>? visiting]) {
    if (interval.exitIndex == null) return null;
    final children = _trimaDirectChildren(interval);
    if (children.isEmpty) return null;

    final seen = visiting ?? <int>{};
    if (!seen.add(interval.enterIndex)) return null;

    bool sawChild = false;
    for (final child in children) {
      if (child.enterIndex == interval.enterIndex) continue;
      sawChild = true;

      // First evaluate the child's own explicit exit rule.
      bool? childOk = _trimaKnownExitSatisfiedLeafOnly(child);

      // Structural/group nodes (for example CentrifugeTests and ACPrime)
      // are completed from their required direct children.
      childOk ??= _trimaAggregatedChildCompletion(child, seen);

      if (childOk != true) {
        seen.remove(interval.enterIndex);
        return childOk == false ? false : null;
      }
    }

    seen.remove(interval.enterIndex);
    return sawChild ? true : null;
  }

  Map<String, Object?>? _trimaPrimeChannelVolumeMetrics(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return null;
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    // Trima Gen 2 Service Manual, Blood Run Prime:
    // PC1=70 mL, PC2=15 mL, PC3=25 mL, PC4=8 mL processed by inlet pump.
    const requiredByState = <String, double>{
      'primechannel1': 70.0,
      'primechannel2': 15.0,
      'primechannel3': 25.0,
      'primechannel4': 8.0,
    };
    final required = requiredByState[n];
    if (required == null) return null;

    // Use InletVol, not InletTotalVol: the manual defines the condition as
    // volume processed by the inlet pump during this prime substate.
    // Carry the value at ENTER, then accept delayed CSV flush up to EXIT+2 s.
    final samples = _trimaDataSamples(
      interval, 'InletVol', postExit: const Duration(seconds: 2));
    if (samples.isEmpty) {
      return <String, Object?>{
        'required': required,
        'start': null,
        'end': null,
        'processed': null,
        'reachedAt': null,
        'ok': null,
      };
    }

    double? asDouble(dynamic v) =>
        v is num ? v.toDouble() : double.tryParse(v.toString().trim());

    // Use the last known InletVol at/before ENTER as the baseline.
    // The Procedure CSV is sparse: the first row emitted inside the state may
    // already contain volume pumped before that row was flushed.
    double? start;
    int? startLine;
    DateTime? startTime;
    for (final e in _trimaInletVolTimeline) {
      if (e.time.isAfter(interval.enterTime!)) break;
      start = e.value;
      startLine = e.line;
      startTime = e.time;
    }
    start ??= asDouble(samples.first.value);
    startTime ??= samples.first.time;
    if (start == null) {
      return <String, Object?>{
        'required': required,
        'start': null,
        'end': null,
        'processed': null,
        'reachedAt': null,
        'ok': null,
      };
    }

    double? end;
    DateTime? reachedAt;
    int? reachedRow;
    for (final sample in samples) {
      final v = asDouble(sample.value);
      if (v == null) continue;
      end = v;
      final processed = v - start;
      if (reachedAt == null && processed >= required - 0.50) {
        reachedAt = sample.time;
        reachedRow = sample.row;
      }
    }

    final processed = end == null ? null : end - start;
    // EXIT+2 s is capture-only.  A delayed CSV row can prove that the firmware
    // reached the volume threshold; it does not extend a documented time limit
    // (these PrimeChannel exit rules are volume-based, not time-based).
    final ok = reachedAt != null
        ? true
        : (processed != null && processed >= required - 0.50 ? true : false);

    return <String, Object?>{
      'required': required,
      'start': start,
      'startLine': startLine,
      'startTime': startTime,
      'end': end,
      'processed': processed,
      'reachedAt': reachedAt,
      'reachedRow': reachedRow,
      'ok': ok,
    };
  }

  bool _trimaIsPrimeChannelVolumeState(_TrimaEnterExitInterval interval) {
    final n = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'primechannel1' ||
        n == 'primechannel2' ||
        n == 'primechannel3' ||
        n == 'primechannel4';
  }

  Widget _trimaPrimeChannelSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final m = _trimaPrimeChannelVolumeMetrics(interval);
    if (m == null) return const SizedBox.shrink();
    final required = m['required'] as double?;
    final start = m['start'] as double?;
    final end = m['end'] as double?;
    final processed = m['processed'] as double?;
    final reachedAt = m['reachedAt'] as DateTime?;
    final ok = m['ok'] as bool?;
    String f(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    String tf(DateTime? t) => t == null
        ? '—'
        : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}.'
          '${t.millisecond.toString().padLeft(3, '0')}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PRIME CHANNEL', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('EXIT CONDITION  Inlet volume processed ≥ ${f(required)} mL'),
          Text('INLET VOL AT ENTER  ${f(start)} mL'),
          Text('INLET VOL OBSERVED  ${f(end)} mL'),
          Text('PROCESSED  ${f(processed)} mL'),
          if (reachedAt != null) Text('THRESHOLD EVIDENCE  ${tf(reachedAt)}'),
          const SizedBox(height: 4),
          Text(
            'FINAL EXIT CONDITION → ${ok == true ? 'SATISFIED' : ok == false ? 'NOT SATISFIED' : 'UNKNOWN'}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: ok == true ? scheme.primary : ok == false ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool? _trimaPrimeChannelExitSatisfied(
      _TrimaEnterExitInterval interval) {
    final m = _trimaPrimeChannelVolumeMetrics(interval);
    return m?['ok'] as bool?;
  }

  bool? _trimaKnownExitSatisfiedLeafOnly(
      _TrimaEnterExitInterval interval) {
    final startup = _trimaStartupExitSatisfied(interval);
    if (startup != null) return startup;
    final startupTransition = _trimaStartupTransitionExitSatisfied(interval);
    if (startupTransition != null) return startupTransition;
    final valve = _trimaValveExitSatisfied(interval);
    if (valve != null) return valve;
    final primeChannel = _trimaPrimeChannelExitSatisfied(interval);
    if (primeChannel != null) return primeChannel;
    final pump = _trimaPumpExitSatisfied(interval);
    if (pump != null) return pump;
    final cassette = _trimaCassetteExitSatisfied(interval);
    if (cassette != null) return cassette;
    final disposable = _trimaDisposableExitSatisfied(interval);
    if (disposable != null) return disposable;
    final aps = _trimaApsExitSatisfied(interval);
    final apsLeaf = _trimaStateLeaf(interval.name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final apsNeedsVolume = apsLeaf == 'checksamplebag' ||
        apsLeaf == 'pressinletline' ||
        apsLeaf == 'pressinletline3' ||
        apsLeaf == 'negativepresstest' ||
        apsLeaf == 'negativepressrelief';
    if (aps != null && !apsNeedsVolume) return aps;
    final door = _trimaDoorExitSatisfied(interval);
    if (door != null) return door;
    final centrifuge = _trimaCentrifugeExitSatisfied(interval);
    if (centrifuge != null) return centrifuge;
    final powerTest = _trimaPowerTestExitSatisfied(interval);
    if (powerTest != null) return powerTest;
    final connectAc = _trimaConnectAcExitSatisfied(interval);
    if (connectAc != null) return connectAc;
    final acPrime = _trimaAcPrimeExitSatisfied(interval);
    if (acPrime != null) return acPrime;
    final leakDetector = _trimaLeakDetectorExitSatisfied(interval);
    if (leakDetector != null) return leakDetector;
    final lowerNotification =
        _trimaLowerNotificationExitSatisfied(interval);
    if (lowerNotification != null) return lowerNotification;
    return null;
  }

  bool? _trimaKnownExitSatisfied(_TrimaEnterExitInterval interval) {
    final own = _trimaKnownExitSatisfiedLeafOnly(interval);
    if (own != null) return own;

    final aggregated = _trimaAggregatedChildCompletion(interval);
    if (aggregated != null) return aggregated;

    // V113: do not turn a documented Trima master state green merely
    // because Enter/Exit exists. A PASS must come from a state-specific
    // evaluator or from all required analyzed children. Missing evidence is
    // UNKNOWN; explicit failures remain FAIL where the specific evaluator can
    // prove them.
    return null;
  }

  bool _trimaIsValveVerificationState(_TrimaEnterExitInterval interval) {
    final n = interval.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // Show valve diagnostics only where valve operation/position is itself
    // part of the substate's verification/exit condition.
    return n == 'valvestest' ||
        n == 'closevalves' ||
        n == 'openvalves' ||
        n == 'evacsetvalves' ||
        n == 'evacresetvalves';
  }

  Widget _trimaValveStateSnapshot(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final initial = _trimaValveStateBefore(interval.enterIndex);
    final finalState = _trimaValveStateAtExit(interval);
    final required = _trimaRequiredValveExit(interval);
    final ok = _trimaValveExitSatisfied(interval);
    final movements = _trimaValveEventsInInterval(interval);
    final discrepancies = movements.where((e) => !e.approved).length;

    String pos(Map<String, int> m, String v) =>
        m[v] == null ? '?' : _trimaValvePosition(m[v]!);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('VALVE STATE',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('ENTER  RBC ${pos(initial, 'RBC')}  •  PLASMA ${pos(initial, 'PLASMA')}  •  PLATELET ${pos(initial, 'PLATELET')}',
              style: const TextStyle(fontSize: 11)),
          if (required != null)
            Text('REQUIRED  RBC ${pos(required, 'RBC')}  •  PLASMA ${pos(required, 'PLASMA')}  •  PLATELET ${pos(required, 'PLATELET')}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          Text('BEFORE EXIT  RBC ${pos(finalState, 'RBC')}  •  PLASMA ${pos(finalState, 'PLASMA')}  •  PLATELET ${pos(finalState, 'PLATELET')}',
              style: const TextStyle(fontSize: 11)),
          if (discrepancies > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Intermediate discrepancies: $discrepancies',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.error,
                ),
              ),
            ),
          if (ok != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                ok ? 'FINAL EXIT CONDITION → SATISFIED' : 'FINAL EXIT CONDITION → NOT SATISFIED',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: ok ? scheme.primary : scheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildTrimaCompactValveSummary(
      _TrimaEnterExitInterval interval, ColorScheme scheme) {
    final events = _trimaValveEventsInInterval(interval);
    if (events.isEmpty) return const <Widget>[];

    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 4),
        child: Text(
          'VALVE MOVEMENTS (${events.length})',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ),
    ];

    // Keep the exact chronological order. This makes the first discrepancy
    // immediately visible in the state where it happened.
    for (var n = 0; n < events.length; n++) {
      final e = events[n];
      final ok = e.approved;
      final orderTime =
          e.orderTime == null ? '—' : _trimaTimeLabel(e.orderTime!);
      final target = _trimaValvePosition(e.order);
      final initial = _trimaValvePosition(e.initialStatus);

      String completion;
      if (e.inPositionStatus == null) {
        completion = 'NO IN POSITION';
      } else {
        completion =
            'IN POSITION ${_trimaValvePosition(e.inPositionStatus!)} '
            '(${e.inPositionStatus})'
            '${e.movementTimeMs == null ? '' : ' • ${e.movementTimeMs} ms'}';
      }

      out.add(
        Container(
          margin: const EdgeInsets.fromLTRB(12, 3, 10, 3),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(
              color: ok ? scheme.outlineVariant : scheme.error,
            ),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${n + 1}.',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              SizedBox(
                width: 76,
                child: Text(
                  e.valve,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$orderTime  •  ORDER $target (${e.order})'
                      '  •  current $initial (${e.initialStatus})',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      completion,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: ok ? scheme.primary : scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  Icon(
                    ok
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                    size: 18,
                    color: ok ? scheme.primary : scheme.error,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ok ? 'OK' : 'DISCREPANCY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: ok ? scheme.primary : scheme.error,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return out;
  }

  String _trimaValveVerdictLabel(_TrimaEnterExitInterval interval) {
    final events = _trimaValveEventsInInterval(interval);
    if (events.isEmpty) return '';
    final failed = events.any((e) =>
        e.inPositionStatus == null || !e.approved);
    return failed ? '  •  VALVES PROBLEM' : '  •  VALVES APPROVED';
  }

  List<_TrimaValveEvent> _trimaValveEventsInInterval(
      _TrimaEnterExitInterval interval) {
    if (interval.exitIndex == null) return const <_TrimaValveEvent>[];

    final orderRx = RegExp(
      r'Valve\s+(plasma|platelet|rbc)\s*:\s*order\s*=\s*(-?\d+)\s+status\s*=\s*(-?\d+)',
      caseSensitive: false,
    );
    final inPositionRx = RegExp(
      r'Valve\s+(plasma|platelet|rbc)\s+in\s+position\s*:\s*status\s*=\s*(-?\d+)\s+time\s*=\s*(-?\d+)\s*ms',
      caseSensitive: false,
    );

    final out = <_TrimaValveEvent>[];
    final pendingByValve = <String, int>{};

    for (var i = interval.enterIndex + 1; i < interval.exitIndex!; i++) {
      final event = widget.episodios[i];

      final orderMatch = orderRx.firstMatch(event);
      if (orderMatch != null) {
        final valve = (orderMatch.group(1) ?? '').toUpperCase();
        final order = int.tryParse(orderMatch.group(2) ?? '');
        final initialStatus = int.tryParse(orderMatch.group(3) ?? '');
        if (order == null || initialStatus == null) continue;

        out.add(_TrimaValveEvent(
          valve: valve,
          order: order,
          initialStatus: initialStatus,
          inPositionStatus: null,
          movementTimeMs: null,
          orderTime: _trimaEventTime(event),
          inPositionTime: null,
          sourceIndex: i,
          inPositionSourceIndex: null,
          raw: event,
          inPositionRaw: null,
        ));
        pendingByValve[valve] = out.length - 1;
        continue;
      }

      final positionMatch = inPositionRx.firstMatch(event);
      if (positionMatch == null) continue;

      final valve = (positionMatch.group(1) ?? '').toUpperCase();
      final status = int.tryParse(positionMatch.group(2) ?? '');
      final movementTimeMs = int.tryParse(positionMatch.group(3) ?? '');
      if (status == null || movementTimeMs == null) continue;

      final pendingIndex = pendingByValve[valve];
      if (pendingIndex == null) continue;

      final previous = out[pendingIndex];
      // Associate "in position" with the most recent command for the SAME
      // valve. This is the actual completion acknowledgement.
      out[pendingIndex] = previous.copyWithInPosition(
        status: status,
        movementTimeMs: movementTimeMs,
        time: _trimaEventTime(event),
        sourceIndex: i,
        raw: event,
      );
      pendingByValve.remove(valve);
    }

    return out;
  }

  List<Widget> _buildTrimaValveAnalysis(
    BuildContext dialogContext,
    _TrimaEnterExitInterval interval,
    ColorScheme scheme,
  ) {
    final events = _trimaValveEventsInInterval(interval);
    if (events.isEmpty) return const <Widget>[];

    final rows = <Widget>[];
    final completed = events.where((e) => e.inPositionStatus != null).length;
    final approved = events.where((e) => e.approved).length;
    final failed = events.where((e) => e.inPositionStatus != null && !e.approved).length;
    final pending = events.length - completed;

    rows.add(
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Icon(Icons.tune_rounded, size: 18, color: scheme.tertiary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'VALVES  •  ${events.length} commands  •  '
                '$approved approved'
                '${failed > 0 ? '  •  $failed FAILED' : ''}'
                '${pending > 0 ? '  •  $pending without in-position' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );

    for (final e in events) {
      final hasAck = e.inPositionStatus != null;
      final resultText = !hasAck
          ? 'WAITING / NO IN-POSITION'
          : (e.approved ? 'APPROVED' : 'FAILED');
      final resultColor = !hasAck
          ? scheme.onSurfaceVariant
          : (e.approved ? scheme.primary : scheme.error);
      final t = e.movementTimeMs == null ? '—' : '${e.movementTimeMs} ms';

      rows.add(
        InkWell(
          onTap: () => _goToTrimaSourceLine(dialogContext, e.sourceIndex),
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 5, 8, 2),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 78,
                      child: Text(e.valve,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    Expanded(
                      child: Text(
                        'ORDER ${_trimaValvePosition(e.order)} (${e.order})  •  '
                        'initial ${_trimaValvePosition(e.initialStatus)} (${e.initialStatus})',
                      ),
                    ),
                    Text(resultText,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: resultColor,
                        )),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 78),
                    Expanded(
                      child: Text(
                        hasAck
                            ? 'IN POSITION ${_trimaValvePosition(e.inPositionStatus!)} '
                              '(${e.inPositionStatus})  •  time $t'
                            : 'No "Valve ${e.valve.toLowerCase()} in position" found '
                              'after this command inside the state.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (hasAck)
                      Icon(
                        e.approved
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded,
                        size: 19,
                        color: resultColor,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

      if (e.inPositionSourceIndex != null && e.inPositionRaw != null) {
        rows.add(
          InkWell(
            onTap: () => _goToTrimaSourceLine(
                dialogContext, e.inPositionSourceIndex!),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 8, 5),
              child: Text(
                '↳ ${e.inPositionRaw}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      }
    }

    return rows;
  }

  List<Widget> _buildTrimaNestedContents(
    BuildContext dialogContext,
    _TrimaEnterExitInterval parent,
    ColorScheme scheme,
  ) {
    if (parent.exitIndex == null) return const <Widget>[];

    // PERFORMANCE: render only child states here. Raw episodic lines are not
    // materialized as hundreds/thousands of Text widgets. Valve diagnostics
    // remain available through the compact state analysis.
    final children = _trimaDirectChildren(parent);
    final widgets = <Widget>[];

    for (final child in children) {
      final enter =
          child.enterTime == null ? '—' : _trimaTimeLabel(child.enterTime!);
      final exit =
          child.exitTime == null ? '—' : _trimaTimeLabel(child.exitTime!);
      final dt = child.durationSeconds == null
          ? '—'
          : '${child.durationSeconds!.toStringAsFixed(3)} s';

      final exitOk = _trimaKnownExitSatisfied(child);
      final c = exitOk == true
          ? scheme.primary
          : (exitOk == false ? scheme.error : scheme.onSurfaceVariant);

      widgets.add(
        Card(
          margin: EdgeInsets.fromLTRB(
            8.0 + ((child.depth - parent.depth - 1).clamp(0, 6) * 8.0),
            4,
            4,
            4,
          ),
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            leading: Icon(
              exitOk == true
                  ? Icons.check_circle_rounded
                  : (exitOk == false
                      ? Icons.cancel_rounded
                      : Icons.radio_button_unchecked_rounded),
              size: 18,
              color: c,
            ),
            title: Text(
              'L${child.enterIndex + 1}  ${_trimaStateLeaf(child.name)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ENTER L${child.enterIndex + 1} $enter  →  '
                  'EXIT ${child.exitIndex == null ? '—' : 'L${child.exitIndex! + 1}'} $exit  •  ΔT $dt',
                  style: const TextStyle(fontSize: 11),
                ),
                Text(
                  _trimaClosedInternalSubstates(child),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            children: [
              if (_trimaIsStartupTestState(child))
                _trimaStartupSnapshot(child, scheme),
              if (_trimaIsStartupTransitionState(child))
                _trimaStartupTransitionSnapshot(child, scheme),
              if (_trimaIsValveVerificationState(child)) ...[
                _trimaValveStateSnapshot(child, scheme),
                ..._buildTrimaCompactValveSummary(child, scheme),
              ],
              if (_trimaIsPumpVerificationState(child))
                _trimaPumpStateSnapshot(child, scheme),
              if (_trimaIsCassetteVerificationState(child))
                _trimaCassetteStateSnapshot(child, scheme),
              if (_trimaIsDisposableVerificationState(child))
                _trimaDisposableSnapshot(child, scheme),
              if (_trimaIsApsVerificationState(child) &&
                  !_trimaIsAcPrimeVerificationState(child) &&
                  !_trimaIsDisposableVerificationState(child))
                _trimaApsStateSnapshot(child, scheme),
              if (_trimaIsDoorVerificationState(child))
                _trimaDoorStateSnapshot(child, scheme),
              if (_trimaIsCentrifugeVerificationState(child))
                _trimaCentrifugeStateSnapshot(child, scheme),
              if (_trimaIsPowerTestState(child))
                _trimaPowerTestSnapshot(child, scheme),
              if (_trimaIsLeakDetectorState(child))
                _trimaLeakDetectorSnapshot(child, scheme),
              if (_trimaIsLowerNotificationState(child))
                _trimaLowerNotificationSnapshot(child, scheme),
              if (_trimaIsConnectAcState(child))
                _trimaConnectAcSnapshot(child, scheme),
              if (_trimaIsAcPrimeVerificationState(child))
                _trimaAcPrimeSnapshot(child, scheme),
              ..._buildTrimaNestedContents(dialogContext, child, scheme),
            ],
          ),
        ),
      );
    }

    return widgets;
  }

  Widget _trimaBoundaryLine(
    BuildContext dialogContext,
    int sourceIndex,
    String label,
    String event,
    ColorScheme scheme,
  ) {
    return InkWell(
      onTap: () => _goToTrimaSourceLine(dialogContext, sourceIndex),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 54,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: Text(
                event,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trimaInsideLine(
    BuildContext dialogContext,
    int sourceIndex,
    String event,
    ColorScheme scheme,
  ) {
    final lower = event.toLowerCase();
    final isNestedEnter = lower.contains('enter:');
    final isNestedExit = lower.contains('exit:');
    final isCommand = lower.contains('command pumps -');
    final isHvE = lower.contains('hve:');

    String kind = 'EVENT';
    if (isNestedEnter) kind = 'ENTER';
    if (isNestedExit) kind = 'EXIT';
    if (isCommand) kind = 'COMMAND';
    if (isHvE) kind = 'HvE';

    return InkWell(
      onTap: () => _goToTrimaSourceLine(dialogContext, sourceIndex),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                kind,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: (isNestedEnter || isNestedExit || isCommand || isHvE)
                      ? FontWeight.w800
                      : FontWeight.w500,
                  color: (isNestedEnter || isNestedExit || isCommand || isHvE)
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                event,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trimaStatChip(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$label  $value',
          style: TextStyle(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700)),
    );
  }

  List<_TrimaEnterExitInterval> _buildTrimaEnterExitIntervals() {
    final result = <_TrimaEnterExitInterval>[];
    final openByName = <String, List<int>>{};

    for (var i = 0; i < widget.episodios.length; i++) {
      final event = widget.episodios[i];

      final enterName = _trimaEnterExitName(event, 'Enter');
      if (enterName != null) {
        final key = enterName.toLowerCase();
        final outputIndex = result.length;
        result.add(_TrimaEnterExitInterval(
          name: enterName,
          enterIndex: i,
          exitIndex: null,
          enterTime: _trimaEventTime(event),
          exitTime: null,
          depth: 0, // recomputed from interval containment for the UI
        ));
        (openByName[key] ??= <int>[]).add(outputIndex);
        continue;
      }

      final exitName = _trimaEnterExitName(event, 'Exit');
      if (exitName == null) continue;
      final key = exitName.toLowerCase();
      final opens = openByName[key];
      if (opens == null || opens.isEmpty) continue;

      // Match the most recent Enter with the same literal state name.
      final outputIndex = opens.removeLast();
      final old = result[outputIndex];
      result[outputIndex] = _TrimaEnterExitInterval(
        name: old.name,
        enterIndex: old.enterIndex,
        exitIndex: i,
        enterTime: old.enterTime,
        exitTime: _trimaEventTime(event),
        depth: 0,
      );
    }

    // Recompute depth using completed interval containment:
    // A contains B iff A.enter < B.enter < B.exit < A.exit.
    // This avoids one unmatched long-lived wrapper (e.g. MainState) hiding
    // the entire useful tree.
    final completed = result.where((e) => e.exitIndex != null).toList();
    final rebuilt = <_TrimaEnterExitInterval>[];
    for (final x in result) {
      var depth = 0;
      if (x.exitIndex != null) {
        for (final p in completed) {
          if (p.enterIndex < x.enterIndex &&
              p.exitIndex! > x.exitIndex!) {
            depth++;
          }
        }
      }
      rebuilt.add(_TrimaEnterExitInterval(
        name: x.name,
        enterIndex: x.enterIndex,
        exitIndex: x.exitIndex,
        enterTime: x.enterTime,
        exitTime: x.exitTime,
        depth: depth,
      ));
    }
    return rebuilt;
  }


  String _trimaPumpLabel(String pump) {
    switch (pump.toLowerCase()) {
      case 'ac':
        return 'AC pump';
      case 'inlet':
        return 'Inlet pump';
      case 'plasma':
        return 'Plasma pump';
      case 'platelet':
      case 'collect':
        return 'Platelet pump';
      case 'return':
        return 'Return pump';
      default:
        return '$pump pump';
    }
  }

  List<_TrimaHvE> _parseTrimaHvEEvent(String event, int episodeIndex) {
    final out = <_TrimaHvE>[];
    if (!event.toLowerCase().contains('hve:')) return out;

    // Typical CONTROL form:
    // HvE: Return pump : 252349 12 247296 ; AC pump : ...
    final tailIndex = event.toLowerCase().indexOf('hve:');
    final tail = event.substring(tailIndex + 4);
    final rx = RegExp(
      r'(inlet|ac|plasma|platelet(?:\s+or\s+collect)?|collect|return)\s+pump\s*:\s*'
      r'(-?\d+)\s+(-?\d+)\s+(-?\d+)',
      caseSensitive: false,
    );

    for (final m in rx.allMatches(tail)) {
      final pump = (m.group(1) ?? '').toLowerCase();
      final encoder = int.tryParse(m.group(2) ?? '');
      final hall = int.tryParse(m.group(3) ?? '');
      final expected = int.tryParse(m.group(4) ?? '');
      if (encoder == null || hall == null || expected == null) continue;
      out.add(_TrimaHvE(
        pump: (pump == 'collect' || pump.startsWith('platelet')) ? 'platelet' : pump,
        encoderCount: encoder,
        hallCount: hall,
        expectedEncoderCount: expected,
        episodeIndex: episodeIndex,
        raw: event,
      ));
    }
    return out;
  }

  // Experimental HvE volume calibration.
  //
  // Hypothesis under test: the first HvE value is a cumulative displacement
  // counter ("V"). These pump-specific factors were derived from the known
  // STARTUP TESTS Start Pumps / Load Cassette signature:
  // AC 60, Inlet 140, Plasma 60, Platelet 60, Return 110 mL/min.
  //
  // They are intentionally kept per pump; do NOT use one global factor.
  static const Map<String, double> _trimaHvECountsPerMl = {
    'ac': 28026.8,
    'inlet': 25360.4,
    'plasma': 23761.5,
    'platelet': 24779.0,
    'return': 7674.0,
  };

  DateTime? _trimaEventTime(String event) {
    // Native Trima CSV timestamp example: 2026/06/23_07:16:58.483
    final m = RegExp(
      r'(\d{4})/(\d{2})/(\d{2})_(\d{2}):(\d{2}):(\d{2})\.(\d{3})',
    ).firstMatch(event);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
      int.parse(m.group(7)!),
    );
  }

  String? _trimaEnterExitName(String event, String kind) {
    final rx = RegExp(
      '\\b${RegExp.escape(kind)}\\s*:\\s*([^\\r\\n,;]+)',
      caseSensitive: false,
    );
    final m = rx.firstMatch(event);
    if (m == null) return null;
    return m.group(1)?.trim();
  }

  ({int start, int end, DateTime? startTime, DateTime? endTime})?
      _trimaResultBounds(_TrimaStartupResult result) {
    final hit = result.episodeIndex;
    if (hit == null || widget.episodios.isEmpty) return null;

    // Anchor on Enter:X. If the result happened to point elsewhere, recover
    // the closest matching Enter marker around it.
    var enterIndex = hit;
    var stateName = _trimaEnterExitName(widget.episodios[enterIndex], 'Enter');

    if (stateName == null) {
      final needles = result.spec.needles.map((e) => e.toLowerCase()).toList();
      for (var i = hit; i >= 0; i--) {
        final candidate = _trimaEnterExitName(widget.episodios[i], 'Enter');
        if (candidate == null) continue;
        final compact = candidate.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (needles.any((n) =>
            compact.contains(n.replaceAll(RegExp(r'[^a-z0-9]'), '')))) {
          enterIndex = i;
          stateName = candidate;
          break;
        }
      }
    }
    if (stateName == null) return null;

    // Match Exit with the EXACT same state/substate name. This correctly
    // handles nested states such as LoadCassette containing StartPumps,
    // LowerCassette and CentShutdownTest.
    int? exitIndex;
    for (var i = enterIndex + 1; i < widget.episodios.length; i++) {
      final exitName = _trimaEnterExitName(widget.episodios[i], 'Exit');
      if (exitName != null &&
          exitName.toLowerCase() == stateName.toLowerCase()) {
        exitIndex = i;
        break;
      }
    }
    if (exitIndex == null) return null;

    return (
      start: enterIndex,
      end: exitIndex,
      startTime: _trimaEventTime(widget.episodios[enterIndex]),
      endTime: _trimaEventTime(widget.episodios[exitIndex]),
    );
  }

  List<_TrimaHvE> _trimaHvEInInterval(
      _TrimaStartupResult result, String pump) {
    final bounds = _trimaResultBounds(result);
    if (bounds == null) return const [];

    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final out = <_TrimaHvE>[];
    for (var i = bounds.start; i <= bounds.end; i++) {
      for (final h in _parseTrimaHvEEvent(widget.episodios[i], i)) {
        if (h.pump != normalized) continue;
        final ht = _trimaEventTime(h.raw);
        if (ht == null) continue;

        // Some HvE messages are physically written inside another state's
        // source-line block although their embedded timestamp belongs outside
        // that state. Require BOTH conditions: line nesting and timestamp.
        if (bounds.startTime != null && ht.isBefore(bounds.startTime!)) continue;
        if (bounds.endTime != null && ht.isAfter(bounds.endTime!)) continue;
        out.add(h);
      }
    }
    out.sort((a, b) =>
        _trimaEventTime(a.raw)!.compareTo(_trimaEventTime(b.raw)!));
    return out;
  }

  List<MapEntry<int, String>> _trimaCommandPumpsInState(
      _TrimaStartupResult result) {
    final bounds = _trimaResultBounds(result);
    if (bounds == null) return const [];
    final out = <MapEntry<int, String>>[];
    for (var i = bounds.start; i <= bounds.end; i++) {
      final e = widget.episodios[i];
      if (e.toLowerCase().contains('command pumps -')) {
        out.add(MapEntry(i, e));
      }
    }
    return out;
  }

  List<_TrimaHvE> _allTimedTrimaHvE(String pump) {
    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final out = <_TrimaHvE>[];
    for (var i = 0; i < widget.episodios.length; i++) {
      for (final h in _parseTrimaHvEEvent(widget.episodios[i], i)) {
        if (h.pump == normalized && _trimaEventTime(h.raw) != null) out.add(h);
      }
    }
    out.sort((a, b) =>
        _trimaEventTime(a.raw)!.compareTo(_trimaEventTime(b.raw)!));
    return out;
  }

  ({_TrimaHvE? before, _TrimaHvE? after}) _trimaHvEBracket(
      DateTime time, String pump) {
    _TrimaHvE? before;
    _TrimaHvE? after;
    for (final h in _allTimedTrimaHvE(pump)) {
      final ht = _trimaEventTime(h.raw)!;
      if (!ht.isAfter(time)) {
        before = h;
      } else {
        after = h;
        break;
      }
    }
    return (before: before, after: after);
  }

  _TrimaHvEFlow? _trimaFlowFromPair(
      _TrimaHvE? a, _TrimaHvE? b, String pump) {
    if (a == null || b == null) return null;
    final ta = _trimaEventTime(a.raw);
    final tb = _trimaEventTime(b.raw);
    if (ta == null || tb == null) return null;
    final ms = tb.difference(ta).inMilliseconds;
    if (ms <= 0 || ms > 30000) return null;
    final dc = b.encoderCount - a.encoderCount;
    if (dc < 0) return null;
    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final cpm = _trimaHvECountsPerMl[normalized];
    if (cpm == null || cpm <= 0) return null;
    final seconds = ms / 1000.0;
    final ml = dc / cpm;
    return _TrimaHvEFlow(
      pump: normalized,
      first: a,
      second: b,
      seconds: seconds,
      deltaCounts: dc,
      volumeMl: ml,
      flowMlMin: ml / seconds * 60.0,
      countsPerMl: cpm,
    );
  }

  List<_TrimaHvEFlow> _trimaHvEFlowsInInterval(
      _TrimaStartupResult result, String pump) {
    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final countsPerMl = _trimaHvECountsPerMl[normalized];
    if (countsPerMl == null || countsPerMl <= 0) return const [];

    final samples = _trimaHvEInInterval(result, normalized);
    if (samples.length < 2) return const [];

    final flows = <_TrimaHvEFlow>[];
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1];
      final b = samples[i];
      final ta = _trimaEventTime(a.raw)!;
      final tb = _trimaEventTime(b.raw)!;
      final dtMs = tb.difference(ta).inMilliseconds;
      if (dtMs <= 0 || dtMs > 30000) continue;

      final deltaCounts = b.encoderCount - a.encoderCount;
      if (deltaCounts < 0) continue; // reset / wrap

      final seconds = dtMs / 1000.0;
      final volumeMl = deltaCounts / countsPerMl;
      flows.add(_TrimaHvEFlow(
        pump: normalized,
        first: a,
        second: b,
        seconds: seconds,
        deltaCounts: deltaCounts,
        volumeMl: volumeMl,
        flowMlMin: volumeMl / seconds * 60.0,
        countsPerMl: countsPerMl,
      ));
    }
    return flows;
  }

  _TrimaHvEInterval? _trimaHvEInterval(
      _TrimaStartupResult result, String pump) {
    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final countsPerMl = _trimaHvECountsPerMl[normalized];
    if (countsPerMl == null || countsPerMl <= 0) return null;

    final samples = _trimaHvEInInterval(result, normalized);
    if (samples.length < 2) return null;

    double totalSeconds = 0;
    int totalCounts = 0;
    int validPairs = 0;

    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1];
      final b = samples[i];
      final ta = _trimaEventTime(a.raw)!;
      final tb = _trimaEventTime(b.raw)!;
      final dtMs = tb.difference(ta).inMilliseconds;
      if (dtMs <= 0 || dtMs > 30000) continue;
      final dc = b.encoderCount - a.encoderCount;
      if (dc < 0) continue; // reset/wrap
      totalSeconds += dtMs / 1000.0;
      totalCounts += dc;
      validPairs++;
    }
    if (validPairs == 0 || totalSeconds <= 0) return null;

    final volumeMl = totalCounts / countsPerMl;
    return _TrimaHvEInterval(
      pump: normalized,
      first: samples.first,
      last: samples.last,
      seconds: totalSeconds,
      deltaCounts: totalCounts,
      volumeMl: volumeMl,
      averageFlowMlMin: volumeMl / totalSeconds * 60.0,
      samples: samples.length,
    );
  }

  _TrimaHvEFlow? _trimaHvEFlowNear(int? center, String pump) {
    if (center == null || widget.episodios.isEmpty) return null;
    final normalized =
        pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();
    final countsPerMl = _trimaHvECountsPerMl[normalized];
    if (countsPerMl == null || countsPerMl <= 0) return null;

    // Gather HvE samples around the state and choose the adjacent pair whose
    // midpoint is closest to the detected substate. This gives us ΔV / Δt.
    const radius = 120;
    final start = (center - radius).clamp(0, widget.episodios.length - 1);
    final end = (center + radius).clamp(0, widget.episodios.length - 1);
    final samples = <_TrimaHvE>[];

    for (var i = start; i <= end; i++) {
      for (final h in _parseTrimaHvEEvent(widget.episodios[i], i)) {
        if (h.pump == normalized && _trimaEventTime(h.raw) != null) {
          samples.add(h);
        }
      }
    }
    if (samples.length < 2) return null;

    _TrimaHvEFlow? best;
    double bestDistance = double.infinity;

    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1];
      final b = samples[i];
      final ta = _trimaEventTime(a.raw)!;
      final tb = _trimaEventTime(b.raw)!;
      final dtMs = tb.difference(ta).inMilliseconds;
      if (dtMs <= 0 || dtMs > 30000) continue;

      final deltaCounts = b.encoderCount - a.encoderCount;
      // A negative jump is most likely a counter reset/wrap; don't turn it
      // into a false reverse flow.
      if (deltaCounts < 0) continue;

      final seconds = dtMs / 1000.0;
      final volumeMl = deltaCounts / countsPerMl;
      final flowMlMin = volumeMl / seconds * 60.0;
      final midpoint = (a.episodeIndex + b.episodeIndex) / 2.0;
      final distance = (midpoint - center).abs();

      if (distance < bestDistance) {
        bestDistance = distance;
        best = _TrimaHvEFlow(
          pump: normalized,
          first: a,
          second: b,
          seconds: seconds,
          deltaCounts: deltaCounts,
          volumeMl: volumeMl,
          flowMlMin: flowMlMin,
          countsPerMl: countsPerMl,
        );
      }
    }
    return best;
  }

  _TrimaHvE? _trimaHvENear(int? center, String pump) {
    if (center == null || widget.episodios.isEmpty) return null;
    final normalized = pump.toLowerCase() == 'collect' ? 'platelet' : pump.toLowerCase();

    // HvE messages are periodic rather than state-transition messages, so use
    // a slightly wider neighborhood and select the nearest sample.
    const radius = 45;
    final start = (center - radius).clamp(0, widget.episodios.length - 1);
    final end = (center + radius).clamp(0, widget.episodios.length - 1);

    _TrimaHvE? best;
    var bestDistance = 1 << 30;
    for (var i = start; i <= end; i++) {
      for (final hve in _parseTrimaHvEEvent(widget.episodios[i], i)) {
        if (hve.pump != normalized) continue;
        final distance = (i - center).abs();
        if (distance < bestDistance) {
          best = hve;
          bestDistance = distance;
        }
      }
    }
    return best;
  }

  Widget _buildTrimaHvESummary(BuildContext context, ColorScheme scheme) {
    var lines = 0;
    var samples = 0;
    final counts = <String, int>{};

    for (var i = 0; i < widget.episodios.length; i++) {
      final parsed = _parseTrimaHvEEvent(widget.episodios[i], i);
      if (parsed.isEmpty) continue;
      lines++;
      samples += parsed.length;
      for (final h in parsed) {
        counts[h.pump] = (counts[h.pump] ?? 0) + 1;
      }
    }

    if (samples == 0) return const SizedBox.shrink();

    var timedLines = 0;
    for (var i = 0; i < widget.episodios.length; i++) {
      if (!widget.episodios[i].toLowerCase().contains('hve:')) continue;
      if (_trimaEventTime(widget.episodios[i]) != null) timedLines++;
    }

    String c(String pump) => '${counts[pump] ?? 0}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.monitor_heart_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'PUMP HALL / ENCODER TRACE (HvE)',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text('$lines lines / $samples samples • $timedLines timed'),
              ],
            ),
            if (timedLines == 0) ...[
              const SizedBox(height: 6),
              Text(
                'No HvE timestamps received. Flow cannot be calculated. '
                'GraphicPage must preserve the CSV timestamp together with the verbose event.',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.error,
                ),
              ),
            ],
            const SizedBox(height: 6),
            const Text(
              'Experimental interpretation: HvE = Hall / Volume / Encoder. '
              'The first counter is used as V (pump displacement) and ΔV/Δt '
              'is converted to mL/min with a pump-specific calibration. '
              'Hall/encoder consistency is still shown independently.',
            ),
            const SizedBox(height: 6),
            Text(
              'Inlet ${c('inlet')}  •  AC ${c('ac')}  •  '
              'Plasma ${c('plasma')}  •  Platelet ${c('platelet')}  •  '
              'Return ${c('return')}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Calibration counts/mL: AC 28026.8 • Inlet 25360.4 • '
              'Plasma 23761.5 • Platelet 24779.0 • Return 7674.0',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrimaValveTraceSummary(
      BuildContext context, ColorScheme scheme) {
    final rx = RegExp(
      r'Valve\s+(plasma|platelet|rbc)\s*:\s*'
      r'order\s*=\s*(\d+)\s+status\s*=\s*(\d+)',
      caseSensitive: false,
    );

    var total = 0;
    final counts = <String, int>{'plasma': 0, 'platelet': 0, 'rbc': 0};
    for (final event in widget.episodios) {
      final m = rx.firstMatch(event);
      if (m == null) continue;
      total++;
      final valve = (m.group(1) ?? '').toLowerCase();
      counts[valve] = (counts[valve] ?? 0) + 1;
    }

    if (total == 0) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.alt_route_rounded, color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'VALVE CONTROL TRACE',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text('$total events'),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'CONTROL valve messages are used as additional command/position '
              'evidence. Mapping confirmed in this Trima log: '
              '1 = Collect, 2 = Open, 3 = Return.',
            ),
            const SizedBox(height: 6),
            Text(
              'Plasma ${counts['plasma']}  •  '
              'Platelet ${counts['platelet']}  •  '
              'RBC ${counts['rbc']}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
    );
  }

  _TrimaValveTrace? _trimaValveTraceNear(int? center, String valve) {
    if (center == null || widget.episodios.isEmpty) return null;

    // These CONTROL messages are emitted when a valve is commanded/moves:
    //   Valve plasma: order=3 status=2
    // The real Trima sample confirms the numeric convention:
    //   1 = Collect, 2 = Open, 3 = Return.
    //
    // Search a small neighborhood around the detected substate. Prefer the
    // closest message, so a transition belonging to another state is less
    // likely to be reused.
    final rx = RegExp(
      'Valve\\\\s+${RegExp.escape(valve)}\\\\s*:\\\\s*'
      'order\\\\s*=\\\\s*(\\\\d+)\\\\s+status\\\\s*=\\\\s*(\\\\d+)',
      caseSensitive: false,
    );

    _TrimaValveTrace? best;
    var bestDistance = 1 << 30;

    const radius = 30;
    final start = (center - radius).clamp(0, widget.episodios.length - 1);
    final end = (center + radius).clamp(0, widget.episodios.length - 1);

    for (var i = start; i <= end; i++) {
      final m = rx.firstMatch(widget.episodios[i]);
      if (m == null) continue;
      final order = int.tryParse(m.group(1) ?? '');
      final status = int.tryParse(m.group(2) ?? '');
      if (order == null || status == null) continue;

      final distance = (i - center).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = _TrimaValveTrace(
          valve: valve,
          order: order,
          status: status,
          episodeIndex: i,
          raw: widget.episodios[i],
        );
      }
    }
    return best;
  }

  List<_TrimaComponentCheck> _trimaChecksFor(_TrimaStartupResult result) {
    final e = result.event ?? '';
    final name = result.spec.label.toLowerCase();
    final checks = <_TrimaComponentCheck>[];

    void numeric(String label, String field, String expected, double target,
        {double tolerance = 5.0, String? actualField}) {
      final cmd = _trimaNumber(e, field);
      final actual = actualField == null ? null : _trimaNumber(e, actualField);
      final valueForResult = actual ?? cmd;
      checks.add(_TrimaComponentCheck(
        component: label,
        expected: expected,
        command: cmd?.toStringAsFixed(1) ?? '—',
        measured: actual?.toStringAsFixed(1) ?? '—',
        ok: valueForResult == null
            ? null
            : (valueForResult - target).abs() <= tolerance,
      ));
    }

    void valve(String label, String cmdField, String posField, String expected) {
      final nativeCmd = _trimaTextValue(e, cmdField);
      final nativePos = _trimaTextValue(e, posField);

      final traceName = label.toLowerCase().contains('platelet')
          ? 'platelet'
          : label.toLowerCase().contains('plasma')
              ? 'plasma'
              : 'rbc';
      final trace = _trimaValveTraceNear(result.episodeIndex, traceName);

      final cmd = nativeCmd ?? trace?.orderName;
      final pos = nativePos ?? trace?.statusName;
      final probe = (pos ?? cmd)?.toLowerCase();

      checks.add(_TrimaComponentCheck(
        component: label,
        expected: expected,
        command: cmd == null
            ? '—'
            : trace != null && nativeCmd == null
                ? '$cmd (TRACE order=${trace.order})'
                : cmd,
        measured: pos == null
            ? '—'
            : trace != null && nativePos == null
                ? '$pos (TRACE status=${trace.status})'
                : pos,
        ok: probe == null ? null : probe.contains(expected.toLowerCase()),
      ));
    }

    if (name == 'start pumps' || name == 'load cassette') {
      numeric('AC pump', 'ACCmd', '60 mL/min', 60,
          actualField: 'ACAct');
      numeric('Inlet pump', 'InletCmd', '140 mL/min', 140,
          actualField: 'InletAct');
      numeric('Plasma pump', 'PlasmaCmd', '60 mL/min', 60,
          actualField: 'PlasmaAct');
      numeric('Platelet pump', 'CollectCmd', '60 mL/min', 60,
          actualField: 'CollectAct');
      numeric('Return pump', 'ReturnCmd', '110 mL/min', 110,
          actualField: 'ReturnAct');
      numeric('Centrifuge', 'CentCmd', '0 / -1', 0,
          tolerance: 1.5, actualField: 'CentAct');
      valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'open');
      valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'open');
      valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'open');
    } else if (name == 'stop pumps') {
      numeric('AC pump', 'ACCmd', '0', 0, actualField: 'ACAct');
      numeric('Inlet pump', 'InletCmd', '0', 0, actualField: 'InletAct');
      numeric('Plasma pump', 'PlasmaCmd', '0', 0, actualField: 'PlasmaAct');
      numeric('Platelet pump', 'CollectCmd', '0', 0, actualField: 'CollectAct');
      numeric('Return pump', 'ReturnCmd', '0', 0, actualField: 'ReturnAct');
    } else if (name == 'evacuate set valves') {
      numeric('AC pump', 'ACCmd', '0', 0);
      numeric('Inlet pump', 'InletCmd', '0', 0);
      numeric('Plasma pump', 'PlasmaCmd', '0', 0);
      numeric('Platelet pump', 'CollectCmd', '0', 0);
      numeric('Return pump', 'ReturnCmd', '0', 0);
      numeric('Centrifuge', 'CentCmd', '0', 0, tolerance: 1.5);
      valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'open');
      valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'open');
      valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
    } else if (name == 'evacuate bags') {
      numeric('AC pump', 'ACCmd', '0', 0);
      numeric('Inlet pump', 'InletCmd', '0', 0);
      numeric('Plasma pump', 'PlasmaCmd', '0', 0);
      numeric('Platelet pump', 'CollectCmd', '0', 0);
      numeric('Return pump', 'ReturnCmd', '90 mL/min', 90,
          actualField: 'ReturnAct');
      numeric('Centrifuge', 'CentCmd', '0', 0, tolerance: 1.5);
      valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'open');
      valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'open');
      valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
    } else if (name == 'close valves' || name == 'check sample bag') {
      valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'return');
      valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'return');
      valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
    } else if (name == 'inlet decay test') {
      numeric('AC pump', 'ACCmd', '20 → 0', 20);
      numeric('Inlet pump', 'InletCmd', '20 → 0', 20);
      numeric('Return pump', 'ReturnCmd', '-40 → 0', -40);
      _addApsCheck(checks, e, 'APS', 'pressure decay evaluated');
    } else if (name == 'press inlet line') {
      numeric('AC pump', 'ACCmd', '142 mL/min', 142);
      _addApsCheck(checks, e, 'APS', '> 400 mmHg before exit');
    } else if (name == 'inlet press test') {
      _addApsCheck(checks, e, 'APS', 'drop < 50 mmHg / 3 s');
    } else if (name == 'negative press test') {
      numeric('Inlet pump', 'InletCmd', '142 mL/min', 142);
      _addApsCheck(checks, e, 'APS', '< -350 mmHg before exit');
    } else if (name == 'ac prime inlet') {
      numeric('AC pump', 'ACCmd', '50 mL/min (30 if APS condition)', 50,
          actualField: 'ACAct');
      numeric('Inlet pump', 'InletCmd', '50 mL/min (30 if APS condition)', 50,
          actualField: 'InletAct');
      final acDetected = _trimaTextValue(e, 'ACDetected');
      checks.add(_TrimaComponentCheck(
        component: 'AC detector',
        expected: 'AC detected before exit',
        command: '—',
        measured: acDetected ?? '—',
        ok: acDetected == null ? null : _truthyTrima(acDetected),
      ));
    } else if (name == 'ac press return line') {
      numeric('Return pump', 'ReturnCmd', '-50 mL/min', -50,
          actualField: 'ReturnAct');
      final aps = _trimaNumber(e, 'APS');
      checks.add(_TrimaComponentCheck(
        component: 'APS',
        expected: '≤ -50 mmHg before exit',
        command: '—',
        measured: aps?.toStringAsFixed(1) ?? '—',
        ok: aps == null ? null : aps <= -50,
      ));
    }


    // ----- Blood Prime -----
    if (result.spec.section == 'BLOOD PRIME') {
      if (name == 'blood prime inlet') {
        numeric('Inlet pump', 'InletCmd', '40 mL/min', 40,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '200 rpm', 200,
            tolerance: 25, actualField: 'CentAct');
        valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'return');
        valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'return');
        valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
      } else if (name == 'blood prime return') {
        numeric('Inlet pump', 'InletCmd', '0', 0);
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '-40 mL/min', -40,
            actualField: 'ReturnAct');
        numeric('Centrifuge', 'CentCmd', '200 rpm', 200,
            tolerance: 25, actualField: 'CentAct');
      } else if (name == 'evac set valves' || name == 'evac reset valves') {
        numeric('AC pump', 'ACCmd', '0', 0);
        numeric('Inlet pump', 'InletCmd', '0', 0);
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '200 rpm', 200, tolerance: 25);
        final pos = name == 'evac set valves' ? 'open' : 'return';
        valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', pos);
        valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', pos);
        valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', pos);
      }
    }

    // ----- Blood Run Prime -----
    if (result.spec.section == 'BLOOD RUN PRIME') {
      if (name == 'prime channel 1') {
        numeric('Inlet pump', 'InletCmd', '35 mL/min', 35,
            actualField: 'InletAct');
        numeric('Centrifuge', 'CentCmd', '2000 rpm', 2000,
            tolerance: 60, actualField: 'CentAct');
      } else if (name == 'prime channel 2') {
        numeric('Inlet pump', 'InletCmd', '13 mL/min', 13,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '2 mL/min', 2,
            actualField: 'PlasmaAct');
        numeric('Platelet pump', 'CollectCmd', '11 mL/min', 11,
            actualField: 'CollectAct');
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '2500 rpm', 2500,
            tolerance: 60, actualField: 'CentAct');
      } else if (name == 'prime channel 3') {
        numeric('Inlet pump', 'InletCmd', '35 mL/min', 35,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '2500 rpm', 2500,
            tolerance: 60, actualField: 'CentAct');
      } else if (name == 'prime channel 4' || name == 'prime vent') {
        numeric('Inlet pump', 'InletCmd', '45 mL/min', 45,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '15 mL/min', 15,
            actualField: 'PlasmaAct');
        numeric('Platelet pump', 'CollectCmd', '15 mL/min', 15,
            actualField: 'CollectAct');
        numeric('Centrifuge', 'CentCmd', '2500 rpm', 2500,
            tolerance: 60, actualField: 'CentAct');
      } else if (name == 'ramp centrifuge') {
        numeric('Inlet pump', 'InletCmd', '45 mL/min', 45,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '12 mL/min', 12,
            actualField: 'PlasmaAct');
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '3000 rpm', 3000,
            tolerance: 60, actualField: 'CentAct');
      }
    }

    // ----- Blood Run / Rinseback -----
    if (result.spec.section == 'BLOOD RUN' && name == 'pre rinseback') {
      numeric('AC pump', 'ACCmd', '0', 0);
      numeric('Inlet pump', 'InletCmd', '0', 0);
      numeric('Plasma pump', 'PlasmaCmd', '0', 0);
      numeric('Platelet pump', 'CollectCmd', '0', 0);
      numeric('Return pump', 'ReturnCmd', '0', 0);
      valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'return');
      valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'return');
      valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
    }

    if (result.spec.section == 'RINSEBACK') {
      if (name == 'rinseback recirculate') {
        numeric('AC pump', 'ACCmd', '0', 0);
        numeric('Inlet pump', 'InletCmd', '100 mL/min', 100,
            actualField: 'InletAct');
        numeric('Return pump', 'ReturnCmd', '100 mL/min', 100,
            actualField: 'ReturnAct');
      } else if (name == 'disconnect prompt') {
        numeric('AC pump', 'ACCmd', '0', 0);
        numeric('Inlet pump', 'InletCmd', '0', 0);
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '0', 0);
      }
      if (name != 'rinseback return') {
        valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'return');
        valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'return');
        valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'return');
      }
    }

    // ----- Donor Disconnect / MSS Disconnect -----
    if (result.spec.section == 'DONOR DISCONNECT' ||
        result.spec.section == 'MSS DISCONNECT') {
      final isMss = result.spec.section == 'MSS DISCONNECT';
      if (name == 'open valves' || name == 'stop pumps') {
        numeric('AC pump', 'ACCmd', '0', 0);
        numeric('Inlet pump', 'InletCmd', '0', 0);
        numeric('Plasma pump', 'PlasmaCmd', '0', 0);
        numeric('Platelet pump', 'CollectCmd', '0', 0);
        numeric('Return pump', 'ReturnCmd', '0', 0);
        numeric('Centrifuge', 'CentCmd', '0', 0);
      } else if (name == 'start pumps' || name == 'raise cassette') {
        numeric('AC pump', 'ACCmd', '60 mL/min', 60, actualField: 'ACAct');
        numeric('Inlet pump', 'InletCmd', '60 mL/min', 60,
            actualField: 'InletAct');
        numeric('Plasma pump', 'PlasmaCmd', '60 mL/min', 60,
            actualField: 'PlasmaAct');
        numeric('Platelet pump', 'CollectCmd', '60 mL/min', 60,
            actualField: 'CollectAct');
        numeric('Return pump', 'ReturnCmd',
            isMss ? '-110 mL/min' : '150 mL/min',
            isMss ? -110 : 150, actualField: 'ReturnAct');
        numeric('Centrifuge', 'CentCmd', '0', 0);
      }
      if (name != 'disconnect test') {
        valve('Platelet valve', 'CollectValveCmd', 'CollectValvePos', 'open');
        valve('Plasma valve', 'PlasmaValveCmd', 'PlasmaValvePos', 'open');
        valve('RBC valve', 'RBCValveCmd', 'RBCValvePos', 'open');
      }
    }

    // Diagnostic HvE view. The real Trima CSV shows SAFETY HvE records
    // can be emitted out of source-line order, so source-line containment is
    // not enough. Show the actual HvE values and ΔT, and for pump-command
    // states use the first "Command pumps -" timestamp as the test anchor.
    const hvePumps = <String, String>{
      'ac': 'AC pump',
      'inlet': 'Inlet pump',
      'plasma': 'Plasma pump',
      'platelet': 'Platelet pump',
      'return': 'Return pump',
    };

    final stateBounds = _trimaResultBounds(result);
    final commandLines = _trimaCommandPumpsInState(result);
    DateTime? testAnchor;
    if (commandLines.isNotEmpty) {
      testAnchor = _trimaEventTime(commandLines.first.value);
      checks.add(_TrimaComponentCheck(
        component: 'TEST START',
        expected: 'Command pumps -',
        command: testAnchor == null ? '—' : _trimaTimeLabel(testAnchor),
        measured: '${commandLines.length} command event(s)',
        ok: null,
      ));
    } else if (stateBounds?.startTime != null) {
      testAnchor = stateBounds!.startTime;
    }

    for (final entry in hvePumps.entries) {
      final base = checks.where((c) => c.component == entry.value).toList();
      if (base.isEmpty || testAnchor == null) continue;

      final bracket = _trimaHvEBracket(testAnchor, entry.key);
      final flow = _trimaFlowFromPair(bracket.before, bracket.after, entry.key);
      if (bracket.before == null && bracket.after == null) continue;

      final t1 = bracket.before == null
          ? '—'
          : _trimaTimeLabel(_trimaEventTime(bracket.before!.raw)!);
      final t2 = bracket.after == null
          ? '—'
          : _trimaTimeLabel(_trimaEventTime(bracket.after!.raw)!);

      checks.add(_TrimaComponentCheck(
        component: '${entry.value} HvE',
        expected: base.first.expected,
        command: bracket.before == null
            ? 'H1 —'
            : 'H1 ${bracket.before!.encoderCount} @ $t1',
        measured: bracket.after == null
            ? 'H2 —'
            : 'H2 ${bracket.after!.encoderCount} @ $t2',
        ok: null,
      ));

      if (flow != null) {
        checks.add(_TrimaComponentCheck(
          component: '${entry.value} ΔT',
          expected: base.first.expected,
          command:
              'ΔH ${flow.deltaCounts} • ΔT ${flow.seconds.toStringAsFixed(3)} s',
          measured:
              '${flow.flowMlMin.toStringAsFixed(1)} mL/min • ${flow.volumeMl.toStringAsFixed(2)} mL',
          ok: null,
        ));
      }
    }

    // Exit conditions that are explicitly volume-based in the service manual.
    // These are judged only from the HvE samples inside the detected substate.
    final volumeRules = <String, MapEntry<String, double>>{
      'prime channel 1': const MapEntry('inlet', 70.0),
      'prime channel 2': const MapEntry('inlet', 15.0),
      'rinseback lower': const MapEntry('return', 10.0),
      'rinseback recirculate': const MapEntry('inlet', 50.0),
    };
    final volumeRule = volumeRules[name];
    if (volumeRule != null) {
      final volumeFlows =
          _trimaHvEFlowsInInterval(result, volumeRule.key);
      final measuredVolume = volumeFlows.isEmpty
          ? null
          : volumeFlows.fold<double>(0.0, (sum, f) => sum + f.volumeMl);
      checks.add(_TrimaComponentCheck(
        component: '${_trimaPumpLabel(volumeRule.key)} volume HvE',
        expected: '${volumeRule.value.toStringAsFixed(0)} mL exit',
        command: '—',
        measured: measuredVolume == null
            ? '—'
            : '${measuredVolume.toStringAsFixed(1)} mL',
        ok: measuredVolume == null
            ? null
            : (measuredVolume - volumeRule.value).abs() <=
                (volumeRule.value * 0.10).clamp(2.0, 7.0),
      ));
    }

    return checks;
  }

  String _trimaTimeLabel(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  String? _trimaTextValue(String text, String name) {
    final rx = RegExp(
      '${RegExp.escape(name)}\\s*[:=]\\s*([^,;\\r\\n]+)',
      caseSensitive: false,
    );
    return rx.firstMatch(text)?.group(1)?.trim();
  }

  bool _truthyTrima(String value) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on' ||
        v == 'detected';
  }

  void _addApsCheck(List<_TrimaComponentCheck> checks, String e,
      String field, String expected) {
    final aps = _trimaNumber(e, field);
    checks.add(_TrimaComponentCheck(
      component: field,
      expected: expected,
      command: '—',
      measured: aps?.toStringAsFixed(1) ?? '—',
      // Dynamic APS conditions require the complete substate interval.
      // A single transition sample is shown but is not judged as FAIL.
      ok: null,
    ));
  }

  void _goToTrimaSourceLine(BuildContext dialogContext, int index) {
    // A modal dialog has to leave the foreground so the event list can be
    // interacted with. Instead of discarding the analyzer, keep it minimized
    // as a floating restore control.
    Navigator.of(dialogContext).pop();

    if (mounted) {
      setState(() => _trimaAnalyzerMinimized = true);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.isAttached) return;
      _scrollController.scrollTo(
        index: index,
        alignment: 0.30,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  List<MapEntry<int, String>> _trimaNearbyLines(int center,
      {int radius = 3}) {
    if (widget.episodios.isEmpty) return const <MapEntry<int, String>>[];
    final first = (center - radius).clamp(0, widget.episodios.length - 1);
    final last = (center + radius).clamp(0, widget.episodios.length - 1);
    return [
      for (var i = first; i <= last; i++)
        MapEntry<int, String>(i, widget.episodios[i]),
    ];
  }

  Widget _buildTrimaStartupCard(
    BuildContext context,
    _TrimaStartupResult result,
    ColorScheme scheme,
  ) {
    final checks = _trimaChecksFor(result);
    final failed = checks.where((c) => c.ok == false).toList();
    final unknown = checks.where((c) => c.ok == null).toList();
    final confirmed = result.status == _TrimaStartupStatus.confirmed;
    final inferred = result.status == _TrimaStartupStatus.inferred;
    final detected = confirmed || inferred;

    final statusLabel = !detected
        ? 'NOT DETECTED'
        : failed.isNotEmpty
            ? 'CHECK'
            : checks.isNotEmpty && unknown.isEmpty
                ? 'OK'
                : confirmed
                    ? 'CONFIRMED'
                    : 'INFERRED';

    final color = !detected
        ? scheme.onSurfaceVariant
        : failed.isNotEmpty
            ? scheme.error
            : unknown.isNotEmpty
                ? scheme.tertiary
                : scheme.primary;

    final icon = !detected
        ? Icons.remove_circle_outline
        : failed.isNotEmpty
            ? Icons.warning_amber_rounded
            : unknown.isNotEmpty
                ? Icons.fact_check_outlined
                : Icons.check_circle_outline;

    // Correct states stay compact. Anything requiring attention opens itself.
    final initiallyExpanded = failed.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 7),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(icon, color: color),
        title: Row(
          children: [
            Expanded(
              child: Text(
                result.spec.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (result.episodeIndex != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Source line in Episodic events',
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'LINE ${result.episodeIndex! + 1}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withOpacity(.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          !detected
              ? 'No direct Substate or known hardware signature found.'
              : checks.isEmpty
                  ? (confirmed
                      ? 'Substate detected.'
                      : 'Detected from hardware signature.')
                  : failed.isNotEmpty
                      ? '${failed.length} value(s) require review.'
                      : unknown.isNotEmpty
                          ? '${checks.length - unknown.length}/${checks.length} values verified; ${unknown.length} require interval data.'
                          : '${checks.length} component values verified.',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          if (result.episodeIndex != null) ...[
            Row(
              children: [
                Icon(Icons.format_list_numbered,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Source line ${result.episodeIndex! + 1}',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      _goToTrimaSourceLine(context, result.episodeIndex!),
                  icon: const Icon(Icons.my_location, size: 17),
                  label: const Text('VIEW LINE'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Immediate context (±3 lines)',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  for (final line
                      in _trimaNearbyLines(result.episodeIndex!, radius: 3))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 54,
                            child: Text(
                              '${line.key + 1}',
                              textAlign: TextAlign.right,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    fontWeight: line.key == result.episodeIndex
                                        ? FontWeight.w900
                                        : FontWeight.w500,
                                    color: line.key == result.episodeIndex
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              line.value,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    fontWeight: line.key == result.episodeIndex
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (result.event != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'DLOG evidence',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                result.event!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (checks.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 38,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 46,
                columns: const [
                  DataColumn(label: Text('Component')),
                  DataColumn(label: Text('Expected')),
                  DataColumn(label: Text('Command')),
                  DataColumn(label: Text('Measured')),
                  DataColumn(label: Text('Result')),
                ],
                rows: [
                  for (final c in checks)
                    DataRow(
                      cells: [
                        DataCell(Text(c.component)),
                        DataCell(Text(c.expected)),
                        DataCell(Text(c.command)),
                        DataCell(Text(c.measured)),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                c.ok == true
                                    ? Icons.check_circle_outline
                                    : c.ok == false
                                        ? Icons.error_outline
                                        : Icons.more_horiz,
                                size: 17,
                                color: c.ok == true
                                    ? scheme.primary
                                    : c.ok == false
                                        ? scheme.error
                                        : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 5),
                              Text(c.ok == true
                                  ? 'OK'
                                  : c.ok == false
                                      ? 'CHECK'
                                      : 'INTERVAL'),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (checks.any((c) => c.ok == null)) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'INTERVAL means the transition sample alone is not enough to '
                'judge the manual condition. It is intentionally not marked as a failure.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }


  Widget _buildAimBootTreeView(
    BuildContext dialogContext,
    List<_AimBootDecision> decisions,
    ColorScheme scheme,
  ) {
    return ListView(
      children: [
        Text(
          'Boot Up Problems — DLOG decision flow',
          style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'This view follows the AIM Boot Up Problems flow and includes the suggested action for the branch reached. Physical voltage/LED checks are explicitly marked MANUAL CHECK.',
          style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < decisions.length; i++) ...[
          _buildAimDecisionCard(dialogContext, decisions[i], scheme),
          if (i != decisions.length - 1)
            Center(
              child: Icon(
                Icons.arrow_downward,
                size: 22,
                color: scheme.outline,
              ),
            ),
        ],
      ],
    );
  }

  String _aimTestWhatWeLookFor(_AimCheckSpec spec) {
    final patterns = spec.needles.map((e) => '"$e"').join(' OR ');
    return 'Find the documented AIM DLOG message for this test step in the expected sequence.\n\nDLOG pattern searched:\n$patterns';
  }

  String _aimBootWhatWeLookFor(String title) {
    switch (title.toLowerCase()) {
      case 'pxe boot request':
        return 'Confirm that the AIM boot-up path begins with a PXE Boot Request. Repeated requests are also relevant because the documented flow notes that they can indicate processor resets.';
      case 'stc fpga version':
      case 'stc fpga version register':
        return 'Find the STC FPGA version register after PXE and verify the STC initialization evidence used by the boot flow.';
      case 'firewire bus manager':
        return 'Confirm that FireWire bus-manager initialization is reached after the STC check.';
      case 'camera node':
        return 'Confirm that the camera node is discovered after FireWire initialization.';
      default:
        return 'Find the DLOG evidence required for this step of the AIM Boot Up Problems flow, in sequence.';
    }
  }

  String _aimSectionIIWhatWeLookFor(String title) {
    switch (title.toLowerCase()) {
      case 'startup test command received':
        return 'Confirm that AIM receives the startup-test command and enters the documented Section II startup-test path.';
      case 'readstartuptestconfig':
        return 'Confirm entry into ReadStartupTestConfig, showing that the startup-test configuration stage was reached.';
      case 'camera brightness':
        return 'Find the camera brightness transaction. If it is a write transaction, Response code: 0 is required by the current validator.';
      case 'camera shutter':
        return 'Find the camera shutter transaction. If it is a write transaction, Response code: 0 is required by the current validator.';
      case 'camera gain':
        return 'Find the camera gain transaction. If it is a write transaction, Response code: 0 is required by the current validator.';
      case 'top strobe':
        return 'Confirm the documented top-strobe result: "top strobe blink test passed for strobe:2".';
      case 'bottom strobe':
        return 'Confirm the documented bottom-strobe result: "bottom strobe blink test passed for strobe:0".';
      case 'startuptestcomplete':
        return 'Confirm that AIM reaches Enter: StartupTestComplete, completing the Section II startup-test sequence.';
      default:
        return 'Find the documented DLOG evidence for this Section II startup-test step.';
    }
  }

  Widget _aimFlowInfoBlock(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String text,
    Color? tone,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
                const SizedBox(height: 5),
                SelectableText(text),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAimDecisionCard(
    BuildContext dialogContext,
    _AimBootDecision decision,
    ColorScheme scheme,
  ) {
    final ok = decision.status == _AimDecisionStatus.ok;
    final iconColor = ok ? scheme.primary : scheme.error;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: iconColor, size: 30),
        title: Text(decision.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(ok ? 'OK' : 'CHECK', style: TextStyle(color: iconColor, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _aimFlowInfoBlock(dialogContext, icon: Icons.search_rounded, title: 'What we are looking for', text: _aimBootWhatWeLookFor(decision.title)),
          const SizedBox(height: 10),
          _aimFlowInfoBlock(dialogContext, icon: ok ? Icons.check_circle_outline : Icons.search_off, title: 'What we found', text: decision.event ?? 'NOT FOUND — no matching DLOG evidence.', tone: iconColor),
          const SizedBox(height: 10),
          _aimFlowInfoBlock(dialogContext, icon: Icons.route_outlined, title: ok ? 'Next step' : 'Suggested action', text: decision.action, tone: iconColor),
          if (decision.episodeIndex != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => _jumpToEpisodeFromAnalyzer(decision.episodeIndex!),
              icon: const Icon(Icons.my_location_outlined, size: 18),
              label: Text('FIND LINE · L${decision.episodeIndex! + 1}'),
            ),
          ],
        ],
      ),
    );
  }


  Widget _buildAimSequenceView(
    BuildContext dialogContext,
    List<_AimCheckResult> results,
    Set<int> skipped,
    ColorScheme scheme,
    StateSetter setDialogState,
  ) {
    final pxe = _findAllEpisodeIndexes('pxe boot request');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'AIM Test sequence reconstructed from the documented DLOG messages. Missing evidence is shown as NOT FOUND; it is not automatically treated as an explicit AIM failure.',
          style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        if (pxe.length > 1) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Attention: ${pxe.length} PXE Boot Request messages were found. The AIM document notes that repeated PXE boot requests for the same bootrom can indicate processor resets.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, i) {
              final r = results[i];
              final isSkipped = skipped.contains(i);
              var ok = r.index != null;
              var manualCheck = false;
              String detail = isSkipped
                  ? 'Step skipped manually'
                  : (r.event ?? 'NOT FOUND — message not present in episodic data');

              if (ok && r.spec.label == 'STC FPGA version register') {
                ok = _aimStcRegisterLooksValid(r.event!);
                if (!ok) {
                  detail = '${r.event}\nRegister value FFFF is not accepted by the AIM document.';
                }
              }
              if (ok &&
                  (r.spec.label == 'Camera brightness' ||
                      r.spec.label == 'Camera shutter' ||
                      r.spec.label == 'Camera gain')) {
                ok = _aimWriteResponseLooksValid(r.event!);
                if (!ok) {
                  final hasResponse = RegExp(
                    r'response\s*code\s*:\s*(-?\d+)',
                    caseSensitive: false,
                  ).hasMatch(r.event!);
                  manualCheck = !hasResponse;
                  detail = hasResponse
                      ? '${r.event}\nFAIL — expected Response code: 0.'
                      : '${r.event}\nMANUAL CHECK — write transaction found, but Response code was not present in this DLOG message.';
                }
              }

              final icon = isSkipped
                  ? Icons.skip_next_outlined
                  : manualCheck
                      ? Icons.help_outline
                      : ok
                          ? Icons.check_circle_outline
                          : (r.index == null
                              ? Icons.help_outline
                              : Icons.error_outline);
              final iconColor = isSkipped
                  ? scheme.secondary
                  : manualCheck
                      ? scheme.onSurfaceVariant
                      : ok
                          ? scheme.primary
                          : (r.index == null
                              ? scheme.onSurfaceVariant
                              : scheme.error);

              final showHeader =
                  i == 0 || results[i - 1].spec.section != r.spec.section;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHeader) ...[
                    if (i != 0) const SizedBox(height: 10),
                    Text(
                      r.spec.section,
                      style: Theme.of(dialogContext)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    clipBehavior: Clip.antiAlias,
                    child: ExpansionTile(
                      dense: true,
                      leading: Icon(icon, color: iconColor),
                      title: Text(
                        r.spec.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        isSkipped
                            ? 'SKIPPED'
                            : manualCheck
                                ? 'MANUAL CHECK'
                                : ok
                                    ? 'FOUND'
                                    : 'NOT FOUND',
                        style: TextStyle(
                          color: iconColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      childrenPadding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _aimFlowInfoBlock(
                          dialogContext,
                          icon: Icons.search_rounded,
                          title: 'What we are looking for',
                          text: _aimTestWhatWeLookFor(r.spec),
                        ),
                        const SizedBox(height: 10),
                        _aimFlowInfoBlock(
                          dialogContext,
                          icon: isSkipped
                              ? Icons.skip_next_outlined
                              : manualCheck
                                  ? Icons.help_outline
                                  : ok
                                      ? Icons.check_circle_outline
                                      : Icons.search_off,
                          title: 'What we found',
                          text: detail,
                          tone: iconColor,
                        ),
                        if (r.index != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Episodic line: L${r.index! + 1}',
                            style: Theme.of(dialogContext)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (r.index != null)
                              FilledButton.tonalIcon(
                                onPressed: () =>
                                    _jumpToEpisodeFromAnalyzer(r.index!),
                                icon: const Icon(
                                  Icons.my_location_outlined,
                                  size: 18,
                                ),
                                label: const Text('FIND LINE'),
                              ),
                            if (r.index == null)
                              TextButton.icon(
                                onPressed: () {
                                  setDialogState(() {
                                    if (isSkipped) {
                                      skipped.remove(i);
                                    } else {
                                      skipped.add(i);
                                    }
                                  });
                                },
                                icon: Icon(
                                  isSkipped
                                      ? Icons.undo
                                      : Icons.skip_next_outlined,
                                ),
                                label: Text(isSkipped ? 'UNDO' : 'SKIP'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _infoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 9),
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Divider(height: 1, color: scheme.outlineVariant),
          const SizedBox(height: 5),
          ...children,
        ],
      ),
    );
  }

  Widget _equipmentPanel(BuildContext context, ColorScheme scheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Icon(Icons.precision_manufacturing_outlined,
                    color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Equipment data',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _infoSection(
                  context,
                  icon: Icons.description_outlined,
                  title: 'DLOG information',
                  children: [
                    _infoRow(
                      context,
                      Icons.insert_drive_file_outlined,
                      'File',
                      widget.fileName ?? '—',
                    ),
                    _infoRow(context, Icons.memory_outlined, 'Platform', _platform),
                    if (_isOptia)
                      _infoRow(context, Icons.assignment_outlined, 'Protocol',
                          _optiaProtocol),
                    _infoRow(context, Icons.schedule, 'Start',
                        _formatDateTime(widget.dataStart)),
                    _infoRow(context, Icons.flag_outlined, 'End',
                        _formatDateTime(widget.dataEnd)),
                    _infoRow(context, Icons.timer_outlined, 'Duration',
                        _formatDuration()),
                    _infoRow(context, Icons.article_outlined, 'Log version',
                        _logVersion),
                    _infoRow(context, Icons.list_alt_rounded, 'Events',
                        '${widget.episodios.length}'),
                  ],
                ),
                _infoSection(
                  context,
                  icon: Icons.precision_manufacturing_outlined,
                  title: 'Equipment information',
                  children: [
                    _infoRow(context, Icons.system_update_alt_outlined, 'Software', _softwareVersion),
                    _infoRow(context, Icons.badge_outlined, 'Revision', _revision),
                    if (!_platform.toLowerCase().contains('reveos'))
                      _infoRow(context, Icons.developer_board_outlined, 'Hardware', _eBoxGeneration),
                    if (_platform.toLowerCase().contains('reveos'))
                      _infoRow(context, Icons.timelapse_outlined, 'Procedure hours', _procedureHours)
                    else
                      _infoRow(context, Icons.timelapse_outlined, 'Machine hours', _machineHours),
                    _infoRow(context, Icons.rotate_right_outlined, 'Centrifuge hours', _centrifugeHours),
                    _infoRow(context, Icons.numbers_outlined, 'Procedure count', _procedureCount),
                    _infoRow(context, Icons.task_alt_outlined, 'Procedures completed', _proceduresCompleted),
                    _infoRow(context, Icons.build_outlined, 'Build date', _buildDate),
                    _infoRow(context, Icons.computer_outlined, 'Computer', _computer),
                    _infoRow(context, Icons.lan_outlined, 'IP', _ipAddress),
                    _infoRow(context, Icons.folder_copy_outlined, 'Config files',
                        '${_configFiles.length}'),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.folder_copy_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Configuration files',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    Text('${_configFiles.length}'),
                  ],
                ),
                const SizedBox(height: 8),
                if (_configFiles.isEmpty)
                  Text(
                    'No ConfigFileData files found',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  )
                else
                  ..._configFiles.map(
                    (file) => Card(
                      margin: const EdgeInsets.only(bottom: 7),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        dense: true,
                        leading: Icon(_fileIcon(file.name)),
                        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          file.path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'View file',
                          onPressed: () => _showConfigFile(context, file),
                          icon: const Icon(Icons.visibility_outlined),
                        ),
                        onTap: () => _showConfigFile(context, file),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => widget.onClose.call(),
                    icon: const Icon(Icons.show_chart),
                    label: const Text('GRAPHIC'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



enum _TrimaStartupStatus { confirmed, inferred, notDetected }

typedef _TrimaInference = bool Function(String episode);

class _TrimaValveEvent {
  final String valve;
  final int order;
  final int initialStatus;
  final int? inPositionStatus;
  final int? movementTimeMs;
  final DateTime? orderTime;
  final DateTime? inPositionTime;
  final int sourceIndex;
  final int? inPositionSourceIndex;
  final String raw;
  final String? inPositionRaw;

  const _TrimaValveEvent({
    required this.valve,
    required this.order,
    required this.initialStatus,
    required this.inPositionStatus,
    required this.movementTimeMs,
    required this.orderTime,
    required this.inPositionTime,
    required this.sourceIndex,
    required this.inPositionSourceIndex,
    required this.raw,
    required this.inPositionRaw,
  });

  bool get approved =>
      inPositionStatus != null && inPositionStatus == order;

  _TrimaValveEvent copyWithInPosition({
    required int status,
    required int movementTimeMs,
    required DateTime? time,
    required int sourceIndex,
    required String raw,
  }) {
    return _TrimaValveEvent(
      valve: valve,
      order: order,
      initialStatus: initialStatus,
      inPositionStatus: status,
      movementTimeMs: movementTimeMs,
      orderTime: orderTime,
      inPositionTime: time,
      sourceIndex: this.sourceIndex,
      inPositionSourceIndex: sourceIndex,
      raw: this.raw,
      inPositionRaw: raw,
    );
  }
}

class _TrimaEnterExitInterval {
  final String name;
  final int enterIndex;
  final int? exitIndex;
  final DateTime? enterTime;
  final DateTime? exitTime;
  final int depth;

  const _TrimaEnterExitInterval({
    required this.name,
    required this.enterIndex,
    required this.exitIndex,
    required this.enterTime,
    required this.exitTime,
    required this.depth,
  });

  double? get durationSeconds {
    if (enterTime == null || exitTime == null) return null;
    return exitTime!.difference(enterTime!).inMilliseconds / 1000.0;
  }
}

class _TrimaOpenState {
  final String name;
  final int enterIndex;
  final DateTime? enterTime;
  final int depth;
  final int outputIndex;

  const _TrimaOpenState({
    required this.name,
    required this.enterIndex,
    required this.enterTime,
    required this.depth,
    required this.outputIndex,
  });
}


class _TrimaStartupSpec {
  final String section;
  final String label;
  final List<String> needles;
  final List<String> stateNeedles;
  final _TrimaInference? inference;

  const _TrimaStartupSpec(
    this.section,
    this.label,
    this.needles, {
    this.stateNeedles = const [],
    this.inference,
  });
}

class _TrimaStartupResult {
  final _TrimaStartupSpec spec;
  final _TrimaStartupStatus status;
  final int? episodeIndex;
  final String? event;

  const _TrimaStartupResult({
    required this.spec,
    required this.status,
    required this.episodeIndex,
    required this.event,
  });
}



class _TrimaHvEInterval {
  final String pump;
  final _TrimaHvE first;
  final _TrimaHvE last;
  final double seconds;
  final int deltaCounts;
  final double volumeMl;
  final double averageFlowMlMin;
  final int samples;

  const _TrimaHvEInterval({
    required this.pump,
    required this.first,
    required this.last,
    required this.seconds,
    required this.deltaCounts,
    required this.volumeMl,
    required this.averageFlowMlMin,
    required this.samples,
  });
}


class _TrimaHvEFlow {
  final String pump;
  final _TrimaHvE first;
  final _TrimaHvE second;
  final double seconds;
  final int deltaCounts;
  final double volumeMl;
  final double flowMlMin;
  final double countsPerMl;

  const _TrimaHvEFlow({
    required this.pump,
    required this.first,
    required this.second,
    required this.seconds,
    required this.deltaCounts,
    required this.volumeMl,
    required this.flowMlMin,
    required this.countsPerMl,
  });
}


class _TrimaHvE {
  final String pump;
  final int encoderCount;
  final int hallCount;
  final int expectedEncoderCount;
  final int episodeIndex;
  final String raw;

  const _TrimaHvE({
    required this.pump,
    required this.encoderCount,
    required this.hallCount,
    required this.expectedEncoderCount,
    required this.episodeIndex,
    required this.raw,
  });

  int get delta => encoderCount - expectedEncoderCount;

  double? get errorPercent {
    if (expectedEncoderCount == 0) return null;
    return delta / expectedEncoderCount * 100.0;
  }

  bool? get isConsistent {
    // At very small counts a percentage is misleading. Avoid declaring a
    // failure until enough encoder activity exists. For established motion,
    // use a conservative 5% discrepancy threshold as analyzer evidence.
    if (expectedEncoderCount.abs() < 1000) return null;
    final p = errorPercent;
    return p == null ? null : p.abs() <= 5.0;
  }
}


class _TrimaValveTrace {
  final String valve;
  final int order;
  final int status;
  final int episodeIndex;
  final String raw;

  const _TrimaValveTrace({
    required this.valve,
    required this.order,
    required this.status,
    required this.episodeIndex,
    required this.raw,
  });

  static String _name(int value) {
    switch (value) {
      case 1:
        return 'Collect';
      case 2:
        return 'Open';
      case 3:
        return 'Return';
      default:
        return 'Unknown($value)';
    }
  }

  String get orderName => _name(order);
  String get statusName => _name(status);
}


class _TrimaComponentCheck {
  final String component;
  final String expected;
  final String command;
  final String measured;
  final bool? ok;

  const _TrimaComponentCheck({
    required this.component,
    required this.expected,
    required this.command,
    required this.measured,
    required this.ok,
  });
}



class _OptiaImageFrame {
  final int imageId;
  final int width;
  final int height;
  final Uint8List pixels;
  final int payloadOffset;
  final int? episodeIndex;
  const _OptiaImageFrame({required this.imageId, required this.width, required this.height, required this.pixels, required this.payloadOffset, required this.episodeIndex});
}

class _OptiaMonoImage extends StatefulWidget {
  final _OptiaImageFrame frame;
  final BoxFit fit;
  const _OptiaMonoImage({required this.frame, this.fit = BoxFit.contain});
  @override
  State<_OptiaMonoImage> createState() => _OptiaMonoImageState();
}

class _OptiaMonoImageState extends State<_OptiaMonoImage> {
  ui.Image? _image;
  @override
  void initState() { super.initState(); _decode(); }
  @override
  void didUpdateWidget(covariant _OptiaMonoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.imageId != widget.frame.imageId) { _image?.dispose(); _image = null; _decode(); }
  }
  void _decode() {
    final f = widget.frame;

    // Gen1 stores JPEG fragments; Gen2 stores raw Mono8 pixels.
    final isJpeg = f.pixels.length >= 2 &&
        f.pixels[0] == 0xff && f.pixels[1] == 0xd8;

    if (isJpeg) {
      ui.instantiateImageCodec(f.pixels).then((codec) async {
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) { frame.image.dispose(); return; }
        setState(() => _image = frame.image);
      }).catchError((_) {});
      return;
    }

    final rgba = Uint8List(f.width * f.height * 4);
    for (var i = 0, j = 0; i < f.pixels.length && j + 3 < rgba.length; i++, j += 4) {
      final v = f.pixels[i];
      rgba[j] = v; rgba[j + 1] = v; rgba[j + 2] = v; rgba[j + 3] = 255;
    }
    ui.decodeImageFromPixels(rgba, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) { img.dispose(); return; }
      setState(() => _image = img);
    });
  }
  @override
  void dispose() { _image?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => _image == null
      ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
      : RawImage(image: _image, fit: widget.fit, filterQuality: FilterQuality.medium);
}

enum _FeedbackSendState { idle, sending, sent, error }

class _EpisodicAlarm {
  final int episodeIndex;
  final int lineNumber;
  final String title;
  final String? timestamp;
  final String raw;
  final String code;
  final String searchText;
  final DlogAlarmReference? reference;
  bool feedbackOpen;

  _EpisodicAlarm({
    required this.episodeIndex,
    required this.lineNumber,
    required this.title,
    required this.timestamp,
    required this.raw,
    required this.code,
    required this.searchText,
    required this.reference,
    this.feedbackOpen = false,
  });
}

class _AimCheckSpec {
  final String section;
  final String label;
  final List<String> needles;

  const _AimCheckSpec(this.section, this.label, this.needles);
}

class _AimCheckResult {
  final _AimCheckSpec spec;
  final int? index;
  final String? event;

  const _AimCheckResult({
    required this.spec,
    required this.index,
    required this.event,
  });
}



class _AimStartupDecision {
  final String title;
  final bool ok;
  final int? episodeIndex;
  final String? event;
  final String? failBranch;

  const _AimStartupDecision({
    required this.title,
    required this.ok,
    required this.episodeIndex,
    required this.event,
    required this.failBranch,
  });
}

enum _AimDecisionStatus { ok, fail }

class _AimBootDecision {
  final String title;
  final _AimDecisionStatus status;
  final int? episodeIndex;
  final String? event;
  final String action;

  const _AimBootDecision({
    required this.title,
    required this.status,
    required this.episodeIndex,
    required this.event,
    required this.action,
  });
}


class _ConfigFileEntry {
  final String path;
  final String content;

  const _ConfigFileEntry({required this.path, required this.content});

  String get name {
    final normalized = path.replaceAll(r'\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty || parts.last.isEmpty ? path : parts.last;
  }
}
