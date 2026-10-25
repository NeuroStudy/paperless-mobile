import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:paperless_mobile/features/chat/view/chat_page.dart';
import 'package:paperless_mobile/routing/navigation_keys.dart';

import 'shells/authenticated_route.dart';

class ChatBranch extends StatefulShellBranchData {
  static final GlobalKey<NavigatorState> $navigatorKey = chatNavigatorKey;

  const ChatBranch();
}

class ChatRoute extends GoRouteData with $ChatRoute {
  const ChatRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const ChatPage();
}
