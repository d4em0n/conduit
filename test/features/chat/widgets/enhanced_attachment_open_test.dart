import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _DocumentApi extends ApiService {
  _DocumentApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  var requests = 0;
  Completer<String>? pending;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => {
    'filename': 'report.docx',
    'meta': {
      'content_type': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    },
  };

  @override
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    requests++;
    return pending?.future ?? base64Encode([0, 255, requests]);
  }
}

void main() {
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  const documentChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.conduit.NativeDocumentHostApi.openFile',
    NativeDocumentHostApi.pigeonChannelCodec,
  );
  late Directory temporary;
  final opened = <List<int>>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('attachment-open-test-');
    opened.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathsChannel,
      (_) async => temporary.path,
    );
    messenger.setMockDecodedMessageHandler<Object?>(documentChannel, (
      message,
    ) async {
      opened.add(await File((message! as List)[0] as String).readAsBytes());
      return [true];
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathsChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(documentChannel, null);
    await temporary.delete(recursive: true);
  });

  Future<void> pumpAttachment(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SizedBox(
              width: 300,
              child: EnhancedAttachment(attachmentId: 'file-1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'chat Open with fetches fresh bytes on every tap, including small binary files',
    (tester) async {
      final api = _DocumentApi();
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => Object()),
        ],
      );
      addTearDown(container.dispose);
      await pumpAttachment(tester, container);
      for (var revision = 1; revision <= 2; revision++) {
        final open =
            tester
                    .widget<ConduitTextButton>(find.byType(ConduitTextButton))
                    .onPressed
                as Future<void> Function();
        await tester.runAsync(open);
        await tester.pumpAndSettle();
      }
      expect(api.requests, 2);
      expect(opened, [
        [0, 255, 1],
        [0, 255, 2],
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat account change discards an in-flight document', (
    tester,
  ) async {
    final api = _DocumentApi()..pending = Completer<String>();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => Object()),
      ],
    );
    addTearDown(container.dispose);
    await pumpAttachment(tester, container);
    await tester.tap(find.text('Open with…'));
    await tester.pump();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    api.pending!.complete(base64Encode([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
