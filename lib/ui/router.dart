// Routes (SPEC 10.1). A StatefulShellRoute keeps the Home, Activity and
// Sync tabs alive; every other screen is pushed over the shell. Until the
// profile exists, every location redirects to /onboarding.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'screens/activity/activity_screen.dart';
import 'screens/expense/expense_detail_screen.dart';
import 'screens/expense/expense_edit_screen.dart';
import 'screens/group/claim_screen.dart';
import 'screens/group/group_edit_screen.dart';
import 'screens/group/group_screen.dart';
import 'screens/group/invite_screen.dart';
import 'screens/group/members_screen.dart';
import 'screens/home/app_shell.dart';
import 'screens/home/home_screen.dart';
import 'screens/join/join_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/person/person_screen.dart';
import 'screens/search/search_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/settle/settle_screen.dart';
import 'screens/sync/host_screen.dart';
import 'screens/sync/scan_screen.dart';
import 'screens/sync/sync_screen.dart';
import 'screens/sync/sync_session_screen.dart';

/// Route paths and builders for links (`context.push(Routes.group(id))`).
abstract final class Routes {
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const activity = '/activity';
  static const sync = '/sync';
  static const syncHost = '/sync/host';
  static const syncScan = '/sync/scan';
  static const syncSession = '/sync/session';
  static const newGroup = '/groups/new';
  static const search = '/search';
  static const settings = '/settings';

  static String group(String gid) => '/groups/$gid';
  static String editGroup(String gid) => '/groups/$gid/edit';
  static String members(String gid) => '/groups/$gid/members';
  static String invite(String gid) => '/groups/$gid/invite';
  static String claim(String gid) => '/groups/$gid/claim';
  static String newExpense({String? groupId, String? personId}) => Uri(
    path: '/expense/new',
    queryParameters: {'gid': ?groupId, 'pid': ?personId},
  ).toString();
  static String expense(String eid) => '/expense/$eid';
  static String editExpense(String eid) => '/expense/$eid/edit';
  static String settle({
    required String groupId,
    String? from,
    String? to,
    String? currency,
  }) => Uri(
    path: '/settle',
    queryParameters: {
      'gid': groupId,
      'from': ?from,
      'to': ?to,
      'cur': ?currency,
    },
  ).toString();
  static String person(String pid) => '/people/$pid';
  static String join(String link) =>
      Uri(path: '/join', queryParameters: {'link': link}).toString();
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Rebuilt never; refreshes its redirect when the profile changes.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(profileProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  String? redirect(BuildContext context, GoRouterState state) {
    final uri = state.uri;
    // settleup://join?... and settleup://sync?... deep links.
    if (uri.scheme == 'settleup' || uri.host == 'join' || uri.host == 'sync') {
      if (uri.host == 'join') return Routes.join(uri.toString());
      if (uri.host == 'sync') {
        return Uri(
          path: Routes.syncScan,
          queryParameters: {'link': uri.toString()},
        ).toString();
      }
    }
    final profile = ref.read(profileProvider);
    if (profile.isLoading && !profile.hasValue) return null;
    final onboarded = profile.value != null;
    final atOnboarding = uri.path == Routes.onboarding;
    if (!onboarded && !atOnboarding) return Routes.onboarding;
    if (onboarded && atOnboarding) return Routes.home;
    if (uri.path == '/' || uri.path.isEmpty) return Routes.home;
    return null;
  }

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: redirect,
    routes: [
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.activity,
                builder: (context, state) => const ActivityScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.sync,
                builder: (context, state) => const SyncScreen(),
                routes: [
                  GoRoute(
                    path: 'host',
                    parentNavigatorKey: _rootKey,
                    builder: (context, state) => const HostScreen(),
                  ),
                  GoRoute(
                    path: 'scan',
                    parentNavigatorKey: _rootKey,
                    builder: (context, state) => ScanScreen(
                      initialLink: state.uri.queryParameters['link'],
                    ),
                  ),
                  GoRoute(
                    path: 'session',
                    parentNavigatorKey: _rootKey,
                    builder: (context, state) => const SyncSessionScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.newGroup,
        builder: (context, state) => const GroupEditScreen(),
      ),
      GoRoute(
        path: '/groups/:gid',
        builder: (context, state) =>
            GroupScreen(groupId: state.pathParameters['gid']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) =>
                GroupEditScreen(groupId: state.pathParameters['gid']),
          ),
          GoRoute(
            path: 'members',
            builder: (context, state) =>
                MembersScreen(groupId: state.pathParameters['gid']!),
          ),
          GoRoute(
            path: 'invite',
            builder: (context, state) =>
                InviteScreen(groupId: state.pathParameters['gid']!),
          ),
          GoRoute(
            path: 'claim',
            builder: (context, state) =>
                ClaimScreen(groupId: state.pathParameters['gid']!),
          ),
        ],
      ),
      GoRoute(
        path: '/expense/new',
        builder: (context, state) => ExpenseEditScreen(
          groupId: state.uri.queryParameters['gid'],
          personId: state.uri.queryParameters['pid'],
        ),
      ),
      GoRoute(
        path: '/expense/:eid',
        builder: (context, state) =>
            ExpenseDetailScreen(expenseId: state.pathParameters['eid']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) =>
                ExpenseEditScreen(expenseId: state.pathParameters['eid']),
          ),
        ],
      ),
      GoRoute(
        path: '/settle',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return SettleScreen(
            groupId: q['gid'] ?? '',
            from: q['from'],
            to: q['to'],
            currency: q['cur'],
          );
        },
      ),
      GoRoute(
        path: '/people/:pid',
        builder: (context, state) =>
            PersonScreen(personId: state.pathParameters['pid']!),
      ),
      GoRoute(
        path: Routes.search,
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/join',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          final link =
              q['link'] ??
              Uri(
                scheme: 'settleup',
                host: 'join',
                query: state.uri.query,
              ).toString();
          return JoinScreen(link: link);
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
