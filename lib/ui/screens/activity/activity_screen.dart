// Activity: every change in every group plus the sync sessions, newest
// first, by day, with filters.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/activity.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/kit_strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

enum ActivityFilter { all, expenses, payments, syncs }

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

/// One line of the feed: a ledger change or a sync session.
sealed class _Item {
  DateTime get at;
}

final class _OpItem extends _Item {
  _OpItem(this.entry);
  final ActivityEntry entry;
  @override
  DateTime get at => entry.at;
}

final class _SyncItem extends _Item {
  _SyncItem(this.record);
  final SyncRecord record;
  @override
  DateTime get at => record.endedAt;
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  ActivityFilter _filter = ActivityFilter.all;

  static bool _isExpense(ActivityKind k) =>
      k == ActivityKind.expenseAdded ||
      k == ActivityKind.expenseEdited ||
      k == ActivityKind.expenseDeleted ||
      k == ActivityKind.expenseRestored;

  static bool _isPayment(ActivityKind k) =>
      k == ActivityKind.paymentAdded ||
      k == ActivityKind.paymentEdited ||
      k == ActivityKind.paymentDeleted ||
      k == ActivityKind.paymentRestored;

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(activityProvider(null));
    final history = ref.watch(syncHistoryProvider).value ?? const [];
    final snap = ref.watch(ledgerProvider).value;
    final me = ref.watch(profileProvider).value?.personId;
    final now = ref.watch(clockProvider)();

