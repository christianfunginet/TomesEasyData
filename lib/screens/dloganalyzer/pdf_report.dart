import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class PdfReportRow {
  final String label;
  final String value;

  const PdfReportRow(this.label, this.value);
}

class PdfAlarmDetail {
  final String name;
  final int incidences;
  final List<PdfReportRow> fields;
  final List<String> files;

  const PdfAlarmDetail({
    required this.name,
    required this.incidences,
    this.fields = const [],
    this.files = const [],
  });
}

Future<void> saveAnalysisPdfReport({
  required String fileName,
  required String title,
  String? subtitle,
  Uint8List? chartPng,
  List<PdfReportRow> summary = const [],
  List<String> selectedItems = const [],
  List<PdfReportRow> ranking = const [],
  List<PdfAlarmDetail> alarmDetails = const [],
  List<String> notes = const [],
}) async {
  final pdf = pw.Document(
    title: title,
    author: 'Terumo Tool Set',
    creator: 'Terumo Tool Set',
  );

  final image = chartPng == null ? null : pw.MemoryImage(chartPng);

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    pw.Text(
                      subtitle,
                      style: const pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            pw.Text(
              _formatDateTime(DateTime.now()),
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey700,
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 14),

        if (summary.isNotEmpty) ...[
          _sectionTitle('Summary'),
          pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            children: summary
                .map(
                  (item) => pw.Container(
                    width: 150,
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey400),
                      borderRadius: pw.BorderRadius.circular(5),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          item.label,
                          style: const pw.TextStyle(
                            fontSize: 8,
                            color: PdfColors.grey700,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          item.value,
                          style: pw.TextStyle(
                            fontSize: 11,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          pw.SizedBox(height: 14),
        ],

        if (image != null) ...[
          _sectionTitle('Chart'),
          pw.Container(
            height: 285,
            width: double.infinity,
            alignment: pw.Alignment.center,
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(height: 14),
        ],

        if (selectedItems.isNotEmpty) ...[
          _sectionTitle('Selected variables'),
          pw.Wrap(
            spacing: 6,
            runSpacing: 5,
            children: selectedItems
                .map(
                  (item) => pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.grey200,
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                    child: pw.Text(
                      item,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ),
                )
                .toList(),
          ),
          pw.SizedBox(height: 14),
        ],

        if (ranking.isNotEmpty) ...[
          _sectionTitle('Alarm incidence'),
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Alarm', 'Incidences'],
            data: [
              for (var i = 0; i < ranking.length; i++)
                ['${i + 1}', ranking[i].label, ranking[i].value],
            ],
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.grey300),
            border: pw.TableBorder.all(
              color: PdfColors.grey400,
              width: 0.5,
            ),
            cellPadding: const pw.EdgeInsets.all(5),
          ),
          pw.SizedBox(height: 12),
        ],

        if (alarmDetails.isNotEmpty) ...[
          _sectionTitle('Alarm details'),
          ...alarmDetails.map(
            (alarm) => pw.Container(
              width: double.infinity,
              margin: const pw.EdgeInsets.only(bottom: 10),
              padding: const pw.EdgeInsets.all(9),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '${alarm.name} (${alarm.incidences})',
                    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
                  ),
                  if (alarm.fields.isNotEmpty) ...[
                    pw.SizedBox(height: 5),
                    ...alarm.fields.where((row) => row.value.trim().isNotEmpty).map(
                      (row) => pw.Padding(
                        padding: const pw.EdgeInsets.only(bottom: 2),
                        child: pw.RichText(
                          text: pw.TextSpan(
                            style: const pw.TextStyle(fontSize: 8),
                            children: [
                              pw.TextSpan(text: '${row.label}: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                              pw.TextSpan(text: row.value),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (alarm.files.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    pw.Text('Files: ${alarm.files.join(', ')}', style: const pw.TextStyle(fontSize: 8)),
                  ],
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 4),
        ],

        if (notes.isNotEmpty) ...[
          _sectionTitle('Notes'),
          ...notes.map(
            (note) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Text('- $note', style: const pw.TextStyle(fontSize: 8)),
            ),
          ),
        ],
      ],
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          'Page ${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(
            fontSize: 8,
            color: PdfColors.grey600,
          ),
        ),
      ),
    ),
  );

  final bytes = await pdf.save();

  await FilePicker.saveFile(
    dialogTitle: 'Save PDF report',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
    bytes: bytes,
  );
}

pw.Widget _sectionTitle(String text) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Text(
      text,
      style: pw.TextStyle(
        fontSize: 12,
        fontWeight: pw.FontWeight.bold,
      ),
    ),
  );
}

String _formatDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}
