import 'dart:async';

import 'package:cached_query_flutter/cached_query_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/core/repository/inbox_repository.dart';
import 'package:paperless_mobile/core/store/slices/local_user_account.dart';
import 'package:paperless_mobile/core/store/slices/user_profile.dart';
import 'package:paperless_mobile/features/chat/cubit/chat_cubit.dart';
import 'package:paperless_mobile/features/chat/view/chat_page.dart';
import 'package:paperless_mobile/features/home/view/scaffold_with_navigation_bar.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/routing/routes/chat_route.dart';
import 'package:paperless_mobile/routing/routes/shells/authenticated_route.dart';
import 'package:provider/provider.dart';

import 'chat_cubit_test.dart' show TestChatApi;

class _InboxRepository implements InboxRepository {
  @override
  final InfiniteQuery<PaginatedResultList<Document>, int> inboxDocumentsQuery =
      InfiniteQuery(
        key: 'chat_navigation_inbox',
        config: QueryConfig(ignoreCacheDuration: true),
        queryFn: (_) async => PaginatedResultList(count: 0, results: []),
        getNextArg: (state) => state == null ? 1 : null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('generated routes register Chat as the sixth branch', () {
    final shell = ($authenticatedRoute as ShellRoute).routes
        .whereType<StatefulShellRoute>()
        .single;
    expect(shell.branches, hasLength(6));
    expect((shell.branches.last.routes.single as GoRoute).path, '/chat');
    expect(const ChatRoute().location, '/chat');
  });

  testWidgets('six tabs preserve chat across tab switches and source viewing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = TestChatApi();
    final cubit = ChatCubit(api);
    final rootKey = GlobalKey<NavigatorState>();
    const paths = [
      '/landing',
      '/documents',
      '/scanner',
      '/labels',
      '/inbox',
      '/chat',
    ];
    final router = GoRouter(
      navigatorKey: rootKey,
      initialLocation: '/landing',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) =>
              ScaffoldWithNavigationBar(navigationShell: shell),
          branches: [
            for (final path in paths)
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: path,
                    builder: (_, _) => path == '/chat'
                        ? const ChatPage()
                        : Center(child: Text('Page $path')),
                    routes: [
                      if (path == '/documents')
                        GoRoute(
                          path: ':documentId',
                          parentNavigatorKey: rootKey,
                          builder: (_, state) => Scaffold(
                            appBar: AppBar(
                              title: Text(
                                'Source ${state.pathParameters['documentId']}',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await api.dispose();
      CachedQuery.instance.deleteCache();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: cubit),
          Provider<InboxRepository>(create: (_) => _InboxRepository()),
          Provider.value(
            value: LocalUserAccount(
              appUserId: 'test@paperless.example',
              serverUrl: 'https://paperless.example',
              apiVersion: 9,
              profile: UserProfile(
                profile: Profile(),
                uiSettings: UiSettingsView(
                  user: UiSettingsViewUser(
                    id: 1,
                    username: 'test',
                    isSuperuser: true,
                  ),
                  settings: UiSettingsViewSettings(aiEnabled: true),
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(6),
    );
    await tester.tap(find.widgetWithText(NavigationDestination, 'Chat'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/chat');
    cubit.send('Question');
    api.responses.single.add(
      const ChatResponse(
        content: 'Answer from your invoice',
        references: [ChatReference(id: 3, title: 'Invoice')],
      ),
    );
    unawaited(api.responses.single.close());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, 'Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, 'Chat'));
    await tester.pumpAndSettle();
    expect(cubit.state.messages, hasLength(2));
    await tester.tap(find.text('Invoice'));
    await tester.pumpAndSettle();
    expect(find.text('Source 3'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/chat');
    expect(find.text('Invoice'), findsOneWidget);
    expect(cubit.state.messages, hasLength(2));
    expect(api.questions, ['Question']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    CachedQuery.instance.deleteCache();
    await tester.pump();
  });
}
