// Expense detail: what it was, how it leaves you, who paid and who owes,
// and its history. Edit, delete (with undo) and restore live here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/activity.dart';
import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../core/ops.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../format/money_format.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/kit_strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

enum _Menu { delete, restore }

class ExpenseDetailScreen extends ConsumerWidget {
  const ExpenseDetailScreen({super.key, required this.expenseId});

  final ExpenseId expenseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(ledgerProvider).value;
    final profile = ref.watch(profileProvider).value;
    final e = snap?.state.expense(expenseId);
    if (snap == null || profile == null || e == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: const SizedBox(),
        ),
        body: snap == null
            ? const SizedBox.shrink()
            : const Center(child: Text(S.errExpenseNotFound)),
      );
    }
    final g = snap.state.groups[e.groupId]!;
    final me = profile.personId;
    final myId = myMemberIn(g, me);
    final names = memberNames(g, me);
    final full = memberFullNames(g);
    final now = ref.watch(clockProvider)();
    final ledger = ref.read(ledgerRepositoryProvider);
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final currency = e.money.currency;

    Future<void> delete() async {
      final title = e.isPayment ? S.paymentTitle.toLowerCase() : e.description;
      final ok = await confirmAction(
        context,
        title: S.deleteExpenseTitle(title),
        body: S.deleteExpenseBody,
        confirmLabel: S.delete,
      );
      if (!ok || !context.mounted) return;
      final done = await runGuarded(context, () => ledger.deleteExpense(e.id));
      if (!done || !context.mounted) return;
      Haptics.medium(context);
      showSnack(
        context,
        S.expenseDeleted,
        actionLabel: S.undo,
        onAction: () => ledger.restoreExpense(e.id),
      );
      if (context.canPop()) context.pop();
    }

    Future<void> restore() async {
      final done = await runGuarded(context, () => ledger.restoreExpense(e.id));
      if (done && context.mounted) showSnack(context, S.expenseRestored);
    }

    final impact = myId == null ? 0 : _impact(g, e, myId);
    final involved =
        myId != null &&
        [
          ...e.money.paid.keys,
          ...e.money.owed.keys,
        ].any((m) => g.resolve(m) == myId);
    final title = e.isPayment
        ? KitStrings.paymentTitle(
            names[e.payer] ?? S.someone,
            (names[e.receiver] ?? S.someone) == S.you
                ? S.you.toLowerCase()
                : names[e.receiver] ?? S.someone,
          )
        : e.description;
    final word = e.isPayment
        ? (impact > 0
              ? KitStrings.paid
              : impact < 0
              ? KitStrings.received
              : KitStrings.notInvolved)
        : impact > 0
        ? KitStrings.youLent
        : impact < 0
        ? KitStrings.youBorrowed
        : involved
        ? KitStrings.settled
        : KitStrings.notInvolved;

    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: AppBarTitle(
          e.isPayment ? S.paymentTitle : S.expenseTitle,
          subtitle: groupTitle(g, me),
        ),
        actions: [
          if (!e.isDeleted)
            IconButton(
              onPressed: () => context.push(Routes.editExpense(e.id)),
              tooltip: S.edit,
              icon: const Icon(Icons.edit_outlined),
            ),
          PopupMenuButton<_Menu>(
            tooltip: S.moreOptions,
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (m) => switch (m) {
              _Menu.delete => delete(),
              _Menu.restore => restore(),
            },
            itemBuilder: (context) => [
              if (e.isDeleted)
                const PopupMenuItem(
                  value: _Menu.restore,
                  child: Text(S.restore),
                )
              else
                const PopupMenuItem(
                  value: _Menu.delete,
                  child: Text(S.deleteExpense),
                ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          if (e.isDeleted)
            gutter(
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Material(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            S.deletedBanner,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        FilledButton(
                          onPressed: restore,
                          style: KitButtonStyles.small(context),
                          child: const Text(S.restore),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          textGutter(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: Space.md),
                  child: e.isPayment
                      ? const TetherGlyph(direction: MoneyDirection.neutral)
                      : CategoryGlyph(categoryId: e.category, size: 28),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.headlineSmall!.copyWith(
                          decoration: e.isDeleted
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        e.isPayment
                            ? ExpenseRow.methodLabel(
                                e.paymentMethod ?? PaymentMethod.other,
                              )
                            : categoryLabel(e.category),
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: ink2,
                        ),
                      ),
                      Text(
                        DateLabels.pickerDate(e.date, now: now),
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.lg),
          textGutter(
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: MoneyText(
                    minor: e.money.total,
                    currency: currency,
                    style: MoneyTextStyle.headline,
                    signed: false,
                    colored: false,
                  ),
                ),
                if (myId != null)
                  BalanceTrailing(
                    word: word,
                    minor: impact,
                    currency: currency,
                    direction: e.isPayment
                        ? MoneyDirection.neutral
                        : MoneyDirection.of(impact),
                  ),
              ],
            ),
          ),
          if (!e.isPayment) ...[
            gutter(
              ListSection(
                title: S.whoPaidTitle,
                dividerIndent: Space.avatarRowInset,
                children: [
                  for (final p in e.money.paid.entries)
                    _PersonAmountRow(
                      id: g.resolve(p.key),
                      name: names[p.key] ?? S.someone,
                      fullName: full[p.key] ?? '',
                      isMe: g.resolve(p.key) == myId,
                      minor: p.value,
                      currency: currency,
                    ),
                ],
              ),
            ),
            gutter(
              ListSection(
                title: S.whoOwesTitle,
                dividerIndent: Space.avatarRowInset,
                children: [
                  for (final o in _sortedOwed(e, myId, g))
                    _PersonAmountRow(
                      id: g.resolve(o.key),
                      name: names[o.key] ?? S.someone,
                      fullName: full[o.key] ?? '',
                      isMe: g.resolve(o.key) == myId,
                      minor: o.value,
                      currency: currency,
                    ),
                ],
              ),
            ),
          ],
          if (e.notes.isNotEmpty)
            gutter(
              ListSection(
                title: S.notes,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(e.notes, style: theme.textTheme.bodyLarge),
                  ),
                ],
              ),
            ),
          _History(expense: e, group: g, me: me),
        ],
      ),
    );
  }

  static int _impact(GroupState g, Expense e, MemberId me) {
    var v = 0;
    e.money.paid.forEach((m, x) {
      if (g.resolve(m) == me) v += x;
    });
    e.money.owed.forEach((m, x) {
      if (g.resolve(m) == me) v -= x;
    });
    return v;
  }

  static List<MapEntry<MemberId, int>> _sortedOwed(
    Expense e,
    MemberId? me,
    GroupState g,
  ) => e.money.owed.entries.toList()
    ..sort((a, b) {
      final am = g.resolve(a.key) == me ? 0 : 1;
      final bm = g.resolve(b.key) == me ? 0 : 1;
      if (am != bm) return am.compareTo(bm);
      return b.value.compareTo(a.value);
    });
}

