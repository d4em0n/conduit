import 'dart:io';

import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/native_document_opener.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const documents = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.conduit.NativeDocumentHostApi.openFile',
    NativeDocumentHostApi.pigeonChannelCodec,
  );
  late Directory temporary;
  final paths = <String>[];
  final contents = <List<int>>[];
  final types = <String>[];
  var opened = true;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'conduit-open-with-test-',
    );
    paths.clear();
    contents.clear();
    types.clear();
    opened = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => temporary.path,
    );
    messenger.setMockDecodedMessageHandler<Object?>(documents, (message) async {
      final args = message! as List<Object?>;
      final file = File(args[0]! as String);
      paths.add(file.path);
      contents.add(await file.readAsBytes());
      types.add(args[1]! as String);
      return [opened];
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockDecodedMessageHandler<Object?>(documents, null);
    await temporary.delete(recursive: true);
  });

  test(
    'each open keeps an independent copy with the original extension',
    () async {
      await openDownloadedDocument(
        [0, 128, 255],
        '../report.docx',
        'application/test; charset=utf-8',
      );
      await openDownloadedDocument(
        [1, 2, 3],
        '../report.docx',
        'application/test',
      );
      expect(contents, [
        [0, 128, 255],
        [1, 2, 3],
      ]);
      expect(paths[0], isNot(paths[1]));
      expect(paths, everyElement(startsWith('${temporary.path}/open-with/')));
      expect(paths, everyElement(endsWith('/.._report.docx')));
      expect(await File(paths[0]).readAsBytes(), [0, 128, 255]);
      expect(types, ['application/test', 'application/test']);
    },
  );

  test('failed opening cleans up its temporary copy', () async {
    opened = false;
    await expectLater(
      openDownloadedDocument([1], 'report.docx', 'application/test'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await Directory('${temporary.path}/open-with').list().toList(),
      isEmpty,
    );
  });

  test(
    'account changes during staging prevent native handoff and remove bytes',
    () async {
      await openDownloadedDocument(
        [1],
        'report.docx',
        'application/test',
        isCurrent: () => false,
      );
      expect(paths, isEmpty);
      expect(
        await Directory('${temporary.path}/open-with').list().toList(),
        isEmpty,
      );
    },
  );
}
