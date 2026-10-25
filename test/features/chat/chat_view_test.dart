import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/api/models/chat_response.dart';
import 'package:paperless_mobile/features/chat/cubit/chat_cubit.dart';
import 'package:paperless_mobile/features/chat/view/chat_view.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

import 'chat_cubit_test.dart' show TestChatApi;

void main() {
  late TestChatApi api;
  late ChatCubit cubit;
  late List<ChatReference> opened;

  setUp(() {
    api = TestChatApi();
    cubit = ChatCubit(api);
    opened = [];
  });

  tearDown(() async {
    await cubit.close();
    await api.dispose();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    bool aiEnabled = true,
    bool canViewDocuments = true,
    ThemeMode themeMode = ThemeMode.light,
    double textScale = 1,
  }) => tester.pumpWidget(
    BlocProvider.value(
      value: cubit,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        theme: ThemeData(colorSchemeSeed: Colors.green),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.green,
          brightness: Brightness.dark,
        ),
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ChatView(
          aiEnabled: aiEnabled,
          canViewDocuments: canViewDocuments,
          onOpenDocument: opened.add,
          onOpenLink: (_) {},
        ),
      ),
    ),
  );

  testWidgets('send, stop, and new chat work from the composer', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ask about your documents.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Find my invoice');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(api.questions, ['Find my invoice']);
    expect(find.byTooltip('Stop'), findsOneWidget);
    api.responses.single.add(const ChatResponse(content: 'The invoice says…'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Response stopped'), findsOneWidget);
    expect(api.tokens.single.isCancelled, isTrue);
    await tester.enterText(find.byType(TextField), 'Draft');
    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();
    expect(cubit.state.messages, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  for (final count in [1, 2, 3]) {
    testWidgets('shows $count source documents and opens the selected ID', (
      tester,
    ) async {
      await pumpChat(tester);
      cubit.send('Question');
      api.responses.single.add(
        ChatResponse(
          content: 'Answer',
          references: List.generate(
            count,
            (i) => ChatReference(id: i + 1, title: 'Source ${i + 1}'),
          ),
        ),
      );
      unawaited(api.responses.single.close());
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(count));
      await tester.tap(find.text('Source $count'));
      expect(opened.single.id, count);
      expect(cubit.state.messages, hasLength(2));
    });
  }

  testWidgets('text-only answers have no source section', (tester) async {
    await pumpChat(tester);
    cubit.send('Question');
    api.responses.single.add(
      const ChatResponse(content: 'No matching documents.'),
    );
    unawaited(api.responses.single.close());
    await tester.pumpAndSettle();
    expect(find.text('Sources'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('failed answers offer retry without another user message', (
    tester,
  ) async {
    await pumpChat(tester);
    cubit.send('Question');
    api.responses.single.addError(const ChatException(ChatFailure.timeout));
    await tester.pumpAndSettle();
    expect(
      find.text('The response timed out. Please try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(api.questions, ['Question', 'Question']);
    expect(cubit.state.messages, hasLength(2));
  });

  testWidgets('disabled AI explains availability without a composer', (
    tester,
  ) async {
    await pumpChat(tester, aiEnabled: false);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('compatible Paperless-ngx server'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(api.questions, isEmpty);
  });

  testWidgets('missing permission blocks chat', (tester) async {
    await pumpChat(tester, canViewDocuments: false);
    await tester.pumpAndSettle();
    expect(
      find.text('You do not have permission to chat with documents.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('fits a narrow screen with large text in $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpChat(tester, themeMode: mode, textScale: 2);
      cubit.send('Question with a long title');
      api.responses.single.add(
        const ChatResponse(
          content: '**Answer**\n\nA relevant document was found.',
          references: [
            ChatReference(
              id: 1,
              title: 'A long document title on a narrow screen',
            ),
          ],
        ),
      );
      unawaited(api.responses.single.close());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'Next question');
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Send'), findsOneWidget);
    });
  }
}
