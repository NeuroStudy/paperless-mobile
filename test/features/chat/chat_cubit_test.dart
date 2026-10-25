import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/api/modules/paperless_chat_api.dart';
import 'package:paperless_mobile/features/chat/cubit/chat_cubit.dart';

class TestChatApi implements PaperlessChatApi {
  final questions = <String>[];
  final tokens = <CancelToken>[];
  final responses = <StreamController<ChatResponse>>[];

  @override
  Stream<ChatResponse> streamChat(String question, {CancelToken? cancelToken}) {
    questions.add(question);
    tokens.add(cancelToken!);
    final response = StreamController<ChatResponse>(sync: true);
    responses.add(response);
    return response.stream;
  }

  Future<void> dispose() async {
    for (final response in responses) {
      await response.close();
    }
  }
}

void main() {
  late TestChatApi api;
  late ChatCubit cubit;

  setUp(() {
    api = TestChatApi();
    cubit = ChatCubit(api);
  });
  tearDown(() async {
    await cubit.close();
    await api.dispose();
  });

  test('keeps a thread while sending each question independently', () async {
    expect(cubit.send(' First question '), isTrue);
    api.responses.single.add(const ChatResponse(content: 'Partial'));
    expect(cubit.state.messages.last.content, 'Partial');
    api.responses.single.add(
      const ChatResponse(
        content: 'Full answer',
        references: [ChatReference(id: 1, title: 'Invoice')],
      ),
    );
    await api.responses.single.close();
    expect(cubit.state.isSending, isFalse);
    expect(cubit.state.messages.last.references.single.id, 1);
    cubit.send('Second question');
    expect(api.questions, ['First question', 'Second question']);
    expect(cubit.state.messages, hasLength(4));
  });

  test('ignores duplicate sends, empty input, and oversized input', () {
    expect(cubit.send(' '), isFalse);
    expect(cubit.send('x' * 4001), isFalse);
    expect(cubit.send('Question'), isTrue);
    expect(cubit.send('Duplicate'), isFalse);
    expect(api.questions, ['Question']);
  });

  test('stop cancels generation and retains the partial answer', () {
    cubit.send('Question');
    api.responses.single.add(const ChatResponse(content: 'Partial'));
    cubit.stop();
    expect(api.tokens.single.isCancelled, isTrue);
    expect(cubit.state.isSending, isFalse);
    expect(cubit.state.messages.last.content, 'Partial');
    expect(cubit.state.messages.last.stopped, isTrue);
    api.responses.single.add(const ChatResponse(content: 'Late response'));
    expect(cubit.state.messages.last.content, 'Partial');
  });

  test('stop removes an empty pending answer', () {
    cubit.send('Question');
    cubit.stop();
    expect(cubit.state.messages, hasLength(1));
    expect(cubit.state.messages.single.isUser, isTrue);
    expect(cubit.state.isSending, isFalse);
  });

  test('new chat cancels the old stream and ignores late responses', () {
    cubit.send('Old question');
    final oldResponse = api.responses.single;
    cubit.newChat();
    expect(api.tokens.single.isCancelled, isTrue);
    expect(cubit.state.messages, isEmpty);
    cubit.send('New question');
    oldResponse.add(const ChatResponse(content: 'Old answer'));
    api.responses.last.add(const ChatResponse(content: 'New answer'));
    expect(cubit.state.messages, hasLength(2));
    expect(cubit.state.messages.last.content, 'New answer');
  });

  test('retry replaces a failed answer without duplicating the question', () {
    cubit.send('Question');
    api.responses.single.add(const ChatResponse(content: 'Partial'));
    api.responses.single.addError(const ChatException(ChatFailure.timeout));
    expect(cubit.state.canRetry, isTrue);
    expect(cubit.state.messages.last.content, 'Partial');
    cubit.retry();
    expect(api.questions, ['Question', 'Question']);
    expect(cubit.state.messages, hasLength(2));
    expect(cubit.state.messages.last.content, isEmpty);
    api.responses.last.add(const ChatResponse(content: 'Replacement'));
    expect(cubit.state.messages.last.content, 'Replacement');
  });

  test('disposal cancels generation; a new session starts empty', () async {
    cubit.send('Question');
    await cubit.close();
    expect(api.tokens.single.isCancelled, isTrue);
    api.responses.single.add(const ChatResponse(content: 'Late answer'));
    final nextSession = ChatCubit(api);
    expect(nextSession.state.messages, isEmpty);
    await nextSession.close();
  });
}
