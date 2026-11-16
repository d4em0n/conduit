import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ApiService.getWebUiLink', () {
    test(
      'application HTML opens as a page, API HTML remains a download',
      () async {
        final adapter = _WebUiLinkAdapter(
          (_) => ResponseBody.fromString(
            '<html>Untrusted when served through the Files API</html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          ),
        );
        final api = _buildAuthenticatedApiService(
          adapter,
          authToken: 'owner-a',
          url: 'https://example.com',
        );
        final auth = api.captureAuthSnapshot();
        final page = await api.getWebUiLink(
          Uri.parse('https://example.com/viewer'),
          authSnapshot: auth,
        );
        expect(page.bytes, isNull);
        final file = await api.getWebUiLink(
          Uri.parse('https://example.com/api/v1/files/demo/content/html'),
          authSnapshot: auth,
        );
        expect(utf8.decode(file.bytes!), contains('Untrusted'));
        expect(
          adapter.requests.every(
            (r) => r.headers['Authorization'] == 'Bearer owner-a',
          ),
          isTrue,
        );
      },
    );

    test(
      'downloads original bytes and decodes server-provided filenames',
      () async {
        final adapter = _WebUiLinkAdapter(
          (_) => ResponseBody.fromBytes(
            [1, 2, 3],
            200,
            headers: {
              Headers.contentTypeHeader: ['application/pdf'],
              'content-disposition': [
                "attachment; filename*=UTF-8''Synthetic%20file.pdf",
              ],
            },
          ),
        );
        final api = _buildAuthenticatedApiService(
          adapter,
          authToken: 'owner-a',
          url: 'https://example.com',
        );
        final result = await api.getWebUiLink(
          Uri.parse('https://example.com/api/v1/files/demo/content'),
          authSnapshot: api.captureAuthSnapshot(),
        );
        expect(result.bytes, [1, 2, 3]);
        expect(result.fileName, 'Synthetic file.pdf');
        expect(result.contentType, 'application/pdf');
      },
    );

    test(
      'follows local redirects but never sends credentials to another origin',
      () async {
        final adapter = _WebUiLinkAdapter(
          (r) => r.uri.path == '/start'
              ? ResponseBody.fromString(
                  '',
                  302,
                  headers: {
                    'location': ['/file'],
                  },
                )
              : ResponseBody.fromString(
                  '',
                  302,
                  headers: {
                    'location': ['https://other.example/private'],
                  },
                ),
        );
        final api = _buildAuthenticatedApiService(
          adapter,
          authToken: 'owner-a',
          url: 'https://example.com',
        );
        await expectLater(
          api.getWebUiLink(
            Uri.parse('https://example.com/start'),
            authSnapshot: api.captureAuthSnapshot(),
          ),
          throwsFormatException,
        );
        expect(adapter.requests.map((r) => r.uri.path), ['/start', '/file']);
        expect(
          adapter.requests.every((r) => r.uri.host == 'example.com'),
          isTrue,
        );
      },
    );

    test('rejects stale ownership before any authenticated request', () async {
      final adapter = _WebUiLinkAdapter(
        (_) => ResponseBody.fromString('', 200),
      );
      final api = _buildAuthenticatedApiService(
        adapter,
        authToken: 'owner-a',
        url: 'https://example.com',
      );
      final auth = api.captureAuthSnapshot();
      api.updateAuthToken('owner-b');
      await expectLater(
        api.getWebUiLink(
          Uri.parse('https://example.com/file'),
          authSnapshot: auth,
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test(
      'bounded streaming rejects downloads without trusting Content-Length',
      () async {
        final adapter = _WebUiLinkAdapter(
          (_) => ResponseBody.fromBytes([1, 2, 3, 4], 200),
        );
        final api = _buildAuthenticatedApiService(
          adapter,
          authToken: 'owner-a',
          url: 'https://example.com',
        );
        await expectLater(
          api.getWebUiLink(
            Uri.parse('https://example.com/file'),
            maxBytes: 3,
            authSnapshot: api.captureAuthSnapshot(),
          ),
          throwsA(isA<FileContentTooLargeException>()),
        );
      },
    );
  });
  group('ApiService.searchFilesForSession', () {
    test('distinguishes no matches from an unavailable endpoint', () async {
      final noMatchesApi = _buildApiService(
        _FileSearchAdapter(
          statusCode: 404,
          response: const {'detail': 'No files found matching the pattern.'},
        ),
      );
      final unavailableApi = _buildApiService(
        _FileSearchAdapter(
          statusCode: 404,
          response: const {'detail': 'Not Found'},
        ),
      );

      final noMatches = await noMatchesApi.searchFilesForSession(
        query: 'recording.m4a',
      );
      check(noMatches).isNotNull();
      check(noMatches!).isEmpty();
      check(await unavailableApi.searchFilesForSession(query: 'recording.m4a'))
          .isNull();
    });

    test('uses a targeted query and forwards cancellation', () async {
      final adapter = _FileSearchAdapter(response: [_fileJson('recording-1')]);
      final api = _buildApiService(adapter);
      final cancelToken = CancelToken();

      final files = await api.searchFilesForSession(
        query: 'recording_123.m4a',
        limit: 100,
        cancelToken: cancelToken,
      );

      check(files).isNotNull().has((it) => it.length, 'length').equals(1);
      check(adapter.requestedPath).equals('/api/v1/files/search');
      check(adapter.queryParameters).isNotNull();
      check(adapter.queryParameters!).deepEquals({
        'filename': '*recording_123.m4a*',
        'content': false,
        'limit': 100,
      });
      check(adapter.receivedCancelFuture).isNotNull();
      cancelToken.cancel('test complete');
      await adapter.requestCancelled.future.timeout(const Duration(seconds: 1));
    });

    test('rejects a stale auth snapshot before transport', () async {
      final adapter = _FileSearchAdapter(response: const <Object?>[]);
      final api = _buildAuthenticatedApiService(
        adapter,
        authToken: 'account-a',
      );
      final snapshot = api.captureAuthSnapshot();
      api.updateAuthToken('account-b');

      await expectLater(
        api.searchFilesForSession(
          query: 'recording.m4a',
          authSnapshot: snapshot,
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requestCount).equals(0);
    });
  });

  group('ApiService.getFileContent', () {
    test('streams image content within the configured byte limit', () async {
      final api = _buildApiService(
        _FileContentAdapter([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3]),
        ]),
      );

      final content = await api.getFileContent('image', maxBytes: 3);

      check(content).equals('data:image/png;base64,AQID');
    });

    test('aborts content that exceeds the configured byte limit', () async {
      final adapter = _FileContentAdapter([
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4]),
      ]);
      final api = _buildApiService(adapter);
      final sharedCancelToken = CancelToken();

      await expectLater(
        api.getFileContent(
          'large-image',
          maxBytes: 3,
          cancelToken: sharedCancelToken,
        ),
        throwsA(isA<FileContentTooLargeException>()),
      );
      await adapter.requestCancelled.future.timeout(const Duration(seconds: 1));
      check(sharedCancelToken.isCancelled).isFalse();

      api.dio.httpClientAdapter = _FileContentAdapter([
        Uint8List.fromList([1, 2, 3]),
      ]);
      check(
        await api.getFileContent(
          'small-image',
          maxBytes: 3,
          cancelToken: sharedCancelToken,
        ),
      ).equals('data:image/png;base64,AQID');
    });

    test('rejects an oversized advertised content length', () async {
      final api = _buildApiService(
        _FileContentAdapter([
          Uint8List.fromList([1]),
        ], advertisedLength: 100),
      );

      await expectLater(
        api.getFileContent('large-image', maxBytes: 3),
        throwsA(isA<FileContentTooLargeException>()),
      );
    });

    test(
      'advertised oversize does not await stalled source cancellation',
      () async {
        final cancelGate = Completer<void>();
        final adapter = _AdversarialCancellationFileContentAdapter(
          onCancel: () => cancelGate.future,
        );
        final api = _buildApiService(adapter);
        final sharedCancelToken = CancelToken();

        await expectLater(
          api
              .getFileContent(
                'large-image',
                maxBytes: 3,
                cancelToken: sharedCancelToken,
              )
              .timeout(
                const Duration(seconds: 1),
                onTimeout: () => throw StateError('size rejection stalled'),
              ),
          throwsA(isA<FileContentTooLargeException>()),
        );
        await adapter.cancelStarted.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('source cancellation never began'),
        );
        check(sharedCancelToken.isCancelled).isFalse();

        api.dio.httpClientAdapter = _FileContentAdapter([
          Uint8List.fromList([1, 2, 3]),
        ]);
        check(
          await api.getFileContent(
            'small-image',
            maxBytes: 3,
            cancelToken: sharedCancelToken,
          ),
        ).equals('data:image/png;base64,AQID');
      },
    );

    test('cancels a stalled response-body stream', () async {
      final adapter = _CancellableFileContentAdapter();
      final api = _buildApiService(adapter);
      final cancelToken = CancelToken();

      final content = api.getFileContent(
        'stalled-image',
        cancelToken: cancelToken,
      );
      await adapter.listenStarted.future.timeout(const Duration(seconds: 1));
      cancelToken.cancel('test stop');

      await expectLater(
        content,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await adapter.requestCancelled.future.timeout(const Duration(seconds: 1));
      await adapter.sourceCancelled.future.timeout(const Duration(seconds: 1));
    });
  });
}

