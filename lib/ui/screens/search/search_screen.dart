// Local search across every expense: description, note, category and the
// names of the people in it. In memory; MVP ledgers are small.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

/// Expenses (payments included) in [state] matching every word of [query].
List<(GroupState, Expense)> searchExpenses(LedgerState state, String query) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  final out = <(GroupState, Expense)>[];
  for (final g in state.visibleGroups) {
    final names = memberFullNames(g);
    for (final e in g.liveExpenses) {
      final haystack = [
        e.description,
        e.notes,
        categoryLabel(e.category),
        g.group!.name,
        for (final m in {...e.money.paid.keys, ...e.money.owed.keys})
          names[m] ?? '',
      ].join(' ').toLowerCase();
      if (words.every(haystack.contains)) out.add((g, e));
    }
  }
  out.sort((a, b) => b.$2.date.compareTo(a.$2.date));
  return out;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(ledgerProvider).value;
    final me = ref.watch(profileProvider).value?.personId;
    final theme = Theme.of(context);
    final q = _query.text.trim();
    final results = snap == null
        ? const <(GroupState, Expense)>[]
        : searchExpenses(snap.state, q);
    final byGroup = <GroupState, List<Expense>>{};
    for (final (g, e) in results) {
      byGroup.putIfAbsent(g, () => []).add(e);
    }
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.titleMedium,
          decoration: InputDecoration(
            hintText: S.searchHint,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: S.clearSearch,
                    onPressed: () => setState(_query.clear),
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      body: snap == null || me == null
          ? const SizedBox.shrink()
          : q.isEmpty
          ? textGutter(
              Padding(
                padding: const EdgeInsets.only(top: Space.lg),
                child: Text(
                  S.searchPrompt,
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : results.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: EmptyState(
                  headline: S.searchNone(q),
                  body: S.searchNoneBody,
                  actionLabel: S.clearSearch,
                  onAction: () => setState(_query.clear),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Space.xl),
              children: [
                for (final entry in byGroup.entries)
                  gutter(
                    ListSection(
                      title: groupTitle(entry.key, me),
                      children: [
                        for (final e in entry.value)
                          ExpenseRow(
                            expense: e,
                            memberNames: memberNames(entry.key, me),
                            myMemberId: myMemberIn(entry.key, me),
                            resolve: entry.key.resolve,
                            possibleDuplicate: possibleDuplicatePayments(
                              entry.key,
                            ).contains(e.id),
                            unshared: snap.unsharedEntityIds.contains(e.id),
                            onTap: () => context.push(Routes.expense(e.id)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
