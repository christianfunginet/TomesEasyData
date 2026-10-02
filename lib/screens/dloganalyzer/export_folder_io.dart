import 'dart:io';
import 'dart:typed_data';

const bool supportsFolderExport = true;

class FolderExportFile {
  final String fileName;
  final Uint8List bytes;

  const FolderExportFile({
    required this.fileName,
    required this.bytes,
  });
}

Future<void> exportFilesToFolder(
  String folderPath,
  List<FolderExportFile> files,
) async {
  for (final item in files) {
    final separator = Platform.pathSeparator;
    final path = folderPath.endsWith(separator)
        ? '$folderPath${item.fileName}'
        : '$folderPath$separator${item.fileName}';
    await File(path).writeAsBytes(item.bytes, flush: true);
  }
}
