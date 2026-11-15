import 'dart:io';

import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart'
    show safeTerminalFileName;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'conduit_platform_apis.g.dart';

/// A fresh URL prevents a receiving app from reusing an earlier document copy.
Future<void> openDownloadedDocument(
  List<int> bytes,
  String fileName,
  String mimeType, {
  bool Function()? isCurrent,
}) async {
  final temporary = await getTemporaryDirectory();
  final root = Directory(path.join(temporary.path, 'open-with'));
  await root.create(recursive: true);
  final directory = await root.createTemp();
  final file = File(path.join(directory.path, safeTerminalFileName(fileName)));
  try {
    await file.writeAsBytes(bytes, flush: true);
    if (isCurrent?.call() == false) {
      await directory.delete(recursive: true);
      return;
    }
    final opened = await NativeDocumentHostApi().openFile(
      file.path,
      mimeType.split(';').first.trim(),
    );
    if (!opened) {
      throw const FileSystemException('No application could open the document');
    }
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
  // The receiving app reads asynchronously; retain its copy in temporary storage.
}
