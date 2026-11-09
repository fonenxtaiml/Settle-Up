// Home (render 1 / 6): the overall answer, the sync strip, groups and the
// people you are not settled with.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/balances.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../sync/sync_engine.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

/// How many groups and people Home lists before "See all".
const int _collapsedGroups = 4;
const int _collapsedPeople = 4;

/// The sync strip and chip state from the engine status and the ledger.
SyncChipState syncChipState(SyncStatus? status, int pending, bool synced) {
  final session = status?.session;
  if (session is SessionActive) return SyncChipState.inProgress;
  if (session is SessionFailed && session.failure != SyncFailure.cancelled) {
    return SyncChipState.failed;
  }
  if (pending > 0) return SyncChipState.changesWaiting;
  return synced ? SyncChipState.allShared : SyncChipState.neverSynced;
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _allGroups = false;
  bool _allPeople = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    final snap = ref.watch(ledgerProvider);
    final summaries = ref.watch(groupSummariesProvider);
    final people = ref.watch(peopleBalancesProvider);
    final overall = ref.watch(overallBalanceProvider);
    final hasGroups = summaries.value?.isNotEmpty ?? false;

    return Scaffold(
      appBar: screenAppBar(
        title: const Text(S.appName),
        actions: [
          IconButton(
            onPressed: () => context.push(Routes.search),
            tooltip: S.searchExpenses,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            onPressed: () => context.push(Routes.newGroup),
            tooltip: S.newGroup,
            icon: const Icon(Icons.group_add_outlined),
          ),
          IconButton(
            onPressed: () => context.push(Routes.settings),
            tooltip: S.yourProfile,
            icon: PersonAvatar(
              id: profile?.personId ?? 'me',
              name: profile?.displayName ?? S.you,
              size: Sizes.avatarSmall,
              isMe: true,
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: const _AboveNavBar(),
      floatingActionButton: hasGroups
          ? AddExpenseFab(onPressed: () => context.push(Routes.newExpense()))
          : null,
      body: AsyncBody(
        value: summaries,
        builder: (groups) {
          final s = snap.value;
          final p = profile;
          if (s == null || p == null) return const SizedBox.shrink();
          if (groups.isEmpty && s.pendingJoins.isEmpty) {
            return _Empty(onCreate: () => context.push(Routes.newGroup));
          }
          return _body(
            context,
            groups: groups,
            people: people.value ?? const [],
            overall: overall.value ?? OverallBalance.zero,
            homeCurrency: p.homeCurrency,
            me: p.personId,
            pendingJoins: s.pendingJoins,
          );
        },
      ),
    );
  }

  Widget _body(
    BuildContext context, {
    required List<GroupBalanceSummary> groups,
    required List<PersonBalance> people,
    required OverallBalance overall,
    required String homeCurrency,
    required String me,
    required Map<String, String> pendingJoins,
  }) {
    // "Coming to you" and "You owe" sum the groups (render 1): what you
    // get back where you are owed and what you owe where you owe.
    final snap = ref.watch(ledgerProvider).value!;
    final owedToMe = <String, int>{};
    final iOwe = <String, int>{};
    for (final g in snap.state.visibleGroups) {
      Summaries.myNetInGroup(g, me).forEach((c, v) {
        if (v > 0) owedToMe[c] = (owedToMe[c] ?? 0) + v;
        if (v < 0) iOwe[c] = (iOwe[c] ?? 0) - v;
      });
    }
    final net = <String, int>{
      for (final c in {...owedToMe.keys, ...iOwe.keys})
        c: (owedToMe[c] ?? 0) - (iOwe[c] ?? 0),
    }..removeWhere((_, v) => v == 0);
    final mainCurrency = mainCurrencyOf({
      ...owedToMe,
      ...iOwe,
      ...overall.net,
    }, homeCurrency);

    final active = groups.where((g) => !g.group.group!.archived).toList();
    final archived = groups.where((g) => g.group.group!.archived).toList();
    final shownGroups = _allGroups
        ? active
        : active.take(_collapsedGroups).toList();
    final canExpandGroups =
        active.length > _collapsedGroups || archived.isNotEmpty;
    final unsettled = people.where((p) => !p.isSettled).toList();
    // Home lists the people you are not settled with; settled friends are
    // a tap away in their groups.
    final shownPeople = _allPeople
        ? unsettled
        : unsettled.take(_collapsedPeople).toList();
    final canExpandPeople = unsettled.length > _collapsedPeople;
    final groupOrder = {
      for (final (i, g) in groups.indexed) g.group.groupId: i,
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const SizedBox(height: Space.xs),
        textGutter(
          BalanceHero(
            net: net,
            owedToMe: owedToMe,
            iOwe: iOwe,
            mainCurrency: mainCurrency,
          ),
        ),
        const SizedBox(height: Space.lg),
        gutter(const _HomeSyncBanner()),
        gutter(
          ListSection(
            title: S.groups,
            titleAction: canExpandGroups
                ? TextLink(
                    _allGroups ? S.showLess : S.seeAll,
                    onPressed: () => setState(() => _allGroups = !_allGroups),
                  )
                : null,
            children: [
              for (final g in shownGroups)
                BalanceRow(
                  kind: BalanceRowKind.group,
                  id: g.group.groupId,
                  title: g.group.group!.name,
                  subtitle: S.people(g.memberCount),
                  net: g.myNet.isEmpty ? {g.group.group!.currency: 0} : g.myNet,
                  onTap: () => context.push(Routes.group(g.group.groupId)),
                ),
              for (final e in pendingJoins.entries)
                KitListRow(
                  title: e.value,
                  subtitle: S.waitingForFirstSync,
                  onTap: () => context.push(Routes.group(e.key)),
                ),
            ],
          ),
        ),
        if (_allGroups && archived.isNotEmpty)
          gutter(
            ListSection(
              title: S.archivedGroups,
              children: [
                for (final g in archived)
                  BalanceRow(
                    kind: BalanceRowKind.group,
                    id: g.group.groupId,
                    title: g.group.group!.name,
                    subtitle: S.people(g.memberCount),
                    net: g.myNet.isEmpty
                        ? {g.group.group!.currency: 0}
                        : g.myNet,
                    onTap: () => context.push(Routes.group(g.group.groupId)),
                  ),
              ],
            ),
          ),
        if (shownPeople.isNotEmpty)
          gutter(
            ListSection(
              title: S.peopleTitle,
              titleAction: canExpandPeople
                  ? TextLink(
                      _allPeople ? S.showLess : S.seeAll,
                      onPressed: () => setState(() => _allPeople = !_allPeople),
                    )
                  : null,
              dividerIndent: Space.avatarRowInset,
              children: [
                for (final p in shownPeople)
                  BalanceRow(
                    kind: BalanceRowKind.person,
                    id: p.personId,
                    title: p.displayName,
                    subtitle: personSubtitle(p, snap.state, groupOrder),
                    net: p.net.isEmpty ? {homeCurrency: 0} : p.net,
                    onTap: () => context.push(Routes.person(p.personId)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Goa trip, Flat 4B": the groups shared with a person; a 1:1 group
/// reads "Just you two".
/// Groups follow [order] (Home's order: unsettled, then recent).
String personSubtitle(
  PersonBalance p,
  LedgerState state, [
  Map<String, int> order = const {},
]) {
  final ids = [...p.groupIds]
    ..sort((a, b) => (order[a] ?? 1 << 20).compareTo(order[b] ?? 1 << 20));
  return [
    for (final id in ids)
      if (state.groups[id]?.group case final g? when !g.archived)
        g.isDirect ? S.justYouTwo : g.name,
  ].join(', ');
}

/// End-float, resting on the navigation bar as in render 1, so the FAB
/// covers less of the list.
class _AboveNavBar extends StandardFabLocation
    with FabEndOffsetX, FabFloatOffsetY {
  const _AboveNavBar();

  @override
  double getOffsetY(ScaffoldPrelayoutGeometry geometry, double adjustment) =>
      super.getOffsetY(geometry, adjustment) + kFloatingActionButtonMargin;
}

class _HomeSyncBanner extends ConsumerWidget {
  const _HomeSyncBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(
      ledgerProvider.select((s) => s.value?.totalUnshared ?? 0),
    );
    final history = ref.watch(syncHistoryProvider).value ?? const [];
    final last = history.where((r) => r.outcome != SyncOutcome.failed);
    final lastRecord = last.isEmpty ? null : last.first;
    final state = syncChipState(status, pending, lastRecord != null);
    final session = status?.session;
    final peer = session is SessionActive
        ? session.progress.peerName
        : lastRecord?.peerName;
    return SyncBanner(
      state: state,
      pendingCount: pending,
      lastSyncedAt: lastRecord?.endedAt,
      peerName: peer,
      now: ref.watch(clockProvider)(),
      onTap: () => context.go(Routes.sync),
      onSync: state == SyncChipState.allShared
          ? null
          : () => context.go(Routes.sync),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmptyState(
            headline: S.homeEmptyHeadline,
            body: S.homeEmptyBody,
            actionLabel: S.createGroup,
            onAction: onCreate,
          ),
          const SizedBox(height: Space.sm),
          TextLink(
            S.joinWithQr,
            onPressed: () => context.push(Routes.syncScan),
          ),
        ],
      ),
    ),
  );
}
