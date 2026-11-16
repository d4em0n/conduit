import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/auth/webview_origin.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart'
    show safeTerminalFileName;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/webview_cookie_helper.dart';
import '../theme/theme_extensions.dart';
import '../utils/external_link_launcher.dart';
import '../utils/platform_page_route.dart';
import 'adaptive_route_shell.dart';
import 'platform_ui/platform_ui.dart';
import 'platform_ui/vocabulary.dart';
import 'themed_dialogs.dart';

/// False leaves unrelated links with the caller's ordinary browser handler.
Future<bool> openAuthenticatedWebUiLink(
  BuildContext context,
  String url,
) async {
  if (!context.mounted) return true;
  final container = ProviderScope.containerOf(context, listen: false);
  final api = container.read(apiServiceProvider);
  final owner = captureOpenWebUiConversationSelectionOwner(container);
  if (api == null || owner == null || !isWebViewSupported) return false;
  final root = Uri.tryParse(api.baseUrl);
  final parsed = Uri.tryParse(url);
  if (root == null || parsed == null) return false;
  final target = root.resolveUri(parsed);
  if (!isWebUiServerLink(root, target)) return false;
  if (!context.mounted) return true;
  // A host open-link request finishes when accepted, not when the reader closes.
  unawaited(
    Navigator.of(context, rootNavigator: true).push(
      buildPlatformPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            AuthenticatedWebUiPage(target: target, api: api, owner: owner),
      ),
    ),
  );
  return true;
}

class AuthenticatedWebUiPage extends ConsumerStatefulWidget {
  const AuthenticatedWebUiPage({
    super.key,
    required this.target,
    required this.api,
    required this.owner,
  });
  final Uri target;
  final ApiService api;
  final OpenWebUiConversationSelectionOwner owner;

  @override
  ConsumerState<AuthenticatedWebUiPage> createState() =>
      _AuthenticatedWebUiPageState();
}

