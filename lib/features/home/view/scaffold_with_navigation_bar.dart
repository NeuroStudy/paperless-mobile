import 'package:cached_query_flutter/cached_query_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/core/extensions/context_extensions.dart';
import 'package:paperless_mobile/features/app_drawer/view/app_drawer.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/theme.dart';

class ScaffoldWithNavigationBar extends StatefulWidget {
  final StatefulNavigationShell navigationShell;
  const ScaffoldWithNavigationBar({super.key, required this.navigationShell});

  @override
  State<ScaffoldWithNavigationBar> createState() =>
      ScaffoldWithNavigationBarState();
}

class ScaffoldWithNavigationBarState extends State<ScaffoldWithNavigationBar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: buildOverlayStyle(theme),
      child: Scaffold(
        drawer: const AppDrawer(),
        bottomNavigationBar: NavigationBar(
          elevation: 3,
          backgroundColor: Theme.of(context).colorScheme.surface,
          selectedIndex: widget.navigationShell.currentIndex,
          onDestinationSelected: (index) {
            widget.navigationShell.goBranch(
              index,
              initialLocation: index == widget.navigationShell.currentIndex,
            );
          },
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: theme.colorScheme.primary),
              label: S.of(context)!.home,
            ),
            _toggleDestination(
              NavigationDestination(
                icon: const Icon(Icons.description_outlined),
                selectedIcon: Icon(
                  Icons.description,
                  color: theme.colorScheme.primary,
                ),
                label: S.of(context)!.documents,
              ),
              disableWhen: !context.uiSettings$.canViewDocuments,
            ),
            _toggleDestination(
              NavigationDestination(
                icon: const Icon(Icons.document_scanner_outlined),
                selectedIcon: Icon(
                  Icons.document_scanner,
                  color: theme.colorScheme.primary,
                ),
                label: S.of(context)!.scanner,
              ),
              disableWhen: !context.uiSettings$.canCreateDocuments,
            ),
            _toggleDestination(
              NavigationDestination(
                icon: const Icon(Icons.sell_outlined),
                selectedIcon: Icon(
                  Icons.sell,
                  color: theme.colorScheme.primary,
                ),
                label: S.of(context)!.labels,
              ),
              disableWhen: !context.uiSettings$.canViewAnyLabel,
            ),
            _toggleDestination(
              NavigationDestination(
                icon: Builder(
                  builder: (context) {
                    return QueryBuilder(
                      query: context.inboxRepository.inboxDocumentsQuery,
                      builder: (context, state) {
                        final count = state.data?.pages.flattened.length ?? 0;
                        return Badge.count(
                          isLabelVisible: count > 0,
                          count: count,
                          child: const Icon(Icons.inbox_outlined),
                        );
                      },
                    );
                  },
                ),
                selectedIcon: QueryBuilder(
                  query: context.inboxRepository.inboxDocumentsQuery,
                  builder: (context, state) {
                    final count = state.data?.pages.flattened.length ?? 0;
                    return Badge.count(
                      isLabelVisible:
                          count > 0 && context.uiSettings$.canViewInbox,
                      count: count,
                      child: Icon(
                        Icons.inbox,
                        color: theme.colorScheme.primary,
                      ),
                    );
                  },
                ),
                label: S.of(context)!.inbox,
              ),
              disableWhen: !context.uiSettings$.canViewInbox,
            ),
            _toggleDestination(
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(
                  Icons.chat_bubble,
                  color: theme.colorScheme.primary,
                ),
                label: S.of(context)!.chat,
              ),
              disableWhen: !context.uiSettings$.canViewDocuments,
            ),
          ],
        ),
        body: widget.navigationShell,
      ),
    );
  }

  Widget _toggleDestination(Widget destination, {required bool disableWhen}) {
    final disabledColor = Theme.of(context).disabledColor;

    final disabledTheme = Theme.of(context).navigationBarTheme.copyWith(
      labelTextStyle: WidgetStatePropertyAll(
        Theme.of(context).textTheme.labelSmall?.copyWith(color: disabledColor),
      ),
      iconTheme: WidgetStatePropertyAll(
        Theme.of(context).iconTheme.copyWith(color: disabledColor),
      ),
    );
    if (disableWhen) {
      return AbsorbPointer(
        child: Theme(
          data: Theme.of(context).copyWith(navigationBarTheme: disabledTheme),
          child: destination,
        ),
      );
    }
    return destination;
  }
}