    return Scaffold(
      appBar: screenAppBar(
        title: const Text(S.activityTitle),
        actions: [
          IconButton(
            onPressed: () => context.push(Routes.search),
            tooltip: S.searchExpenses,
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: AsyncBody(
        value: activity,
        builder: (entries) {
          if (snap == null || me == null) return const SizedBox.shrink();
          final items = <_Item>[
            if (_filter != ActivityFilter.syncs)
              for (final e in entries)
                if (_filter == ActivityFilter.all ||
                    (_filter == ActivityFilter.expenses &&
                        _isExpense(e.kind)) ||
                    (_filter == ActivityFilter.payments && _isPayment(e.kind)))
                  _OpItem(e),
            if (_filter == ActivityFilter.all ||
                _filter == ActivityFilter.syncs)
              for (final r in history) _SyncItem(r),
          ]..sort((a, b) => b.at.compareTo(a.at));
          final byDay = <String, List<_Item>>{};
          for (final i in items) {
            byDay
                .putIfAbsent(DateLabels.dayHeader(i.at, now: now), () => [])
                .add(i);
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: Space.xl),
            children: [
              _Filters(
                value: _filter,
                onChanged: (f) => setState(() => _filter = f),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Space.xl),
                  child: EmptyState(
                    headline: S.activityEmptyHeadline,
                    body: S.activityEmptyBody,
                  ),
                ),
              for (final day in byDay.entries)
                gutter(
                  ListSection(
                    title: day.key,
                    dividerIndent: Space.avatarRowInset,
                    children: [
                      for (final i in day.value)
                        switch (i) {
                          _OpItem(:final entry) => ActivityRow(
                            entry: entry,
                            state: snap.state,
                            me: me,
                          ),
                          _SyncItem(:final record) => SyncRecordRow(
                            record: record,
                          ),
                        },
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.value, required this.onChanged});

  final ActivityFilter value;
  final ValueChanged<ActivityFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {
      ActivityFilter.all: S.filterAll,
      ActivityFilter.expenses: S.filterExpenses,
      ActivityFilter.payments: S.filterPayments,
      ActivityFilter.syncs: S.filterSyncs,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Space.screen),
      child: Row(
        children: [
          for (final f in ActivityFilter.values) ...[
            if (f != ActivityFilter.all) const SizedBox(width: Space.sm),
            ChoiceChip(
              label: Text(labels[f]!),
              selected: f == value,
              showCheckmark: false,
              onSelected: (_) {
                Haptics.selection(context);
                onChanged(f);
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// One ledger change: who did what, where and when.
class ActivityRow extends ConsumerWidget {
  const ActivityRow({
    super.key,
    required this.entry,
    required this.state,
    required this.me,
  });

  final ActivityEntry entry;
  final LedgerState state;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = state.groups[entry.groupId];
    final names = g == null ? const <String, String>{} : memberNames(g, me);
    final full = g == null ? const <String, String>{} : memberFullNames(g);
    final actorId = entry.actor;
    final actor = actorId == null ? S.someone : names[actorId] ?? S.someone;
    final groupName = g == null ? '' : groupTitle(g, me);
    final expense = entry.op.entityType.name == 'expense'
        ? g?.expenses[entry.entityId]
        : null;
    final member = entry.op.entityType.name == 'member'
        ? g?.members[entry.entityId]
        : null;
    final what = expense == null
        ? ''
        : expense.isPayment
        ? KitStrings.paymentTitle(
            names[expense.payer] ?? S.someone,
            names[expense.receiver] == S.you
                ? S.you.toLowerCase()
                : names[expense.receiver] ?? S.someone,
          )
        : expense.description;
    final memberName = member?.displayName ?? S.someone;

    final sentence = switch (entry.kind) {
      ActivityKind.groupCreated => S.actCreatedGroup(actor, groupName),
      ActivityKind.groupEdited => S.actEditedGroup(actor, groupName),
      ActivityKind.groupDeleted => S.actDeletedGroup(actor, groupName),
      ActivityKind.memberAdded => S.actAddedMember(actor, memberName),
      ActivityKind.memberEdited => S.actEditedMember(actor, memberName),
      ActivityKind.memberRemoved => S.actRemovedMember(actor, memberName),
      ActivityKind.membersMerged => S.actMerged(actor, memberName),
      ActivityKind.memberClaimed => S.actClaimed(
        member == null ? S.someone : (names[member.id] ?? memberName),
      ),
      ActivityKind.expenseAdded => S.actAddedExpense(actor, what),
      ActivityKind.expenseEdited => S.actEditedExpense(actor, what),
      ActivityKind.expenseDeleted => S.actDeletedExpense(actor, what),
      ActivityKind.expenseRestored => S.actRestoredExpense(actor, what),
      ActivityKind.paymentAdded =>
        expense == null
            ? S.actAddedExpense(actor, S.paymentTitle.toLowerCase())
            : S.actPayment(
                actor,
                names[expense.payer] ?? S.someone,
                names[expense.receiver] == S.you
                    ? S.you.toLowerCase()
                    : names[expense.receiver] ?? S.someone,
              ),
      ActivityKind.paymentEdited => S.actEditedPayment(actor),
      ActivityKind.paymentDeleted => S.actDeletedPayment(actor),
      ActivityKind.paymentRestored => S.actRestoredPayment(actor),
    };
    final subtitle = [
      if (groupName.isNotEmpty) groupName,
      DateLabels.clock12(entry.at),
      if (!entry.isLocal) S.bySync,
      if (entry.isLocal && !entry.isShared) S.notYetShared,
    ].join(', ');

    final myId = g == null ? null : myMemberIn(g, me);
    Widget? trailing;
    if (expense != null &&
        !expense.isDeleted &&
        (entry.kind == ActivityKind.expenseAdded ||
            entry.kind == ActivityKind.paymentAdded)) {
      final impact = ExpenseRow.impactOf(expense, myId, resolve: g?.resolve);
      final v = ExpenseRow.impactValue(expense, myId, resolve: g?.resolve);
      if (impact == ExpenseImpact.lent || impact == ExpenseImpact.borrowed) {
        trailing = BalanceTrailing(
          word: expense.isPayment
              ? (v > 0 ? KitStrings.paid : KitStrings.received)
              : (v > 0 ? KitStrings.youLent : KitStrings.youBorrowed),
          minor: v,
          currency: expense.money.currency,
          direction: expense.isPayment
              ? MoneyDirection.neutral
              : MoneyDirection.of(v),
          compact: true,
        );
      }
    }
    if (expense != null &&
        expense.isDeleted &&
        (entry.kind == ActivityKind.expenseDeleted ||
            entry.kind == ActivityKind.paymentDeleted)) {
      trailing = TextButton(
        onPressed: () => runGuarded(
          context,
          () => ref.read(ledgerRepositoryProvider).restoreExpense(expense.id),
        ),
        child: const Text(S.restore),
      );
    }

    final leading = actorId == null
        ? const PersonAvatar(id: '?', name: '?')
        : PersonAvatar(
            id: g?.resolve(actorId) ?? actorId,
            name: full[actorId] ?? actor,
            isMe: g != null && g.resolve(actorId) == myId,
          );

    return KitListRow(
      title: sentence,
      subtitle: subtitle,
      leading: leading,
      trailing: trailing,
      onTap: expense == null
          ? (g?.group == null
                ? null
                : () => context.push(Routes.group(entry.groupId)))
          : () => context.push(Routes.expense(expense.id)),
    );
  }
}

/// A sync session in the feed.
class SyncRecordRow extends StatelessWidget {
  const SyncRecordRow({super.key, required this.record});

  final SyncRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = record.outcome == SyncOutcome.completed;
    return KitListRow(
      title: ok
          ? S.syncedWith(record.peerName)
          : S.syncStoppedWith(record.peerName),
      subtitle:
          '${S.sentGot(record.sentOps, record.receivedOps)}, '
          '${transportWord(record.transport)}, '
          '${DateLabels.clock12(record.endedAt)}',
      leading: SizedBox.square(
        dimension: Sizes.avatar,
        child: Center(
          child: Icon(
            ok ? Icons.sync_alt_rounded : Icons.error_outline_rounded,
            color: ok ? theme.colorScheme.onSurface : theme.colorScheme.error,
          ),
        ),
      ),
      onTap: () => context.go(Routes.sync),
    );
  }
}

String transportWord(TransportKind k) =>
    k == TransportKind.lan ? S.wifi : S.bluetooth;
