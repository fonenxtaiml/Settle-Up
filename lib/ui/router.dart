// Routes (SPEC 10.1). A StatefulShellRoute keeps the Home, Activity and
// Sync tabs alive; every other screen is pushed over the shell. Until the
// profile exists, every location redirects to /onboarding.
import 'dart:async';

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
  static String groupActivity(String gid) => '/groups/$gid/activity';
  static String invite(String gid) => '/groups/$gid/invite';
  static String claim(String gid) => '/groups/$gid/claim';
  static String newExpense({String? groupId, String? personId}) => Uri(
    path: '/expense/new',
    queryParameters: {'gid': ?groupId, 'pid': ?personId},
  ).toString();

  /// [groupId] names the expense's group. Pass it when known: entity ids
  /// are scoped by group (SPEC 7.2), so only it picks the right one if
  /// hostile input reused the id in another group.
  static String expense(String eid, {String? groupId}) =>
      _withGroup('/expense/$eid', groupId);
  static String editExpense(String eid, {String? groupId}) =>
      _withGroup('/expense/$eid/edit', groupId);
  static String _withGroup(String path, String? groupId) => groupId == null
      ? path
      : Uri(path: path, queryParameters: {'gid': groupId}).toString();
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

  /// The invitation, stacked over Home so Close and Back land there. The
  /// link rides in the path: a query would stay on /home after a pop.
  static String join(String link) => '$joinPath/${Uri.encodeComponent(link)}';
  static const joinPath = '/home/join';
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Where a settleup://join or settleup://sync deep link opens, or null when
/// [uri] is not one.
String? _deepLinkTarget(Uri uri) {
  if (uri.scheme != 'settleup' && uri.host != 'join' && uri.host != 'sync') {
    return null;
  }
  if (uri.host == 'join') return Routes.join(uri.toString());
  if (uri.host == 'sync') {
    return Uri(
      path: Routes.syncScan,
      queryParameters: {'link': uri.toString()},
    ).toString();
  }
  return null;
}

/// Rebuilt never; refreshes its redirect when the profile changes.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(profileProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  // A join or sync link that arrived before onboarding finished: opened
  // once the profile exists, instead of being lost on the way to Home.
  String? pendingLink;

  String? redirect(BuildContext context, GoRouterState state) {
    final uri = state.uri;
    String? target = _deepLinkTarget(uri);
    if (target == null &&
        (uri.path.startsWith('${Routes.joinPath}/') ||
            (uri.path == Routes.syncScan &&
                uri.queryParameters['link'] != null))) {
      target = uri.toString();
    }
    final profile = ref.read(profileProvider);
    if (profile.isLoading && !profile.hasValue) {
      // Not known yet whether onboarding is done: hold the link and wait
      // on Home. Opening it now would start a sync (or an invitation)
      // before a profile exists, and its follow-up screens are not link
      // targets, so the link would be lost on the way to Onboarding.
      if (target != null) {
        pendingLink = target;
        return Routes.home;
      }
      return null;
    }
    final onboarded = profile.value != null;
    final atOnboarding = uri.path == Routes.onboarding;
    if (!onboarded) {
      if (target != null) pendingLink = target;
      return atOnboarding ? null : Routes.onboarding;
    }
    final link = pendingLink;
    if (link != null) {
      pendingLink = null;
      if (link != uri.toString()) return link;
    }
    if (atOnboarding) return Routes.home;
    if (target != null && target != uri.toString()) return target;
    if (uri.path == '/' || uri.path.isEmpty) return Routes.home;
    return null;
  }

  // The platform hands a deep link over as go(), which replaces the whole
  // stack: an Add expense, Settle up or Edit group draft under it would be
  // disposed without its discard check. Once onboarded, a link that
  // arrives over such a screen is pushed on top instead, so closing the
  // invitation (or the sync) returns to the draft.
  FutureOr<OnEnterResult> onEnter(
    BuildContext context,
    GoRouterState current,
    GoRouterState next,
    GoRouter router,
  ) {
    final target = _deepLinkTarget(next.uri);
    if (target == null) return const Allow();
    final profile = ref.read(profileProvider);
    if (profile.value == null) return const Allow();
    final here = current.uri.path;
    const tabRoots = {Routes.home, Routes.activity, Routes.sync};
    if (here.isEmpty ||
        here == '/' ||
        here == Routes.onboarding ||
        tabRoots.contains(here)) {
      return const Allow();
    }
    return Block.then(() => router.push<void>(target));
  }

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.home,
    refreshListenable: refresh,
    onEnter: onEnter,
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
                routes: [
                  GoRoute(
                    path: 'join/:link',
                    parentNavigatorKey: _rootKey,
                    builder: (context, state) =>
                        JoinScreen(link: state.pathParameters['link']!),
                  ),
                ],
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
            path: 'activity',
            builder: (context, state) =>
                ActivityScreen(groupId: state.pathParameters['gid']),
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
        builder: (context, state) => ExpenseDetailScreen(
          expenseId: state.pathParameters['eid']!,
          groupId: state.uri.queryParameters['gid'],
        ),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) => ExpenseEditScreen(
              expenseId: state.pathParameters['eid'],
              groupId: state.uri.queryParameters['gid'],
            ),
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
      // Older links to /join: the invitation now sits over Home.
      GoRoute(
        path: '/join',
        redirect: (context, state) {
          final q = state.uri.queryParameters;
          return Routes.join(
            q['link'] ??
                Uri(
                  scheme: 'settleup',
                  host: 'join',
                  query: state.uri.query,
                ).toString(),
          );
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