class _WebUiLinkAdapter implements HttpClientAdapter {
  _WebUiLinkAdapter(this.response);
  final ResponseBody Function(RequestOptions) response;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return response(options);
  }

  @override
  void close({bool force = false}) {}
}

final class _AdversarialCancellationFileContentAdapter
    implements HttpClientAdapter {
  _AdversarialCancellationFileContentAdapter({required this.onCancel});

  final Future<void> Function() onCancel;
  final cancelStarted = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      _AdversarialCancelStream(
        onCancel: onCancel,
        cancelStarted: cancelStarted,
      ),
      200,
      headers: const {
        'content-type': ['image/png'],
        'content-length': ['100'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _AdversarialCancelStream extends Stream<Uint8List> {
  const _AdversarialCancelStream({
    required this.onCancel,
    required this.cancelStarted,
  });

  final Future<void> Function() onCancel;
  final Completer<void> cancelStarted;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _AdversarialCancelSubscription(
    onCancel: onCancel,
    cancelStarted: cancelStarted,
  );
}

final class _AdversarialCancelSubscription
    implements StreamSubscription<Uint8List> {
  const _AdversarialCancelSubscription({
    required this.onCancel,
    required this.cancelStarted,
  });

  final Future<void> Function() onCancel;
  final Completer<void> cancelStarted;

  @override
  Future<void> cancel() {
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    return onCancel();
  }

  @override
  void onData(void Function(Uint8List data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;
}

final class _CancellableFileContentAdapter implements HttpClientAdapter {
  _CancellableFileContentAdapter() {
    controller = StreamController<Uint8List>(
      onListen: () => listenStarted.complete(),
      onCancel: () {
        if (!sourceCancelled.isCompleted) sourceCancelled.complete();
      },
    );
  }

  final listenStarted = Completer<void>();
  final requestCancelled = Completer<void>();
  final sourceCancelled = Completer<void>();
  late final StreamController<Uint8List> controller;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>((_) {
          if (!requestCancelled.isCompleted) requestCancelled.complete();
        }),
      );
    }
    return ResponseBody(
      controller.stream,
      200,
      headers: const {
        'content-type': ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    if (!controller.isClosed) unawaited(controller.close());
  }
}

final class _FileContentAdapter implements HttpClientAdapter {
  _FileContentAdapter(this.chunks, {this.advertisedLength});

  final List<Uint8List> chunks;
  final int? advertisedLength;
  final requestCancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>((_) {
          if (!requestCancelled.isCompleted) requestCancelled.complete();
        }),
      );
    }
    return ResponseBody(
      Stream<Uint8List>.fromIterable(chunks),
      200,
      headers: {
        'content-type': ['image/png'],
        if (advertisedLength != null) 'content-length': ['$advertisedLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FileSearchAdapter implements HttpClientAdapter {
  _FileSearchAdapter({required this.response, this.statusCode = 200});

  final Object? response;
  final int statusCode;
  String? requestedPath;
  Map<String, dynamic>? queryParameters;
  Future<void>? receivedCancelFuture;
  final requestCancelled = Completer<void>();
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    requestedPath = options.path;
    queryParameters = Map<String, dynamic>.from(options.queryParameters);
    receivedCancelFuture = cancelFuture;
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>((_) {
          if (!requestCancelled.isCompleted) requestCancelled.complete();
        }),
      );
    }
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(response)))),
      statusCode,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _buildApiService(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

ApiService _buildAuthenticatedApiService(
  HttpClientAdapter adapter, {
  required String authToken,
  String url = 'http://localhost:0',
}) {
  final service = ApiService(
    serverConfig: ServerConfig(id: 'test', name: 'Test', url: url),
    workerManager: WorkerManager(),
    authToken: authToken,
  );
  service.dio.httpClientAdapter = adapter;
  return service;
}

Map<String, dynamic> _fileJson(String id) {
  return {
    'id': id,
    'user_id': 'user-1',
    'filename': '$id.txt',
    'original_filename': '$id.txt',
    'content_type': 'text/plain',
    'size': 128,
    'created_at': 1713786305,
    'updated_at': 1713786305,
  };
}
