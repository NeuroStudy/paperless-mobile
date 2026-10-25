import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:paperless_mobile/api/constants/request_options.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/api/utils/chat_response_parser.dart';

abstract interface class PaperlessChatApi {
  static const maxQuestionLength = 4000;

  Stream<ChatResponse> streamChat(String question, {CancelToken? cancelToken});
}

class PaperlessChatApiImpl implements PaperlessChatApi {
  final Dio _client;

  PaperlessChatApiImpl(this._client);

  @override
  Stream<ChatResponse> streamChat(
    String question, {
    CancelToken? cancelToken,
  }) async* {
    final prompt = question.trim();
    if (prompt.isEmpty ||
        prompt.runes.length > PaperlessChatApi.maxQuestionLength) {
      throw ArgumentError(
        'A question must contain between 1 and 4000 characters.',
      );
    }

    try {
      final response = await _client.post<ResponseBody>(
        '/api/documents/chat/',
        data: {'q': prompt},
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(minutes: 2),
          receiveDataWhenStatusError: false,
          extra: {skipConnectionRetryKey: true},
        ),
      );
      final body = response.data;
      if (body == null) throw const ChatException(ChatFailure.unknown);
      final parser = ChatResponseParser();
      await for (final chunk
          in body.stream
              .cast<List<int>>()
              .transform(utf8.decoder)
              .timeout(const Duration(minutes: 2))) {
        yield parser.add(chunk);
      }
      final answer = parser.add('', isFinal: true);
      if (answer.content.trim().isEmpty) {
        throw const ChatException(ChatFailure.unknown);
      }
      yield answer;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final failure = switch (error.response?.statusCode) {
        400 || 404 || 405 => ChatFailure.unavailable,
        401 || 403 => ChatFailure.forbidden,
        _ => switch (error.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.receiveTimeout ||
          DioExceptionType.sendTimeout => ChatFailure.timeout,
          DioExceptionType.connectionError => ChatFailure.connection,
          _ => ChatFailure.unknown,
        },
      };
      throw ChatException(failure);
    } on TimeoutException {
      throw const ChatException(ChatFailure.timeout);
    }
  }
}
