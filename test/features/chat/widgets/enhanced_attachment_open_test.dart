import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
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
  void Function()? onRequest;
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
    onRequest?.call();
    return pending?.future ?? base64Encode([0, 255, requests]);
  }
}

void main() {
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
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
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      final paths = (call.arguments as Map)['paths'] as List;
      opened.add(await File(paths.single as String).readAsBytes());
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathsChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
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
    'chat attachment retains its original share action with fresh binary bytes',
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
      expect(find.text('Open with…'), findsNothing);
      for (var revision = 1; revision <= 2; revision++) {
        final open =
            tester
                    .widget<GestureDetector>(
                      find
                          .ancestor(
                            of: find.text('report.docx'),
                            matching: find.byType(GestureDetector),
                          )
                          .first,
                    )
                    .onTap
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

  testWidgets('an account change during local preparation prevents sharing', (
    tester,
  ) async {
    final api = _DocumentApi();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => Object()),
      ],
    );
    addTearDown(container.dispose);
    await pumpAttachment(tester, container);
    final share =
        tester
                .widget<GestureDetector>(
                  find
                      .ancestor(
                        of: find.text('report.docx'),
                        matching: find.byType(GestureDetector),
                      )
                      .first,
                )
                .onTap
            as Future<void> Function();
    await tester.runAsync(() async {
      final preparing = Completer<void>();
      final directory = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathsChannel, (_) {
            preparing.complete();
            return directory.future;
          });
      final sharing = share();
      await preparing.future;
      container.invalidate(openWebUiAuthSessionEpochProvider);
      directory.complete(temporary.path);
      await sharing;
    });
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

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
    final share =
        tester
                .widget<GestureDetector>(
                  find
                      .ancestor(
                        of: find.text('report.docx'),
                        matching: find.byType(GestureDetector),
                      )
                      .first,
                )
                .onTap
            as Future<void> Function();
    await tester.runAsync(() async {
      final started = Completer<void>();
      api.onRequest = started.complete;
      unawaited(share());
      await started.future;
    });
    await tester.pumpAndSettle();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    api.pending!.complete(base64Encode([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
