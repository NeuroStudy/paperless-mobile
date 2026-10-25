import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/api/modules/paperless_chat_api.dart';

class ChatMessage extends Equatable {
  final bool isUser;
  final String content;
  final List<ChatReference> references;
  final ChatFailure? failure;
  final bool stopped;

  const ChatMessage({
    required this.isUser,
    required this.content,
    this.references = const [],
    this.failure,
    this.stopped = false,
  });

  @override
  List<Object?> get props => [isUser, content, references, failure, stopped];
}

class ChatState extends Equatable {
  final List<ChatMessage> messages;
  final bool isSending;

  const ChatState({this.messages = const [], this.isSending = false});

  bool get canRetry => !isSending && messages.lastOrNull?.failure != null;

  @override
  List<Object?> get props => [messages, isSending];
}

/// One conversation for the current authenticated app session. Never hydrated.
class ChatCubit extends Cubit<ChatState> {
  final PaperlessChatApi _api;
  CancelToken? _cancelToken;
  StreamSubscription<ChatResponse>? _subscription;
  int _requestId = 0;

  ChatCubit(this._api) : super(const ChatState());

  bool send(String question) {
    final prompt = question.trim();
    if (isClosed ||
        state.isSending ||
        prompt.isEmpty ||
        prompt.runes.length > PaperlessChatApi.maxQuestionLength) {
      return false;
    }
    _start(prompt, [
      ...state.messages,
      ChatMessage(isUser: true, content: prompt),
    ]);
    return true;
  }

  void retry() {
    if (isClosed || !state.canRetry) return;
    final messages = state.messages.sublist(0, state.messages.length - 1);
    _start(messages.last.content, messages);
  }

  void _start(String question, List<ChatMessage> messages) {
    _cancelRequest();
    final requestId = _requestId;
    final cancelToken = _cancelToken = CancelToken();
    emit(
      ChatState(
        messages: List.unmodifiable([
          ...messages,
          const ChatMessage(isUser: false, content: ''),
        ]),
        isSending: true,
      ),
    );
    _subscription = _api
        .streamChat(question, cancelToken: cancelToken)
        .listen(
          (response) {
            if (!_isCurrent(requestId)) return;
            _replaceAnswer(
              ChatMessage(
                isUser: false,
                content: response.content,
                references: response.references,
              ),
              isSending: true,
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_isCurrent(requestId)) return;
            _replaceAnswer(
              ChatMessage(
                isUser: false,
                content: state.messages.last.content,
                failure: error is ChatException
                    ? error.failure
                    : ChatFailure.unknown,
              ),
            );
            _cancelRequest();
          },
          onDone: () {
            if (!_isCurrent(requestId)) return;
            final answer = state.messages.last;
            _replaceAnswer(
              answer.content.trim().isEmpty
                  ? const ChatMessage(
                      isUser: false,
                      content: '',
                      failure: ChatFailure.unknown,
                    )
                  : answer,
            );
            _subscription = null;
            _cancelToken = null;
          },
        );
  }

  bool _isCurrent(int requestId) =>
      !isClosed && requestId == _requestId && state.isSending;

  void _replaceAnswer(ChatMessage answer, {bool isSending = false}) {
    emit(
      ChatState(
        messages: List.unmodifiable([
          ...state.messages.take(state.messages.length - 1),
          answer,
        ]),
        isSending: isSending,
      ),
    );
  }

  void stop() {
    if (isClosed || !state.isSending) return;
    _cancelRequest();
    final answer = state.messages.last;
    if (answer.content.isEmpty) {
      emit(
        ChatState(
          messages: List.unmodifiable(
            state.messages.take(state.messages.length - 1),
          ),
        ),
      );
    } else {
      _replaceAnswer(
        ChatMessage(isUser: false, content: answer.content, stopped: true),
      );
    }
  }

  void newChat() {
    if (isClosed) return;
    _cancelRequest();
    emit(const ChatState());
  }

  void _cancelRequest() {
    _requestId++;
    _cancelToken?.cancel();
    _cancelToken = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  @override
  Future<void> close() {
    _cancelRequest();
    return super.close();
  }
}
