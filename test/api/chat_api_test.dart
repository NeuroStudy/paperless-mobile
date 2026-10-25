import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/api/constants/request_options.dart';
import 'package:paperless_mobile/api/interceptor/dio_http_error_interceptor.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/api/models/ui_settings_view_settings.dart';
import 'package:paperless_mobile/api/modules/paperless_chat_api.dart';
import 'package:paperless_mobile/api/utils/chat_response_parser.dart';
import 'package:paperless_mobile/core/interceptor/dio_offline_interceptor.dart';
import 'package:paperless_mobile/core/interceptor/retry_on_connection_change_interceptor.dart';

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const delimiter = ChatResponseParser.metadataDelimiter;

  group('chat metadata', () {
    test('hides the trailer at every possible chunk boundary', () {
      const content = 'An answer with **formatting**.';
      final response =
          '$content$delimiter${jsonEncode({
            'references': [
              {'id': 7, 'title': 'Invoice'},
              {'id': 8, 'title': 'Contract'},
              {'id': 9, 'title': 'Receipt'},
            ],
          })}';
      for (var split = 0; split <= response.length; split++) {
        final parser = ChatResponseParser();
        final partial = parser.add(response.substring(0, split));
        expect(partial.content, isNot(contains('__PAPERLESS')));
        final answer = parser.add(response.substring(split), isFinal: true);
        expect(answer.content, content);
        expect(answer.references.map((e) => e.id), [7, 8, 9]);
      }
    });

    test('deduplicates and validates sources, keeping the first three', () {
      final answer = ChatResponseParser().add(
        'Answer$delimiter${jsonEncode({
          'references': [
            null,
            {'id': -1},
            {'id': '2'},
            {'id': 2, 'title': ' First '},
            {'id': 2, 'title': 'Duplicate'},
            {'id': 4, 'title': null},
            {'id': 6, 'title': 'Third'},
            {'id': 8, 'title': 'Fourth'},
          ],
        })}',
      );
      expect(answer.references, const [
        ChatReference(id: 2, title: 'First'),
        ChatReference(id: 4, title: ''),
        ChatReference(id: 6, title: 'Third'),
      ]);
    });

    for (final metadata in ['{', '{"references":', '{}', '[]', 'null']) {
      test('preserves answer with malformed or empty metadata: $metadata', () {
        final answer = ChatResponseParser().add(
          'Answer$delimiter$metadata',
          isFinal: true,
        );
        expect(answer.content, 'Answer');
        expect(answer.references, isEmpty);
      });
    }

    test(
      'preserves ordinary trailing newlines and hides a truncated trailer',
      () {
        expect(
          ChatResponseParser().add('Answer\n\n', isFinal: true).content,
          'Answer\n\n',
        );
        expect(
          ChatResponseParser()
              .add('Answer\n\n__PAPERLESS_CHAT_', isFinal: true)
              .content,
          'Answer',
        );
      },
    );
  });

  group('native chat API', () {
    late Dio client;
    late PaperlessChatApi api;

    setUp(() {
      client = Dio(
        BaseOptions(
          baseUrl: 'https://paperless.example',
          headers: {'Authorization': 'Token test-token'},
        ),
      );
      client.interceptors.addAll([
        DioHttpErrorInterceptor(),
        DioOfflineInterceptor(),
        RetryOnConnectionChangeInterceptor(dio: client),
      ]);
      api = PaperlessChatApiImpl(client);
    });

    tearDown(() => client.close(force: true));

    test(
      'decodes UTF-8 byte chunks and posts only the current question',
      () async {
        final encoded = utf8.encode(
          'Überweisung 😊$delimiter{"references":[{"id":1,"title":"Rechnung"}]}',
        );
        final adapter = _Adapter(
          (_) => ResponseBody(
            Stream.fromIterable(
              encoded.map((byte) => Uint8List.fromList([byte])),
            ),
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          ),
        );
        client.httpClientAdapter = adapter;
        final responses = await api.streamChat('  Find invoices  ').toList();
        expect(responses.last.content, 'Überweisung 😊');
        expect(responses.last.references.single.id, 1);
        expect(
          responses.every((e) => !e.content.contains('__PAPERLESS')),
          isTrue,
        );
        final request = adapter.requests.single;
        expect(request.path, '/api/documents/chat/');
        expect(request.method, 'POST');
        expect(request.data, {'q': 'Find invoices'});
        expect(request.headers['Authorization'], 'Token test-token');
        expect(request.receiveTimeout, const Duration(minutes: 2));
        expect(request.extra[skipConnectionRetryKey], isTrue);
      },
    );

    test('supports text-only servers', () async {
      client.httpClientAdapter = _Adapter(
        (_) => ResponseBody.fromString('A plain answer', 200),
      );
      expect((await api.streamChat('Question').last).content, 'A plain answer');
    });

    test('cancels the HTTP response stream after a partial answer', () async {
      final body = StreamController<Uint8List>();
      client.httpClientAdapter = _Adapter(
        (_) => ResponseBody(body.stream, 200),
      );
      final token = CancelToken();
      final responses = StreamIterator(
        api.streamChat('Question', cancelToken: token),
      );
      final first = responses.moveNext();
      body.add(Uint8List.fromList(utf8.encode('Partial')));
      expect(await first, isTrue);
      expect(responses.current.content, 'Partial');
      token.cancel();
      await expectLater(
        responses.moveNext(),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await responses.cancel();
      await body.close();
    });

    test('rejects blank or oversized questions without a request', () async {
      final adapter = _Adapter((_) => ResponseBody.fromString('Answer', 200));
      client.httpClientAdapter = adapter;
      for (final question in ['   ', 'x' * 4001]) {
        await expectLater(
          api.streamChat(question),
          emitsError(isArgumentError),
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('treats an empty answer as a recoverable failure', () async {
      client.httpClientAdapter = _Adapter(
        (_) => ResponseBody.fromString('', 200),
      );
      await expectLater(
        api.streamChat('Question'),
        emitsError(isA<ChatException>()),
      );
    });

    for (final entry in {
      400: ChatFailure.unavailable,
      401: ChatFailure.forbidden,
      403: ChatFailure.forbidden,
      404: ChatFailure.unavailable,
      405: ChatFailure.unavailable,
      500: ChatFailure.unknown,
    }.entries) {
      test('completes HTTP ${entry.key} errors without hanging', () async {
        client.httpClientAdapter = _Adapter(
          (_) => ResponseBody.fromString('Error', entry.key),
        );
        await expectLater(
          api.streamChat('Question'),
          emitsError(
            isA<ChatException>().having(
              (e) => e.failure,
              'failure',
              entry.value,
            ),
          ),
        );
      });
    }

    test('forwards an unmatched SocketException without hanging', () async {
      client.httpClientAdapter = _Adapter(
        (_) => throw const SocketException('Connection refused'),
      );
      await expectLater(
        api.streamChat('Question'),
        emitsError(isA<ChatException>()),
      );
    });

    test('reports timeouts', () async {
      client.httpClientAdapter = _Adapter(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
      );
      await expectLater(
        api.streamChat('Question'),
        emitsError(
          isA<ChatException>().having(
            (e) => e.failure,
            'failure',
            ChatFailure.timeout,
          ),
        ),
      );
    });

    test('never automatically replays a chat request', () async {
      final adapter = _Adapter(
        (options) => throw DioException(
          requestOptions: options,
          error: const HttpException('Connection closed'),
          message: 'Connection closed before full header was received',
        ),
      );
      client.httpClientAdapter = adapter;
      await expectLater(
        api.streamChat('Question'),
        emitsError(isA<ChatException>()),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('cancels before response headers arrive', () async {
      final pending = Completer<ResponseBody>();
      final adapter = _Adapter((_) => pending.future);
      client.httpClientAdapter = adapter;
      final token = CancelToken();
      final result = expectLater(
        api.streamChat('Question', cancelToken: token),
        emitsError(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await result;
      pending.complete(ResponseBody.fromString('Late answer', 200));
    });
  });

  test('AI availability defaults to false on older servers', () {
    expect(UiSettingsViewSettings.fromJson({}).aiEnabled, isFalse);
    expect(
      UiSettingsViewSettings.fromJson({'ai_enabled': true}).aiEnabled,
      isTrue,
    );
  });
}
