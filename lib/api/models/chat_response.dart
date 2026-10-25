import 'package:equatable/equatable.dart';

class ChatReference extends Equatable {
  final int id;
  final String title;

  const ChatReference({required this.id, required this.title});

  @override
  List<Object?> get props => [id, title];
}

class ChatResponse extends Equatable {
  final String content;
  final List<ChatReference> references;

  const ChatResponse({required this.content, this.references = const []});

  @override
  List<Object?> get props => [content, references];
}

enum ChatFailure { unavailable, forbidden, timeout, connection, unknown }

class ChatException implements Exception {
  final ChatFailure failure;

  const ChatException(this.failure);
}
