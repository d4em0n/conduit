import 'package:conduit/shared/widgets/authenticated_webui_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';

import '../../features/terminal/widgets/computer_test_platform.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:conduit/platform/webview_cookie_helper.dart';

final _epoch = NotifierProvider<_Epoch, Object>(_Epoch.new);

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();
  void change() => state = Object();
}

void main() {
  testWidgets(
    'an account transition retires the browser even when the API object is reused',
    (tester) async {
      await tester.runAsync(
        () => rootBundle.loadString('assets/webui/session.js'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      debugIsWebViewSupportedOverride = true;
      addTearDown(() => debugIsWebViewSupportedOverride = null);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final oldPlatform = InAppWebViewPlatform.instance;
      InAppWebViewPlatform.instance = ComputerTestPlatform();
      addTearDown(() {
        if (oldPlatform != null) InAppWebViewPlatform.instance = oldPlatform;
      });
      const server = ServerConfig(
        id: 'web',
        name: 'Web',
        url: 'https://webui.example',
      );
      final api = ApiService(
        serverConfig: server,
        authToken: 'token-a',
        workerManager: WorkerManager(),
      );
      final adapter = _PageAdapter();
      api.dio.httpClientAdapter = adapter;
      bool? accepted;
      var changeBeforeBuild = false;
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          activeServerProvider.overrideWith((ref) => server),
          authTokenProvider3.overrideWithValue('token-a'),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'a',
              username: 'A',
              email: 'a@example.com',
              role: 'user',
            ),
          ),
          appDatabaseProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_epoch),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        api.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await openAuthenticatedWebUiLink(
                    context,
                    'https://webui.example/viewer?file=demo',
                  );
                  if (changeBeforeBuild)
                    container.read(_epoch.notifier).change();
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final preparation = tester
          .widget<FutureBuilder<String?>>(find.byType(FutureBuilder<String?>))
          .future;
      await tester.runAsync(() async => await preparation);
      await tester.pump();
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(
        accepted,
        isTrue,
        reason: 'The MCP host must not wait for the reader to close.',
      );
      final params = tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params;
      expect(params.initialData!.baseUrl.toString(), 'https://webui.example/');
      expect(params.initialData!.data, contains('"bootstrap":true'));
      expect(
        params.initialData!.data,
        contains('https://webui.example/viewer?file=demo'),
      );
      expect(params.initialUserScripts!.single.forMainFrameOnly, isTrue);
      expect(params.initialSettings!.allowFileAccess, isFalse);
      final controller = ComputerTestWebController();
      params.onWebViewCreated!(controller);
      // WKWebView asks about loadData's base URL before running its bootstrap.
      expect(
        await params.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
            request: URLRequest(url: WebUri('https://webui.example/')),
            isForMainFrame: true,
            navigationType: NavigationType.OTHER,
          ),
        ),
        NavigationActionPolicy.ALLOW,
      );
      expect(controller.scripts, isEmpty);
      expect(
        await params.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
            request: URLRequest(
              url: WebUri('https://webui.example/viewer?file=demo'),
            ),
            isForMainFrame: true,
            navigationType: NavigationType.OTHER,
          ),
        ),
        NavigationActionPolicy.ALLOW,
      );
      container.read(_epoch.notifier).change();
      await tester.pumpAndSettle();
      expect(find.byType(AuthenticatedWebUiPage), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      changeBeforeBuild = true;
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(AuthenticatedWebUiPage), findsNothing);
      expect(
        adapter.requests,
        1,
        reason: 'A queued route must not adopt a later account.',
      );
    },
  );
}

class _PageAdapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '<html></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
