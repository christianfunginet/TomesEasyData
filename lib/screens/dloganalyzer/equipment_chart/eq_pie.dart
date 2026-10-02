import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../constants.dart';
import 'package:tomesdashboard/cont.dart';

/// Pie chart de incidencia de alarmas.
///
/// [values]:
///   nombre de alarma -> cantidad de incidencias
///
/// V3:
/// - La selección se realiza solo con click/tap.
/// - El hover no modifica el estado.
/// - Los sectores mantienen radio fijo para evitar el "temblor" del gráfico.
/// - Click/tap sobre el sector seleccionado vuelve al total.
class EquipmetnPieChart extends StatefulWidget {
  final Map<String, int> values;
  final int topAlarms;
  final Map<String, String> detailsByAlarm;
  final Map<String, List<String>> filesByAlarm;
  /// Color estable por nombre de alarma. Permite compartir exactamente la
  /// misma paleta con Stacked y Operating hours.
  final Map<String, Color> colorsByAlarm;
  final ValueChanged<String>? onFileTap;

  const EquipmetnPieChart({
    required this.values,
    this.topAlarms = 8,
    this.detailsByAlarm = const <String, String>{},
    this.filesByAlarm = const <String, List<String>>{},
    this.colorsByAlarm = const <String, Color>{},
    this.onFileTap,
    super.key,
  });

  @override
  State<EquipmetnPieChart> createState() => _EquipmetnPieChartState();
}

class _AlarmSlice {
  final String name;
  final int count;
  final Map<String, int> details;

  const _AlarmSlice({
    required this.name,
    required this.count,
    this.details = const {},
  });

  bool get isOther => name == 'Other';
}

class _EquipmetnPieChartState extends State<EquipmetnPieChart> {
  int selectedIndex = -1;
  int hoveredIndex = -1;
  bool _panelLocked = false;
  int? _suppressedHoverIndex;

  Map<String, int> get _groupedValues {
    final grouped = <String, int>{};
    widget.values.forEach((name, count) {
      final normalizedName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (normalizedName.isEmpty || count <= 0) return;
      grouped[normalizedName] = (grouped[normalizedName] ?? 0) + count;
    });
    return grouped;
  }

