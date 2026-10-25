import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_markdown_community/flutter_markdown.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/api/modules/paperless_chat_api.dart';
import 'package:paperless_mobile/features/chat/cubit/chat_cubit.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

class ChatView extends StatefulWidget {
  final bool aiEnabled;
  final bool canViewDocuments;
  final ValueChanged<ChatReference> onOpenDocument;
  final ValueChanged<String> onOpenLink;
  final Widget? drawer;

  const ChatView({
    super.key,
    required this.aiEnabled,
    required this.canViewDocuments,
    required this.onOpenDocument,
    required this.onOpenLink,
    this.drawer,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _followAnswer = true;

  bool get _available => widget.aiEnabled && widget.canViewDocuments;

  @override
  void initState() {
    super.initState();
    _input.addListener(_inputChanged);
    _scroll.addListener(_scrollChanged);
  }

  void _inputChanged() => setState(() {});

  void _scrollChanged() {
    _followAnswer = _scroll.position.extentAfter < 120;
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    if (!_available) return;
    if (context.read<ChatCubit>().send(_input.text)) {
      _input.clear();
      _followAnswer = true;
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _followAnswer) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = S.of(context)!;
    return BlocConsumer<ChatCubit, ChatState>(
      listener: (context, state) => _scrollToBottom(),
      builder: (context, state) => Scaffold(
        drawer: widget.drawer,
        appBar: AppBar(
          title: Text(l10n.chat),
          actions: [
            IconButton(
              tooltip: l10n.chatNewChat,
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: state.messages.isEmpty
                  ? null
                  : () {
                      context.read<ChatCubit>().newChat();
                      _input.clear();
                      _followAnswer = true;
                      _focus.requestFocus();
                    },
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: !_available
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.canViewDocuments
                          ? l10n.chatUnavailable
                          : l10n.chatForbidden,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: state.messages.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  l10n.chatEmptyHint,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.all(16),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: state.messages.length,
                              itemBuilder: (context, index) => _message(
                                state.messages[index],
                                isStreaming:
                                    state.isSending &&
                                    index == state.messages.length - 1,
                                canRetry:
                                    state.canRetry &&
                                    index == state.messages.length - 1,
                              ),
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _input,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: PaperlessChatApi.maxQuestionLength,
                              enabled: !state.isSending,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              decoration: InputDecoration(
                                hintText: l10n.chatQuestionHint,
                                counterText: '',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: IconButton.filled(
                              tooltip: state.isSending
                                  ? l10n.chatStop
                                  : l10n.chatSend,
                              icon: Icon(
                                state.isSending ? Icons.stop : Icons.send,
                              ),
                              onPressed: state.isSending
                                  ? context.read<ChatCubit>().stop
                                  : _input.text.trim().isEmpty
                                  ? null
                                  : _send,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _message(
    ChatMessage message, {
    required bool isStreaming,
    required bool canRetry,
  }) {
    final l10n = S.of(context)!;
    final theme = Theme.of(context);
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: message.isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.content.isNotEmpty)
              if (message.isUser)
                SelectableText(message.content)
              else
                MarkdownBody(
                  data: message.content,
                  selectable: true,
                  fitContent: false,
                  onTapLink: (_, href, _) {
                    if (href != null) widget.onOpenLink(href);
                  },
                ),
            if (isStreaming)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(l10n.chatThinking)),
                  ],
                ),
              ),
            if (message.stopped)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.chatStopped, style: theme.textTheme.bodySmall),
              ),
            if (message.failure case final failure?) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _errorMessage(failure),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
              if (canRetry)
                TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.tryAgain),
                  onPressed: () {
                    _followAnswer = true;
                    context.read<ChatCubit>().retry();
                  },
                ),
            ],
            if (!isStreaming && message.references.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l10n.chatSources, style: theme.textTheme.labelLarge),
              for (final reference in message.references)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(
                    reference.title.isEmpty
                        ? l10n.chatDocumentTitle(reference.id)
                        : reference.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onOpenDocument(reference),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _errorMessage(ChatFailure failure) {
    final l10n = S.of(context)!;
    return switch (failure) {
      ChatFailure.unavailable => l10n.chatUnavailable,
      ChatFailure.forbidden => l10n.chatForbidden,
      ChatFailure.timeout => l10n.chatTimeout,
      ChatFailure.connection => l10n.youAreCurrentlyOffline,
      ChatFailure.unknown => l10n.chatResponseFailed,
    };
  }
}
