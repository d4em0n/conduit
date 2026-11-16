import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart' show CancelToken, Options;
import 'package:conduit_core/models/server_config.dart';

import '../../../shared/widgets/platform_ui/vocabulary.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../platform/webview_cookie_helper.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../controllers/terminal_controller_gateways.dart';
import '../models/terminal_models.dart';

bool openWebUiSameOrigin(Uri root, Uri target) =>
    target.userInfo.isEmpty &&
    target.scheme == root.scheme &&
    target.host == root.host &&
    target.port == root.port;

String? openWebUiDownloadFileId(Uri root, Uri target) {
  if (!openWebUiSameOrigin(root, target)) return null;
  final prefix = root.path.replaceFirst(RegExp(r'/+$'), '');
  return RegExp('^${RegExp.escape(prefix)}/api/v1/files/([\\w-]+)/content/?\$')
      .firstMatch(target.path)
      ?.group(1);
}

class AuthenticatedWebUiPage extends ConsumerStatefulWidget {
  const AuthenticatedWebUiPage({
    super.key,
    required this.fileName,
    required this.target,
    this.download,
    this.isCurrent,
  });

  final String fileName;
  final Map<String, String> target;

  final VoidCallback? download;
  final bool Function()? isCurrent;

  static Future<bool> open(
    BuildContext context, {
    required String fileName,
    required Map<String, String> target,
    VoidCallback? download,
    void Function(ModalRoute<dynamic>)? onShown,
    bool Function()? isCurrent,
  }) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final api = container.read(apiServiceProvider);
    final owner = captureOpenWebUiConversationSelectionOwner(container);
    if (api == null ||
        owner == null ||
        api.serverConfig.customHeaders.isNotEmpty ||
        api.serverConfig.needsCustomTlsClient) {
      return false;
    }
    bool current() =>
        context.mounted &&
        openWebUiConversationSelectionOwnerIsCurrent(container, owner) &&
        isCurrent?.call() != false;
    try {
      final capability = await api.dio.get(
        '/document-preview/config.json',
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      if (!current()) return true;
      if (capability.data is! Map ||
          capability.data['formats'] is! List ||
          !(capability.data['formats'] as List).contains(
            fileName.split('.').last.toLowerCase(),
          )) {
        return false;
      }
    } catch (_) {
      return !current();
    }
    if (!context.mounted) return true;
    final route = buildPlatformPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => AuthenticatedWebUiPage(
        fileName: fileName,
        target: target,
        download: download,
        isCurrent: isCurrent,
      ),
    );
    onShown?.call(route);
    await Navigator.of(context, rootNavigator: true).push(route);
    return true;
  }

  @override
  ConsumerState<AuthenticatedWebUiPage> createState() =>
      _AuthenticatedWebUiPageState();
}