class _PersonAmountRow extends StatelessWidget {
  const _PersonAmountRow({
    required this.id,
    required this.name,
    required this.fullName,
    required this.isMe,
    required this.minor,
    required this.currency,
  });

  final String id;
  final String name;
  final String fullName;
  final bool isMe;
  final int minor;
  final String currency;

  @override
  Widget build(BuildContext context) => KitListRow(
    title: name,
    minHeight: Sizes.rowMinDense,
    leading: PersonAvatar(
      id: id,
      name: fullName,
      size: Sizes.avatarSmall,
      isMe: isMe,
    ),
    trailing: Text(
      MoneyFormat.format(minor, currency),
      style: AppType.amount(context),
    ),
  );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            for (final l in lines) Text(l, style: sub),
          ],
        ),
      ),
    );
  }
}

class _History extends ConsumerWidget {
  const _History({
    required this.expense,
    required this.group,
    required this.me,
  });

  final Expense expense;
  final GroupState group;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(expenseHistoryProvider(expense.id)).value;
    if (entries == null || entries.isEmpty) return const SizedBox.shrink();
    final names = memberNames(group, me);
    final now = ref.watch(clockProvider)();
    return gutter(
      ListSection(
        title: S.history,
        children: [
          for (final a in entries.reversed)
            _HistoryRow(
              title: _sentence(a, names),
              lines: [
                ..._changes(a, names),
                [
                  '${DateLabels.pickerDate(a.at, now: now)}, '
                      '${DateLabels.clock12(a.at)}',
                  if (!a.isLocal) S.bySync,
                  if (a.isLocal && !a.isShared) S.notYetShared,
                ].join(', '),
                if (a.supersededBy != null) S.conflictNote,
              ],
            ),
        ],
      ),
    );
  }

  String _actor(ActivityEntry a, Map<MemberId, String> names) =>
      a.actor == null ? S.someone : names[a.actor] ?? S.someone;

  String _sentence(ActivityEntry a, Map<MemberId, String> names) {
    final who = _actor(a, names);
    const it = 'this';
    return switch (a.kind) {
      ActivityKind.expenseAdded ||
      ActivityKind.paymentAdded => S.actAddedExpense(who, it),
      ActivityKind.expenseEdited ||
      ActivityKind.paymentEdited => S.actEditedExpense(who, it),
      ActivityKind.expenseDeleted ||
      ActivityKind.paymentDeleted => S.actDeletedExpense(who, it),
      ActivityKind.expenseRestored ||
      ActivityKind.paymentRestored => S.actRestoredExpense(who, it),
      _ => S.actEditedExpense(who, it),
    };
  }

  /// "Amount ₹2,000 → ₹2,400" style lines for an edit.
  List<String> _changes(ActivityEntry a, Map<MemberId, String> names) {
    if (a.op.kind != OpKind.update) return const [];
    final out = <String>[];
    a.changes.forEach((field, c) {
      switch (field) {
        case ExpenseFields.description:
          out.add('${S.description}: ${c.after}');
        case ExpenseFields.money:
          final before = c.before is Map
              ? MoneyBlock.fromJson(Map<String, Object?>.from(c.before! as Map))
              : null;
          final after = c.after is Map
              ? MoneyBlock.fromJson(Map<String, Object?>.from(c.after! as Map))
              : null;
          if (after != null) {
            final b = before == null
                ? ''
                : '${MoneyFormat.format(before.total, before.currency)} → ';
            out.add(
              '${S.amount}: $b${MoneyFormat.format(after.total, after.currency)}',
            );
          }
        case ExpenseFields.category:
          out.add('${S.category}: ${categoryLabel('${c.after}')}');
        case ExpenseFields.date:
          if (c.after is int) {
            out.add(
              '${S.date}: ${DateLabels.shortDate(utcFromMillis(c.after! as int))}',
            );
          }
        case ExpenseFields.notes:
          out.add('${S.notes}: ${c.after}');
      }
    });
    return out;
  }
}
