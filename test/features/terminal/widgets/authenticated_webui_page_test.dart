import 'package:conduit/features/terminal/widgets/authenticated_webui_page.dart';
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

import 'computer_test_platform.dart';

final _epoch = NotifierProvider<_Epoch, Object>(_Epoch.new);

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();
  void change() => state = Object();
}

void main() {
  test('only exact server-origin file links receive native authentication', () {
    final root = Uri.parse('https://webui.example/workspace/');
    expect(
      openWebUiDownloadFileId(
        root,
        Uri.parse(
          'https://webui.example/workspace/api/v1/files/demo-id/content?download=true',
        ),
      ),
      'demo-id',
    );
    for (final url in [
      'https://other.example/workspace/api/v1/files/demo-id/content',
      'http://webui.example/workspace/api/v1/files/demo-id/content',
      'https://webui.example:444/workspace/api/v1/files/demo-id/content',
      'https://user@webui.example/workspace/api/v1/files/demo-id/content',
      'https://webui.example/api/v1/files/demo-id/content',
      'https://webui.example/workspace/api/v1/auths/',
      'https://webui.example/workspace/api/v1/files/../auths/content',
      'https://webui.example/workspace/api/v1/files/demo-id/content/extra',
      'javascript:alert(1)',
    ]) {
      expect(
        openWebUiDownloadFileId(root, Uri.parse(url)),
        isNull,
        reason: url,
      );
    }
  });
  testWidgets(
    'an account transition retires the browser even when the API object is reused',
    (tester) async {
      await tester.runAsync(
        () => rootBundle.loadString('assets/webui/session.js'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
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
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AuthenticatedWebUiPage(
                      fileName: 'Demo.pdf',
                      target: {'file_id': 'demo'},
                    ),
                  ),
                ),
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
      final url = tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params
          .initialUrlRequest!
          .url!
          .uriValue;
      expect(url.path, '/document-preview/');
      expect(url.queryParameters['file_id'], 'demo');
      expect(url.queryParameters.containsKey('token'), isFalse);
      container.read(_epoch.notifier).change();
      await tester.pumpAndSettle();
      expect(find.byType(AuthenticatedWebUiPage), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    },
  );
}