class _AuthenticatedWebUiPageState
    extends ConsumerState<AuthenticatedWebUiPage> {
  static const _maxBytes = 32 * 1024 * 1024;
  final _cancel = CancelToken();
  late final ApiService? _api = ref.read(apiServiceProvider);
  late final _owner = captureOpenWebUiConversationSelectionOwner(ref);
  late final _auth = _api?.captureAuthSnapshot();
  late final Uri? _root = Uri.tryParse(_api?.baseUrl ?? '');
  late final Future<String?> _script = _prepare();
  final _handler = 'download_${Random.secure().nextInt(1 << 32)}';
  final _session =
      '${Random.secure().nextInt(1 << 32)}${Random.secure().nextInt(1 << 32)}';
  InAppWebViewController? _web;
  bool _loading = true;
  bool _failed = false;
  bool _saving = false;
  bool _retired = false;

  bool get _current =>
      mounted &&
      !_retired &&
      widget.isCurrent?.call() != false &&
      _api != null &&
      _owner != null &&
      openWebUiConversationSelectionOwnerIsCurrent(ref, _owner);

  Future<String?> _prepare() async {
    if (!_current ||
        _root == null ||
        (!['http', 'https'].contains(_root.scheme) ||
            _root.host.isEmpty ||
            _root.userInfo.isNotEmpty)) {
      return null;
    }
    // This trial reuses standard server authentication, not custom gateway credentials.
    if (_api!.authToken?.isNotEmpty != true ||
        _api.serverConfig.customHeaders.isNotEmpty ||
        _api.serverConfig.needsCustomTlsClient) {
      return null;
    }
    if (!await WebViewCookieHelper.ensurePendingLogoutDataCleared() ||
        !_current) {
      return null;
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        !await WebViewFeature.isFeatureSupported(
          WebViewFeature.DOCUMENT_START_SCRIPT,
        )) {
      return null;
    }
    final script = await rootBundle.loadString('assets/webui/session.js');
    if (!_current) return null;
    final args = jsonEncode({
      'origin': _root.origin,
      'token': _api.authToken,
      'session': _session,
      'handler': _handler,
      'path':
          '${_root.path.replaceFirst(RegExp(r'/+$'), '')}/document-preview/',
    }).replaceAll('<', r'\u003c');
    return '$script\nconduitWebUiSession($args);';
  }

  Uri get _start {
    final prefix = _root!.path.replaceFirst(RegExp(r'/+$'), '');
    return _root.replace(
      path: '$prefix/document-preview/',
      queryParameters: {
        ...widget.target,
        'theme': Theme.of(context).brightness == Brightness.dark
            ? 'dark'
            : 'light',
      },
      fragment: null,
    );
  }

  @override
  void dispose() {
    _retired = true;
    _cancel.cancel();
    _web?.removeJavaScriptHandler(handlerName: _handler);
    unawaited(
      _web
          ?.evaluateJavascript(
            source:
                '''
if (location.origin === ${jsonEncode(_root?.origin)} &&
    localStorage.getItem('conduit.session') === ${jsonEncode(_session)}) {
  localStorage.clear(); sessionStorage.clear();
}''',
          )
          .catchError((_) => null),
    );
    super.dispose();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _cancel.cancel();
    unawaited(_web?.stopLoading());
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route?.isActive == true) {
        route!.navigator?.removeRoute(route);
      }
    });
    setState(() {});
  }

  Future<bool> _download(Map value) async {
    if (!_current || _saving) return false;
    _saving = true;
    try {
      final data = value['data'];
      Uint8List bytes;
      var name = value['name'] is String ? value['name'] as String : 'download';
      if (data is String && data.length <= (_maxBytes * 4 ~/ 3) + 1024) {
        final comma = data.indexOf(',');
        if (!data.startsWith('data:') ||
            comma < 0 ||
            !data.substring(0, comma).endsWith(';base64')) {
          throw const FormatException();
        }
        bytes = base64Decode(data.substring(comma + 1));
      } else {
        final target = Uri.tryParse(
          value['url'] is String ? value['url'] as String : '',
        );
        final id = target == null
            ? null
            : openWebUiDownloadFileId(_root!, target);
        if (id == null) throw const FormatException();
        final data = await _api!.getFileContent(
          id,
          maxBytes: _maxBytes,
          authSnapshot: _auth,
          cancelToken: _cancel,
        );
        if (!_current) return false;
        bytes = base64Decode(
          data.startsWith('data:')
              ? data.substring(data.indexOf(',') + 1)
              : data,
        );
        if (name.isEmpty) {
          final info = await _api.getFileInfo(
            id,
            authSnapshot: _auth,
            cancelToken: _cancel,
          );
          name = info['filename']?.toString() ?? 'download';
        }
      }
      if (!_current) return false;
      if (bytes.length > _maxBytes) throw const FormatException();
      await const DefaultTerminalBrowserPlatformGateway().saveDownload(
        TerminalDownloadedFile(
          fileName: name,
          bytes: bytes,
          contentType: 'application/octet-stream',
        ),
      );
      return true;
    } catch (error) {
      if (mounted && _current) {
        DebugLogger.warning(
          'webui-download-failed',
          scope: 'terminal/webui',
          data: {'errorType': error.runtimeType.toString()},
        );
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.terminalDownloadFailed,
        );
      }
      return false;
    } finally {
      _saving = false;
    }
  }

  Future<NavigationActionPolicy> _navigate(NavigationAction action) async {
    final target = action.request.url?.uriValue;
    if (!_current || target == null) return NavigationActionPolicy.CANCEL;
    if (openWebUiDownloadFileId(_root!, target) != null) {
      unawaited(_download({'url': target.toString()}));
      return NavigationActionPolicy.CANCEL;
    }
    if (openWebUiSameOrigin(_root, target)) {
      if (target.path == _start.path ||
          target.path == _start.path.replaceFirst(RegExp(r'/$'), '')) {
        return NavigationActionPolicy.ALLOW;
      }
      if (target.path.endsWith('/auth')) {
        setState(() {
          _failed = true;
          _loading = false;
        });
        return NavigationActionPolicy.CANCEL;
      }
    }
    if (action.hasGesture == true ||
        action.navigationType == NavigationType.LINK_ACTIVATED) {
      final l10n = AppLocalizations.of(context)!;
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: l10n.terminalOpenInBrowserAction,
        message: target.toString(),
        confirmText: l10n.terminalOpenInBrowserAction,
      );
      if (confirmed && _current) {
        await launchExternalLink(target.toString(), scope: 'terminal/webui');
      }
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(openWebUiAuthSessionEpochProvider, (_, _) {
      if (!_current) _retire();
    });
    ref.listen(activeConversationProvider, (_, _) {
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
        title: widget.fileName,
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
          AdaptiveAppBarAction(
            icon: Icons.download_outlined,
            iosSymbol: 'arrow.down.to.line',
            semanticLabel: l10n.download,
            onPressed:
                widget.download ??
                () => _web?.evaluateJavascript(
                  source: "document.getElementById('download')?.click();",
                ),
          ),
        ],
      ),
      body: FutureBuilder<String?>(
        future: _script,
        builder: (context, snapshot) {
          if (_retired ||
              snapshot.hasError ||
              (snapshot.connectionState == ConnectionState.done &&
                  snapshot.data == null)) {
            return Center(
              child: Text(l10n.openWebUiDirectConnectionUnsupportedAuth),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: AdaptiveProgressIndicator());
          }
          return Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri.uri(_start)),
                initialUserScripts: UnmodifiableListView([
                  UserScript(
                    source: snapshot.data!,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    forMainFrameOnly: true,
                    allowedOriginRules: {_root!.origin},
                  ),
                ]),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  // Android incognito clears cookies shared with the app's other WebViews.
                  incognito: defaultTargetPlatform != TargetPlatform.android,
                  cacheEnabled: false,
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
                      return _download(data.args.first as Map);
                    },
                  );
                },
                shouldOverrideUrlLoading: (_, action) => _navigate(action),
                onCreateWindow: (controller, action) async {
                  if (await _navigate(action) == NavigationActionPolicy.ALLOW &&
                      _current) {
                    await controller.loadUrl(urlRequest: action.request);
                  }
                  return false;
                },
                onDownloadStarting: (_, request) async {
                  unawaited(
                    _download({
                      'url': request.url.toString(),
                      'name': request.suggestedFilename ?? '',
                    }),
                  );
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
                      !openWebUiSameOrigin(_root, url.uriValue)) {
                    unawaited(_web?.stopLoading());
                    return;
                  }
                  setState(() {
                    _loading = true;
                    _failed = false;
                  });
                },
                onLoadStop: (_, _) {
                  if (mounted) setState(() => _loading = false);
                },
                onReceivedError: (_, request, error) {
                  if (mounted && request.isForMainFrame == true) {
                    setState(() {
                      _failed = true;
                      _loading = false;
                    });
                  }
                },
              ),
              if (_loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AdaptiveProgressIndicator.linear(minHeight: 2),
                ),
              if (_failed)
                Center(child: Text(l10n.terminalPortPreviewLoadFailed)),
            ],
          );
        },
      ),
    );
  }
}
