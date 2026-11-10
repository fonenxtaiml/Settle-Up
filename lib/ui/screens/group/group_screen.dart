// Group detail (render 2): your position, Settle up and All balances,
// suggested payments with the simplify switch, then the expenses by day.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/balances.dart';
import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../data/repositories.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../format/money_format.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../csv_share.dart';
import 'missing_key_notice.dart';

enum _Menu { edit, members, activity, export }

class GroupScreen extends ConsumerWidget {
  const GroupScreen({super.key, required this.groupId});

  final GroupId groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(groupProvider(groupId));
    final profile = ref.watch(profileProvider).value;
    final snap = ref.watch(ledgerProvider).value;
    final g = group.value;
    final pendingName = snap?.pendingJoins[groupId];

    if (group.hasValue && (g?.group == null || g!.group!.isDeleted)) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: AppBarTitle(pendingName ?? S.groups),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: pendingName != null
                ? EmptyState(
                    headline: S.pendingGroupTitle,
                    body: S.pendingGroupBody,
                    actionLabel: S.openSync,
                    onAction: () => context.go(Routes.sync),
                  )
                : const Text(S.groupNotFound, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (g == null || profile == null || snap == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: const SizedBox(),
        ),
        body: AsyncBody(value: group, builder: (_) => const SizedBox()),
      );
    }

    final info = g.group!;
    final me = profile.personId;
    final myId = myMemberIn(g, me);
    final currency = info.currency;
    final spent = spentIn(g, currency);
    final title = groupTitle(g, me);

    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: AppBarTitle(
          title,
          subtitle: info.isDirect
              ? S.justYouTwo
              : S.groupSubtitle(
                  g.activeMembers.length,
                  MoneyFormat.format(spent, currency),
                ),
          shortSubtitle: info.isDirect
              ? null
              : S.groupSpent(MoneyFormat.format(spent, currency)),
        ),
        actions: [
          if (!info.isDirect)
            IconButton(
              onPressed: () => context.push(Routes.members(groupId)),
              tooltip: S.members,
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
          PopupMenuButton<_Menu>(
            tooltip: S.moreOptions,
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (m) => switch (m) {
              _Menu.edit => context.push(Routes.editGroup(groupId)),
              _Menu.members => context.push(Routes.members(groupId)),
              _Menu.activity => context.push(Routes.groupActivity(groupId)),
              _Menu.export => shareGroupCsv(context, g, title),
            },
            itemBuilder: (context) => [
              if (!info.isDirect)
                const PopupMenuItem(
                  value: _Menu.edit,
                  child: Text(S.editGroup),
                ),
              const PopupMenuItem(value: _Menu.members, child: Text(S.members)),
              const PopupMenuItem(
                value: _Menu.activity,
                child: Text(S.activityTitle),
              ),
              const PopupMenuItem(
                value: _Menu.export,
                child: Text(S.exportCsv),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: AddExpenseFab(
        onPressed: () => context.push(Routes.newExpense(groupId: groupId)),
      ),
      body: _GroupBody(group: g, me: me, myId: myId, snapshot: snap),
    );
  }
}

class _GroupBody extends ConsumerWidget {
  const _GroupBody({
    required this.group,
    required this.me,
    required this.myId,
    required this.snapshot,
  });

  final GroupState group;
  final String me;
  final MemberId? myId;
  final LedgerSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = group;
    final info = g.group!;
    final nets = BalanceCalculator.groupNets(g);
    final myNet = {
      for (final c in nets.keys)
        if (myId != null && nets[c]![myId] != null) c: nets[c]![myId]!,
    };
    final currency = mainCurrencyOf(myNet, info.currency);
    final position = myNet[currency] ?? 0;
    final names = memberNames(g, me);
    final fullNames = memberFullNames(g);
    final now = ref.watch(clockProvider)();
    final unshared = snapshot.unsharedEntityIds;
    final duplicates = possibleDuplicatePayments(g);

    final transfers = [...BalanceCalculator.suggestedTransfers(g)]
      ..sort((a, b) {
        int mine(Transfer t) => t.from == myId || t.to == myId ? 0 : 1;
        final c = mine(a).compareTo(mine(b));
        return c != 0 ? c : b.amount.compareTo(a.amount);
      });

    String? detail;
    if (myId != null) {
      final ps = myPaidAndShare(g, myId!, currency);
      detail = ps.paid == 0 && ps.share == 0
          ? S.groupDetailNothing
          : S.groupDetail(
              MoneyFormat.format(ps.paid, currency),
              MoneyFormat.format(ps.share, currency),
            );
    }

    final expenses = g.liveExpenses;
    final byDay = <String, List<Expense>>{};
    for (final e in expenses) {
      byDay
          .putIfAbsent(DateLabels.dayHeader(e.date, now: now), () => [])
          .add(e);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        if (snapshot.groupsWithoutKey.contains(g.groupId))
          gutter(const MissingKeyNotice()),
        if (myId != null)
          textGutter(
            GroupBalanceHero(
              minor: position,
              currency: currency,
              detail: detail,
            ),
          ),
        const SizedBox(height: 14),
        textGutter(
          ButtonPair(
            labels: const [S.settleUp, S.allBalances],
            first: FilledButton(
              onPressed: () => context.push(Routes.settle(groupId: g.groupId)),
              child: const Text(S.settleUp),
            ),
            second: FilledButton.tonal(
              onPressed: () => _showAllBalances(context, g, myId, fullNames),
              child: const Text(S.allBalances),
            ),
          ),
        ),
        const SizedBox(height: 14),
        gutter(
          ListSection(
            header: SuggestedPaymentsHeader(
              simplify: info.simplifyDebts,
              onSimplifyChanged: (v) => runGuarded(
                context,
                () => ref
                    .read(ledgerRepositoryProvider)
                    .updateGroup(g.groupId, GroupPatch(simplifyDebts: v)),
              ),
            ),
            padding: const EdgeInsets.only(bottom: 4),
            children: [
              if (transfers.isEmpty)
                KitListRow(
                  title: S.everyoneSettled,
                  subtitle: S.everyoneSettledBody,
                  leading: const TetherGlyph(direction: MoneyDirection.settled),
                ),
              for (final t in transfers)
                TransferRow(
                  fromId: t.from,
                  fromName: fullNames[t.from] ?? S.someone,
                  toId: t.to,
                  toName: fullNames[t.to] ?? S.someone,
                  amountMinor: t.amount,
                  currency: t.currency,
                  fromIsMe: t.from == myId,
                  toIsMe: t.to == myId,
                  onTap: () => context.push(
                    Routes.settle(
                      groupId: g.groupId,
                      from: t.from,
                      to: t.to,
                      currency: t.currency,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (expenses.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.xl, Space.xl, 0),
            child: EmptyState(
              headline: S.groupEmptyHeadline,
              body: S.groupEmptyBody,
            ),
          )
        else
          gutter(
            ListSection(
              title: S.expenses,
              padding: const EdgeInsets.only(bottom: 4),
              children: [
                for (final day in byDay.entries) ...[
                  DateSubhead(day.key),
                  for (final e in day.value)
                    ExpenseRow(
                      expense: e,
                      memberNames: names,
                      myMemberId: myId,
                      resolve: g.resolve,
                      unshared: unshared.contains(e.id),
                      possibleDuplicate: duplicates.contains(e.id),
                      onTap: () => context.push(
                        Routes.expense(e.id, groupId: e.groupId),
                      ),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  void _showAllBalances(
    BuildContext context,
    GroupState g,
    MemberId? myId,
    Map<MemberId, String> fullNames,
  ) {
    final nets = BalanceCalculator.groupNets(g);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                textGutter(
                  Text(S.allBalancesTitle, style: theme.textTheme.titleLarge),
                ),
                const SizedBox(height: Space.sm),
                gutter(
                  ListSection(
                    dividerIndent: Space.avatarRowInset,
                    children: [
                      for (final m in g.activeMembers)
                        BalanceRow(
                          kind: BalanceRowKind.member,
                          id: m.id,
                          title: m.id == myId ? S.you : m.displayName,
                          subtitle: m.isPlaceholder
                              ? S.placeholderSub
                              : S.onSettleUp,
                          isMe: m.id == myId,
                          isPlaceholder: m.isPlaceholder && m.id != myId,
                          net: {
                            for (final c in nets.keys) c: nets[c]![m.id] ?? 0,
                            if (nets.isEmpty) g.group!.currency: 0,
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.lg),
              ],
            ),
          ),
        );
      },
    );
  }
}