class _AuthenticatedWebUiPageState
    extends ConsumerState<AuthenticatedWebUiPage> {
  static const _maxBytes = 32 * 1024 * 1024;
  final _cancel = CancelToken();
  final _session =
      '${Random.secure().nextInt(1 << 32)}${Random.secure().nextInt(1 << 32)}';
  final _handler = 'save_${Random.secure().nextInt(1 << 32)}';
  late final _api = widget.api;
  late final _owner = widget.owner;
  late final _auth = _api.captureAuthSnapshot();
  late final Uri _root = Uri.parse(_api.baseUrl);
  late final Future<String?> _prepared = _prepare();
  InAppWebViewController? _web;
  Uri? _allowedNavigation;
  bool _retired = false, _loading = true, _failed = false, _saving = false;
  String? _title;

  bool get _current =>
      mounted &&
      !_retired &&
      identical(ref.read(apiServiceProvider), _api) &&
      openWebUiConversationSelectionOwnerIsCurrent(ref, _owner);

  Future<String?> _prepare() async {
    if (!_current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _retire();
      });
      return null;
    }
    final result = await _api.getWebUiLink(
      widget.target,
      authSnapshot: _auth,
      cancelToken: _cancel,
    );
    if (!_current) return null;
    if (result.bytes case final bytes?) {
      await _save(bytes, result.fileName);
      if (_current) _retire();
      return null;
    }
    if (_owner.userId == null ||
        _api.serverConfig.customHeaders.isNotEmpty ||
        _api.serverConfig.needsCustomTlsClient ||
        !await WebViewCookieHelper.ensurePendingLogoutDataCleared() ||
        !_current) {
      return null;
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        !await WebViewFeature.isFeatureSupported(
          WebViewFeature.DOCUMENT_START_SCRIPT,
        )) {
      return null;
    }
    final source = await rootBundle.loadString('assets/webui/session.js');
    if (!_current || !mounted) return null;
    _allowedNavigation = result.uri;
    final args = jsonEncode({
      'bootstrap': false,
      'origin': _root.origin,
      'prefix': _root.path.replaceFirst(RegExp(r'/+$'), ''),
      'token': _owner.authToken,
      'userId': _owner.userId,
      'session': _session,
      'handler': _handler,
      'target': result.uri.toString(),
      'failureMessage': AppLocalizations.of(context)!
          .terminalPortPreviewLoadFailed,
    }).replaceAll('<', r'\u003c');
    return '$source\nconduitWebUiSession($args);';
  }

  @override
  void dispose() {
    _retired = true;
    _cancel.cancel();
    _web?.removeJavaScriptHandler(handlerName: _handler);
    unawaited(
      WebViewCookieHelper.runSerializedDataOperation(() async {
        try {
          await _web?.evaluateJavascript(
            source:
                '''
await window.conduitCloseWebUi?.();
if (location.origin === ${jsonEncode(_root.origin)} &&
    localStorage.getItem('conduit.session') === ${jsonEncode(_session)}) {
  localStorage.clear(); sessionStorage.clear();
}''',
          );
          await _web?.stopLoading();
        } catch (_) {}
      }),
    );
    super.dispose();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _cancel.cancel();
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route?.isActive == true) {
        route!.navigator?.removeRoute(route);
      }
    });
    setState(() {});
  }

  Future<void> _save(Uint8List bytes, String name) async {
    if (!_current || _saving) return;
    _saving = true;
    try {
      if (bytes.length > _maxBytes) throw const FileContentTooLargeException();
      await FilePicker.saveFile(
        fileName: safeTerminalFileName(name),
        bytes: bytes,
      );
    } finally {
      _saving = false;
    }
  }

  void _error(Object error) {
    if (!_current) return;
    DebugLogger.warning(
      'webui-link-failed',
      scope: 'webui/browser',
      data: {'errorType': error.runtimeType.toString()},
    );
    setState(() {
      _failed = true;
      _loading = false;
    });
  }

  Future<void> _openTarget(Uri target) async {
    if (!_current) return;
    try {
      if (!await _browserSessionIsCurrent()) return;
      if (target.scheme == 'blob' || target.scheme == 'data') {
        await _web?.callAsyncJavaScript(
          functionBody:
              'window.conduitDownload?.(${jsonEncode(target.toString())}, "");',
        );
        return;
      }
      if (!isWebUiServerLink(_root, target)) return;
      final result = await _api.getWebUiLink(
        target,
        authSnapshot: _auth,
        cancelToken: _cancel,
      );
      if (!_current) return;
      if (result.bytes case final bytes?) {
        await _save(bytes, result.fileName);
      } else {
        _allowedNavigation = result.uri;
        await _web?.loadUrl(
          urlRequest: URLRequest(url: WebUri.uri(result.uri)),
        );
      }
    } catch (error) {
      _error(error);
    }
  }

  Future<bool> _browserSessionIsCurrent() async {
    if (!_current || _web == null) return false;
    final valid = await _web!.evaluateJavascript(
      source:
          '''
location.origin === ${jsonEncode(_root.origin)} &&
localStorage.getItem('conduit.session') === ${jsonEncode(_session)} &&
localStorage.getItem('token') === ${jsonEncode(_owner.authToken)}''',
    );
    if (!_current) return false;
    if (valid != true) {
      _retire();
      return false;
    }
    return true;
  }

  Future<NavigationActionPolicy> _navigate(
    NavigationAction action, {
    bool newWindow = false,
  }) async {
    final target = action.request.url?.uriValue;
    if (!_current || target == null) return NavigationActionPolicy.CANCEL;
    if (action.isForMainFrame == false && !newWindow) {
      return NavigationActionPolicy.ALLOW;
    }
    if (isWebUiApplicationPage(_root, target)) {
      if (target == _allowedNavigation && !newWindow) {
        _allowedNavigation = null;
        return NavigationActionPolicy.ALLOW;
      }
      // The handoff's first navigation already had a native preflight.
      if (_web == null) return NavigationActionPolicy.CANCEL;
    }
    if (isWebUiServerLink(_root, target) ||
        target.scheme == 'blob' ||
        target.scheme == 'data') {
      unawaited(_openTarget(target));
    } else if (action.hasGesture == true ||
        action.navigationType == NavigationType.LINK_ACTIVATED) {
      final l10n = AppLocalizations.of(context)!;
      final allowed = await ThemedDialogs.confirm(
        context,
        title: l10n.terminalOpenInBrowserAction,
        message: target.toString(),
        confirmText: l10n.terminalOpenInBrowserAction,
      );
      if (allowed && _current) {
        await launchExternalLink(target.toString(), scope: 'webui/browser');
      }
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(openWebUiAuthSessionEpochProvider, (_, _) {
      if (!_current) _retire();
    });
    ref.listen(apiServiceProvider, (_, _) {
      if (!_current) _retire();
    });
    final l10n = AppLocalizations.of(context)!;
    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      bodySafeArea: true,
      appBar: AdaptiveAppBar(
        title: _title ?? widget.target.host,
        leading: AdaptiveButton.icon(
          icon: Icons.close,
          semanticLabel: l10n.close,
          style: AdaptiveButtonStyle.plain,
          size: AdaptiveButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          AdaptiveAppBarAction(
            icon: Icons.refresh,
            iosSymbol: 'arrow.clockwise',
            semanticLabel: l10n.terminalPortPreviewReload,
            onPressed: () => _web?.reload(),
          ),
        ],
      ),
      body: FutureBuilder<String?>(
        future: _prepared,
        builder: (context, snapshot) {
          if (_retired) return const SizedBox.shrink();
          if (snapshot.hasError || _failed) {
            return Center(child: Text(l10n.terminalPortPreviewLoadFailed));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: AdaptiveProgressIndicator());
          }
          if (snapshot.data == null) {
            return Center(
              child: Text(l10n.openWebUiDirectConnectionUnsupportedAuth),
            );
          }
          final script = snapshot.data!;
          return Stack(
            children: [
              InAppWebView(
                initialData: InAppWebViewInitialData(
                  baseUrl: WebUri.uri(
                    _root.replace(
                      path: '${_root.path.replaceFirst(RegExp(r'/+$'), '')}/',
                      query: null,
                      fragment: null,
                    ),
                  ),
                  data:
                      '<!doctype html><html><body><script>${script.replaceFirst('"bootstrap":false', '"bootstrap":true')}</script></body></html>',
                ),
                initialUserScripts: UnmodifiableListView([
                  UserScript(
                    source: script,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    forMainFrameOnly: true,
                    allowedOriginRules: {_root.origin},
                  ),
                ]),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  incognito: defaultTargetPlatform != TargetPlatform.android,
                  sharedCookiesEnabled: false,
                  thirdPartyCookiesEnabled: false,
                  allowFileAccess: false,
                  allowContentAccess: false,
                  allowFileAccessFromFileURLs: false,
                  allowUniversalAccessFromFileURLs: false,
                  useShouldOverrideUrlLoading: true,
                  useOnDownloadStart: true,
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: false,
                  javaScriptHandlersForMainFrameOnly: true,
                  javaScriptHandlersOriginAllowList: {_root.origin},
                ),
                onWebViewCreated: (controller) {
                  _web = controller;
                  controller.addJavaScriptHandler(
                    handlerName: _handler,
                    callback: (JavaScriptHandlerFunctionData data) async {
                      if (!_current ||
                          !data.isMainFrame ||
                          data.origin.toString() != _root.origin ||
                          data.args.length != 1 ||
                          data.args.first is! Map) {
                        return false;
                      }
                      final value = data.args.first as Map;
                      final encoded = value['data'];
                      if (encoded is! String ||
                          encoded.length > (_maxBytes * 4 ~/ 3) + 1024) {
                        return false;
                      }
                      try {
                        if (!await _browserSessionIsCurrent()) return false;
                        final comma = encoded.indexOf(',');
                        if (!encoded.startsWith('data:') ||
                            comma < 0 ||
                            !encoded.substring(0, comma).endsWith(';base64')) {
                          return false;
                        }
                        await _save(
                          base64Decode(encoded.substring(comma + 1)),
                          value['name'] is String
                              ? value['name'] as String
                              : 'download',
                        );
                        return _current;
                      } catch (error) {
                        _error(error);
                        return false;
                      }
                    },
                  );
                },
                shouldOverrideUrlLoading: (_, action) => _navigate(action),
                onCreateWindow: (_, action) async {
                  await _navigate(action, newWindow: true);
                  return false;
                },
                onDownloadStarting: (_, request) async {
                  unawaited(_openTarget(request.url.uriValue));
                  return DownloadStartResponse(
                    action: DownloadStartResponseAction.CANCEL,
                    handled: true,
                  );
                },
                onLoadStart: (_, url) {
                  if (!_current) {
                    _retire();
                    return;
                  }
                  if (url != null &&
                      !isWebUiApplicationPage(_root, url.uriValue)) {
                    unawaited(_web?.stopLoading());
                    return;
                  }
                  setState(() {
                    _loading = true;
                  });
                },
                onLoadStop: (controller, _) async {
                  final title = await controller.getTitle();
                  if (_current) {
                    setState(() {
                      _title = title;
                      _loading = false;
                    });
                  }
                },
                onReceivedError: (_, request, error) {
                  if (request.isForMainFrame == true) _error(error);
                },
              ),
              if (_loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AdaptiveProgressIndicator.linear(minHeight: 2),
                ),
            ],
          );
        },
      ),
    );
  }
}
