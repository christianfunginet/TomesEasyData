import 'dart:typed_data';

const bool supportsFolderExport = false;

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
) {
  throw UnsupportedError(
    'Folder export is not available on this platform.',
  );
}
