import 'dart:convert';

import 'package:paperless_mobile/api/models/chat_response.dart';

/// Paperless sends raw text, followed by an optional JSON metadata trailer.
/// This is not SSE framing, despite the response's text/event-stream type.
class ChatResponseParser {
  static const metadataDelimiter = '\n\n__PAPERLESS_CHAT_METADATA__';

  final _buffer = StringBuffer();

  ChatResponse add(String chunk, {bool isFinal = false}) {
    _buffer.write(chunk);
    final text = _buffer.toString();
    final delimiterIndex = text.indexOf(metadataDelimiter);
    if (delimiterIndex >= 0) {
      return ChatResponse(
        content: text.substring(0, delimiterIndex),
        references: _references(
          text.substring(delimiterIndex + metadataDelimiter.length),
        ),
      );
    }

    // Hold back a delimiter prefix so it never flashes in the visible answer.
    for (var length = metadataDelimiter.length - 1; length > 0; length--) {
      if (text.endsWith(metadataDelimiter.substring(0, length))) {
        // Ordinary trailing newlines are preserved when a text-only reply ends.
        if (isFinal && length <= 2) break;
        return ChatResponse(content: text.substring(0, text.length - length));
      }
    }
    return ChatResponse(content: text);
  }

  List<ChatReference> _references(String metadata) {
    try {
      final json = jsonDecode(metadata);
      if (json is! Map || json['references'] is! List) return const [];
      final references = <ChatReference>[];
      final seen = <int>{};
      for (final reference in json['references'] as List) {
        if (reference is! Map) continue;
        final id = reference['id'];
        final title = reference['title'];
        if (id is! int || id <= 0 || !seen.add(id)) continue;
        references.add(
          ChatReference(id: id, title: title is String ? title.trim() : ''),
        );
        if (references.length == 3) break;
      }
      return List.unmodifiable(references);
    } on FormatException {
      // The trailer may still be arriving, or an older server may omit it.
      return const [];
    }
  }
}
