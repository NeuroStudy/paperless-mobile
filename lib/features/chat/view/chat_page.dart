import 'package:flutter/material.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/core/extensions/context_extensions.dart';
import 'package:paperless_mobile/features/app_drawer/view/app_drawer.dart';
import 'package:paperless_mobile/features/chat/view/chat_view.dart';
import 'package:paperless_mobile/routing/routes/documents_route.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.uiSettings$;
    return ChatView(
      aiEnabled: settings.settings?.aiEnabled ?? false,
      canViewDocuments: settings.canViewDocuments,
      drawer: const AppDrawer(),
      onOpenDocument: (reference) => _openDocument(context, reference),
      onOpenLink: (href) {
        final base = Uri.tryParse(context.loggedInUser.serverUrl);
        final link = Uri.tryParse(href);
        if (base == null || link == null) return;
        final resolved = base.resolveUri(link);
        if (resolved.scheme != 'https' && resolved.scheme != 'http') return;
        final match = RegExp(r'/documents/(\d+)/?$').firstMatch(resolved.path);
        if (resolved.origin == base.origin && match != null) {
          final id = int.tryParse(match.group(1)!);
          if (id == null || id <= 0) return;
          _openDocument(context, ChatReference(id: id, title: ''));
        } else {
          launchUrl(resolved, mode: LaunchMode.externalApplication);
        }
      },
    );
  }

  void _openDocument(BuildContext context, ChatReference reference) {
    DocumentDetailsRoute(
      documentId: reference.id,
      title: reference.title.isEmpty ? null : reference.title,
      isLabelClickable: false,
    ).push(context);
  }
}