  List<_AlarmSlice> get _slices {
    final entries = _groupedValues.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });

    if (entries.isEmpty) return const [];

    final topCount = widget.topAlarms.clamp(1, entries.length);
    final top = entries.take(topCount).toList();
    final remaining = entries.skip(topCount).toList();

    final result = top
        .map((e) => _AlarmSlice(name: e.key, count: e.value))
        .toList();

    if (remaining.isNotEmpty) {
      final otherDetails = <String, int>{
        for (final e in remaining) e.key: e.value,
      };
      final otherTotal =
          remaining.fold<int>(0, (total, e) => total + e.value);

      result.add(_AlarmSlice(
        name: 'Other',
        count: otherTotal,
        details: otherDetails,
      ));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final slices = _slices;
    final totalIncidences =
        slices.fold<int>(0, (total, slice) => total + slice.count);

    _AlarmSlice? selected;
    if (selectedIndex >= 0 && selectedIndex < slices.length) {
      selected = slices[selectedIndex];
    }

    final selectedPercent = selected == null || totalIncidences == 0
        ? 0.0
        : (selected.count / totalIncidences) * 100.0;

    if (slices.isEmpty) {
      return const Center(child: Text('No alarms'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final shortest = constraints.maxHeight < constraints.maxWidth
            ? constraints.maxHeight
            : constraints.maxWidth;
        final centerRadius = (shortest * 0.25).clamp(34.0, 48.0);
        final sectionRadius = (shortest * 0.18).clamp(26.0, 34.0);

        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            PieChart(
              PieChartData(
                borderData: FlBorderData(show: false),
                sectionsSpace: 3,
                centerSpaceRadius: centerRadius,
                startDegreeOffset: -90,
                sections: _pieChartCompactData(
                  slices,
                  selectedIndex,
                  sectionRadius,
                  widget.colorsByAlarm,
                ),
                pieTouchData: PieTouchData(
                  touchCallback: (FlTouchEvent event, response) {
                    final section = response?.touchedSection;
                    final hover = section?.touchedSectionIndex ?? -1;

                    // Hover solo controla el tooltip. No cambia radio ni geometría.
                    if (event is FlPointerHoverEvent) {
                      if (_panelLocked || hover < 0) return;

                      // Si el usuario cerró el panel con X, no lo reabrimos
                      // mientras el puntero siga sobre el mismo sector.
                      if (_suppressedHoverIndex == hover) return;

                      // Al pasar a otro sector, el hover vuelve a quedar habilitado.
                      if (_suppressedHoverIndex != null &&
                          _suppressedHoverIndex != hover) {
                        _suppressedHoverIndex = null;
                      }

                      if (hoveredIndex != hover) {
                        setState(() => hoveredIndex = hover);
                      }
                      return;
                    }

                    // Conservamos el último hover para poder mover el puntero
                    // hasta el panel sin perder su contenido.
                    if (event is FlPointerExitEvent) return;

                    // Click/tap mantiene la selección estable que ya teníamos.
                    if (event is! FlTapUpEvent) return;

                    if (section == null) {
                      if (selectedIndex != -1) {
                        setState(() => selectedIndex = -1);
                      }
                      return;
                    }

                    final index = section.touchedSectionIndex;
                    setState(() {
                      selectedIndex = selectedIndex == index ? -1 : index;
                    });
                  },
                ),
              ),
            ),
            IgnorePointer(
              child: SizedBox(
                width: centerRadius * 1.65,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      selected?.count.toString() ?? totalIncidences.toString(),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      selected == null
                          ? 'Total alarms'
                          : '${selectedPercent.toStringAsFixed(1)}%',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            if ((hoveredIndex >= 0 && hoveredIndex < slices.length) || selected != null)
              Positioned(
                left: 6,
                top: 6,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _panelLocked = true),
                  onExit: (_) => setState(() => _panelLocked = false),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth - 12,
                      maxHeight: constraints.maxHeight - 12,
                    ),
                    child: _PieRatHoverPanel(
                    slice: (hoveredIndex >= 0 && hoveredIndex < slices.length)
                        ? slices[hoveredIndex]
                        : selected!,
                    totalIncidences: totalIncidences,
                    details: widget.detailsByAlarm[(hoveredIndex >= 0 && hoveredIndex < slices.length)
                        ? slices[hoveredIndex].name
                        : selected!.name] ?? '',
                    files: widget.filesByAlarm[(hoveredIndex >= 0 && hoveredIndex < slices.length)
                        ? slices[hoveredIndex].name
                        : selected!.name] ?? const <String>[],
                    onFileTap: widget.onFileTap,
                    onClose: () => setState(() {
                      final activeIndex =
                          (hoveredIndex >= 0 && hoveredIndex < slices.length)
                              ? hoveredIndex
                              : selectedIndex;
                      _suppressedHoverIndex = activeIndex >= 0 ? activeIndex : null;
                      hoveredIndex = -1;
                      selectedIndex = -1;
                      _panelLocked = false;
                    }),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

}

class _PieRatHoverPanel extends StatelessWidget {
  final _AlarmSlice slice;
  final int totalIncidences;
  final String details;
  final List<String> files;
  final ValueChanged<String>? onFileTap;
  final VoidCallback onClose;

  const _PieRatHoverPanel({
    required this.slice,
    required this.totalIncidences,
    required this.details,
    required this.files,
    required this.onFileTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = totalIncidences == 0 ? 0.0 : (slice.count / totalIncidences) * 100.0;
    return Material(
      elevation: 6,
      color: scheme.surface.withOpacity(0.98),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 300,
          maxHeight: 300,
        ),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera fija: no se desplaza junto con el contenido RAT.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    slice.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${slice.count} incidence${slice.count == 1 ? '' : 's'} · ${percent.toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (details.trim().isNotEmpty || files.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 7),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (details.trim().isNotEmpty)
                        Text(details, style: Theme.of(context).textTheme.bodySmall),
                      if (files.isNotEmpty) ...[
                        if (details.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Divider(height: 1, color: scheme.outlineVariant),
                          const SizedBox(height: 7),
                        ],
                        Text(
                          'Files',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 3),
                        ...files.map(
                          (fileName) => InkWell(
                            borderRadius: BorderRadius.circular(7),
                            onTap: onFileTap == null ? null : () => onFileTap!(fileName),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                              child: Row(
                                children: [
                                  const Icon(Icons.insert_drive_file_outlined, size: 16),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      fileName,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: scheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                  const Icon(Icons.open_in_new, size: 14),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OtherAlarmDetails extends StatelessWidget {
  final _AlarmSlice slice;
  final int totalIncidences;

  const _OtherAlarmDetails({
    required this.slice,
    required this.totalIncidences,
  });

  @override
  Widget build(BuildContext context) {
    final details = slice.details.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final percent = totalIncidences == 0
        ? 0.0
        : (slice.count / totalIncidences) * 100.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Other • ${slice.count} (${percent.toStringAsFixed(1)}%)',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 90),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: details.map((entry) {
                final itemPercent = totalIncidences == 0
                    ? 0.0
                    : (entry.value / totalIncidences) * 100.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    '${entry.key}: ${entry.value} '
                    '(${itemPercent.toStringAsFixed(1)}%)',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

List<PieChartSectionData> _pieChartCompactData(
  List<_AlarmSlice> slices,
  int selectedIndex,
  double radius,
  Map<String, Color> colorsByAlarm,
) {
  return List.generate(slices.length, (i) {
    final slice = slices[i];
    final selected = i == selectedIndex;

    return PieChartSectionData(
      color: colorsByAlarm[slice.name] ?? lineColors[i % lineColors.length],
      value: slice.count.toDouble(),
      showTitle: false,
      radius: radius,
      borderSide: selected
          ? const BorderSide(color: Colors.white, width: 2)
          : BorderSide.none,
    );
  });
}
